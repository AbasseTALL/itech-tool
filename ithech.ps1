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

function Clear-ToolHistory {
    try {
        $historyPath = (Get-PSReadLineOption -ErrorAction Stop).HistorySavePath
        if ($historyPath -and (Test-Path $historyPath)) {
            $lines = Get-Content $historyPath -ErrorAction Stop |
                Where-Object { $_ -notmatch [regex]::Escape($ScriptUrl) }
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

    Write-Host "[1/5] Fichiers temporaires utilisateur..."
    Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "[2/5] Fichiers temporaires systeme..."
    Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "[3/5] Cache Windows Update..."
    Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv, bits -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

    Write-Host "[4/5] Corbeille (tous les disques)..."
    Get-PSDrive -PSProvider FileSystem | ForEach-Object {
        $rb = Join-Path $_.Root '$Recycle.Bin'
        if (Test-Path $rb) { Remove-Item $rb -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Write-Host "[5/5] Nettoyage des anciens composants de mise a jour (WinSxS)..."
    Start-Process Dism.exe -ArgumentList "/online /Cleanup-Image /StartComponentCleanup" -Wait -NoNewWindow

    Write-Host "`nNettoyage termine.`n"
    Write-Host "Nettoyage plus profond possible (empeche de desinstaller les MAJ recentes) :"
    Write-Host "  Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase"
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
    Start-Process Dism.exe -ArgumentList "/Online /Cleanup-Image /RestoreHealth /Source:wim:$wimpath`:$wimindex /LimitAccess" -Wait -NoNewWindow

    Write-Host "`nVerification des fichiers systeme (SFC)...`n"
    Start-Process sfc.exe -ArgumentList "/scannow" -Wait -NoNewWindow

    Write-Host "`nTermine. Erreur de source DISM = version ISO differente du PC -- essaie l'option en ligne."
    Read-HostClean "Appuie sur Entree pour continuer"
}

function ReparationOnline {
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  Reparation - en ligne (Windows Update)" -ForegroundColor Cyan
    Write-Host "===============================================`n"
    Read-HostClean "Verifie la connexion internet du PC, puis appuie sur Entree"

    Write-Host "`nLancement de la reparation, patience (15-30 min)...`n"
    Start-Process Dism.exe -ArgumentList "/Online /Cleanup-Image /RestoreHealth" -Wait -NoNewWindow

    Write-Host "`nVerification des fichiers systeme (SFC)...`n"
    Start-Process sfc.exe -ArgumentList "/scannow" -Wait -NoNewWindow

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
    Write-Host "  Windows        : $(Get-WindowsActivation)"
    Write-Host "  Office         : $(Get-OfficeActivation)"

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

    Read-HostClean "`nAppuie sur Entree pour continuer"
}

do {
    Clear-Host
    Write-Host "==============================================="
    Write-Host "  ITHECH - Outil de maintenance PC"
    Write-Host "===============================================`n"
    Write-Host "  1. Optimisation (services + nettoyage disque)"
    Write-Host "  2. Reparation de l'image Windows (DISM)"
    Write-Host "  3. Mise a niveau du systeme (Windows 10/11)"
    Write-Host "  4. Reparer l'acces TLS 1.1/1.2 (Windows 7/8/8.1)"
    Write-Host "  5. Informations systeme (OS, RAM, CPU...)`n"
    Write-Host "  0. Quitter`n"
    $choix = Read-HostClean "Choix"
    switch ($choix) {
        "1" { Optimisation }
        "2" { MenuReparation }
        "3" { MiseANiveau }
        "4" { FixTLS }
        "5" { InfosSysteme }
        "0" { Clear-ToolHistory; exit }
        default { Write-Host "Choix invalide."; Start-Sleep 1 }
    }
} while ($true)
