@echo off
setlocal enabledelayedexpansion

rem =========================================================
rem  Collecte des donnees d'activation Windows (WPA / OEM)
rem  Registre + fichiers + dllcache + infos systeme
rem  Usage : collecte_wpa.bat [etiquette_etat]
rem  Ex.   : collecte_wpa.bat avant
rem          collecte_wpa.bat apres_reinstall_pidgen
rem =========================================================

set "BASE=C:\temp\2k3"

if "%~1"=="" (
    set /p "LABEL=Nom/etiquette de l'etat (ex: avant, apres) : "
) else (
    set "LABEL=%~1"
)
if "%LABEL%"=="" set "LABEL=etat"

rem --- horodatage independant des parametres regionaux ---
for /f %%T in ('wmic os get localdatetime ^| find "."') do set "DTS=%%T"
if not defined DTS set "DTS=00000000000000"
set "STAMP=%DTS:~0,8%_%DTS:~8,6%"

set "DEST=%BASE%\%COMPUTERNAME%_%LABEL%_%STAMP%"
set "REGDIR=%DEST%\registre"
set "FILEDIR=%DEST%\fichiers"
set "CACHEDIR=%DEST%\dllcache"
set "INFODIR=%DEST%\info"

md "%BASE%"    >nul 2>&1
md "%DEST%"    >nul 2>&1
md "%REGDIR%"  >nul 2>&1
md "%FILEDIR%" >nul 2>&1
md "%CACHEDIR%">nul 2>&1
md "%INFODIR%" >nul 2>&1

echo ============================================================
echo  Collecte des donnees d'activation Windows (WPA)
echo  Etat        : %LABEL%
echo  Ordinateur  : %COMPUTERNAME%
echo  Horodatage  : %STAMP%
echo  Destination : %DEST%
echo ============================================================
echo.

rem ------------------------------------------------------------
echo [*] Export des cles de registre...
reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion"          "%REGDIR%\WinNT_CurrentVersion.reg"  /y >nul 2>&1
reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WPAEvents" "%REGDIR%\WPAEvents.reg"             /y >nul 2>&1
reg export "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion"             "%REGDIR%\Windows_CurrentVersion.reg" /y >nul 2>&1
reg export "HKLM\SOFTWARE\Microsoft\Internet Explorer\Registration"     "%REGDIR%\IE_Registration.reg"        /y >nul 2>&1
reg export "HKLM\SYSTEM\Setup"                                          "%REGDIR%\System_Setup.reg"           /y >nul 2>&1
reg export "HKLM\SYSTEM\WPA"                                            "%REGDIR%\System_WPA.reg"             /y >nul 2>&1

rem ------------------------------------------------------------
echo [*] Copie des fichiers lies a l'activation (System32)...
set "SRC=%SystemRoot%\System32"

for %%F in (
    pidgen.dll
    dpcdll.dll
    licdll.dll
    licwmi.dll
    regwizc.dll
    wpabaln.exe
    oembios.bin
    oembios.dat
    oembios.sig
    wpa.dbl
    wpa.bak
) do (
    if exist "%SRC%\%%F" (
        copy /y "%SRC%\%%F" "%FILEDIR%\" >nul 2>&1
    ) else (
        echo     absent : %%F >> "%INFODIR%\fichiers_manquants.txt"
    )
)

if exist "%SRC%\oobe\msoobe.exe" (
    copy /y "%SRC%\oobe\msoobe.exe" "%FILEDIR%\" >nul 2>&1
) else (
    echo     absent : oobe\msoobe.exe >> "%INFODIR%\fichiers_manquants.txt"
)

echo [*] Recherche de oembios.cat dans System32\CatRoot...
set "FOUND_CAT=0"
if exist "%SRC%\CatRoot" (
    for /r "%SRC%\CatRoot" %%C in (oembios.cat) do (
        if exist "%%C" (
            copy /y "%%C" "%FILEDIR%\oembios.cat" >nul 2>&1
            set "FOUND_CAT=1"
        )
    )
)
if "!FOUND_CAT!"=="0" echo     absent : CatRoot\...\oembios.cat >> "%INFODIR%\fichiers_manquants.txt"

rem ------------------------------------------------------------
echo [*] Copie des equivalents dans System32\dllcache...
for %%F in (
    pidgen.dll
    dpcdll.dll
    licdll.dll
    licwmi.dll
    regwizc.dll
    wpabaln.exe
    msoobe.exe
    oembios.bin
    oembios.dat
    oembios.sig
    oembios.cat
    wpa.dbl
    wpa.bak
) do (
    if exist "%SRC%\dllcache\%%F" (
        copy /y "%SRC%\dllcache\%%F" "%CACHEDIR%\" >nul 2>&1
    ) else (
        echo     absent dans dllcache : %%F >> "%INFODIR%\fichiers_manquants.txt"
    )
)

rem ------------------------------------------------------------
echo [*] Lancement de winver (fermez la fenetre pour continuer)...
start "" /wait winver.exe

echo [*] systeminfo...
systeminfo > "%INFODIR%\systeminfo.txt" 2>&1

echo [*] wmic Win32_WindowsProductActivation...
wmic path Win32_WindowsProductActivation get /value > "%INFODIR%\wmic_WindowsProductActivation.txt" 2>&1

echo [*] reg query HKLM\SYSTEM\WPA /s...
reg query "HKLM\SYSTEM\WPA" /s > "%INFODIR%\reg_query_WPA.txt" 2>&1

echo.
echo ============================================================
echo  Termine. Donnees enregistrees dans :
echo  %DEST%
echo ============================================================
endlocal
pause
