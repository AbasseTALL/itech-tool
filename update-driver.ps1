#Requires -Version 5.1

<#
.SYNOPSIS
    Inventorie les pilotes Windows et installe les mises à jour
    de pilotes proposées par Windows Update / Microsoft Update.

.DESCRIPTION
    Un pilote est considéré comme "obsolète" lorsqu'une mise à jour
    correspondante est proposée par Microsoft Update.

    Le script :
      1. demande automatiquement les droits administrateur ;
      2. inventorie les pilotes installés ;
      3. recherche les mises à jour de pilotes ;
      4. télécharge les mises à jour ;
      5. installe chaque pilote séparément ;
      6. génère des rapports CSV et un journal d'exécution.

.NOTES
    Compatible avec Windows PowerShell 5.1.
    Une confirmation UAC reste obligatoire lors de l'élévation.
#>

# =====================================================================
# CONFIGURATION
# =====================================================================

# URL Raw du présent script dans votre dépôt GitHub public.
$ScriptUrl = "https://raw.githubusercontent.com/AbasseTALL/itech-tool/main/Update-Drivers.ps1"

# Dossier dans lequel les rapports seront enregistrés.
$ReportRoot = Join-Path $env:ProgramData "Windows-Driver-Updater"

# Mettre à $true pour utiliser Microsoft Update.
$UseMicrosoftUpdate = $true

# Le script ne redémarre pas automatiquement par défaut.
$AutomaticRestart = $false

# =====================================================================
# FONCTIONS GÉNÉRALES
# =====================================================================

function Test-IsAdministrator {
    $CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object Security.Principal.WindowsPrincipal(
        $CurrentIdentity
    )

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Start-ElevatedRemoteScript {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    if ($Url -match "VOTRE-UTILISATEUR") {
        throw @"
L'adresse GitHub n'a pas été configurée.

Modifiez la variable `$ScriptUrl au début du script :

https://raw.githubusercontent.com/VOTRE-UTILISATEUR/Windows-Driver-Updater/main/Update-Drivers.ps1
"@
    }

    if ($Url -notmatch "^https://raw\.githubusercontent\.com/") {
        throw "L'URL configurée n'est pas une adresse GitHub Raw valide."
    }

    Write-Host ""
    Write-Host "Des droits administrateur sont nécessaires." `
        -ForegroundColor Yellow
    Write-Host "Affichage de la demande UAC..." `
        -ForegroundColor Yellow

    # La nouvelle instance PowerShell retélécharge le script depuis GitHub.
    $ElevatedCommand = @"
`$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
`$Content = Invoke-RestMethod -Uri '$Url' -UseBasicParsing
Invoke-Expression ([string]`$Content)
"@

    # Encodage UTF-16LE attendu par powershell.exe -EncodedCommand.
    $EncodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($ElevatedCommand)
    )

    $PowerShellPath = Join-Path `
        $PSHOME `
        "powershell.exe"

    Start-Process `
        -FilePath $PowerShellPath `
        -Verb RunAs `
        -ArgumentList @(
            "-NoLogo"
            "-NoProfile"
            "-ExecutionPolicy", "Bypass"
            "-EncodedCommand", $EncodedCommand
        ) |
        Out-Null
}

function Convert-DriverDate {
    param(
        [AllowNull()]
        $Date
    )

    if ($null -eq $Date) {
        return $null
    }

    try {
        if ($Date -is [datetime]) {
            return $Date
        }

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

function Get-UpdateResultText {
    param(
        [int]$ResultCode
    )

    switch ($ResultCode) {
        0 { return "Non commencé" }
        1 { return "En cours" }
        2 { return "Réussi" }
        3 { return "Réussi avec erreurs" }
        4 { return "Échec" }
        5 { return "Annulé" }
        default { return "Code inconnu : $ResultCode" }
    }
}

function Get-ResultColor {
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
        $UnsignedValue = [Convert]::ToUInt32(
            ([int64]$HResult -band 0xFFFFFFFF)
        )

        return "0x{0:X8}" -f $UnsignedValue
    }
    catch {
        return [string]$HResult
    }
}

function Get-ComProperty {
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    try {
        return $Object.$PropertyName
    }
    catch {
        return $null
    }
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

# =====================================================================
# PROGRAMME PRINCIPAL
# =====================================================================

function Invoke-DriverUpdater {
    $PreviousErrorActionPreference = $ErrorActionPreference
    $PreviousProgressPreference = $ProgressPreference

    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue"

    # -----------------------------------------------------------------
    # Élévation administrative
    # -----------------------------------------------------------------

    if (-not (Test-IsAdministrator)) {
        Start-ElevatedRemoteScript -Url $ScriptUrl
        return
    }

    # -----------------------------------------------------------------
    # Préparation des rapports
    # -----------------------------------------------------------------

    $ExecutionDate = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $ReportDirectory = Join-Path $ReportRoot $ExecutionDate

    New-Item `
        -Path $ReportDirectory `
        -ItemType Directory `
        -Force |
        Out-Null

    $InventoryReport = Join-Path `
        $ReportDirectory `
        "01-Pilotes-Installés.csv"

    $AvailableReport = Join-Path `
        $ReportDirectory `
        "02-Pilotes-Obsolètes.csv"

    $InstallationReport = Join-Path `
        $ReportDirectory `
        "03-Résultats-Installation.csv"

    $LogFile = Join-Path `
        $ReportDirectory `
        "Execution.log"

    $TranscriptStarted = $false
    $RestartRequired = $false

    try {
        try {
            Start-Transcript `
                -Path $LogFile `
                -Append |
                Out-Null

            $TranscriptStarted = $true
        }
        catch {
            Write-Warning "Le journal d'exécution n'a pas pu être démarré."
        }

        Write-Section "MISE À JOUR DES PILOTES WINDOWS"

        Write-Host "Ordinateur       : $env:COMPUTERNAME"
        Write-Host "Utilisateur      : $env:USERDOMAIN\$env:USERNAME"
        Write-Host "Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
        Write-Host "Mode             : Administrateur" -ForegroundColor Green
        Write-Host "Rapports         : $ReportDirectory"

        # =============================================================
        # 1. INVENTAIRE DES PILOTES
        # =============================================================

        Write-Section "1. INVENTAIRE DES PILOTES INSTALLÉS"

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
                    Statut       = "Installé"
                }
            } |
            Sort-Object Peripherique, Version
        )

        if ($InstalledDrivers.Count -eq 0) {
            Write-Warning "Aucun pilote Plug-and-Play n'a été trouvé."
        }
        else {
            foreach ($Driver in $InstalledDrivers) {
                Write-Host "[INSTALLÉ] " -NoNewline -ForegroundColor DarkGray
                Write-Host $Driver.Peripherique -NoNewline
                Write-Host " — $($Driver.Version)" -ForegroundColor Gray
            }
        }

        $InstalledDrivers |
            Export-Csv `
                -Path $InventoryReport `
                -NoTypeInformation `
                -Encoding UTF8

        Write-Host ""
        Write-Host "$($InstalledDrivers.Count) pilote(s) inventorié(s)." `
            -ForegroundColor Green

        # =============================================================
        # 2. CONNEXION À WINDOWS UPDATE / MICROSOFT UPDATE
        # =============================================================

        Write-Section "2. CONNEXION AU SERVICE DE MISE À JOUR"

        Write-Host "Création de la session Windows Update..." `
            -ForegroundColor Gray

        $UpdateSession = New-Object `
            -ComObject "Microsoft.Update.Session"

        $UpdateSession.ClientApplicationID = "Windows-Driver-Updater"

        $UpdateSearcher = $UpdateSession.CreateUpdateSearcher()
        $UpdateSource = "Windows Update"

        if ($UseMicrosoftUpdate) {
            try {
                Write-Host "Activation de Microsoft Update..." `
                    -ForegroundColor Gray

                $ServiceManager = New-Object `
                    -ComObject "Microsoft.Update.ServiceManager"

                $ServiceManager.ClientApplicationID = "Windows-Driver-Updater"

                $MicrosoftUpdateServiceId = `
                    "7971f918-a847-4430-9279-4a52d1efe18d"

                $MicrosoftUpdateService = $ServiceManager.AddService2(
                    $MicrosoftUpdateServiceId,
                    7,
                    ""
                )

                # ssOthers = 3 : utilisation d'un service spécifique.
                $UpdateSearcher.ServerSelection = 3
                $UpdateSearcher.ServiceID = $MicrosoftUpdateServiceId

                $UpdateSource = "Microsoft Update"

                Write-Host "Source : Microsoft Update" `
                    -ForegroundColor Green
            }
            catch {
                Write-Warning @"
Microsoft Update n'a pas pu être activé :
$($_.Exception.Message)

Le script utilisera Windows Update.
"@

                # ssWindowsUpdate = 2
                $UpdateSearcher.ServerSelection = 2
                $UpdateSource = "Windows Update"
            }
        }
        else {
            $UpdateSearcher.ServerSelection = 2
            $UpdateSource = "Windows Update"

            Write-Host "Source : Windows Update" `
                -ForegroundColor Green
        }

        # =============================================================
        # 3. RECHERCHE DES MISES À JOUR
        # =============================================================

        Write-Section "3. RECHERCHE DES PILOTES OBSOLÈTES"

        Write-Host "Recherche en cours auprès de $UpdateSource..." `
            -ForegroundColor Yellow

        $SearchCriteria = "IsInstalled=0 and IsHidden=0 and Type='Driver'"

        $SearchResult = $UpdateSearcher.Search($SearchCriteria)
        $UpdateCount = $SearchResult.Updates.Count

        $AvailableUpdates = @()

        if ($UpdateCount -eq 0) {
            Write-Host ""
            Write-Host "[À JOUR] " -NoNewline -ForegroundColor Green
            Write-Host "Aucune mise à jour de pilote n'est proposée par $UpdateSource."

            @() |
                Select-Object `
                    Numero,
                    Pilote,
                    Fabricant,
                    Modele,
                    Classe,
                    VersionProposee,
                    DateVersion,
                    KB,
                    Statut |
                Export-Csv `
                    -Path $AvailableReport `
                    -NoTypeInformation `
                    -Encoding UTF8

            Write-Section "RÉSUMÉ"

            Write-Host "Pilotes inventoriés        : $($InstalledDrivers.Count)"
            Write-Host "Pilotes obsolètes détectés : 0" -ForegroundColor Green
            Write-Host "Installation nécessaire    : Non" -ForegroundColor Green
            Write-Host ""
            Write-Host "Rapports : $ReportDirectory" -ForegroundColor Cyan

            return
        }

        Write-Host ""
        Write-Host "$UpdateCount mise(s) à jour de pilote détectée(s)." `
            -ForegroundColor Yellow
        Write-Host ""

        for ($Index = 0; $Index -lt $UpdateCount; $Index++) {
            $Update = $SearchResult.Updates.Item($Index)

            $DriverManufacturer = Get-ComProperty `
                -Object $Update `
                -PropertyName "DriverManufacturer"

            $DriverModel = Get-ComProperty `
                -Object $Update `
                -PropertyName "DriverModel"

            $DriverClass = Get-ComProperty `
                -Object $Update `
                -PropertyName "DriverClass"

            $DriverVersion = Get-ComProperty `
                -Object $Update `
                -PropertyName "DriverVerVersion"

            $DriverDate = Get-ComProperty `
                -Object $Update `
                -PropertyName "DriverVerDate"

            Write-Host "[OBSOLÈTE] " -NoNewline -ForegroundColor Yellow
            Write-Host $Update.Title -ForegroundColor White

            if ($DriverModel) {
                Write-Host "            Modèle  : $DriverModel" `
                    -ForegroundColor DarkGray
            }

            if ($DriverVersion) {
                Write-Host "            Version : $DriverVersion" `
                    -ForegroundColor DarkGray
            }

            $AvailableUpdates += [PSCustomObject]@{
                Numero           = $Index + 1
                Pilote           = $Update.Title
                Fabricant        = $DriverManufacturer
                Modele           = $DriverModel
                Classe           = $DriverClass
                VersionProposee  = $DriverVersion
                DateVersion      = $DriverDate
                KB               = $Update.KBArticleIDs -join ","
                Identite         = $Update.Identity.UpdateID
                Revision         = $Update.Identity.RevisionNumber
                DejaTelecharge   = $Update.IsDownloaded
                RedemarrageAvant = $Update.RebootRequired
                Statut           = "Obsolète - mise à jour disponible"
            }
        }

        $AvailableUpdates |
            Export-Csv `
                -Path $AvailableReport `
                -NoTypeInformation `
                -Encoding UTF8

        # =============================================================
        # 4. PRÉPARATION ET TÉLÉCHARGEMENT
        # =============================================================

        Write-Section "4. TÉLÉCHARGEMENT DES MISES À JOUR"

        $DownloadCollection = New-Object `
            -ComObject "Microsoft.Update.UpdateColl"

        $SkippedUpdates = @()

        for ($Index = 0; $Index -lt $UpdateCount; $Index++) {
            $Update = $SearchResult.Updates.Item($Index)

            try {
                if (-not $Update.EulaAccepted) {
                    $Update.AcceptEula()
                }

                [void]$DownloadCollection.Add($Update)

                Write-Host "[PRÉPARÉ] " -NoNewline -ForegroundColor Cyan
                Write-Host $Update.Title
            }
            catch {
                Write-Host "[IGNORÉ] " -NoNewline -ForegroundColor Red
                Write-Host $Update.Title

                Write-Warning $_.Exception.Message

                $SkippedUpdates += [PSCustomObject]@{
                    Pilote                = $Update.Title
                    Statut                = "Ignoré"
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
            throw "Aucune mise à jour n'a pu être préparée."
        }

        Write-Host ""
        Write-Host "Téléchargement de $($DownloadCollection.Count) pilote(s)..." `
            -ForegroundColor Yellow

        $Downloader = $UpdateSession.CreateUpdateDownloader()
        $Downloader.Updates = $DownloadCollection

        $DownloadResult = $Downloader.Download()
        $DownloadStatus = Get-UpdateResultText $DownloadResult.ResultCode
        $DownloadColor = Get-ResultColor $DownloadResult.ResultCode

        Write-Host "Résultat du téléchargement : " -NoNewline
        Write-Host $DownloadStatus -ForegroundColor $DownloadColor

        # Les codes 2 et 3 permettent de poursuivre :
        # 2 = réussite ; 3 = réussite avec erreurs.
        if ($DownloadResult.ResultCode -notin 2, 3) {
            throw @"
Le téléchargement des pilotes a échoué.
Code de résultat : $($DownloadResult.ResultCode)
Statut           : $DownloadStatus
"@
        }

        # =============================================================
        # 5. INSTALLATION INDIVIDUELLE
        # =============================================================

        Write-Section "5. INSTALLATION DES PILOTES OBSOLÈTES"

        $InstallationResults = @($SkippedUpdates)

        for (
            $Index = 0;
            $Index -lt $DownloadCollection.Count;
            $Index++
        ) {
            $Update = $DownloadCollection.Item($Index)
            $CurrentNumber = $Index + 1

            Write-Host ""
            Write-Host "[$CurrentNumber/$($DownloadCollection.Count)] " `
                -NoNewline `
                -ForegroundColor Cyan

            Write-Host $Update.Title

            if (-not $Update.IsDownloaded) {
                Write-Host "[ÉCHEC] " -NoNewline -ForegroundColor Red
                Write-Host "Le pilote n'a pas été téléchargé."

                $InstallationResults += [PSCustomObject]@{
                    Pilote                = $Update.Title
                    Statut                = "Échec du téléchargement"
                    Code                  = $null
                    HResult               = $null
                    Message               = "Le fichier n'est pas téléchargé."
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

                Write-Host "Installation..." -ForegroundColor Gray

                $InstallResult = $Installer.Install()
                $ResultCode = [int]$InstallResult.ResultCode
                $ResultText = Get-UpdateResultText $ResultCode
                $ResultColor = Get-ResultColor $ResultCode

                try {
                    $IndividualResult = $InstallResult.GetUpdateResult(0)
                    $HResult = $IndividualResult.HResult
                }
                catch {
                    $HResult = Get-ComProperty `
                        -Object $InstallResult `
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
                    Write-Host "            Redémarrage nécessaire" `
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
                Write-Host "[ÉCHEC] " -NoNewline -ForegroundColor Red
                Write-Host $Update.Title

                Write-Warning $_.Exception.Message

                $InstallationResults += [PSCustomObject]@{
                    Pilote                = $Update.Title
                    Statut                = "Échec"
                    Code                  = $null
                    HResult               = Convert-HResultToHex `
                                                $_.Exception.HResult
                    Message               = $_.Exception.Message
                    RedemarrageNecessaire = $false
                    Date                  = Get-Date
                }
            }
        }

        $InstallationResults |
            Export-Csv `
                -Path $InstallationReport `
                -NoTypeInformation `
                -Encoding UTF8

        # =============================================================
        # 6. RÉSUMÉ
        # =============================================================

        Write-Section "6. RÉSUMÉ"

        $SuccessCount = @(
            $InstallationResults |
            Where-Object {
                $_.Code -eq 2
            }
        ).Count

        $PartialSuccessCount = @(
            $InstallationResults |
            Where-Object {
                $_.Code -eq 3
            }
        ).Count

        $FailureCount = @(
            $InstallationResults |
            Where-Object {
                $_.Statut -in @(
                    "Échec",
                    "Échec du téléchargement",
                    "Ignoré"
                ) -or $_.Code -eq 4
            }
        ).Count

        Write-Host "Pilotes installés détectés : $($InstalledDrivers.Count)"
        Write-Host "Mises à jour détectées     : $UpdateCount" `
            -ForegroundColor Yellow
        Write-Host "Installations réussies     : $SuccessCount" `
            -ForegroundColor Green
        Write-Host "Réussites avec erreurs     : $PartialSuccessCount" `
            -ForegroundColor Yellow
        Write-Host "Échecs ou pilotes ignorés  : $FailureCount" `
            -ForegroundColor $(if ($FailureCount) { "Red" } else { "Green" })

        Write-Host ""
        Write-Host "Rapport des pilotes installés :" `
            -ForegroundColor Cyan
        Write-Host "  $InventoryReport"

        Write-Host "Rapport des pilotes obsolètes :" `
            -ForegroundColor Cyan
        Write-Host "  $AvailableReport"

        Write-Host "Rapport des installations :" `
            -ForegroundColor Cyan
        Write-Host "  $InstallationReport"

        Write-Host "Journal d'exécution :" `
            -ForegroundColor Cyan
        Write-Host "  $LogFile"

        if ($RestartRequired) {
            Write-Host ""
            Write-Host "[REDÉMARRAGE NÉCESSAIRE]" `
                -ForegroundColor Yellow

            if ($AutomaticRestart) {
                Write-Host "Redémarrage automatique dans 30 secondes..." `
                    -ForegroundColor Yellow

                shutdown.exe /r /t 30 /c `
                    "Redémarrage requis après la mise à jour des pilotes."
            }
            else {
                Write-Host @"
Un ou plusieurs pilotes nécessitent un redémarrage.
Le redémarrage automatique est désactivé.
"@ -ForegroundColor Yellow
            }
        }
        else {
            Write-Host ""
            Write-Host "Aucun redémarrage demandé." `
                -ForegroundColor Green
        }
    }
    catch {
        Write-Host ""
        Write-Host "[ERREUR CRITIQUE]" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red

        Write-Host ""
        Write-Host "Consultez le journal :" -ForegroundColor Yellow
        Write-Host $LogFile
    }
    finally {
        if ($TranscriptStarted) {
            try {
                Stop-Transcript | Out-Null
            }
            catch {
                # Le transcript était peut-être déjà arrêté.
            }
        }

        $ErrorActionPreference = $PreviousErrorActionPreference
        $ProgressPreference = $PreviousProgressPreference
    }
}

# =====================================================================
# DÉMARRAGE
# =====================================================================

Invoke-DriverUpdater
