@echo off
REM ================================================================
REM  DIGITAL REAPER - Background / Silent Runner
REM  Runs the downloader with no visible window.
REM  Add links to audioLinks.txt or videoLinks.txt, then run this.
REM
REM  HOW TO SCHEDULE (one-time setup):
REM    1. Open Task Scheduler  (taskschd.msc)
REM    2. "Create Basic Task" -> give it a name
REM    3. Trigger: choose your schedule (e.g. Daily)
REM    4. Action: "Start a program"
REM         Program:   %SystemRoot%\System32\cmd.exe
REM         Arguments: /c "C:\Path\To\runBackground.bat"
REM    5. Finish.  Done - Reaper will harvest automatically.
REM ================================================================

powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0digitalReaper.ps1"
