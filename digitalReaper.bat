@echo off
title DIGITAL REAPER
color 0A

echo ===============================================
echo        DIGITAL REAPER - INITIALIZING
echo ===============================================
echo.

REM Check if a file was dropped on this batch file
if "%~1" neq "" (
    echo [+] Processing dropped file: %~1
    if /I "%~x1"==".json" (
        echo [+] Detected manifest/config file...
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0digitalReaper.ps1" -ConfigFile "%~1"
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0digitalReaper.ps1" -LinksFile "%~1"
    )
) else (
    echo [+] Starting DIGITAL REAPER in interactive mode...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0digitalReaper.ps1"
)

echo.
echo ===============================================
if errorlevel 1 (
    echo [!] Script encountered an error!
    echo Check the messages above for details.
) else (
    echo [+] DIGITAL REAPER session completed.
)
echo ===============================================
echo.
echo Press any key to exit...
pause >nul
