#Requires -Version 5.1

<#
.SYNOPSIS
    Inventorie et met à jour les pilotes Windows.

.DESCRIPTION
    - S'élève automatiquement en administrateur via l'UAC.
    - Liste les pilotes installés.
    - Recherche les mises à jour de pilotes proposées par Microsoft Update.
    - Marque les mises à jour disponibles comme [OBSOLETE].
    - Télécharge et installe chaque pilote.
    - Génère des rapports CSV et un journal d'exécution.

.EXAMPLE
    irm "https://raw.githubusercontent.com/AbasseTALL/itech-tool/main/Update-Drivers.ps1" | iex
#>

# =====================================================================
# CONFIGURATION
# =====================================================================

$GitHubOwner      = "AbasseTALL"
$GitHubRepository = "itech-tool"
$GitHubBranch     = "main"
$GitHubScriptPath = "Update-Drivers.ps1"

$ScriptUrl = "https://raw.githubusercontent.com/$GitHubOwner/$GitHubRepository/$GitHubBranch/$GitHubScriptPath"

$ReportRoot = Join-Path $env:ProgramData "itech-tool\Driver-Updater"

# Utiliser le catalogue Microsoft Update.
$UseMicrosoftUpdate = $true

# Redémarrer automatiquement si une mise à jour le demande.
$AutomaticRestart = $false

# Délai avant le redémarrage automatique.
$RestartDelaySeconds = 60

# =====================================================================
# PARAMÈTRES GÉNÉRAUX
# =====================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =====================================================================
# FONCTIONS
# =====================================================================

function Test-IsAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        Security.Principal.WindowsPrincipal($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Start-ElevatedScript {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    if ($GitHubOwner -eq "VOTRE-UTILISATEUR") {
        throw @"
Le propriétaire GitHub n'a pas été configuré.

Modifiez cette ligne dans Update-Drivers.ps1 :

`$GitHubOwner = "VOTRE-UTILISATEUR"
"@
    }

    if ($Url -notmatch '^https://raw\.githubusercontent\.com/') {
        throw "L'adresse du script n'est pas une URL GitHub Raw valide."
    }

    Write-Host ""
    Write-Host "[ADMINISTRATEUR REQUIS]" -ForegroundColor Yellow
    Write-Host "Affichage de la demande UAC..." -ForegroundColor Yellow

    $EscapedUrl = $Url.Replace("'", "''")

    $ElevatedCode = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
`$ScriptContent = Invoke-RestMethod -Uri '$EscapedUrl' -UseBasicParsing
Invoke-Expression ([string]`$ScriptContent)
"@

    $EncodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($ElevatedCode)
    )

    $PowerShellExe = Join-Path `
        $env:SystemRoot `
        "System32\WindowsPowerShell\v1.0\powershell.exe"

    Start-Process `
        -FilePath $PowerShellExe `
        -Verb RunAs `
        -ArgumentList @(
            "-NoLogo"
            "-NoProfile"
            "-ExecutionPolicy", "Bypass"
            "-EncodedCommand", $EncodedCommand
        ) |
        Out-Null
}

function Write-Section {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
}

function Convert-DriverDate {
    param(
        [AllowNull()]
        $Date
    )

    if ($null -eq $Date) {
        return $null
    }

    if ($Date -is [datetime]) {
        return $Date
    }

    try {
        return [Management.ManagementDateTimeConverter]::ToDateTime(
            [string]$Date
        )
    }
    catch {
        try {
            return [datetime]$Date
        }
        catch {
            return $Date
        }
    }
}

function Get-ComProperty {
    param(
        [Parameter(Mandatory)]
        $InputObject,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    try {
        return $InputObject.$PropertyName
    }
    catch {
        return $null
    }
}

function Get-UpdateResultText {
    param(
        [int]$ResultCode
    )

    switch ($ResultCode) {
        0 { return "Non commence" }
        1 { return "En cours" }
        2 { return "Reussi" }
        3 { return "Reussi avec erreurs" }
        4 { return "Echec" }
        5 { return "Annule" }
        default { return "Code inconnu : $ResultCode" }
    }
}

function Get-UpdateResultColor {
    param(
        [int]$ResultCode
    )

    switch ($ResultCode) {
        2 { return "Green" }
        3 { return "Yellow" }
        default { return "Red" }
    }
}

function Convert-HResultToHex {
    param(
        [AllowNull()]
        $HResult
    )

    if ($null -eq $HResult) {
        return $null
    }

    try {
        $Value = [uint32]([int64]$HResult -band 0xFFFFFFFFL)
        return "0x{0:X8}" -f $Value
    }
    catch {
        return [string]$HResult
    }
}

function Export-EmptyCsv {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$Columns
    )

    $Header = ($Columns | ForEach-Object {
        '"{0}"' -f $_.Replace('"', '""')
    }) -join ","

    Set-Content `
        -Path $Path `
        -Value $Header `
        -Encoding UTF8
}

# =====================================================================
# ÉLÉVATION ADMINISTRATEUR
# =====================================================================

if (-not (Test-IsAdministrator)) {
    try {
        Start-ElevatedScript -Url $ScriptUrl
    }
    catch {
        Write-Host ""
        Write-Host "[ERREUR]" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }

    return
}

# =====================================================================
# PRÉPARATION DES RAPPORTS
# =====================================================================

$ExecutionDate = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$ReportDirectory = Join-Path $ReportRoot $ExecutionDate

New-Item `
    -Path $ReportDirectory `
    -ItemType Directory `
    -Force |
    Out-Null

$InventoryReport = Join-Path `
    $ReportDirectory `
    "01-Pilotes-Installes.csv"

$AvailableReport = Join-Path `
    $ReportDirectory `
    "02-Pilotes-Obsoletes.csv"

$InstallationReport = Join-Path `
    $ReportDirectory `
    "03-Resultats-Installation.csv"

$LogFile = Join-Path `
    $ReportDirectory `
    "Execution.log"

$TranscriptStarted = $false
$RestartRequired = $false
$InstalledDrivers = @()
$AvailableUpdates = @()
$InstallationResults = @()

# =====================================================================
# PROGRAMME PRINCIPAL
# =====================================================================

try {
    try {
        Start-Transcript `
            -Path $LogFile `
            -Append |
            Out-Null

        $TranscriptStarted = $true
    }
    catch {
        Write-Warning "Le journal d'execution n'a pas pu etre demarre."
    }

    Write-Section "ITECH-TOOL - MISE A JOUR DES PILOTES"

    Write-Host "Ordinateur  : $env:COMPUTERNAME"
    Write-Host "Utilisateur : $env:USERDOMAIN\$env:USERNAME"
    Write-Host "Execution   : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
    Write-Host "Privileges  : Administrateur" -ForegroundColor Green
    Write-Host "Rapports    : $ReportDirectory"

    # =================================================================
    # 1. INVENTAIRE DES PILOTES
    # =================================================================

    Write-Section "1. PILOTES INSTALLES"

    Write-Host "Lecture des pilotes Plug-and-Play..." `
        -ForegroundColor Gray

    $InstalledDrivers = @(
        Get-CimInstance `
            -ClassName Win32_PnPSignedDriver `
            -ErrorAction Stop |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.DeviceName)
        } |
        ForEach-Object {
            [PSCustomObject]@{
                Peripherique = $_.DeviceName
                Fabricant    = $_.Manufacturer
                Fournisseur  = $_.DriverProviderName
                Classe       = $_.DeviceClass
                Version      = $_.DriverVersion
                DatePilote   = Convert-DriverDate $_.DriverDate
                FichierINF   = $_.InfName
                DeviceID     = $_.DeviceID
                Signe        = $_.IsSigned
                Statut       = "Installe"
            }
        } |
        Sort-Object Peripherique, Version
    )

    foreach ($Driver in $InstalledDrivers) {
        Write-Host "[INSTALLE] " `
            -NoNewline `
            -ForegroundColor DarkGray

        Write-Host $Driver.Peripherique `
            -NoNewline `
            -ForegroundColor White

        Write-Host " - Version $($Driver.Version)" `
            -ForegroundColor Gray
    }

    if ($InstalledDrivers.Count -gt 0) {
        $InstalledDrivers |
            Export-Csv `
                -Path $InventoryReport `
                -NoTypeInformation `
                -Encoding UTF8
    }
    else {
        Export-EmptyCsv `
            -Path $InventoryReport `
            -Columns @(
                "Peripherique",
                "Fabricant",
                "Fournisseur",
                "Classe",
                "Version",
                "DatePilote",
                "FichierINF",
                "DeviceID",
                "Signe",
                "Statut"
            )
    }

    Write-Host ""
    Write-Host "$($InstalledDrivers.Count) pilote(s) inventorie(s)." `
        -ForegroundColor Green

    # =================================================================
    # 2. CONNEXION AU SERVICE DE MISE À JOUR
    # =================================================================

    Write-Section "2. CONNEXION AU SERVICE DE MISE A JOUR"

    $UpdateSession = New-Object `
        -ComObject "Microsoft.Update.Session"

    $UpdateSession.ClientApplicationID = "itech-tool Driver Updater"

    $UpdateSearcher = $UpdateSession.CreateUpdateSearcher()
    $UpdateSource = "Windows Update"

    if ($UseMicrosoftUpdate) {
        try {
            Write-Host "Activation de Microsoft Update..." `
                -ForegroundColor Gray

            $ServiceManager = New-Object `
                -ComObject "Microsoft.Update.ServiceManager"

            $ServiceManager.ClientApplicationID = `
                "itech-tool Driver Updater"

            $MicrosoftUpdateServiceId = `
                "7971f918-a847-4430-9279-4a52d1efe18d"

            try {
                $null = $ServiceManager.AddService2(
                    $MicrosoftUpdateServiceId,
                    7,
                    ""
                )
            }
            catch {
                # Le service peut déjà être enregistré.
                Write-Host "Microsoft Update est deja enregistre." `
                    -ForegroundColor DarkGray
            }

            # ssOthers = 3
            $UpdateSearcher.ServerSelection = 3
            $UpdateSearcher.ServiceID = $MicrosoftUpdateServiceId

            $UpdateSource = "Microsoft Update"

            Write-Host "Source selectionnee : Microsoft Update" `
                -ForegroundColor Green
        }
        catch {
            Write-Warning @"
Microsoft Update n'a pas pu etre active.
Utilisation de Windows Update.

Detail : $($_.Exception.Message)
"@

            # ssWindowsUpdate = 2
            $UpdateSearcher.ServerSelection = 2
            $UpdateSource = "Windows Update"
        }
    }
    else {
        $UpdateSearcher.ServerSelection = 2

        Write-Host "Source selectionnee : Windows Update" `
            -ForegroundColor Green
    }

    # =================================================================
    # 3. RECHERCHE DES PILOTES OBSOLÈTES
    # =================================================================

    Write-Section "3. RECHERCHE DES PILOTES OBSOLETES"

    Write-Host "Recherche en cours aupres de $UpdateSource..." `
        -ForegroundColor Yellow

    $SearchCriteria = `
        "IsInstalled=0 and IsHidden=0 and Type='Driver'"

    $SearchResult = $UpdateSearcher.Search($SearchCriteria)
    $UpdateCount = $SearchResult.Updates.Count

    if ($UpdateCount -eq 0) {
        Write-Host ""
        Write-Host "[A JOUR] " `
            -NoNewline `
            -ForegroundColor Green

        Write-Host "Aucune mise a jour de pilote n'est disponible."

        Export-EmptyCsv `
            -Path $AvailableReport `
            -Columns @(
                "Numero",
                "Pilote",
                "Fabricant",
                "Modele",
                "Classe",
                "VersionProposee",
                "DateVersion",
                "KB",
                "Identite",
                "Revision",
                "Statut"
            )
    }
    else {
        Write-Host ""
        Write-Host "$UpdateCount mise(s) a jour disponible(s)." `
            -ForegroundColor Yellow

        for ($Index = 0; $Index -lt $UpdateCount; $Index++) {
            $Update = $SearchResult.Updates.Item($Index)

            $Manufacturer = Get-ComProperty `
                -InputObject $Update `
                -PropertyName "DriverManufacturer"

            $Model = Get-ComProperty `
                -InputObject $Update `
                -PropertyName "DriverModel"

            $Class = Get-ComProperty `
                -InputObject $Update `
                -PropertyName "DriverClass"

            $ProposedVersion = Get-ComProperty `
                -InputObject $Update `
                -PropertyName "DriverVerVersion"

            $ProposedDate = Get-ComProperty `
                -InputObject $Update `
                -PropertyName "DriverVerDate"

            Write-Host ""
            Write-Host "[OBSOLETE] " `
                -NoNewline `
                -ForegroundColor Yellow

            Write-Host $Update.Title -ForegroundColor White

            if ($Manufacturer) {
                Write-Host "           Fabricant : $Manufacturer" `
                    -ForegroundColor DarkGray
            }

            if ($Model) {
                Write-Host "           Modele    : $Model" `
                    -ForegroundColor DarkGray
            }

            if ($ProposedVersion) {
                Write-Host "           Version   : $ProposedVersion" `
                    -ForegroundColor DarkGray
            }

            $AvailableUpdates += [PSCustomObject]@{
                Numero           = $Index + 1
                Pilote           = $Update.Title
                Fabricant        = $Manufacturer
                Modele           = $Model
                Classe           = $Class
                VersionProposee  = $ProposedVersion
                DateVersion      = $ProposedDate
                KB               = $Update.KBArticleIDs -join ","
                Identite         = $Update.Identity.UpdateID
                Revision         = $Update.Identity.RevisionNumber
                DejaTelecharge   = $Update.IsDownloaded
                RedemarrageAvant = $Update.RebootRequired
                Statut           = "Obsolete - mise a jour disponible"
            }
        }

        $AvailableUpdates |
            Export-Csv `
                -Path $AvailableReport `
                -NoTypeInformation `
                -Encoding UTF8
    }

    # =================================================================
    # 4. TÉLÉCHARGEMENT
    # =================================================================

    if ($UpdateCount -gt 0) {
        Write-Section "4. TELECHARGEMENT DES PILOTES"

        $DownloadCollection = New-Object `
            -ComObject "Microsoft.Update.UpdateColl"

        for ($Index = 0; $Index -lt $UpdateCount; $Index++) {
            $Update = $SearchResult.Updates.Item($Index)

            try {
                if (-not $Update.EulaAccepted) {
                    $Update.AcceptEula()
                }

                [void]$DownloadCollection.Add($Update)

                Write-Host "[PREPARE] " `
                    -NoNewline `
                    -ForegroundColor Cyan

                Write-Host $Update.Title
            }
            catch {
                Write-Host "[IGNORE] " `
                    -NoNewline `
                    -ForegroundColor Red

                Write-Host $Update.Title

                $InstallationResults += [PSCustomObject]@{
                    Pilote                = $Update.Title
                    Statut                = "Ignore"
                    Code                  = $null
                    HResult               = Convert-HResultToHex `
                                                $_.Exception.HResult
                    Message               = $_.Exception.Message
                    RedemarrageNecessaire = $false
                    Date                  = Get-Date
                }
            }
        }

        if ($DownloadCollection.Count -eq 0) {
            throw "Aucune mise a jour n'a pu etre preparee."
        }

        Write-Host ""
        Write-Host "Telechargement de $($DownloadCollection.Count) pilote(s)..." `
            -ForegroundColor Yellow

        $Downloader = $UpdateSession.CreateUpdateDownloader()
        $Downloader.Updates = $DownloadCollection

        $DownloadResult = $Downloader.Download()
        $DownloadCode = [int]$DownloadResult.ResultCode
        $DownloadText = Get-UpdateResultText $DownloadCode
        $DownloadColor = Get-UpdateResultColor $DownloadCode

        Write-Host "Telechargement : " -NoNewline
        Write-Host $DownloadText -ForegroundColor $DownloadColor

        if ($DownloadCode -notin 2, 3) {
            throw @"
Le telechargement des pilotes a echoue.
Code   : $DownloadCode
Statut : $DownloadText
"@
        }

        # =============================================================
        # 5. INSTALLATION
        # =============================================================

        Write-Section "5. INSTALLATION DES PILOTES OBSOLETES"

        for (
            $Index = 0;
            $Index -lt $DownloadCollection.Count;
            $Index++
        ) {
            $Update = $DownloadCollection.Item($Index)
            $Number = $Index + 1

            Write-Host ""
            Write-Host "[$Number/$($DownloadCollection.Count)] " `
                -NoNewline `
                -ForegroundColor Cyan

            Write-Host "[MISE A JOUR] " `
                -NoNewline `
                -ForegroundColor Yellow

            Write-Host $Update.Title

            if (-not $Update.IsDownloaded) {
                Write-Host "[ECHEC] Pilote non telecharge." `
                    -ForegroundColor Red

                $InstallationResults += [PSCustomObject]@{
                    Pilote                = $Update.Title
                    Statut                = "Echec du telechargement"
                    Code                  = $null
                    HResult               = $null
                    Message               = "Le pilote n'a pas ete telecharge."
                    RedemarrageNecessaire = $false
                    Date                  = Get-Date
                }

                continue
            }

            try {
                $SingleUpdateCollection = New-Object `
                    -ComObject "Microsoft.Update.UpdateColl"

                [void]$SingleUpdateCollection.Add($Update)

                $Installer = $UpdateSession.CreateUpdateInstaller()
                $Installer.Updates = $SingleUpdateCollection

                Write-Host "Installation en cours..." `
                    -ForegroundColor Gray

                $InstallResult = $Installer.Install()

                $ResultCode = [int]$InstallResult.ResultCode
                $ResultText = Get-UpdateResultText $ResultCode
                $ResultColor = Get-UpdateResultColor $ResultCode

                $HResult = $null

                try {
                    $IndividualResult = `
                        $InstallResult.GetUpdateResult(0)

                    $HResult = $IndividualResult.HResult
                }
                catch {
                    $HResult = Get-ComProperty `
                        -InputObject $InstallResult `
                        -PropertyName "HResult"
                }

                if ($InstallResult.RebootRequired) {
                    $RestartRequired = $true
                }

                Write-Host "[$ResultText] " `
                    -NoNewline `
                    -ForegroundColor $ResultColor

                Write-Host $Update.Title

                if ($InstallResult.RebootRequired) {
                    Write-Host "Redemarrage necessaire." `
                        -ForegroundColor Yellow
                }

                $InstallationResults += [PSCustomObject]@{
                    Pilote                = $Update.Title
                    Statut                = $ResultText
                    Code                  = $ResultCode
                    HResult               = Convert-HResultToHex $HResult
                    Message               = $null
                    RedemarrageNecessaire = $InstallResult.RebootRequired
                    Date                  = Get-Date
                }
            }
            catch {
                Write-Host "[ECHEC] " `
                    -NoNewline `
                    -ForegroundColor Red

                Write-Host $Update.Title

                Write-Warning $_.Exception.Message

                $InstallationResults += [PSCustomObject]@{
                    Pilote                = $Update.Title
                    Statut                = "Echec"
                    Code                  = $null
                    HResult               = Convert-HResultToHex `
                                                $_.Exception.HResult
                    Message               = $_.Exception.Message
                    RedemarrageNecessaire = $false
                    Date                  = Get-Date
                }
            }
        }
    }

    # =================================================================
    # 6. RAPPORT D'INSTALLATION
    # =================================================================

    if ($InstallationResults.Count -gt 0) {
        $InstallationResults |
            Export-Csv `
                -Path $InstallationReport `
                -NoTypeInformation `
                -Encoding UTF8
    }
    else {
        Export-EmptyCsv `
            -Path $InstallationReport `
            -Columns @(
                "Pilote",
                "Statut",
                "Code",
                "HResult",
                "Message",
                "RedemarrageNecessaire",
                "Date"
            )
    }

    # =================================================================
    # 7. RÉSUMÉ
    # =================================================================

    Write-Section "6. RESUME"

    $SuccessCount = @(
        $InstallationResults |
        Where-Object {
            $_.Code -eq 2
        }
    ).Count

    $PartialCount = @(
        $InstallationResults |
        Where-Object {
            $_.Code -eq 3
        }
    ).Count

    $FailureCount = @(
        $InstallationResults |
        Where-Object {
            $_.Code -eq 4 -or
            $_.Statut -in @(
                "Echec",
                "Echec du telechargement",
                "Ignore"
            )
        }
    ).Count

    Write-Host "Pilotes inventories      : $($InstalledDrivers.Count)"
    Write-Host "Pilotes obsoletes        : $UpdateCount" `
        -ForegroundColor $(if ($UpdateCount -gt 0) {
            "Yellow"
        }
        else {
            "Green"
        })

    Write-Host "Installations reussies   : $SuccessCount" `
        -ForegroundColor Green

    Write-Host "Reussies avec erreurs    : $PartialCount" `
        -ForegroundColor $(if ($PartialCount -gt 0) {
            "Yellow"
        }
        else {
            "Green"
        })

    Write-Host "Echecs ou pilotes ignores: $FailureCount" `
        -ForegroundColor $(if ($FailureCount -gt 0) {
            "Red"
        }
        else {
            "Green"
        })

    Write-Host ""
    Write-Host "Rapport des pilotes installes :" `
        -ForegroundColor Cyan
    Write-Host "  $InventoryReport"

    Write-Host "Rapport des pilotes obsoletes :" `
        -ForegroundColor Cyan
    Write-Host "  $AvailableReport"

    Write-Host "Rapport d'installation :" `
        -ForegroundColor Cyan
    Write-Host "  $InstallationReport"

    Write-Host "Journal d'execution :" `
        -ForegroundColor Cyan
    Write-Host "  $LogFile"

    # =================================================================
    # 8. REDÉMARRAGE
    # =================================================================

    if ($RestartRequired) {
        Write-Host ""
        Write-Host "[REDEMARRAGE NECESSAIRE]" `
            -ForegroundColor Yellow

        if ($AutomaticRestart) {
            Write-Host @"
L'ordinateur redemarrera dans $RestartDelaySeconds seconde(s).
Pour annuler : shutdown /a
"@ -ForegroundColor Yellow

            shutdown.exe `
                /r `
                /t $RestartDelaySeconds `
                /c "Redemarrage requis apres la mise a jour des pilotes."
        }
        else {
            Write-Host @"
Un ou plusieurs pilotes necessitent un redemarrage.
Le redemarrage automatique est desactive.
"@ -ForegroundColor Yellow
        }
    }
    else {
        Write-Host ""
        Write-Host "Aucun redemarrage n'est necessaire." `
            -ForegroundColor Green
    }
}
catch {
    Write-Host ""
    Write-Host "[ERREUR CRITIQUE]" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    Write-Host ""
    Write-Host "Journal disponible dans :" `
        -ForegroundColor Yellow
    Write-Host $LogFile
}
finally {
    if ($TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            # Le transcript est peut-être déjà arrêté.
        }
    }
}
