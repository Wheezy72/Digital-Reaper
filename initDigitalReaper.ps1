<# 
    DIGITAL REAPER - Engine Bootstrap Script
    ---------------------------------------
    One-time initializer that:
      - Creates the engine/ folder
      - Downloads yt-dlp.exe into engine/
      - Downloads a Windows FFmpeg build, extracts ffmpeg.exe into engine/
      - Cleans up temp files
      - Then schedules its own deletion

    Usage:
      1. Right-click this file > "Run with PowerShell"
         OR run from a PowerShell prompt:
             powershell -ExecutionPolicy Bypass -File .\initDigitalReaper.ps1
      2. After it finishes, you should have:
             engine\yt-dlp.exe
             engine\ffmpeg.exe
      3. The script will then remove itself.
#>

param()

$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK]   $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERR]  $Message" -ForegroundColor Red
}

try {
    $scriptPath = $MyInvocation.MyCommand.Path
    $scriptDir  = Split-Path -Parent $scriptPath
    $engineDir  = Join-Path $scriptDir "engine"

    Write-Host "==================================================" -ForegroundColor Magenta
    Write-Host "       DIGITAL REAPER - ENGINE INITIALIZER        " -ForegroundColor Magenta
    Write-Host "==================================================" -ForegroundColor Magenta
    Write-Host ""

    if (-not (Test-Path $engineDir)) {
        New-Item -Path $engineDir -ItemType Directory -Force | Out-Null
        Write-Ok "Created engine folder at: $engineDir"
    } else {
        Write-Info "engine folder already exists: $engineDir"
    }

    # -----------------------------
    # Download yt-dlp.exe
    # -----------------------------
    $ytDlpPath = Join-Path $engineDir "yt-dlp.exe"
    if (-not (Test-Path $ytDlpPath)) {
        Write-Info "Downloading yt-dlp.exe (latest release)..."
        $ytDlpUrl = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"
        Invoke-WebRequest -Uri $ytDlpUrl -OutFile $ytDlpPath -UseBasicParsing
        Write-Ok "yt-dlp.exe downloaded to engine/"
    } else {
        Write-Info "yt-dlp.exe already present in engine/. Skipping download."
    }

    # -----------------------------
    # Download FFmpeg (Windows build)
    # -----------------------------
    $ffmpegExePath = Join-Path $engineDir "ffmpeg.exe"
    if (-not (Test-Path $ffmpegExePath)) {
        Write-Info "Downloading FFmpeg (Windows 64-bit, GPL build)..."

        # This URL points to the latest 64-bit GPL static build zip from BtbN/FFmpeg-Builds
        $ffmpegZipUrl  = "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip"
        $ffmpegZipPath = Join-Path $engineDir "ffmpeg-download.zip"

        Invoke-WebRequest -Uri $ffmpegZipUrl -OutFile $ffmpegZipPath -UseBasicParsing
        Write-Ok "FFmpeg zip downloaded."

        Write-Info "Extracting ffmpeg.exe..."
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ffmpegZipPath, $engineDir)

        $ffmpegFound = Get-ChildItem -Path $engineDir -Filter "ffmpeg.exe" -Recurse | Select-Object -First 1
        if ($null -eq $ffmpegFound) {
            throw "ffmpeg.exe not found after extraction. The FFmpeg package layout may have changed."
        }

        Copy-Item $ffmpegFound.FullName $ffmpegExePath -Force
        Write-Ok "ffmpeg.exe placed in engine/."

        # Clean up extracted folders except ffmpeg.exe root copy
        Write-Info "Cleaning up temporary FFmpeg files..."
        Remove-Item $ffmpegZipPath -Force -ErrorAction SilentlyContinue

        Get-ChildItem -Path $engineDir -Directory | ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                # ignore cleanup failures
            }
        }
    } else {
        Write-Info "ffmpeg.exe already present in engine/. Skipping download."
    }

    Write-Host ""
    Write-Ok "ENGINE INITIALIZATION COMPLETE."
    Write-Host "yt-dlp.exe and ffmpeg.exe are now in: $engineDir" -ForegroundColor Cyan
    Write-Host ""

    # Schedule self-delete
    Write-Info "Scheduling initializer self-destruct..."
    $quotedPath = $scriptPath.Replace("'", "''")
    $cleanupCommand = "Start-Sleep -Seconds 3; Remove-Item -LiteralPath '$quotedPath' -Force"

    Start-Process powershell -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-Command", $cleanupCommand -WindowStyle Hidden | Out-Null

    Write-Host "This script will now exit and delete itself." -ForegroundColor Yellow
}
catch {
    Write-Err $_.Exception.Message
    Write-Host ""
    Write-Warn "Initialization failed. The script will NOT delete itself so you can inspect errors."
    exit 1
}