@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "SETUP_PS1=%SCRIPT_DIR%setup.ps1"

if not exist "%SETUP_PS1%" (
    echo [!] setup.ps1 not found.
    exit /b 1
)

where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%" -Silent
    exit /b %errorlevel%
)

where powershell >nul 2>&1
if %errorlevel%==0 (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%" -Silent
    exit /b %errorlevel%
)

echo [!] PowerShell is not available on this system.
echo     Install PowerShell 7+ from https://aka.ms/powershell-release?tag=stable
exit /b 1
