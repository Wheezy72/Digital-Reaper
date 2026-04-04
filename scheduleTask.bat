@echo off
setlocal enabledelayedexpansion
title DIGITAL REAPER - Task Scheduler Setup
color 0A

echo ================================================================
echo           DIGITAL REAPER - SCHEDULE SETUP
echo ================================================================
echo.
echo This will register Digital Reaper as a Windows Scheduled Task
echo so it runs automatically in the background.
echo.
echo NOTE: You will be asked for an interval. Add your links to
echo       audioLinks.txt or videoLinks.txt beforehand.
echo.
echo ================================================================
echo.

REM --- Task name
set "TASK_NAME=DigitalReaper"
set "BAT_PATH=%~dp0runBackground.bat"

REM --- Check if task already exists
schtasks /query /tn "%TASK_NAME%" >nul 2>&1
if %errorlevel% equ 0 (
    echo [!] A scheduled task named "%TASK_NAME%" already exists.
    echo.
    set /p OVERWRITE="Overwrite it? (y/n): "
    if /I not "!OVERWRITE!"=="y" (
        echo.
        echo [INFO] Setup cancelled. Existing task left unchanged.
        pause
        exit /b 0
    )
    schtasks /delete /tn "%TASK_NAME%" /f >nul 2>&1
    echo [INFO] Old task removed.
    echo.
)

REM --- Choose interval
echo How often should Digital Reaper run?
echo.
echo   1 = Every hour
echo   2 = Every 4 hours
echo   3 = Every 12 hours
echo   4 = Once a day  (midnight)
echo   5 = Once a week (Sunday midnight)
echo.
set /p CHOICE="Enter choice (1-5): "

if "%CHOICE%"=="1" (
    set "SCHEDULE_ARGS=/sc HOURLY /mo 1"
    set "SCHEDULE_DESC=every hour"
) else if "%CHOICE%"=="2" (
    set "SCHEDULE_ARGS=/sc HOURLY /mo 4"
    set "SCHEDULE_DESC=every 4 hours"
) else if "%CHOICE%"=="3" (
    set "SCHEDULE_ARGS=/sc HOURLY /mo 12"
    set "SCHEDULE_DESC=every 12 hours"
) else if "%CHOICE%"=="4" (
    set "SCHEDULE_ARGS=/sc DAILY /st 00:00"
    set "SCHEDULE_DESC=daily at midnight"
) else if "%CHOICE%"=="5" (
    set "SCHEDULE_ARGS=/sc WEEKLY /d SUN /st 00:00"
    set "SCHEDULE_DESC=weekly on Sunday at midnight"
) else (
    echo.
    echo [!] Invalid choice. Setup cancelled.
    pause
    exit /b 1
)

REM --- Register the task (runs as the current user)
schtasks /create /tn "%TASK_NAME%" /tr "cmd.exe /c \"%BAT_PATH%\"" %SCHEDULE_ARGS% /ru %USERNAME% /rl HIGHEST /f >nul 2>&1

if %errorlevel% equ 0 (
    echo.
    echo ================================================================
    echo  [+] Task "%TASK_NAME%" registered successfully!
    echo      Schedule : !SCHEDULE_DESC!
    echo      Runner   : %BAT_PATH%
    echo ================================================================
    echo.
    echo  To view or edit: open Task Scheduler (taskschd.msc)
    echo  To remove:       run removeTask.bat  -or-
    echo                   schtasks /delete /tn "%TASK_NAME%" /f
    echo.
) else (
    echo.
    echo [!] Failed to create task. Try running this as Administrator.
    echo.
)

pause
endlocal
