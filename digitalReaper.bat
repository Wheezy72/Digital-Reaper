@echo off
title DIGITAL REAPER
color 0A

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
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0digitalReaper.ps1"
)
