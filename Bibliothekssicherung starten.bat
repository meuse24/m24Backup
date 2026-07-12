@echo off
setlocal

set "SCRIPT=%~dp0Bibliothekssicherung-GUI.ps1"

if not exist "%SCRIPT%" (
    echo FEHLER: Das PowerShell-Skript wurde nicht gefunden:
    echo "%SCRIPT%"
    echo.
    pause
    exit /b 1
)

start "" powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%SCRIPT%"
exit /b 0
