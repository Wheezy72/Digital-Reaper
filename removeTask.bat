@echo off
title DIGITAL REAPER - Remove Scheduled Task
color 0A

echo ================================================================
echo         DIGITAL REAPER - REMOVE SCHEDULED TASK
echo ================================================================
echo.

schtasks /query /tn "DigitalReaper" >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] No scheduled task named "DigitalReaper" found.
    echo        Nothing to remove.
    echo.
    pause
    exit /b 0
)

echo [INFO] Found scheduled task "DigitalReaper".
set /p CONFIRM="Remove it? (y/n): "
if /I not "%CONFIRM%"=="y" (
    echo.
    echo [INFO] Cancelled. Task left in place.
    pause
    exit /b 0
)

schtasks /delete /tn "DigitalReaper" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo.
    echo [+] Task removed successfully.
) else (
    echo.
    echo [!] Failed to remove task. Try running as Administrator.
)

echo.
pause
