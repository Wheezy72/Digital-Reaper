@echo off
setlocal enabledelayedexpansion

title DIGITAL REAPER - Directory Cleanup Tool
color 0A

echo ================================================================
echo                 DIGITAL REAPER CLEANUP TOOL
echo ================================================================
echo.
echo This script hides technical files for a clean user experience.
echo Only essential files will remain visible after cleanup.
echo.

REM List of files and folders to keep visible
set "VISIBLE_FILES=digitalReaper.bat settings.json README.md downloads cleanup.bat"

echo [INFO] Starting directory cleanup...
echo [INFO] Files to keep visible: %VISIBLE_FILES%
echo.

REM Count files for progress tracking
set /a HIDDEN_COUNT=0
set /a KEPT_COUNT=0

REM Process all files in current directory
for %%f in (*) do (
    set "HIDE_FILE=1"
    
    REM Check if file should remain visible
    for %%v in (%VISIBLE_FILES%) do (
        if /I "%%f"=="%%v" set "HIDE_FILE=0"
    )
    
    REM Hide file if not in visible list
    if !HIDE_FILE!==1 (
        attrib +h "%%f" >nul 2>&1
        if !errorlevel!==0 (
            echo [HIDDEN] %%f
            set /a HIDDEN_COUNT+=1
        ) else (
            echo [ERROR]  Could not hide: %%f
        )
    ) else (
        echo [KEEP]   %%f
        set /a KEPT_COUNT+=1
    )
)

REM Process directories (except downloads)
echo.
echo [INFO] Processing directories...
for /d %%d in (*) do (
    if /I not "%%d"=="downloads" (
        attrib +h "%%d" >nul 2>&1
        if !errorlevel!==0 (
            echo [HIDDEN] %%d/ (directory)
            set /a HIDDEN_COUNT+=1
            
            REM Hide contents of hidden directories
            if exist "%%d\*" (
                for /f "delims=" %%i in ('dir /b "%%d" 2^>nul') do (
                    attrib +h "%%d\%%i" >nul 2>&1
                )
            )
        ) else (
            echo [ERROR]  Could not hide directory: %%d
        )
    ) else (
        echo [KEEP]   %%d/ (downloads directory)
        set /a KEPT_COUNT+=1
    )
)

REM Display summary
echo.
echo ================================================================
echo                       CLEANUP SUMMARY
echo ================================================================
echo Files/folders hidden: %HIDDEN_COUNT%
echo Files/folders kept visible: %KEPT_COUNT%
echo.
echo VISIBLE ITEMS:
echo   - digitalReaper.bat  ^(main launcher^)
echo   - settings.json      ^(configuration^)
echo   - README.md          ^(documentation^)
echo   - downloads/         ^(output folder^)
echo.
echo HIDDEN ITEMS:
echo   - digitalReaper.ps1  ^(main script^)
echo   - yt-dlp.exe         ^(downloader binary^)
echo   - links.txt          ^(URL list^)
echo   - bin/               ^(ffmpeg folder^)
echo   - Other technical files
echo.
echo ================================================================
echo Cleanup completed successfully!
echo ================================================================
echo.

REM Ask user if they want to delete this cleanup script
set /p DELETE_SCRIPT="Delete this cleanup script? (y/n): "
if /I "%DELETE_SCRIPT%"=="y" (
    echo.
    echo [INFO] Self-destructing cleanup script...
    timeout /t 3 /nobreak >nul
    del "%~f0" >nul 2>&1
) else (
    echo.
    echo [INFO] Cleanup script kept. You can run it again if needed.
    pause
)

endlocal
