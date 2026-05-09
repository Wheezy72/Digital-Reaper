@echo off
setlocal enabledelayedexpansion
title DIGITAL REAPER - Scheduler
color 07

set "TASK_NAME=DigitalReaper"
set "SCRIPT_DIR=%~dp0"

:MENU
cls
echo ================================================================
echo           DIGITAL REAPER - SCHEDULER
echo ================================================================
echo.
echo   1 = Schedule  (register / update automated task)
echo   2 = Remove    (unregister scheduled task)
echo   3 = Run Now   (one silent background run)
echo   4 = Status    (check if task is registered)
echo   5 = Exit
echo.
echo ================================================================
echo.
set /p ACTION="Enter choice (1-5): "

if "%ACTION%"=="1" goto SCHEDULE
if "%ACTION%"=="2" goto REMOVE
if "%ACTION%"=="3" goto RUN_NOW
if "%ACTION%"=="4" goto STATUS
if "%ACTION%"=="5" goto END

echo.
echo [!] Invalid choice. Please enter 1-5.
timeout /t 2 >nul
goto MENU

REM ================================================================
REM  1 - SCHEDULE
REM ================================================================
:SCHEDULE
echo.
echo ----------------------------------------------------------------
echo  SCHEDULE SETUP
echo ----------------------------------------------------------------
echo.
echo  NOTE: Add your links to audioLinks.txt or videoLinks.txt
echo        before the task fires for the first time.
echo.

REM Check if task already exists
schtasks /query /tn "%TASK_NAME%" >nul 2>&1
if %errorlevel% equ 0 (
    echo [!] A scheduled task named "%TASK_NAME%" already exists.
    echo.
    set /p OVERWRITE="Overwrite it? (y/n): "
    if /I not "!OVERWRITE!"=="y" (
        echo.
        echo [INFO] Setup cancelled. Existing task left unchanged.
        echo.
        pause
        goto MENU
    )
    schtasks /delete /tn "%TASK_NAME%" /f >nul 2>&1
    echo [INFO] Old task removed.
    echo.
)

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
    echo.
    pause
    goto MENU
)

REM Register the task to call PowerShell directly — avoids a CMD window flash on every run
schtasks /create /tn "%TASK_NAME%" /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%SCRIPT_DIR%digitalReaper.ps1\" -Silent" %SCHEDULE_ARGS% /ru %USERNAME% /rl HIGHEST /f >nul 2>&1

if %errorlevel% equ 0 (
    echo.
    echo ================================================================
    echo  [+] Task "%TASK_NAME%" registered successfully!
    echo      Schedule : !SCHEDULE_DESC!
    echo ================================================================
    echo.
    echo  To view or edit: open Task Scheduler (taskschd.msc)
    echo  To remove:       run this script and choose option 2
    echo.
) else (
    echo.
    echo [!] Failed to create task. Try running this script as Administrator.
    echo.
)
pause
goto MENU

REM ================================================================
REM  2 - REMOVE
REM ================================================================
:REMOVE
echo.
echo ----------------------------------------------------------------
echo  REMOVE SCHEDULED TASK
echo ----------------------------------------------------------------
echo.

schtasks /query /tn "%TASK_NAME%" >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] No scheduled task named "%TASK_NAME%" found. Nothing to remove.
    echo.
    pause
    goto MENU
)

echo [INFO] Found scheduled task "%TASK_NAME%".
set /p CONFIRM="Remove it? (y/n): "
if /I not "%CONFIRM%"=="y" (
    echo.
    echo [INFO] Cancelled. Task left in place.
    echo.
    pause
    goto MENU
)

schtasks /delete /tn "%TASK_NAME%" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo.
    echo [+] Task removed successfully.
) else (
    echo.
    echo [!] Failed to remove task. Try running this script as Administrator.
)
echo.
pause
goto MENU

REM ================================================================
REM  3 - RUN NOW  (also called silently by the scheduled task)
REM ================================================================
:RUN_NOW
if /I "%1"=="/silent" (
    powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%digitalReaper.ps1" -Silent
    exit /b
)
echo.
echo ----------------------------------------------------------------
echo  RUNNING NOW (background / no window)
echo ----------------------------------------------------------------
echo.
echo [INFO] Launching Digital Reaper silently...
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%digitalReaper.ps1"
echo [INFO] Done.
echo.
pause
goto MENU

REM ================================================================
REM  4 - STATUS
REM ================================================================
:STATUS
echo.
echo ----------------------------------------------------------------
echo  TASK STATUS
echo ----------------------------------------------------------------
echo.
schtasks /query /tn "%TASK_NAME%" /fo LIST 2>nul
if %errorlevel% neq 0 (
    echo [INFO] No scheduled task named "%TASK_NAME%" is registered.
)
echo.
pause
goto MENU

REM ================================================================
REM  EXIT
REM ================================================================
:END
endlocal
