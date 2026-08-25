# ITHECH - Outil de maintenance PC
# Usage : irm https://raw.githubusercontent.com/AbasseTALL/itech-tool/main/ithech.ps1 | iex

$ScriptUrl = "https://raw.githubusercontent.com/AbasseTALL/itech-tool/main/ithech.ps1"

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
    Start-Service wuauserv, bits -ErrorAction SilentlyContinue

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
    Read-Host "`nAppuie sur Entree pour continuer"
}

function ReparationLocale {
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  Reparation - source locale" -ForegroundColor Cyan
    Write-Host "===============================================`n"
    Write-Host "Monte l'ISO Windows ou branche la cle USB, puis indique le chemin.`n"
    $wimpath = Read-Host "Chemin complet vers install.wim (ex: D:\sources\install.wim)"
    if (-not (Test-Path $wimpath)) {
        Write-Host "Fichier introuvable : $wimpath" -ForegroundColor Red
        Read-Host "Appuie sur Entree pour continuer"
        return
    }
    $wimindex = Read-Host "Index de l'edition dans le wim (Entree = 1 par defaut)"
    if ([string]::IsNullOrWhiteSpace($wimindex)) { $wimindex = "1" }

    Write-Host "`nLancement de la reparation, patience...`n"
    Start-Process Dism.exe -ArgumentList "/Online /Cleanup-Image /RestoreHealth /Source:wim:$wimpath`:$wimindex /LimitAccess" -Wait -NoNewWindow

    Write-Host "`nVerification des fichiers systeme (SFC)...`n"
    Start-Process sfc.exe -ArgumentList "/scannow" -Wait -NoNewWindow

    Write-Host "`nTermine. Erreur de source DISM = version ISO differente du PC -- essaie l'option en ligne."
    Read-Host "Appuie sur Entree pour continuer"
}

function ReparationOnline {
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  Reparation - en ligne (Windows Update)" -ForegroundColor Cyan
    Write-Host "===============================================`n"
    Read-Host "Verifie la connexion internet du PC, puis appuie sur Entree"

    Write-Host "`nLancement de la reparation, patience (15-30 min)...`n"
    Start-Process Dism.exe -ArgumentList "/Online /Cleanup-Image /RestoreHealth" -Wait -NoNewWindow

    Write-Host "`nVerification des fichiers systeme (SFC)...`n"
    Start-Process sfc.exe -ArgumentList "/scannow" -Wait -NoNewWindow

    Write-Host "`nTermine."
    Read-Host "Appuie sur Entree pour continuer"
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
        $sc = Read-Host "Choix"
        switch ($sc) {
            "1" { ReparationLocale }
            "2" { ReparationOnline }
            "0" { return }
            default { Write-Host "Choix invalide."; Start-Sleep 1 }
        }
    } while ($true)
}

do {
    Clear-Host
    Write-Host "==============================================="
    Write-Host "  ITHECH - Outil de maintenance PC"
    Write-Host "===============================================`n"
    Write-Host "  1. Optimisation (services + nettoyage disque)"
    Write-Host "  2. Reparation de l'image Windows (DISM)`n"
    Write-Host "  0. Quitter`n"
    $choix = Read-Host "Choix"
    switch ($choix) {
        "1" { Optimisation }
        "2" { MenuReparation }
        "0" { Clear-ToolHistory; exit }
        default { Write-Host "Choix invalide."; Start-Sleep 1 }
    }
} while ($true)
