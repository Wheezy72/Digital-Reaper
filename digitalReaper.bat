@echo off
title DIGITAL REAPER - YouTube Harvester
color 07

REM Prefer PowerShell 7 when it is installed: it starts faster and does not wrap
REM native stderr in NativeCommandError blocks. Windows PowerShell 5.1 stays the
REM fallback, so a fresh Windows install still works without pwsh.
set "PSEXE=powershell"
where pwsh >nul 2>&1 && set "PSEXE=pwsh"

REM /doctor runs the diagnostics pass, then pauses so the window stays readable
if /I "%~1"=="/doctor" goto :DOCTOR

echo ===============================================
echo        DIGITAL REAPER - INITIALIZING
echo ===============================================
echo.

REM Check if a file was dropped on this batch file
if "%~1" neq "" (
    echo [+] Processing dropped file: %~1
    if /I "%~x1"==".json" (
        echo [+] Detected manifest/config file...
        "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0digitalReaper.ps1" -ConfigFile "%~1"
    ) else (
        "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0digitalReaper.ps1" -LinksFile "%~1"
    )
) else (
    echo [+] Starting DIGITAL REAPER in interactive mode...
    "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0digitalReaper.ps1"
)
exit /b

:DOCTOR
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0digitalReaper.ps1" -Doctor -Silent
set "DOCTOR_RC=%errorlevel%"
pause
exit /b %DOCTOR_RC%
