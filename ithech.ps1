# ITHECH - Outil de maintenance PC
# Usage : irm https://raw.githubusercontent.com/AbasseTALL/itech-tool/main/ithech.ps1 | iex

$ScriptUrl = "https://raw.githubusercontent.com/AbasseTALL/itech-tool/main/ithech.ps1"

# Force TLS 1.2 pour cette session -- utile sur les vieux Windows 7/8
# ou TLS 1.2 est present mais desactive par defaut
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Read-HostClean {
    param([string]$Prompt)
    for ($i = 0; $i -lt 4; $i++) {
        try { while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null } } catch {}
        try { $Host.UI.RawUI.FlushInputBuffer() } catch {}
        Start-Sleep -Milliseconds 100
    }
    return Read-Host $Prompt
}

$RestoreUrl = "https://raw.githubusercontent.com/AbasseTALL/itech-tool/main/Restore-WindowsOldFiles.ps1"

function Clear-ToolHistory {
    $urlsToClean = @($ScriptUrl, $RestoreUrl)
    try {
        $historyPath = (Get-PSReadLineOption -ErrorAction Stop).HistorySavePath
        if ($historyPath -and (Test-Path $historyPath)) {
            $lines = Get-Content $historyPath -ErrorAction Stop
            foreach ($url in $urlsToClean) {
                $lines = $lines | Where-Object { $_ -notmatch [regex]::Escape($url) }
            }
            Set-Content -Path $historyPath -Value $lines -ErrorAction Stop
        }
    } catch {
        # PSReadLine absent ou fichier verrouille : on ignore silencieusement
    }
}

# --- Auto-elevation ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Demande des droits administrateur..."
    Start-Process powershell -Verb RunAs -ArgumentList `
        "-NoExit -Command `"iex (New-Object Net.WebClient).DownloadString('$ScriptUrl')`""
    Clear-ToolHistory
    exit
}

function Get-DiskType {
    try {
        $disk = Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1
        return $disk.MediaType
    } catch {
        return "Inconnu"
    }
}

function Show-DismWarning {
    param([string]$Operation = "DISM")
    $diskType = Get-DiskType
    if ($diskType -match "SSD") {
        $duree = "5-15 minutes (SSD detecte)"
        $color = "Green"
    } elseif ($diskType -match "HDD") {
        $duree = "20-60 minutes (HDD detecte -- peut aller jusqu'a 1h30 pour SFC)"
        $color = "Yellow"
    } else {
        $duree = "20-60 minutes (type de disque inconnu)"
        $color = "Yellow"
    }
    Write-Host "Duree estimee : $duree" -ForegroundColor $color
    Write-Host "Ne pas fermer la fenetre, ne pas eteindre le PC." -ForegroundColor Yellow
    Write-Host ""
}

function Show-WaitAnimation {
    param([string]$Message = "Initialisation")
    $frames = @("|", "/", "-", "\")
    $end = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $end) {
        foreach ($f in $frames) {
            Write-Host "`r  $f  $Message..." -NoNewline
            Start-Sleep -Milliseconds 120
        }
    }
    Write-Host "`r  OK $Message -- demarrage en cours.   "
    Write-Host ""
}

function Optimisation {
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  ITHECH - Desactivation des services inutiles" -ForegroundColor Cyan
    Write-Host "===============================================`n"

    $services = @(
        @{N="SysMain"; L="SysMain (Superfetch)"},
        @{N="DiagTrack"; L="Experiences utilisateur connectees et telemetrie"},
        @{N="WerSvc"; L="Rapport d'erreurs Windows"},
        @{N="PcaSvc"; L="Assistant de compatibilite des programmes"},
        @{N="WSearch"; L="Windows Search (indexation)"},
        @{N="Fax"; L="Telecopie (Fax)"},
        @{N="bthserv"; L="Support Bluetooth"},
        @{N="XblAuthManager"; L="Xbox Live Auth Manager"},
        @{N="XblGameSave"; L="Xbox Live Game Save"},
        @{N="XboxNetApiSvc"; L="Xbox Live Networking"},
        @{N="TabletInputService"; L="Clavier tactile / ecriture manuscrite"},
        @{N="MapsBroker"; L="Cartes telechargees"}
    )
    foreach ($svc in $services) {
        Write-Host "-> $($svc.L)..."
        Set-Service -Name $svc.N -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name $svc.N -Force -ErrorAction SilentlyContinue
    }

    Write-Host "`nServices termine.`n"
    Write-Host "Non inclus (verifier le besoin client avant de les desactiver) :"
    Write-Host "  - Spooler (impression), RemoteRegistry, seclogon"
    Write-Host "NE JAMAIS desactiver : Windows Update, BITS`n"

    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  Nettoyage des fichiers inutiles" -ForegroundColor Cyan
    Write-Host "===============================================`n"

    Write-Host "[1/7] Fichiers temporaires (tous les utilisateurs)..."
    Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $userTemp = Join-Path $_.FullName "AppData\Local\Temp"
        if (Test-Path $userTemp) {
            Remove-Item "$userTemp\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "[2/7] Fichiers temporaires systeme (C:\Windows\Temp)..."
    Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "[3/7] Cache Windows Update..."
    Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv, bits -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

    Write-Host "[4/7] Corbeille (tous les disques)..."
    Get-PSDrive -PSProvider FileSystem | ForEach-Object {
        $rb = Join-Path $_.Root '$Recycle.Bin'
        if (Test-Path $rb) { Remove-Item $rb -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Write-Host "[5/7] Cache des miniatures (thumbnails)..."
    Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $thumbPath = Join-Path $_.FullName "AppData\Local\Microsoft\Windows\Explorer"
        if (Test-Path $thumbPath) {
            Remove-Item "$thumbPath\thumbcache_*.db" -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "[6/7] Cache DNS..."
    try {
        Clear-DnsClientCache -ErrorAction Stop
    } catch {
        & ipconfig /flushdns | Out-Null
    }

    Write-Host "[7/7] Nettoyage des anciens composants de mise a jour (WinSxS)..."
    Write-Host ""
    Write-Host "┌─────────────────────────────────────────────────┐" -ForegroundColor DarkGreen
    Write-Host "│  DISM - NETTOYAGE DISQUE (option 1)             │" -ForegroundColor DarkGreen
    Write-Host "│  Suppression des anciens composants Windows.    │" -ForegroundColor DarkGreen
    Write-Host "│  Aucune reparation -- liberation d'espace only. │" -ForegroundColor DarkGreen
    Write-Host "└─────────────────────────────────────────────────┘" -ForegroundColor DarkGreen
    Write-Host ""
    Show-DismWarning -Operation "DISM nettoyage"
    Show-WaitAnimation -Message "DISM"
    & "$env:windir\system32\Dism.exe" /online /Cleanup-Image /StartComponentCleanup

    Write-Host "`nNettoyage termine."
    Read-HostClean "`nAppuie sur Entree pour continuer"
}

function ReparationLocale {
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  Reparation - source locale" -ForegroundColor Cyan
    Write-Host "===============================================`n"
    Write-Host "Monte l'ISO Windows ou branche la cle USB, puis indique le chemin.`n"
    $wimpath = Read-HostClean "Chemin complet vers install.wim (ex: D:\sources\install.wim)"
    if (-not (Test-Path $wimpath)) {
        Write-Host "Fichier introuvable : $wimpath" -ForegroundColor Red
        Read-HostClean "Appuie sur Entree pour continuer"
        return
    }
    $wimindex = Read-HostClean "Index de l'edition dans le wim (Entree = 1 par defaut)"
    if ([string]::IsNullOrWhiteSpace($wimindex)) { $wimindex = "1" }

    Write-Host "`nLancement de la reparation, patience...`n"
    Write-Host "┌─────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
    Write-Host "│  DISM - REPARATION (option 2 -- source locale)  │" -ForegroundColor DarkCyan
    Write-Host "│  Analyse et correction des fichiers systeme.    │" -ForegroundColor DarkCyan
    Write-Host "│  Source : ISO locale (pas de connexion requise) │" -ForegroundColor DarkCyan
    Write-Host "└─────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
    Write-Host ""
    Show-DismWarning -Operation "DISM reparation"
    Show-WaitAnimation -Message "DISM"
    & "$env:windir\system32\Dism.exe" /Online /Cleanup-Image /RestoreHealth /Source:wim:$wimpath`:$wimindex /LimitAccess

    Write-Host "`nVerification des fichiers systeme (SFC)...`n"
    Show-DismWarning -Operation "SFC"
    Show-WaitAnimation -Message "SFC"
    & "$env:windir\system32\sfc.exe" /scannow

    Write-Host "`nTermine. Erreur de source DISM = version ISO differente du PC -- essaie l'option en ligne."
    Read-HostClean "Appuie sur Entree pour continuer"
}

function ReparationOnline {
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  Reparation - en ligne (Windows Update)" -ForegroundColor Cyan
    Write-Host "===============================================`n"
    Read-HostClean "Verifie la connexion internet du PC, puis appuie sur Entree"

    Write-Host "`nLancement de la reparation, patience (15-30 min)...`n"
    Write-Host "┌─────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
    Write-Host "│  DISM - REPARATION (option 2 -- en ligne)       │" -ForegroundColor DarkCyan
    Write-Host "│  Analyse et correction des fichiers systeme.    │" -ForegroundColor DarkCyan
    Write-Host "│  Source : Windows Update (connexion requise)    │" -ForegroundColor DarkCyan
    Write-Host "└─────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
    Write-Host ""
    & "$env:windir\system32\Dism.exe" /Online /Cleanup-Image /RestoreHealth

    Write-Host "`nVerification des fichiers systeme (SFC)...`n"
    & "$env:windir\system32\sfc.exe" /scannow

    Write-Host "`nTermine."
    Read-HostClean "Appuie sur Entree pour continuer"
}

function MenuReparation {
    do {
        Clear-Host
        Write-Host "==============================================="
        Write-Host "  Reparation de l'image Windows (DISM)"
        Write-Host "===============================================`n"
        Write-Host "  1. Source locale (ISO/cle USB) - rapide, hors-ligne"
        Write-Host "     mais exige la meme version/build que le PC.`n"
        Write-Host "  2. En ligne (Windows Update) - plus lent, internet"
        Write-Host "     requis, mais s'adapte a la version exacte du PC.`n"
        Write-Host "  0. Retour au menu principal`n"
        $sc = Read-HostClean "Choix"
        switch ($sc) {
            "1" { ReparationLocale }
            "2" { ReparationOnline }
            "0" { return }
            default { Write-Host "Choix invalide."; Start-Sleep 1 }
        }
    } while ($true)
}

function Add-DefenderExclusions {
    $paths = @(
        (Join-Path $env:TEMP "Fido.ps1"),
        (Join-Path $env:TEMP "Windows10.iso"),
        (Join-Path $env:TEMP "Windows11.iso")
    )
    foreach ($p in $paths) {
        try {
            Add-MpPreference -ExclusionPath $p -ErrorAction Stop
        } catch {
            # Defender absent, ou gere par une politique d'entreprise/GPO -- on ignore
        }
    }
}

function Get-WindowsIso {
    param([string]$WinVersion, [string]$Edition = "Pro")

    $fidoPath = Join-Path $env:TEMP "Fido.ps1"
    Add-DefenderExclusions
    Write-Host "Recuperation de Fido (telechargeur officiel d'ISO Microsoft)..."
    try {
        (New-Object Net.WebClient).DownloadFile(
            "https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1", $fidoPath)
    } catch {
        Write-Host "Impossible de recuperer Fido -- verifie la connexion internet." -ForegroundColor Red
        return $null
    }

    # RELEASE_CIBLE : change ici si tu veux figer un build precis (ex: "22H2") au lieu de "Latest"
    $RELEASE_CIBLE = "Latest"

    Write-Host "Recherche du lien officiel (Windows $WinVersion, $RELEASE_CIBLE, $Edition, French, x64)..."
    $url = & powershell -ExecutionPolicy Bypass -File $fidoPath `
        -Win $WinVersion -Rel $RELEASE_CIBLE -Ed $Edition -Lang French -Arch x64 -GetUrl 2>$null |
        Select-Object -Last 1

    if (-not $url -or $url -notmatch "^https?://") {
        Write-Host "Fido n'a pas retourne de lien valide (Microsoft a peut-etre change sa page)." -ForegroundColor Red
        return $null
    }

    $isoPath = Join-Path $env:TEMP "Windows$WinVersion.iso"
    Write-Host "Telechargement de l'ISO (plusieurs Go, patience)..." -ForegroundColor Yellow
    Write-Host "$url"
    try {
        Start-BitsTransfer -Source $url -Destination $isoPath -Description "Telechargement Windows $WinVersion" -ErrorAction Stop
    } catch {
        Write-Host "BITS indisponible, telechargement sans barre de progression..." -ForegroundColor Yellow
        try {
            (New-Object Net.WebClient).DownloadFile($url, $isoPath)
        } catch {
            Write-Host "Echec du telechargement." -ForegroundColor Red
            return $null
        }
    }
    return $isoPath
}

function Find-WindowsSetup {
    # 1. Racines de lecteurs (ISO monte, cle USB)
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $setupPath = Join-Path $drive.Root "setup.exe"
        $wim = Join-Path $drive.Root "sources\install.wim"
        $esd = Join-Path $drive.Root "sources\install.esd"
        if ((Test-Path $setupPath -ErrorAction SilentlyContinue) -and
            ((Test-Path $wim -ErrorAction SilentlyContinue) -or (Test-Path $esd -ErrorAction SilentlyContinue))) {
            return $setupPath
        }
    }

    # 2. Dossiers courants d'extraction (7-Zip, etc.) -- recherche limitee en profondeur
    #    pour eviter de scanner tout le disque
    $searchRoots = @($env:TEMP, "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads")
    foreach ($root in $searchRoots) {
        if (-not (Test-Path $root -ErrorAction SilentlyContinue)) { continue }
        $found = Get-ChildItem -Path $root -Filter "setup.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Where-Object {
                (Test-Path (Join-Path $_.DirectoryName "sources\install.wim") -ErrorAction SilentlyContinue) -or
                (Test-Path (Join-Path $_.DirectoryName "sources\install.esd") -ErrorAction SilentlyContinue)
            } | Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    # 3. Dernier recours : demander le chemin exact (ex: extraction 7-Zip ailleurs)
    Write-Host "setup.exe introuvable automatiquement (racines de lecteur, Temp, Bureau, Telechargements)." -ForegroundColor Yellow
    $manual = Read-HostClean "Chemin complet vers setup.exe (ou vide pour annuler)"
    if ($manual -and (Test-Path $manual -ErrorAction SilentlyContinue)) { return $manual }
    return $null
}

function Launch-AutoUpgrade {
    param([string]$WinVersion)

    $canAutoMount = Get-Command Mount-DiskImage -ErrorAction SilentlyContinue

    if ($canAutoMount) {
        $iso = Get-WindowsIso -WinVersion $WinVersion
        if (-not $iso) {
            Write-Host "`nRepli sur la methode manuelle : ouverture de la page Microsoft..."
            try { Start-Process "https://www.microsoft.com/software-download/windows$WinVersion" } catch {}
            Read-HostClean "Telecharge et monte l'ISO manuellement, puis appuie sur Entree"
        } else {
            Write-Host "`nMontage automatique de l'ISO..."
            $mount = Mount-DiskImage -ImagePath $iso -PassThru
            Start-Sleep -Seconds 2
        }
    } else {
        # Pas de Mount-DiskImage (Windows 7) -- Fido reste utile pour eviter la page interactive,
        # mais le montage doit rester manuel
        $iso = Get-WindowsIso -WinVersion $WinVersion
        if ($iso) {
            Write-Host "`nISO telecharge : $iso"
            Write-Host "Ce PC ne sait pas monter un ISO nativement -- utilise 7-Zip pour l'extraire,"
            Write-Host "ou grave-le sur une cle USB (Ventoy) pour le monter sur un autre PC."
        } else {
            Write-Host "`nRepli sur la methode manuelle : ouverture de la page Microsoft..."
            try { Start-Process "https://www.microsoft.com/software-download/windows$WinVersion" } catch {}
        }
        Read-HostClean "Une fois l'ISO accessible (monte ou extrait), appuie sur Entree"
    }

    $setupExe = Find-WindowsSetup
    if (-not $setupExe) {
        Write-Host "`nAucun setup.exe trouve sur les lecteurs montes. Verifie que l'ISO est bien accessible." -ForegroundColor Red
        return
    }
    Write-Host "`nTrouve : $setupExe" -ForegroundColor Green
    $confirm = Read-HostClean "Lancer la mise a niveau automatique maintenant (garde fichiers/applis) ? (O/N)"
    if ($confirm -notmatch "^[oO]") { return }

    Write-Host "`nLancement... le PC va redemarrer plusieurs fois SEUL, ne pas eteindre." -ForegroundColor Yellow
    Start-Process -FilePath $setupExe -ArgumentList `
        "/auto upgrade /quiet /dynamicupdate disable /eula accept /showoobe none /compat ignorewarning"
}

function MiseANiveau {
    Clear-Host
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  ITHECH - Assistant de mise a niveau Windows" -ForegroundColor Cyan
    Write-Host "===============================================`n"

    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host "Version detectee : $($os.Caption)`n"

    if ($os.Caption -match "Windows 7|Windows 8") {
        Write-Host "=== Mise a niveau vers Windows 10 ===" -ForegroundColor Cyan
        Write-Host ""
        $freeGB = [math]::Round((Get-PSDrive C -ErrorAction SilentlyContinue).Free / 1GB, 1)
        Write-Host "Espace libre sur C: : $freeGB Go (minimum recommande : 20 Go)"
        if ($freeGB -lt 20) {
            Write-Host "ATTENTION : espace insuffisant, libere de la place avant de continuer." -ForegroundColor Red
        } else {
            Write-Host "Espace suffisant." -ForegroundColor Green
        }

        Launch-AutoUpgrade -WinVersion "10"
    }
    elseif ($os.Caption -match "Windows 10") {
        Write-Host "=== Mise a niveau vers Windows 11 ===" -ForegroundColor Cyan
        Write-Host ""
        try {
            $tpm = Get-Tpm -ErrorAction Stop
            Write-Host "TPM present : $($tpm.TpmPresent)  |  Version : $($tpm.ManufacturerVersion)"
        } catch {
            Write-Host "TPM : impossible a detecter automatiquement (normal sur certains PC)."
        }

        Write-Host "`nApplication du contournement TPM/CPU non supporte..."
        reg add "HKLM\SYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f | Out-Null
        Write-Host "Cle de registre appliquee." -ForegroundColor Green

        Launch-AutoUpgrade -WinVersion "11"
        Write-Host "`nRappel : 10 jours pour revenir en arriere si besoin"
        Write-Host "(Parametres > Systeme > Recuperation)."
    }
    else {
        Write-Host "Version non prise en charge par cet assistant : $($os.Caption)" -ForegroundColor Yellow
        Write-Host "(Deja sur Windows 11, ou version non reconnue.)"
    }

    Read-HostClean "`nAppuie sur Entree pour continuer"
}

function FixTLS {
    Clear-Host
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  ITHECH - Activation TLS 1.1 / TLS 1.2" -ForegroundColor Cyan
    Write-Host "===============================================`n"
    Write-Host "Sans ca, ce PC ne peut pas atteindre la plupart des sites HTTPS actuels`n(dont microsoft.com), ni telecharger quoi que ce soit via PowerShell.`n"

    $keys = @(
        @{Path="HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Client"; Name="DisabledByDefault"; Value=0},
        @{Path="HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Server"; Name="DisabledByDefault"; Value=0},
        @{Path="HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"; Name="DisabledByDefault"; Value=0},
        @{Path="HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server"; Name="DisabledByDefault"; Value=0},
        @{Path="HKLM:\SOFTWARE\Microsoft\.NETFramework\v2.0.50727"; Name="SchUseStrongCrypto"; Value=1},
        @{Path="HKLM:\SOFTWARE\Microsoft\.NETFramework\v2.0.50727"; Name="SystemDefaultTlsVersions"; Value=1},
        @{Path="HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"; Name="SchUseStrongCrypto"; Value=1},
        @{Path="HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"; Name="SystemDefaultTlsVersions"; Value=1},
        @{Path="HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v2.0.50727"; Name="SchUseStrongCrypto"; Value=1},
        @{Path="HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v2.0.50727"; Name="SystemDefaultTlsVersions"; Value=1},
        @{Path="HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"; Name="SchUseStrongCrypto"; Value=1},
        @{Path="HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"; Name="SystemDefaultTlsVersions"; Value=1}
    )

    foreach ($k in $keys) {
        try {
            if (-not (Test-Path $k.Path)) { New-Item -Path $k.Path -Force | Out-Null }
            New-ItemProperty -Path $k.Path -Name $k.Name -Value $k.Value -PropertyType DWord -Force | Out-Null
            Write-Host "OK : $($k.Path) -> $($k.Name)=$($k.Value)" -ForegroundColor Green
        } catch {
            Write-Host "Echec : $($k.Path) ($($_.Exception.Message))" -ForegroundColor Red
        }
    }

    Write-Host "`n==============================================="
    Write-Host "  Termine. REDEMARRAGE requis pour appliquer."
    Write-Host "  Si ca ne marche toujours pas apres redemarrage"
    Write-Host "  (PC jamais mis a jour depuis des annees) :"
    Write-Host "  installer KB3140245 avant de refaire cette etape."
    Write-Host "===============================================`n"

    $r = Read-HostClean "Redemarrer maintenant ? (O/N)"
    if ($r -match "^[oO]") { Restart-Computer -Force }
}

function Get-WindowsActivation {
    try {
        $lic = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop -Filter `
            "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND LicenseStatus=1" |
            Select-Object -First 1
        if (-not $lic) { return "NON activee" }

        $channel = $lic.ProductKeyChannel
        if ($channel -match "Volume:GVLK") {
            return "Active - licence EN VOLUME/KMS periodique [$channel]"
        } elseif ($channel -match "Volume:MAK") {
            return "Active - licence en volume MAK (permanente) [$channel]"
        } elseif ($channel) {
            return "Active - licence PERMANENTE [$channel]"
        } else {
            return "Active - licence PERMANENTE"
        }
    } catch {
        return "Impossible a verifier ($($_.Exception.Message))"
    }
}

function Get-OfficeActivation {
    try {
        $lic = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop -Filter `
            "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND LicenseStatus=1" |
            Select-Object -First 1
        if ($lic) {
            $channel = $lic.ProductKeyChannel
            if ($channel -match "Volume:GVLK") {
                return "Active - licence EN VOLUME/KMS periodique [$channel]"
            } elseif ($channel -match "Volume:MAK") {
                return "Active - licence en volume MAK (permanente) [$channel]"
            } elseif ($channel) {
                return "Active - licence PERMANENTE [$channel]"
            } else {
                return "Active - licence PERMANENTE"
            }
        }
    } catch {
        # Rien trouve via WMI -- on retente via ospp.vbs (vieilles installations MSI)
    }

    $osppPaths = @(
        "$env:ProgramFiles\Microsoft Office\Office16\ospp.vbs",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office16\ospp.vbs",
        "$env:ProgramFiles\Microsoft Office\Office15\ospp.vbs",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office15\ospp.vbs"
    )
    $osppPath = $osppPaths | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if (-not $osppPath) {
        return "Non detectee (Office absent, ou Click-to-Run/365 -- activation par compte Microsoft, non verifiable ici)"
    }
    try {
        $result = cscript //nologo $osppPath /dstatus 2>$null
        $text = ($result -join "`n")
        if ($text -match "(?i)licens") {
            if ($text -match "(?i)kms") { return "Active - licence EN VOLUME (KMS, periodique)" }
            elseif ($text -match "(?i)retail") { return "Active - licence RETAIL (permanente)" }
            elseif ($text -match "(?i)oem") { return "Active - licence OEM (permanente)" }
            else { return "Active (type non precise)" }
        } else {
            return "NON activee ou etat indetermine"
        }
    } catch {
        return "Impossible a verifier"
    }
}

function InfosSysteme {
    Clear-Host
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  ITHECH - Informations systeme" -ForegroundColor Cyan
    Write-Host "===============================================`n"

    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor
    $cs = Get-CimInstance Win32_ComputerSystem

    Write-Host "SYSTEME" -ForegroundColor Yellow
    Write-Host "  OS             : $($os.Caption) ($($os.OSArchitecture))"
    Write-Host "  Version/Build  : $($os.Version) (Build $($os.BuildNumber))"
    Write-Host "  Machine        : $($cs.Manufacturer) $($cs.Model)"

    Write-Host "`nPROCESSEUR" -ForegroundColor Yellow
    Write-Host "  Modele         : $($cpu.Name.Trim())"
    Write-Host "  Coeurs         : $($cpu.NumberOfCores) coeurs / $($cpu.NumberOfLogicalProcessors) logiques"

    Write-Host "`nMEMOIRE" -ForegroundColor Yellow
    $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    Write-Host "  RAM installee  : $ramGB Go"

    Write-Host "`nDISQUE" -ForegroundColor Yellow
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        $totalGB = [math]::Round($_.Size / 1GB, 1)
        $freeGB = [math]::Round($_.FreeSpace / 1GB, 1)
        Write-Host "  $($_.DeviceID)  $freeGB Go libres / $totalGB Go au total"
    }

    Write-Host "`nCOMPATIBILITE WINDOWS 11" -ForegroundColor Yellow
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        Write-Host "  TPM            : present=$($tpm.TpmPresent), actif=$($tpm.TpmEnabled), version=$($tpm.ManufacturerVersion)"
    } catch {
        Write-Host "  TPM            : non detectable (normal sur Windows 7/8)"
    }
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        Write-Host "  Mode demarrage : UEFI"
        Write-Host "  Secure Boot    : $(if ($sb) { 'Actif' } else { 'Present mais desactive dans le BIOS' })"
    } catch {
        Write-Host "  Mode demarrage : Legacy / BIOS (ou non determinable)"
        Write-Host "  Secure Boot    : non disponible"
    }

    Write-Host "`nACTIVATION" -ForegroundColor Yellow
    $winAct = Get-WindowsActivation
    $offAct = Get-OfficeActivation
    Write-Host "  Windows        : $winAct"
    Write-Host "  Office         : $offAct"

    if ($winAct -notmatch "^Active" -or $offAct -notmatch "^Active") {
        $retry = Read-HostClean "`nTenter une (re)activation avec la licence deja configuree sur ce PC ? (O/N)"
        if ($retry -match "^[oO]") {
            Write-Host "`nActivation Windows..."
            cscript //nologo "$env:windir\system32\slmgr.vbs" /ato
            Write-Host "`nActivation Office..."
            $osppPaths = @(
                "$env:ProgramFiles\Microsoft Office\Office16\ospp.vbs",
                "${env:ProgramFiles(x86)}\Microsoft Office\Office16\ospp.vbs",
                "$env:ProgramFiles\Microsoft Office\Office15\ospp.vbs",
                "${env:ProgramFiles(x86)}\Microsoft Office\Office15\ospp.vbs"
            )
            $osppPath = $osppPaths | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
            if ($osppPath) {
                cscript //nologo $osppPath /act
            } else {
                Write-Host "Office non detecte, etape ignoree."
            }
            Write-Host "`nNouveau statut :"
            Write-Host "  Windows        : $(Get-WindowsActivation)"
            Write-Host "  Office         : $(Get-OfficeActivation)"
        }
    }

    Read-HostClean "`nAppuie sur Entree pour continuer"
}

function RestoreWindowsOld {
    Clear-Host
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  ITHECH - Recuperation fichiers Windows.old" -ForegroundColor Cyan
    Write-Host "===============================================`n"

    $oldPath = "C:\Windows.old"

    if (-not (Test-Path $oldPath)) {
        Write-Host "Windows.old introuvable sur C: -- ce PC n'a pas de donnees a recuperer." -ForegroundColor Yellow
        Read-HostClean "`nAppuie sur Entree pour continuer"
        return
    }

    Write-Host "Windows.old detecte : $oldPath" -ForegroundColor Green
    Write-Host "`nCe script va transferer vos dossiers personnels (Bureau, Documents,"
    Write-Host "Telechargements, Images, Musique, Videos, Favoris...) depuis l'ancien"
    Write-Host "systeme vers votre profil Windows actuel."
    Write-Host "`nMode par defaut : DEPLACEMENT (les fichiers sont retires de Windows.old"
    Write-Host "une fois transferes). Windows.old n'est jamais supprime automatiquement."

    $confirm = Read-HostClean "`nLancer la recuperation ? (O/N)"
    if ($confirm -notmatch "^[oO]") {
        Write-Host "Annule." -ForegroundColor Yellow
        return
    }

    Write-Host "`nTelechargement du script de recuperation..."
    try {
        $scriptContent = (New-Object Net.WebClient).DownloadString($RestoreUrl)
        Invoke-Expression $scriptContent
    } catch {
        Write-Host "`nEchec du telechargement : $_" -ForegroundColor Red
        Write-Host "Verifie la connexion internet ou lance directement :"
        Write-Host "  irm $RestoreUrl | iex" -ForegroundColor Yellow
        Read-HostClean "`nAppuie sur Entree pour continuer"
    }
}

# ===================== OPTION 7 — CLES PRODUIT =====================

function Decode-RegistryKey {
    param([byte[]]$dpid)
    try {
        $keyOffset = 52
        $isWin8 = [math]::Floor($dpid[$keyOffset + 14] / 6) -band 1
        $dpid[$keyOffset + 14] = ($dpid[$keyOffset + 14] -band 0xF7) -bor (($isWin8 -band 2) * 4)
        $chars = "BCDFGHJKMPQRTVWXY2346789"
        $key = ""; $dpidCopy = $dpid.Clone()
        for ($i = 24; $i -ge 0; $i--) {
            $cur = 0
            for ($j = 14; $j -ge 0; $j--) {
                $cur = $cur * 256 -bxor $dpidCopy[$j + $keyOffset]
                $dpidCopy[$j + $keyOffset] = [math]::Floor($cur / 24)
                $cur = $cur % 24
            }
            $key = $chars[$cur] + $key
            if ($i % 5 -eq 0 -and $i -ne 0) { $key = "-" + $key }
        }
        if ($isWin8) { $key = $key.Substring(2, 14) + "N" + $key.Substring(16) }
        return $key
    } catch { return $null }
}

function RecuperationCle {
    Clear-Host
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  ITHECH - Recuperation des cles produit" -ForegroundColor Cyan
    Write-Host "===============================================`n"

    Write-Host "WINDOWS" -ForegroundColor Yellow
    $winKey = $null
    try {
        $oemKey = (Get-WmiObject -query 'select * from SoftwareLicensingService' -ErrorAction Stop).OA3xOriginalProductKey
        if ($oemKey -and $oemKey.Trim().Length -gt 10) { $winKey = "OEM/UEFI  : $($oemKey.Trim())" }
    } catch {}
    if (-not $winKey) {
        try {
            $dpid = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop).DigitalProductId
            $decoded = Decode-RegistryKey ([byte[]]$dpid)
            if ($decoded) { $winKey = "Registre  : $decoded" }
        } catch {}
    }
    if ($winKey) {
        Write-Host "  Cle       : $winKey" -ForegroundColor Green
    } else {
        Write-Host "  Licence numerique liee au materiel -- pas de cle textuelle recuperable." -ForegroundColor Yellow
        Write-Host "  (Normal sur PC Windows 10/11 active par licence numerique)" -ForegroundColor Gray
    }

    Write-Host "`nOFFICE" -ForegroundColor Yellow
    $osppPaths = @(
        "$env:ProgramFiles\Microsoft Office\Office16\ospp.vbs",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office16\ospp.vbs",
        "$env:ProgramFiles\Microsoft Office\Office15\ospp.vbs",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office15\ospp.vbs"
    )
    $osppPath = $osppPaths | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if ($osppPath) {
        $result = cscript //nologo $osppPath /dstatus 2>$null
        $last5  = ($result | Select-String -Pattern "derniers|Last 5|last5" -ErrorAction SilentlyContinue |
                   Select-Object -First 1) -replace ".*:\s*", ""
        if ($last5) {
            Write-Host "  5 derniers caracteres : $last5" -ForegroundColor Green
            Write-Host "  (Microsoft masque le reste -- seuls les 5 derniers sont accessibles)" -ForegroundColor Gray
        } else {
            Write-Host "  Impossible de lire (Click-to-Run/365 -- activation par compte Microsoft)" -ForegroundColor Yellow
        }
    } else { Write-Host "  Office non detecte sur ce PC." -ForegroundColor Yellow }

    Read-HostClean "`nAppuie sur Entree pour continuer"
}

# ===================== OPTION 8 — SAUVEGARDE RAPIDE =====================

function SauvegardeRapide {
    Clear-Host
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  ITHECH - Sauvegarde rapide" -ForegroundColor Cyan
    Write-Host "===============================================`n"
    Write-Host "Dossiers sauvegardes : Bureau, Documents, Telechargements, Images`n"

    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Root -ne "C:\" -and (Test-Path $_.Root) }
    if (-not $drives) {
        Write-Host "Aucun lecteur de destination detecte (cle USB, disque externe)." -ForegroundColor Red
        Write-Host "Branche un support externe puis relance cette option."
        Read-HostClean "`nAppuie sur Entree pour continuer"
        return
    }

    Write-Host "Lecteurs disponibles :"
    $drives | ForEach-Object {
        $free = [math]::Round($_.Free / 1GB, 1)
        Write-Host "  $($_.Root)  --  $free Go libres" -ForegroundColor Cyan
    }

    $dest = Read-HostClean "`nLettre de destination (ex: D)"
    $destRoot = "$($dest.Trim().TrimEnd(':')):\Sauvegarde_ITHECH_$(Get-Date -Format 'yyyyMMdd_HHmm')"
    if (-not (Test-Path "$($dest.Trim().TrimEnd(':')):\")) {
        Write-Host "Lecteur introuvable." -ForegroundColor Red
        Read-HostClean "Appuie sur Entree pour continuer"
        return
    }

    $folders = @("Desktop","Documents","Downloads","Pictures")
    $shellFolders = @{
        Desktop     = [Environment]::GetFolderPath("Desktop")
        Documents   = [Environment]::GetFolderPath("MyDocuments")
        Downloads   = Join-Path $env:USERPROFILE "Downloads"
        Pictures    = [Environment]::GetFolderPath("MyPictures")
    }

    foreach ($name in $folders) {
        $src = $shellFolders[$name]
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $destRoot $name
        Write-Host "`nCopie : $name  -->  $dst"
        & robocopy $src $dst /E /MT:4 /R:1 /W:1 /NFL /NDL /NJH /NJS
    }

    Write-Host "`nSauvegarde terminee : $destRoot" -ForegroundColor Green
    Read-HostClean "`nAppuie sur Entree pour continuer"
}

# ===================== OPTION 9 — DIAGNOSTIC RESEAU =====================

function DiagnosticReseau {
    Clear-Host
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  ITHECH - Diagnostic reseau" -ForegroundColor Cyan
    Write-Host "===============================================`n"

    try {
        $adapters = Get-WmiObject Win32_NetworkAdapterConfiguration -ErrorAction Stop |
            Where-Object { $_.IPEnabled -eq $true }
    } catch {
        Write-Host "Impossible de lire la configuration reseau." -ForegroundColor Red
        Read-HostClean "`nAppuie sur Entree pour continuer"
        return
    }

    foreach ($a in $adapters) {
        Write-Host "Adaptateur : $($a.Description)" -ForegroundColor Yellow
        Write-Host "  IP        : $($a.IPAddress[0])"
        Write-Host "  Masque    : $($a.IPSubnet[0])"
        $gw = if ($a.DefaultIPGateway) { $a.DefaultIPGateway[0] } else { "(non definie)" }
        Write-Host "  Passerelle: $gw"
        $dns = if ($a.DNSServerSearchOrder) { $a.DNSServerSearchOrder -join ", " } else { "(aucun)" }
        Write-Host "  DNS       : $dns"

        if ($a.DefaultIPGateway) {
            $pingGW = Test-Connection $a.DefaultIPGateway[0] -Count 1 -Quiet -ErrorAction SilentlyContinue
            Write-Host "  Ping GW   : $(if ($pingGW) {'OK' } else {'ECHEC'} )" -ForegroundColor $(if ($pingGW) {"Green"} else {"Red"})
        }
        Write-Host ""
    }

    $ping88 = Test-Connection "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue
    Write-Host "Ping internet (8.8.8.8)  : $(if ($ping88) {'OK'} else {'ECHEC'})" -ForegroundColor $(if ($ping88) {"Green"} else {"Red"})

    try {
        $null = [System.Net.Dns]::GetHostAddresses("www.google.com")
        Write-Host "Resolution DNS (google)  : OK" -ForegroundColor Green
    } catch {
        Write-Host "Resolution DNS (google)  : ECHEC -- probleme DNS" -ForegroundColor Red
    }

    Write-Host ""
    if (-not $ping88) {
        Write-Host "Conseil : pas de ping internet --> essaie l'option 11 (Reset pile reseau)." -ForegroundColor Yellow
    }

    Read-HostClean "`nAppuie sur Entree pour continuer"
}

# ===================== OPTION 10 — PILOTES INUTILES =====================

function NettoyagePilotes {
    Clear-Host
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  ITHECH - Nettoyage des pilotes inutiles" -ForegroundColor Cyan
    Write-Host "===============================================`n"
    Write-Host "Recherche des peripheriques fantomes (deconnectes)..."

    try {
        $ghosts = Get-PnpDevice -ErrorAction Stop |
            Where-Object { $_.Status -eq 'Unknown' -or $_.Present -eq $false } |
            Where-Object { $_.Class -notin @('Computer','Processor','DiskDrive','Volume','HIDClass') }
    } catch {
        Write-Host "Get-PnpDevice non disponible (Windows 7)." -ForegroundColor Yellow
        $env:devmgr_show_nonpresent_devices = "1"
        Write-Host "Active l'affichage des peripheriques masques dans le Gestionnaire de peripheriques :"
        Write-Host "  devmgmt.msc -> Affichage -> Afficher les peripheriques masques"
        Read-HostClean "`nAppuie sur Entree pour continuer"
        return
    }

    if (-not $ghosts) {
        Write-Host "Aucun peripherique fantome detecte." -ForegroundColor Green
        Read-HostClean "`nAppuie sur Entree pour continuer"
        return
    }

    Write-Host "$($ghosts.Count) peripherique(s) fantome(s) detecte(s) :`n"
    $ghosts | ForEach-Object { Write-Host "  [$($_.Class)]  $($_.FriendlyName)" }

    $confirm = Read-HostClean "`nSupprimerles peripheriques fantomes et leurs pilotes ? (O/N)"
    if ($confirm -notmatch "^[oO]") { Write-Host "Annule."; return }

    $ghosts | ForEach-Object {
        Write-Host "  Suppression : $($_.FriendlyName)..."
        & pnputil /remove-device $_.InstanceId | Out-Null
    }

    Write-Host "`nNettoyage termine." -ForegroundColor Green
    Read-HostClean "`nAppuie sur Entree pour continuer"
}

# ===================== OPTION 11 — RESET PILE RESEAU =====================

function ResetReseau {
    Clear-Host
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  ITHECH - Reinitialisation de la pile reseau" -ForegroundColor Cyan
    Write-Host "===============================================`n"
    Write-Host "Corrige la plupart des problemes 'plus d'internet' sans reinstaller."
    Write-Host "REDEMARRAGE obligatoire a la fin.`n"

    $confirm = Read-HostClean "Confirmer la reinitialisation ? (O/N)"
    if ($confirm -notmatch "^[oO]") { Write-Host "Annule."; return }

    Write-Host "`n[1/6] Winsock reset..."
    netsh winsock reset | Out-Null

    Write-Host "[2/6] IP reset..."
    netsh int ip reset | Out-Null

    Write-Host "[3/6] IPv4 reset..."
    netsh int ipv4 reset | Out-Null

    Write-Host "[4/6] IPv6 reset..."
    netsh int ipv6 reset | Out-Null

    Write-Host "[5/6] Liberation IP (release)..."
    ipconfig /release | Out-Null

    Write-Host "[6/6] Vider le cache DNS..."
    ipconfig /flushdns | Out-Null

    Write-Host "`nReinitialisation terminee." -ForegroundColor Green
    Write-Host "IMPORTANT : redemarrage necessaire pour appliquer." -ForegroundColor Yellow

    $r = Read-HostClean "Redemarrer maintenant ? (O/N)"
    if ($r -match "^[oO]") { Restart-Computer -Force }
}

# ===================== OPTION 12 — PLANIFICATEUR DE TACHES =====================

function NettoyageTaches {
    Clear-Host
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  ITHECH - Desactivation des taches inutiles" -ForegroundColor Cyan
    Write-Host "===============================================`n"

    $tasks = @(
        @{Path="\Microsoft\Windows\Application Experience"; Name="Microsoft Compatibility Appraiser"},
        @{Path="\Microsoft\Windows\Application Experience"; Name="ProgramDataUpdater"},
        @{Path="\Microsoft\Windows\Autochk";                Name="Proxy"},
        @{Path="\Microsoft\Windows\Customer Experience Improvement Program"; Name="Consolidator"},
        @{Path="\Microsoft\Windows\Customer Experience Improvement Program"; Name="UsbCeip"},
        @{Path="\Microsoft\Windows\DiskDiagnostic";         Name="Microsoft-Windows-DiskDiagnosticDataCollector"},
        @{Path="\Microsoft\Windows\Feedback\Siuf";          Name="DmClient"},
        @{Path="\Microsoft\Windows\Feedback\Siuf";          Name="DmClientOnScenarioDownload"},
        @{Path="\Microsoft\Windows\Windows Error Reporting";Name="QueueReporting"},
        @{Path="\Microsoft\Windows\Maps";                   Name="MapsUpdateTask"},
        @{Path="\Microsoft\Windows\Maps";                   Name="MapsToastTask"},
        @{Path="\Microsoft\Windows\Power Efficiency Diagnostics"; Name="AnalyzeSystem"},
        @{Path="\Microsoft\Windows\Shell";                  Name="FamilySafetyMonitor"},
        @{Path="\Microsoft\Windows\Shell";                  Name="FamilySafetyRefreshTask"}
    )

    $disabled = 0; $notFound = 0
    foreach ($t in $tasks) {
        try {
            Disable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop | Out-Null
            Write-Host "  OK : $($t.Name)" -ForegroundColor Green
            $disabled++
        } catch {
            Write-Host "  -- : $($t.Name) (absente ou deja desactivee)" -ForegroundColor Gray
            $notFound++
        }
    }

    Write-Host "`n$disabled tache(s) desactivee(s), $notFound absente(s) ou deja desactivee(s)." -ForegroundColor Cyan
    Read-HostClean "`nAppuie sur Entree pour continuer"
}

# ===================== SOUS-MENUS PRINCIPAUX =====================

function Menu1DiagnosticInfo {
    do {
        Clear-Host
        Write-Host "===============================================" -ForegroundColor Cyan
        Write-Host "  1. Diagnostic et Informations" -ForegroundColor Cyan
        Write-Host "===============================================`n"
        Write-Host "  1. Informations systeme (OS, RAM, CPU, activation...)"
        Write-Host "  2. Cles produit (Windows + Office)`n"
        Write-Host "  0. Retour`n"
        switch (Read-HostClean "Choix") {
            "1" { InfosSysteme }
            "2" { RecuperationCle }
            "0" { return }
            default { Write-Host "Choix invalide."; Start-Sleep 1 }
        }
    } while ($true)
}

function DemarrageProgrammes {
    Clear-Host
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  ITHECH - Programmes au demarrage" -ForegroundColor Cyan
    Write-Host "===============================================`n"

    $regPaths = @(
        @{Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; Scope="HKCU"},
        @{Path="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; Scope="HKLM"},
        @{Path="HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Scope="HKLM32"}
    )

    $disabled = 0; $errors = 0; $found = 0

    foreach ($reg in $regPaths) {
        if (-not (Test-Path $reg.Path -ErrorAction SilentlyContinue)) { continue }
        $entries = Get-ItemProperty $reg.Path -ErrorAction SilentlyContinue
        if (-not $entries) { continue }

        $approvedPath = if ($reg.Scope -eq "HKCU") {
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
        } else {
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
        }

        $entries.PSObject.Properties |
            Where-Object { $_.Name -notlike "PS*" } |
            ForEach-Object {
                $name = $_.Name; $found++
                try {
                    if (-not (Test-Path $approvedPath -ErrorAction SilentlyContinue)) {
                        New-Item -Path $approvedPath -Force | Out-Null
                    }
                    # 0x03 = desactive (meme methode que Task Manager -- reversible)
                    $val = [byte[]](0x03,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)
                    New-ItemProperty -Path $approvedPath -Name $name -Value $val -PropertyType Binary -Force | Out-Null
                    Write-Host "  [DESACTIVE] $name" -ForegroundColor Green
                    $disabled++
                } catch {
                    Write-Host "  [ECHEC]    $name -- $_" -ForegroundColor Red
                    $errors++
                }
            }
    }

    if ($found -eq 0) {
        Write-Host "Aucun programme de demarrage trouve." -ForegroundColor Green
    } else {
        Write-Host "`n$disabled desactive(s)" -ForegroundColor Cyan
        if ($errors -gt 0) { Write-Host "$errors echec(s) -- droits insuffisants sur ces entrees." -ForegroundColor Red }
        Write-Host "`nTous reversibles via : Gestionnaire des taches > Demarrage." -ForegroundColor Yellow
    }

    Read-HostClean "`nAppuie sur Entree pour continuer"
}

function Menu2Optimisation {
    do {
        Clear-Host
        Write-Host "===============================================" -ForegroundColor Cyan
        Write-Host "  2. Optimisation" -ForegroundColor Cyan
        Write-Host "===============================================`n"
        Write-Host "  1. Services inutiles + Nettoyage disque complet"
        Write-Host "  2. Programmes au demarrage (desactivation automatique)"
        Write-Host "  3. Desactivation des taches planifiees inutiles"
        Write-Host "  4. Nettoyage des pilotes fantomes`n"
        Write-Host "  0. Retour`n"
        switch (Read-HostClean "Choix") {
            "1" { Optimisation }
            "2" { DemarrageProgrammes }
            "3" { NettoyageTaches }
            "4" { NettoyagePilotes }
            "0" { return }
            default { Write-Host "Choix invalide."; Start-Sleep 1 }
        }
    } while ($true)
}

function Menu3Reparation {
    do {
        Clear-Host
        Write-Host "===============================================" -ForegroundColor Cyan
        Write-Host "  3. Reparation systeme" -ForegroundColor Cyan
        Write-Host "===============================================`n"
        Write-Host "  1. DISM + SFC -- source locale (ISO/cle USB)"
        Write-Host "     Rapide, hors-ligne, meme version requise."
        Write-Host ""
        Write-Host "  2. DISM + SFC -- en ligne (Windows Update)"
        Write-Host "     Plus lent, internet requis, toutes versions.`n"
        Write-Host "  0. Retour`n"
        switch (Read-HostClean "Choix") {
            "1" { ReparationLocale }
            "2" { ReparationOnline }
            "0" { return }
            default { Write-Host "Choix invalide."; Start-Sleep 1 }
        }
    } while ($true)
}

function Menu4Reseau {
    do {
        Clear-Host
        Write-Host "===============================================" -ForegroundColor Cyan
        Write-Host "  4. Reseau" -ForegroundColor Cyan
        Write-Host "===============================================`n"
        Write-Host "  1. Diagnostic reseau (IP, ping, DNS)"
        Write-Host "  2. Reinitialisation pile reseau (Winsock, IP...)"
        Write-Host "  3. Reparer acces TLS 1.1/1.2 (Windows 7/8/8.1)`n"
        Write-Host "  0. Retour`n"
        switch (Read-HostClean "Choix") {
            "1" { DiagnosticReseau }
            "2" { ResetReseau }
            "3" { FixTLS }
            "0" { return }
            default { Write-Host "Choix invalide."; Start-Sleep 1 }
        }
    } while ($true)
}

function Menu5Migration {
    do {
        Clear-Host
        Write-Host "===============================================" -ForegroundColor Cyan
        Write-Host "  5. Migration Windows" -ForegroundColor Cyan
        Write-Host "===============================================`n"
        Write-Host "  1. Sauvegarde rapide (Bureau, Documents...)"
        Write-Host "  2. Mise a niveau Windows 10/11"
        Write-Host "  3. Recuperer les fichiers depuis Windows.old`n"
        Write-Host "  0. Retour`n"
        switch (Read-HostClean "Choix") {
            "1" { SauvegardeRapide }
            "2" { MiseANiveau }
            "3" { RestoreWindowsOld }
            "0" { return }
            default { Write-Host "Choix invalide."; Start-Sleep 1 }
        }
    } while ($true)
}

# ===================== MENU PRINCIPAL =====================

do {
    Clear-Host
    Write-Host "================================================"
    Write-Host "   ITHECH - Outil de maintenance PC"
    Write-Host "================================================`n"
    Write-Host "  1. Diagnostic et Informations"
    Write-Host "     Infos systeme, cles produit, activation"
    Write-Host ""
    Write-Host "  2. Optimisation"
    Write-Host "     Services, nettoyage disque, taches, pilotes"
    Write-Host ""
    Write-Host "  3. Reparation systeme"
    Write-Host "     DISM + SFC (locale ou en ligne)"
    Write-Host ""
    Write-Host "  4. Reseau"
    Write-Host "     Diagnostic, reset pile, fix TLS"
    Write-Host ""
    Write-Host "  5. Migration Windows"
    Write-Host "     Sauvegarde, mise a niveau, Windows.old`n"
    Write-Host "  0. Quitter`n"
    $choix = Read-HostClean "Choix"
    switch ($choix) {
        "1" { Menu1DiagnosticInfo }
        "2" { Menu2Optimisation }
        "3" { Menu3Reparation }
        "4" { Menu4Reseau }
        "5" { Menu5Migration }
        "0" { Clear-ToolHistory; exit }
        default { Write-Host "Choix invalide."; Start-Sleep 1 }
    }
} while ($true)
