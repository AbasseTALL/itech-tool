#Requires -Version 5.1

<#
.SYNOPSIS
    Déplace ou copie les fichiers personnels de Windows.old
    vers les dossiers correspondants du profil Windows actuel.

.DESCRIPTION
    Correspondances prises en charge :
      Desktop / Bureau       -> Bureau actuel
      Documents              -> Documents actuels
      Downloads              -> Téléchargements actuels
      Pictures               -> Images actuelles
      Music                  -> Musique actuelle
      Videos                 -> Vidéos actuelles
      Favorites              -> Favoris actuels
      Contacts               -> Contacts actuels
      Links                  -> Liens actuels
      Saved Games            -> Parties enregistrées actuelles
      Searches               -> Recherches actuelles

    Le mode Déplacer est proposé par défaut.

    Les fichiers existants ne sont pas écrasés. En cas de conflit,
    le fichier provenant de Windows.old est renommé automatiquement.

.EXAMPLE
    irm "https://raw.githubusercontent.com/AbasseTALL/itech-tool/main/Restore-WindowsOldFiles.ps1" | iex
#>

# =====================================================================
# CONFIGURATION
# =====================================================================

$GitHubOwner      = "AbasseTALL"
$GitHubRepository = "itech-tool"
$GitHubBranch     = "main"
$GitHubScriptPath = "Restore-WindowsOldFiles.ps1"

$ScriptUrl = "https://raw.githubusercontent.com/$GitHubOwner/$GitHubRepository/$GitHubBranch/$GitHubScriptPath"

$WindowsOldPath = "C:\Windows.old"

$ReportRoot = Join-Path `
    $env:ProgramData `
    "itech-tool\WindowsOld-Restore"

# Move : déplacement proposé par défaut.
# Copy : copie proposée par défaut.
$PreferredMode = "Move"

# Renomme automatiquement les fichiers en conflit.
$RenameConflictingFiles = $true

# Nombre de traitements parallèles Robocopy.
$RobocopyThreads = 8

# Nombre de nouvelles tentatives en cas d'erreur.
$RobocopyRetries = 2

# Délai entre les tentatives.
$RobocopyWaitSeconds = 2

# Nettoyer les dossiers sources devenus vides après le déplacement.
$RemoveEmptySourceDirectories = $true

# =====================================================================
# PARAMÈTRES POWERSHELL
# =====================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

[Net.ServicePointManager]::SecurityProtocol = `
    [Net.SecurityProtocolType]::Tls12

# =====================================================================
# FONCTIONS GÉNÉRALES
# =====================================================================

function Test-IsAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        Security.Principal.WindowsPrincipal($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
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

function Wait-ForEnter {
    Write-Host ""

    try {
        [void](Read-Host "Appuyez sur Entree pour fermer")
    }
    catch {
        # Console non interactive.
    }
}

function Get-RegistryKnownFolder {
    param(
        [Parameter(Mandatory)]
        [string]$ValueName,

        [Parameter(Mandatory)]
        [string]$Fallback
    )

    $RegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"

    try {
        $Value = Get-ItemPropertyValue `
            -Path $RegistryPath `
            -Name $ValueName `
            -ErrorAction Stop

        $ExpandedValue = [Environment]::ExpandEnvironmentVariables(
            [string]$Value
        )

        if (-not [string]::IsNullOrWhiteSpace($ExpandedValue)) {
            return $ExpandedValue
        }
    }
    catch {
        # Utilisation du chemin de secours.
    }

    return $Fallback
}

function Get-CurrentUserFolderMap {
    $Profile = $env:USERPROFILE

    $Desktop = [Environment]::GetFolderPath("Desktop")

    if ([string]::IsNullOrWhiteSpace($Desktop)) {
        $Desktop = Join-Path $Profile "Desktop"
    }

    $Documents = [Environment]::GetFolderPath("MyDocuments")

    if ([string]::IsNullOrWhiteSpace($Documents)) {
        $Documents = Join-Path $Profile "Documents"
    }

    $Pictures = [Environment]::GetFolderPath("MyPictures")

    if ([string]::IsNullOrWhiteSpace($Pictures)) {
        $Pictures = Join-Path $Profile "Pictures"
    }

    $Music = [Environment]::GetFolderPath("MyMusic")

    if ([string]::IsNullOrWhiteSpace($Music)) {
        $Music = Join-Path $Profile "Music"
    }

    $Videos = [Environment]::GetFolderPath("MyVideos")

    if ([string]::IsNullOrWhiteSpace($Videos)) {
        $Videos = Join-Path $Profile "Videos"
    }

    $Favorites = [Environment]::GetFolderPath("Favorites")

    if ([string]::IsNullOrWhiteSpace($Favorites)) {
        $Favorites = Join-Path $Profile "Favorites"
    }

    $Downloads = Get-RegistryKnownFolder `
        -ValueName "{374DE290-123F-4565-9164-39C4925E467B}" `
        -Fallback (Join-Path $Profile "Downloads")

    return [ordered]@{
        Profile    = $Profile
        Desktop    = $Desktop
        Documents  = $Documents
        Downloads  = $Downloads
        Pictures   = $Pictures
        Music      = $Music
        Videos     = $Videos
        Favorites  = $Favorites
        Contacts   = Join-Path $Profile "Contacts"
        Links      = Join-Path $Profile "Links"
        SavedGames = Join-Path $Profile "Saved Games"
        Searches   = Join-Path $Profile "Searches"
    }
}

function ConvertTo-EncodedText {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    return [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($Text)
    )
}

function ConvertFrom-EncodedText {
    param(
        [Parameter(Mandatory)]
        [string]$EncodedText
    )

    return [Text.Encoding]::Unicode.GetString(
        [Convert]::FromBase64String($EncodedText)
    )
}

# =====================================================================
# ÉLÉVATION ADMINISTRATEUR
# =====================================================================

function Start-ElevatedScript {
    param(
        [Parameter(Mandatory)]
        $CurrentFolderMap
    )

    Write-Host ""
    Write-Host "[ADMINISTRATEUR REQUIS]" -ForegroundColor Yellow
    Write-Host "Affichage de la demande UAC..." -ForegroundColor Yellow

    # Conservation des destinations du véritable utilisateur.
    # Cela évite de restaurer les fichiers dans le profil d'un autre
    # administrateur si des identifiants différents sont utilisés à l'UAC.
    $FolderMapJson = $CurrentFolderMap |
        ConvertTo-Json -Compress

    $EncodedFolderMap = ConvertTo-EncodedText `
        -Text $FolderMapJson

    $EscapedFolderMap = $EncodedFolderMap.Replace("'", "''")

    $IsLocalScript = (
        -not [string]::IsNullOrWhiteSpace($PSCommandPath) -and
        (Test-Path -LiteralPath $PSCommandPath)
    )

    if ($IsLocalScript) {
        $EscapedLocalPath = $PSCommandPath.Replace("'", "''")

        $ElevatedCode = @"
`$env:ITECH_FOLDER_MAP = '$EscapedFolderMap'
& '$EscapedLocalPath'
"@
    }
    else {
        if (
            $GitHubOwner -eq "AbasseTALL" -or
            $ScriptUrl -match "AbasseTALL"
        ) {
            throw @"
Le propriétaire GitHub n'a pas été configuré.

Remplacez :

`$GitHubOwner = "AbasseTALL"

par le propriétaire réel du dépôt itech-tool.
"@
        }

        if ($ScriptUrl -notmatch '^https://raw\.githubusercontent\.com/') {
            throw "L'adresse GitHub Raw configurée n'est pas valide."
        }

        $EscapedUrl = $ScriptUrl.Replace("'", "''")

        $ElevatedCode = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$env:ITECH_FOLDER_MAP = '$EscapedFolderMap'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
`$ScriptContent = Invoke-RestMethod -Uri '$EscapedUrl' -UseBasicParsing
Invoke-Expression ([string]`$ScriptContent)
"@
    }

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

# =====================================================================
# PROFILS WINDOWS.OLD
# =====================================================================

function Get-OldUserProfiles {
    param(
        [Parameter(Mandatory)]
        [string]$UsersPath
    )

    $ExcludedProfiles = @(
        "All Users",
        "Default",
        "Default User",
        "defaultuser0",
        "Public",
        "WDAGUtilityAccount"
    )

    return @(
        Get-ChildItem `
            -LiteralPath $UsersPath `
            -Directory `
            -Force `
            -ErrorAction Stop |
        Where-Object {
            $_.Name -notin $ExcludedProfiles -and
            -not (
                $_.Attributes -band
                [IO.FileAttributes]::ReparsePoint
            )
        } |
        Sort-Object Name
    )
}

function Select-OldUserProfile {
    param(
        [Parameter(Mandatory)]
        [array]$Profiles,

        [Parameter(Mandatory)]
        [string]$TargetProfileName
    )

    if ($Profiles.Count -eq 0) {
        throw "Aucun profil utilisateur n'a été trouvé dans Windows.old."
    }

    # Sélection automatique si le nom correspond au profil actuel.
    $MatchingProfile = @(
        $Profiles |
        Where-Object {
            $_.Name -eq $TargetProfileName
        }
    )

    if ($MatchingProfile.Count -eq 1) {
        Write-Host "Profil correspondant détecté automatiquement :" `
            -ForegroundColor Green

        Write-Host "  $($MatchingProfile[0].FullName)"

        return $MatchingProfile[0]
    }

    if ($Profiles.Count -eq 1) {
        Write-Host "Ancien profil détecté :" -ForegroundColor Green
        Write-Host "  $($Profiles[0].FullName)"

        return $Profiles[0]
    }

    Write-Host "Plusieurs anciens profils ont été détectés :"
    Write-Host ""

    for ($Index = 0; $Index -lt $Profiles.Count; $Index++) {
        Write-Host "[$($Index + 1)] " `
            -NoNewline `
            -ForegroundColor Cyan

        Write-Host $Profiles[$Index].FullName
    }

    Write-Host ""

    while ($true) {
        $Selection = Read-Host "Numéro du profil à restaurer"
        $Number = 0

        if (
            [int]::TryParse($Selection, [ref]$Number) -and
            $Number -ge 1 -and
            $Number -le $Profiles.Count
        ) {
            return $Profiles[$Number - 1]
        }

        Write-Host "Sélection invalide." -ForegroundColor Red
    }
}

function Find-SourceFolder {
    param(
        [Parameter(Mandatory)]
        [string]$ProfilePath,

        [Parameter(Mandatory)]
        [string[]]$CandidateNames
    )

    foreach ($Name in $CandidateNames) {
        $Candidate = Join-Path $ProfilePath $Name

        if (Test-Path -LiteralPath $Candidate -PathType Container) {
            return $Candidate
        }
    }

    return $null
}

# =====================================================================
# SÉLECTION DU MODE
# =====================================================================

function Select-TransferMode {
    Write-Host ""
    Write-Host "[Entrée] Déplacer les fichiers " `
        -NoNewline `
        -ForegroundColor Yellow

    Write-Host "(recommandé pour libérer l'espace)"

    Write-Host "[C]      Copier les fichiers " `
        -NoNewline `
        -ForegroundColor Green

    Write-Host "(Windows.old reste intact)"

    Write-Host "[Q]      Quitter" -ForegroundColor Red
    Write-Host ""

    while ($true) {
        $Choice = Read-Host "Votre choix"

        if ([string]::IsNullOrWhiteSpace($Choice)) {
            return $PreferredMode
        }

        switch ($Choice.Trim().ToUpperInvariant()) {
            "M"         { return "Move" }
            "D"         { return "Move" }
            "MOVE"      { return "Move" }
            "DEPLACER"  { return "Move" }

            "C"         { return "Copy" }
            "COPY"      { return "Copy" }
            "COPIER"    { return "Copy" }

            "Q"         { return "Cancel" }
            "QUITTER"   { return "Cancel" }
            "ANNULER"   { return "Cancel" }

            default {
                Write-Host "Choix invalide." -ForegroundColor Red
            }
        }
    }
}

# =====================================================================
# GESTION DES FICHIERS SANS SUIVRE LES JONCTIONS
# =====================================================================

function Get-FilesWithoutFollowingReparsePoints {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath
    )

    $RootDirectory = Get-Item `
        -LiteralPath $RootPath `
        -Force `
        -ErrorAction Stop

    $Directories = New-Object `
        "System.Collections.Generic.Stack[System.IO.DirectoryInfo]"

    $Directories.Push($RootDirectory)

    while ($Directories.Count -gt 0) {
        $CurrentDirectory = $Directories.Pop()

        try {
            foreach ($File in $CurrentDirectory.GetFiles()) {
                Write-Output $File
            }
        }
        catch {
            Write-Warning "Lecture impossible : $($CurrentDirectory.FullName)"
        }

        try {
            foreach ($ChildDirectory in $CurrentDirectory.GetDirectories()) {
                if (
                    -not (
                        $ChildDirectory.Attributes -band
                        [IO.FileAttributes]::ReparsePoint
                    )
                ) {
                    $Directories.Push($ChildDirectory)
                }
            }
        }
        catch {
            Write-Warning "Accès impossible : $($CurrentDirectory.FullName)"
        }
    }
}

function Get-UniqueConflictPath {
    param(
        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $Directory = Split-Path `
        -Path $DestinationPath `
        -Parent

    $FileName = [IO.Path]::GetFileNameWithoutExtension(
        $DestinationPath
    )

    $Extension = [IO.Path]::GetExtension(
        $DestinationPath
    )

    $Candidate = Join-Path `
        $Directory `
        "$FileName (Windows.old)$Extension"

    $Number = 2

    while (Test-Path -LiteralPath $Candidate) {
        $Candidate = Join-Path `
            $Directory `
            "$FileName (Windows.old $Number)$Extension"

        $Number++
    }

    return $Candidate
}

function Resolve-FileConflicts {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [ValidateSet("Move", "Copy")]
        [string]$Mode
    )

    $Results = @()
    $NormalizedSource = $Source.TrimEnd("\")
    $SourceFiles = Get-FilesWithoutFollowingReparsePoints `
        -RootPath $Source

    foreach ($SourceFile in $SourceFiles) {
        $RelativePath = $SourceFile.FullName.Substring(
            $NormalizedSource.Length
        ).TrimStart("\")

        $NormalDestination = Join-Path `
            $Destination `
            $RelativePath

        if (-not (Test-Path -LiteralPath $NormalDestination)) {
            continue
        }

        $ConflictDestination = Get-UniqueConflictPath `
            -DestinationPath $NormalDestination

        $ConflictDirectory = Split-Path `
            -Path $ConflictDestination `
            -Parent

        try {
            New-Item `
                -Path $ConflictDirectory `
                -ItemType Directory `
                -Force |
                Out-Null

            if ($Mode -eq "Move") {
                Move-Item `
                    -LiteralPath $SourceFile.FullName `
                    -Destination $ConflictDestination `
                    -ErrorAction Stop

                $Action = "Déplacé et renommé"
            }
            else {
                Copy-Item `
                    -LiteralPath $SourceFile.FullName `
                    -Destination $ConflictDestination `
                    -ErrorAction Stop

                $Action = "Copié et renommé"
            }

            Write-Host "  [CONFLIT RENOMMÉ] " `
                -NoNewline `
                -ForegroundColor Yellow

            Write-Host $RelativePath

            Write-Host "                     -> $ConflictDestination" `
                -ForegroundColor DarkGray

            $Results += [PSCustomObject]@{
                Source      = $SourceFile.FullName
                Destination = $ConflictDestination
                Action      = $Action
                Statut      = "Réussi"
                Message     = $null
                Date        = Get-Date
            }
        }
        catch {
            Write-Host "  [CONFLIT NON TRAITÉ] " `
                -NoNewline `
                -ForegroundColor Red

            Write-Host $RelativePath

            $Results += [PSCustomObject]@{
                Source      = $SourceFile.FullName
                Destination = $ConflictDestination
                Action      = $Mode
                Statut      = "Échec"
                Message     = $_.Exception.Message
                Date        = Get-Date
            }
        }
    }

    return @($Results)
}

# =====================================================================
# NETTOYAGE DES DOSSIERS VIDES
# =====================================================================

function Remove-EmptyDirectories {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath
    )

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return
    }

    $Directories = @(
        Get-ChildItem `
            -LiteralPath $RootPath `
            -Directory `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue |
        Where-Object {
            -not (
                $_.Attributes -band
                [IO.FileAttributes]::ReparsePoint
            )
        } |
        Sort-Object {
            $_.FullName.Length
        } -Descending
    )

    foreach ($Directory in $Directories) {
        try {
            $RemainingItem = Get-ChildItem `
                -LiteralPath $Directory.FullName `
                -Force `
                -ErrorAction Stop |
                Select-Object -First 1

            if ($null -eq $RemainingItem) {
                Remove-Item `
                    -LiteralPath $Directory.FullName `
                    -Force `
                    -ErrorAction Stop
            }
        }
        catch {
            # Le dossier n'est pas vide ou n'est pas accessible.
        }
    }
}

# =====================================================================
# ROBOCOPY
# =====================================================================

function Get-RobocopyStatus {
    param(
        [int]$ExitCode
    )

    if ($ExitCode -eq 0) {
        return "Aucun fichier restant à transférer"
    }

    if ($ExitCode -lt 8) {
        return "Transfert terminé avec succès"
    }

    if ($ExitCode -lt 16) {
        return "Certains fichiers n'ont pas pu être transférés"
    }

    return "Erreur grave Robocopy"
}

function Invoke-FolderTransfer {
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [ValidateSet("Move", "Copy")]
        [string]$Mode,

        [Parameter(Mandatory)]
        [string]$RobocopyLog
    )

    Write-Host ""
    Write-Host "[$DisplayName]" -ForegroundColor Cyan
    Write-Host "  Source      : $Source"
    Write-Host "  Destination : $Destination"

    New-Item `
        -Path $Destination `
        -ItemType Directory `
        -Force |
        Out-Null

    $ConflictResults = @()

    if ($RenameConflictingFiles) {
        Write-Host "  Vérification des conflits..." `
            -ForegroundColor Gray

        $ConflictResults = @(
            Resolve-FileConflicts `
                -Source $Source `
                -Destination $Destination `
                -Mode $Mode
        )
    }

    $Arguments = @(
        $Source
        $Destination
        "*"
        "/E"
        "/COPY:DAT"
        "/DCOPY:DAT"
        "/R:$RobocopyRetries"
        "/W:$RobocopyWaitSeconds"
        "/MT:$RobocopyThreads"
        "/XJ"
        "/ZB"
        "/FFT"
        "/NP"
        "/TEE"
        "/LOG+:$RobocopyLog"
    )

    # Protection supplémentaire contre tout écrasement.
    $Arguments += @(
        "/XC"
        "/XN"
        "/XO"
    )

    if ($Mode -eq "Move") {
        # /MOV supprime uniquement les fichiers correctement transférés.
        $Arguments += "/MOV"
    }

    Write-Host "  Opération   : " -NoNewline

    if ($Mode -eq "Move") {
        Write-Host "DÉPLACEMENT" -ForegroundColor Yellow
    }
    else {
        Write-Host "COPIE" -ForegroundColor Green
    }

    & robocopy.exe @Arguments

    $ExitCode = $LASTEXITCODE
    $Success = $ExitCode -lt 8
    $Status = Get-RobocopyStatus -ExitCode $ExitCode

    if (
        $Mode -eq "Move" -and
        $Success -and
        $RemoveEmptySourceDirectories
    ) {
        Remove-EmptyDirectories -RootPath $Source
    }

    Write-Host "  Résultat    : " -NoNewline

    if ($Success) {
        Write-Host "$Status (code $ExitCode)" `
            -ForegroundColor Green
    }
    else {
        Write-Host "$Status (code $ExitCode)" `
            -ForegroundColor Red
    }

    $FailedConflictCount = @(
        $ConflictResults |
        Where-Object {
            $_.Statut -eq "Échec"
        }
    ).Count

    return [PSCustomObject]@{
        Dossier          = $DisplayName
        Source           = $Source
        Destination      = $Destination
        Mode             = $Mode
        ConflitsRenommes = @(
            $ConflictResults |
            Where-Object {
                $_.Statut -eq "Réussi"
            }
        ).Count
        ConflitsEnEchec  = $FailedConflictCount
        CodeRobocopy     = $ExitCode
        Statut           = $Status
        Reussite         = (
            $Success -and
            $FailedConflictCount -eq 0
        )
        Date             = Get-Date
        ConflictResults  = $ConflictResults
    }
}

# =====================================================================
# RÉCUPÉRATION DES DOSSIERS DE DESTINATION
# =====================================================================

$InitialFolderMap = Get-CurrentUserFolderMap

if (-not (Test-IsAdministrator)) {
    try {
        Start-ElevatedScript `
            -CurrentFolderMap $InitialFolderMap
    }
    catch {
        Write-Host ""
        Write-Host "[ERREUR]" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Wait-ForEnter
    }

    return
}

# Si le script vient d'être élevé, récupérer les dossiers du véritable
# utilisateur qui a lancé le programme.
if (-not [string]::IsNullOrWhiteSpace($env:ITECH_FOLDER_MAP)) {
    try {
        $FolderMapJson = ConvertFrom-EncodedText `
            -EncodedText $env:ITECH_FOLDER_MAP

        $FolderMap = $FolderMapJson |
            ConvertFrom-Json

        Remove-Item Env:\ITECH_FOLDER_MAP `
            -ErrorAction SilentlyContinue
    }
    catch {
        throw "Impossible de récupérer les dossiers du profil utilisateur."
    }
}
else {
    $FolderMap = $InitialFolderMap
}

$TargetProfile = [string]$FolderMap.Profile

if ([string]::IsNullOrWhiteSpace($TargetProfile)) {
    throw "Le profil utilisateur de destination est introuvable."
}

# =====================================================================
# RAPPORTS
# =====================================================================

$ExecutionDate = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$ReportDirectory = Join-Path $ReportRoot $ExecutionDate

New-Item `
    -Path $ReportDirectory `
    -ItemType Directory `
    -Force |
    Out-Null

$TranscriptLog = Join-Path `
    $ReportDirectory `
    "Execution.log"

$RobocopyLog = Join-Path `
    $ReportDirectory `
    "Robocopy.log"

$TransferReport = Join-Path `
    $ReportDirectory `
    "Transferts.csv"

$ConflictReport = Join-Path `
    $ReportDirectory `
    "Conflits-Renommes.csv"

$TranscriptStarted = $false
$TransferResults = @()
$AllConflictResults = @()

# =====================================================================
# PROGRAMME PRINCIPAL
# =====================================================================

try {
    try {
        Start-Transcript `
            -Path $TranscriptLog `
            -Append |
            Out-Null

        $TranscriptStarted = $true
    }
    catch {
        Write-Warning "Le journal PowerShell n'a pas pu être démarré."
    }

    Write-Section "ITECH-TOOL - TRANSFERT DE WINDOWS.OLD"

    Write-Host "Ordinateur         : $env:COMPUTERNAME"
    Write-Host "Profil destination : $TargetProfile"
    Write-Host "Windows.old        : $WindowsOldPath"
    Write-Host "Date                : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
    Write-Host "Privilèges          : Administrateur" `
        -ForegroundColor Green

    Write-Host ""
    Write-Host "AppData et les fichiers système ne seront pas transférés." `
        -ForegroundColor Yellow

    # -----------------------------------------------------------------
    # Vérification de Windows.old
    # -----------------------------------------------------------------

    Write-Section "1. VÉRIFICATION DE WINDOWS.OLD"

    if (-not (Test-Path -LiteralPath $WindowsOldPath -PathType Container)) {
        throw "Le dossier $WindowsOldPath est introuvable."
    }

    $OldUsersPath = Join-Path $WindowsOldPath "Users"

    if (-not (Test-Path -LiteralPath $OldUsersPath -PathType Container)) {
        throw "Le dossier $OldUsersPath est introuvable."
    }

    Write-Host "[OK] Windows.old est accessible." `
        -ForegroundColor Green

    # -----------------------------------------------------------------
    # Sélection de l'ancien profil
    # -----------------------------------------------------------------

    Write-Section "2. PROFIL À RÉCUPÉRER"

    $TargetProfileName = Split-Path `
        -Path $TargetProfile `
        -Leaf

    $OldProfiles = Get-OldUserProfiles `
        -UsersPath $OldUsersPath

    $SelectedProfile = Select-OldUserProfile `
        -Profiles $OldProfiles `
        -TargetProfileName $TargetProfileName

    $SourceProfile = $SelectedProfile.FullName

    Write-Host ""
    Write-Host "Profil source      : $SourceProfile"
    Write-Host "Profil destination : $TargetProfile"

    # -----------------------------------------------------------------
    # Construction du plan
    # -----------------------------------------------------------------

    Write-Section "3. PLAN DE TRANSFERT"

    $FolderDefinitions = @(
        [PSCustomObject]@{
            Name        = "Bureau"
            SourceNames = @("Desktop", "Bureau")
            Destination = [string]$FolderMap.Desktop
        }
        [PSCustomObject]@{
            Name        = "Documents"
            SourceNames = @("Documents", "Mes documents")
            Destination = [string]$FolderMap.Documents
        }
        [PSCustomObject]@{
            Name        = "Téléchargements"
            SourceNames = @(
                "Downloads",
                "Téléchargements",
                "Telechargements"
            )
            Destination = [string]$FolderMap.Downloads
        }
        [PSCustomObject]@{
            Name        = "Images"
            SourceNames = @("Pictures", "Images", "Mes images")
            Destination = [string]$FolderMap.Pictures
        }
        [PSCustomObject]@{
            Name        = "Musique"
            SourceNames = @("Music", "Musique", "Ma musique")
            Destination = [string]$FolderMap.Music
        }
        [PSCustomObject]@{
            Name        = "Vidéos"
            SourceNames = @(
                "Videos",
                "Vidéos",
                "Mes vidéos",
                "Mes videos"
            )
            Destination = [string]$FolderMap.Videos
        }
        [PSCustomObject]@{
            Name        = "Favoris"
            SourceNames = @("Favorites", "Favoris")
            Destination = [string]$FolderMap.Favorites
        }
        [PSCustomObject]@{
            Name        = "Contacts"
            SourceNames = @("Contacts")
            Destination = [string]$FolderMap.Contacts
        }
        [PSCustomObject]@{
            Name        = "Liens"
            SourceNames = @("Links", "Liens")
            Destination = [string]$FolderMap.Links
        }
        [PSCustomObject]@{
            Name        = "Parties enregistrées"
            SourceNames = @(
                "Saved Games",
                "Parties enregistrées",
                "Parties enregistrees"
            )
            Destination = [string]$FolderMap.SavedGames
        }
        [PSCustomObject]@{
            Name        = "Recherches"
            SourceNames = @("Searches", "Recherches")
            Destination = [string]$FolderMap.Searches
        }
    )

    $TransferPlan = @()

    foreach ($Definition in $FolderDefinitions) {
        $SourceFolder = Find-SourceFolder `
            -ProfilePath $SourceProfile `
            -CandidateNames $Definition.SourceNames

        if ($null -eq $SourceFolder) {
            Write-Host "[ABSENT] " `
                -NoNewline `
                -ForegroundColor DarkGray

            Write-Host $Definition.Name
            continue
        }

        if ([string]::IsNullOrWhiteSpace($Definition.Destination)) {
            Write-Host "[DESTINATION INTROUVABLE] " `
                -NoNewline `
                -ForegroundColor Red

            Write-Host $Definition.Name
            continue
        }

        $TransferPlan += [PSCustomObject]@{
            Name        = $Definition.Name
            Source      = $SourceFolder
            Destination = $Definition.Destination
        }

        Write-Host "[PRÊT] " `
            -NoNewline `
            -ForegroundColor Green

        Write-Host $Definition.Name

        Write-Host "       $SourceFolder" `
            -ForegroundColor DarkGray

        Write-Host "    -> $($Definition.Destination)" `
            -ForegroundColor DarkGray
    }

    if ($TransferPlan.Count -eq 0) {
        throw "Aucun dossier personnel à transférer n'a été trouvé."
    }

    # -----------------------------------------------------------------
    # Choix du mode
    # -----------------------------------------------------------------

    Write-Section "4. MODE DE TRANSFERT"

    $TransferMode = Select-TransferMode

    if ($TransferMode -eq "Cancel") {
        Write-Host ""
        Write-Host "Opération annulée." -ForegroundColor Yellow
        return
    }

    Write-Host ""

    if ($TransferMode -eq "Move") {
        Write-Host "Mode sélectionné : DÉPLACEMENT" `
            -ForegroundColor Yellow

        Write-Host @"
Les fichiers correctement transférés seront retirés de Windows.old.
Les fichiers portant le même nom seront conservés et renommés.
Windows.old ne sera pas supprimé automatiquement.
"@ -ForegroundColor Yellow
    }
    else {
        Write-Host "Mode sélectionné : COPIE" `
            -ForegroundColor Green

        Write-Host "Tous les fichiers sources resteront dans Windows.old." `
            -ForegroundColor Green
    }

    Write-Host ""
    $Confirmation = Read-Host "Continuer ? [O/n]"

    if (
        -not [string]::IsNullOrWhiteSpace($Confirmation) -and
        $Confirmation.Trim().ToUpperInvariant() -notin @(
            "O",
            "OUI",
            "Y",
            "YES"
        )
    ) {
        Write-Host ""
        Write-Host "Opération annulée." -ForegroundColor Yellow
        return
    }

    # -----------------------------------------------------------------
    # Transfert
    # -----------------------------------------------------------------

    Write-Section "5. TRANSFERT DES DOSSIERS"

    $FolderNumber = 0

    foreach ($Folder in $TransferPlan) {
        $FolderNumber++

        Write-Host ""
        Write-Host "Dossier $FolderNumber/$($TransferPlan.Count)" `
            -ForegroundColor DarkCyan

        $Result = Invoke-FolderTransfer `
            -DisplayName $Folder.Name `
            -Source $Folder.Source `
            -Destination $Folder.Destination `
            -Mode $TransferMode `
            -RobocopyLog $RobocopyLog

        $TransferResults += $Result

        if ($Result.ConflictResults) {
            $AllConflictResults += @(
                $Result.ConflictResults
            )
        }
    }

    # -----------------------------------------------------------------
    # Rapports
    # -----------------------------------------------------------------

    $TransferResults |
        Select-Object `
            Dossier,
            Source,
            Destination,
            Mode,
            ConflitsRenommes,
            ConflitsEnEchec,
            CodeRobocopy,
            Statut,
            Reussite,
            Date |
        Export-Csv `
            -Path $TransferReport `
            -NoTypeInformation `
            -Encoding UTF8

    if ($AllConflictResults.Count -gt 0) {
        $AllConflictResults |
            Export-Csv `
                -Path $ConflictReport `
                -NoTypeInformation `
                -Encoding UTF8
    }
    else {
        '"Source","Destination","Action","Statut","Message","Date"' |
            Set-Content `
                -Path $ConflictReport `
                -Encoding UTF8
    }

    # -----------------------------------------------------------------
    # Résumé
    # -----------------------------------------------------------------

    Write-Section "6. RÉSUMÉ"

    $SuccessfulFolders = @(
        $TransferResults |
        Where-Object {
            $_.Reussite -eq $true
        }
    ).Count

    $FailedFolders = @(
        $TransferResults |
        Where-Object {
            $_.Reussite -eq $false
        }
    ).Count

    $RenamedConflicts = @(
        $AllConflictResults |
        Where-Object {
            $_.Statut -eq "Réussi"
        }
    ).Count

    $FailedConflicts = @(
        $AllConflictResults |
        Where-Object {
            $_.Statut -eq "Échec"
        }
    ).Count

    Write-Host "Profil source          : $SourceProfile"
    Write-Host "Profil destination     : $TargetProfile"

    Write-Host "Mode                    : " -NoNewline

    if ($TransferMode -eq "Move") {
        Write-Host "Déplacement" -ForegroundColor Yellow
    }
    else {
        Write-Host "Copie" -ForegroundColor Green
    }

    Write-Host "Dossiers traités       : $($TransferResults.Count)"
    Write-Host "Dossiers réussis       : $SuccessfulFolders" `
        -ForegroundColor Green

    Write-Host "Dossiers avec erreurs  : $FailedFolders" `
        -ForegroundColor $(if ($FailedFolders -gt 0) {
            "Red"
        }
        else {
            "Green"
        })

    Write-Host "Conflits renommés      : $RenamedConflicts" `
        -ForegroundColor $(if ($RenamedConflicts -gt 0) {
            "Yellow"
        }
        else {
            "Green"
        })

    Write-Host "Conflits en échec      : $FailedConflicts" `
        -ForegroundColor $(if ($FailedConflicts -gt 0) {
            "Red"
        }
        else {
            "Green"
        })

    Write-Host ""
    Write-Host "Rapport des transferts :" -ForegroundColor Cyan
    Write-Host "  $TransferReport"

    Write-Host "Rapport des conflits :" -ForegroundColor Cyan
    Write-Host "  $ConflictReport"

    Write-Host "Journal Robocopy :" -ForegroundColor Cyan
    Write-Host "  $RobocopyLog"

    Write-Host "Journal PowerShell :" -ForegroundColor Cyan
    Write-Host "  $TranscriptLog"

    if (
        $FailedFolders -eq 0 -and
        $FailedConflicts -eq 0
    ) {
        Write-Host ""
        Write-Host "[TERMINÉ] Tous les dossiers ont été traités." `
            -ForegroundColor Green
    }
    else {
        Write-Host ""
        Write-Host "[TERMINÉ AVEC DES ERREURS]" `
            -ForegroundColor Yellow

        Write-Host @"
Certains fichiers peuvent encore être présents dans Windows.old.
Consultez les rapports avant de supprimer Windows.old.
"@ -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "[IMPORTANT]" -ForegroundColor Yellow
    Write-Host @"
Vérifiez les fichiers récupérés avant de supprimer Windows.old.
Le script ne supprime jamais automatiquement le dossier Windows.old.
"@ -ForegroundColor Yellow
}
catch {
    Write-Host ""
    Write-Host "[ERREUR CRITIQUE]" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    Write-Host ""
    Write-Host "Windows.old n'a pas été supprimé." `
        -ForegroundColor Yellow

    if (Test-Path -LiteralPath $ReportDirectory) {
        Write-Host "Journaux : $ReportDirectory" `
            -ForegroundColor Yellow
    }
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

    Wait-ForEnter
}
