@echo off
title ITHECH - Outil de maintenance PC

:: Auto-elevation : si pas admin, se relance lui-meme avec les
:: droits administrateur (declenche l'invite UAC automatiquement)
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Demande des droits administrateur...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:menu
cls
echo ===============================================
echo   ITHECH - Outil de maintenance PC
echo ===============================================
echo.
echo   1. Optimisation (services + nettoyage disque)
echo   2. Reparation de l'image Windows (DISM)
echo.
echo   0. Quitter
echo ===============================================
echo.
set "choix="
set /p choix="Choix : "

if "%choix%"=="1" goto optimisation
if "%choix%"=="2" goto reparation
if "%choix%"=="0" goto fin
echo.
echo Choix invalide.
pause
goto menu

:optimisation
cls
echo ===============================================
echo   ITHECH - Desactivation des services inutiles
echo ===============================================
echo.

echo [1/9] SysMain (Superfetch)...
sc config SysMain start= disabled >nul
sc stop SysMain >nul 2>&1

echo [2/9] Experiences utilisateur connectees et telemetrie...
sc config DiagTrack start= disabled >nul
sc stop DiagTrack >nul 2>&1

echo [3/9] Rapport d'erreurs Windows...
sc config WerSvc start= disabled >nul
sc stop WerSvc >nul 2>&1

echo [4/9] Assistant de compatibilite des programmes...
sc config PcaSvc start= disabled >nul
sc stop PcaSvc >nul 2>&1

echo [5/9] Windows Search (indexation)...
sc config WSearch start= disabled >nul
sc stop WSearch >nul 2>&1

echo [6/9] Telecopie (Fax)...
sc config Fax start= disabled >nul
sc stop Fax >nul 2>&1

echo [7/9] Support Bluetooth...
sc config bthserv start= disabled >nul
sc stop bthserv >nul 2>&1

echo [8/9] Services Xbox Live...
sc config XblAuthManager start= disabled >nul
sc config XblGameSave start= disabled >nul
sc config XboxNetApiSvc start= disabled >nul
sc stop XblAuthManager >nul 2>&1
sc stop XblGameSave >nul 2>&1
sc stop XboxNetApiSvc >nul 2>&1

echo [9/9] Clavier tactile / ecriture manuscrite + Cartes telechargees...
sc config TabletInputService start= disabled >nul
sc config MapsBroker start= disabled >nul
sc stop TabletInputService >nul 2>&1
sc stop MapsBroker >nul 2>&1

echo.
echo ===============================================
echo   Services termine.
echo.
echo   Non inclus ici (verifier le besoin du client
echo   AVANT de les desactiver manuellement) :
echo     - Spooler          (coupe l'impression)
echo     - RemoteRegistry
echo     - seclogon         (ouverture de session secondaire)
echo.
echo   NE JAMAIS desactiver : Windows Update, BITS
echo ===============================================
echo.
echo ===============================================
echo   Nettoyage des fichiers inutiles
echo ===============================================
echo.

echo [1/5] Fichiers temporaires utilisateur (%%TEMP%%)...
del /q /f /s "%TEMP%\*" >nul 2>&1
for /d %%D in ("%TEMP%\*") do rd /s /q "%%D" >nul 2>&1

echo [2/5] Fichiers temporaires systeme (C:\Windows\Temp)...
del /q /f /s "C:\Windows\Temp\*" >nul 2>&1
for /d %%D in ("C:\Windows\Temp\*") do rd /s /q "%%D" >nul 2>&1

echo [3/5] Cache Windows Update (SoftwareDistribution\Download)...
net stop wuauserv >nul 2>&1
net stop bits >nul 2>&1
rd /s /q "C:\Windows\SoftwareDistribution\Download" >nul 2>&1
net start wuauserv >nul 2>&1
net start bits >nul 2>&1

echo [4/5] Corbeille (tous les disques)...
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\" rd /s /q "%%D:\$Recycle.Bin" >nul 2>&1
)

echo [5/5] Nettoyage des anciens composants de mise a jour (WinSxS)...
Dism.exe /online /Cleanup-Image /StartComponentCleanup >nul

echo.
echo ===============================================
echo   Nettoyage termine.
echo.
echo   Nettoyage plus profond possible (mais empeche de
echo   desinstaller les mises a jour recentes) :
echo     Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase
echo ===============================================
echo.
pause
goto menu

:reparation
cls
echo ===============================================
echo   Reparation de l'image Windows (DISM)
echo ===============================================
echo.
echo   1. Source locale (ISO / cle USB)
echo      Rapide, fonctionne sans internet -- MAIS l'ISO
echo      doit etre exactement la meme version/build que
echo      celle deja installee sur le PC (ex: ISO 24H2 sur
echo      un PC encore en 21H2 = echec "source introuvable").
echo.
echo   2. En ligne (Windows Update)
echo      Plus lent, necessite une connexion internet active
echo      -- mais recupere automatiquement les bons fichiers
echo      pour la version EXACTE deja installee sur le PC,
echo      peu importe laquelle. A privilegier en cas de doute
echo      ou d'echec de l'option 1.
echo.
echo   0. Retour au menu principal
echo ===============================================
echo.
set "sousChoix="
set /p sousChoix="Choix : "

if "%sousChoix%"=="1" goto reparation_locale
if "%sousChoix%"=="2" goto reparation_online
if "%sousChoix%"=="0" goto menu
echo.
echo Choix invalide.
pause
goto reparation

:reparation_locale
cls
echo ===============================================
echo   Reparation - source locale
echo ===============================================
echo.
echo   Etapes avant de continuer :
echo     1. Monte l'ISO Windows (clic droit ^> Monter)
echo        ou branche la cle USB qui le contient.
echo     2. Repere la lettre du lecteur et le chemin vers
echo        sources\install.wim sur ce lecteur.
echo.
set "wimpath="
set /p wimpath="Chemin complet vers install.wim (ex: D:\sources\install.wim) : "

if not exist "%wimpath%" (
    echo.
    echo Fichier introuvable : %wimpath%
    pause
    goto reparation
)

set "wimindex="
set /p wimindex="Index de l'edition dans le wim (Entree = 1 par defaut) : "
if "%wimindex%"=="" set "wimindex=1"

echo.
echo Lancement de la reparation, patience (plusieurs minutes,
echo ca peut sembler bloque a certains pourcentages, c'est normal)...
echo.
Dism.exe /Online /Cleanup-Image /RestoreHealth /Source:wim:%wimpath%:%wimindex% /LimitAccess

echo.
echo ===============================================
echo   Verification des fichiers systeme (SFC)
echo ===============================================
echo.
sfc /scannow

echo.
echo ===============================================
echo   Termine. Verifie les messages ci-dessus :
echo   "L'operation a reussi" (DISM) et "Windows Resource
echo   Protection n'a trouve aucune violation" ou "a
echo   reussi a reparer" (SFC) = ok.
echo   Erreur de source DISM (0x800f081f ou similaire) = la
echo   version de l'ISO ne correspond pas au PC -- relance
echo   ce script et choisis l'option 2 (en ligne) a la place.
echo ===============================================
echo.
pause
goto menu

:reparation_online
cls
echo ===============================================
echo   Reparation - en ligne (Windows Update)
echo ===============================================
echo.
echo   Verifie que le PC a bien un acces internet actif
echo   avant de continuer.
echo.
pause
echo.
echo Lancement de la reparation, patience (peut prendre
echo 15-30 minutes selon la connexion, ca peut sembler
echo bloque a certains pourcentages, c'est normal)...
echo.
Dism.exe /Online /Cleanup-Image /RestoreHealth

echo.
echo ===============================================
echo   Verification des fichiers systeme (SFC)
echo ===============================================
echo.
sfc /scannow

echo.
echo ===============================================
echo   Termine. Verifie les messages ci-dessus :
echo   "L'operation a reussi" (DISM) et "Windows Resource
echo   Protection n'a trouve aucune violation" ou "a
echo   reussi a reparer" (SFC) = ok.
echo ===============================================
echo.
pause
goto menu

:fin
echo.
echo A bientot.
timeout /t 2 >nul
exit /b 0
