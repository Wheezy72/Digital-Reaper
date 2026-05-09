<#
========================================================================
    DIGITAL REAPER - YouTube Downloader
    Custom tool for grabbing content with style
    Made by Wheezy for the culture
========================================================================
#>

param(
    [string]$LinksFile  = "",
    [string]$ConfigFile = "",
    [switch]$Silent
)

# ===================================================================
# --- SCRIPT CONFIGURATION ---
# ===================================================================

$script:ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:EngineDir   = Join-Path $script:ScriptDir "engine"
$script:YtDlpPath   = Join-Path $script:EngineDir "yt-dlp.exe"
$script:FfmpegPath  = Join-Path $script:EngineDir "ffmpeg.exe"
$script:FfprobePath = Join-Path $script:EngineDir "ffprobe.exe"

$script:DownloadsDir      = Join-Path $script:ScriptDir "downloads"
$script:DefaultLinksFile  = Join-Path $script:ScriptDir "links.txt"
$script:DefaultConfigFile = Join-Path $script:ScriptDir "settings.json"

# Dedicated audio/video link files + output folders
$script:AudioLinksFile = Join-Path $script:ScriptDir "audioLinks.txt"
$script:VideoLinksFile = Join-Path $script:ScriptDir "videoLinks.txt"
$script:AudioOutputDir = Join-Path $script:DownloadsDir "audio"
$script:VideoOutputDir = Join-Path $script:DownloadsDir "videos"

# Tracks the source file used by interactive mode (for post-download cleanup)
$script:SourceFile = ""

# Lock file — prevents concurrent scheduled runs
$script:LockFilePath = Join-Path $script:EngineDir "reaper.lock"

# Version file — persists the installed yt-dlp version across runs
$script:VersionFilePath = Join-Path $script:EngineDir "version.txt"

# ===================================================================
# --- ENHANCED AESTHETIC FUNCTIONS ---
# ===================================================================

function Write-TypeWriter {
    param([string]$Text, [string]$Color = "White", [int]$Speed = 30, [switch]$NoNewLine)
    foreach ($char in $Text.ToCharArray()) {
        Write-Host -NoNewline $char -ForegroundColor $Color
        Start-Sleep -Milliseconds $Speed
    }
    if (-not $NoNewLine) { Write-Host "" }
}

function Write-Pulse {
    param([string]$Text, [string[]]$Colors = @("Cyan", "White", "Cyan"), [int]$Cycles = 3, [int]$Speed = 500)
    for ($i = 0; $i -lt $Cycles; $i++) {
        foreach ($color in $Colors) {
            Write-Host "`r$Text" -ForegroundColor $color -NoNewline
            Start-Sleep -Milliseconds $Speed
        }
    }
    Write-Host ""
}

function Show-ProgressUpdate {
    param([string]$Status, [string]$Type = "Info")
    $timestamp = Get-Date -Format "HH:mm:ss"
    if ($Type -eq "Success") {
        Write-Pulse -Text "[$timestamp] $Status" -Colors @("Green", "White", "Green") -Cycles 1 -Speed 200
    } elseif ($Type -eq "Error") {
        Write-Pulse -Text "[$timestamp] $Status" -Colors @("Red", "DarkRed", "Red") -Cycles 2 -Speed 300
    } else {
        $color = switch ($Type) {
            "Warning" { "Yellow" }; "Target" { "Cyan" }; "System" { "Blue" }; "Update" { "Magenta" }
            default { "White" }
        }
        Write-Host "[$timestamp] $Status" -ForegroundColor $color
    }
}

function Show-StartupSequence {
    Write-Host ""
    Write-Host "________  .__       .__  __         .__    __________                                   " -ForegroundColor DarkRed
    Write-Host "\______ \ |__| ____ |__|/  |______  |  |   \______   \ ____ _____  ______   ___________ " -ForegroundColor DarkRed
    Write-Host " |    |  \|  |/ ___\|  \   __\__  \ |  |    |       _// __ \\__  \ \____ \_/ __ \_  __ \" -ForegroundColor DarkRed
    Write-Host " |    `   \  / /_/  >  ||  |  / __ \|  |__  |    |   \  ___/ / __ \|  |_> >  ___/|  | \/" -ForegroundColor DarkRed
    Write-Host "/_______  /__\___  /|__||__| (____  /____/  |____|_  /\___  >____  /   __/ \___  >__|   " -ForegroundColor DarkRed
    Write-Host "        \/  /_____/               \/               \/     \/     \/|__|        \/       " -ForegroundColor DarkRed
    Write-Host ""
    Write-Host "                            DIGITAL REAPER: LINK HARVESTER                             " -ForegroundColor Gray
    Write-Host ""
}

function Show-CompletionBanner {    $prodByWheezy = @'
    ____                 __   __             _       ____                         
   / __ \_______  ____/ /  / /_  __  __   | |     / / /_  ___  ___  ____  __  __
  / /_/ / ___/ __ \/ __  /  / __ \/ / / /   | | /| / / __ \/ _ \/ _ \/_  / / / / /
 / ____/ /  / /_/ / /_/ /  / /_/ / /_/ /    | |/ |/ / / / /  __/  __/ / /_/ /_/ / 
/_/   /_/   \____/\__,_/  /_.___/\__, /     |__/|__/_/ /_/\___/\___/ /___/\__, /  
                                /____/                                   /____/
'@

    $lines = $prodByWheezy -split "`n"
    foreach ($line in $lines) {
        Write-Host $line -ForegroundColor Magenta
    }

    Write-Host ""
}

function Get-UrlsFromFile {
    param ([string]$FilePath)
    $urls = @()
    if (Test-Path $FilePath) {
        $content = Get-Content $FilePath
        foreach ($line in $content) {
            if (Test-ValidUrl -Line $line) {
                $urls += Remove-InvisibleCharacters -Text $line
            }
        }
        if ($urls.Count -gt 0) {
            Show-ProgressUpdate "[+] $($urls.Count) target(s) loaded from file" -Type "Target"
        }
    }
    return $urls
}

function Show-MenuOption {
    param(
        [string]$Prompt,
        [string]$Options
    )

    Write-Host ""
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " $Prompt" -ForegroundColor Yellow
    Write-Host " Options: $Options" -ForegroundColor Gray
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    Write-Host -NoNewline "> " -ForegroundColor Yellow
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Show-DownloadBanner {
    param(
        [string]$TypeLabel,
        [string]$Mode,          # "BATCH" or "EXFILTRATION"
        [int]$TargetCount,
        [string]$OutputDir,
        [string]$Quality = ""
    )
    Write-Host ""
    Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkRed
    Write-Host "  |  DIGITAL REAPER  >>  $TypeLabel $Mode" -ForegroundColor Red
    Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkRed
    Write-Host "  | Targets : " -NoNewline -ForegroundColor Gray
    Write-Host "$TargetCount" -ForegroundColor Cyan
    Write-Host "  | Output  : " -NoNewline -ForegroundColor Gray
    Write-Host $OutputDir -ForegroundColor Yellow
    if ($Quality) {
        Write-Host "  | Quality : " -NoNewline -ForegroundColor Gray
        Write-Host $Quality -ForegroundColor Magenta
    }
    Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkRed
    Write-Host ""
}

function Remove-InvisibleCharacters {
    param([string]$Text)
    # Strip BOM (U+FEFF) and other invisible/zero-width characters
    return $Text.Trim().TrimStart([char]0xFEFF, [char]0x200B, [char]0x200C, [char]0x200D, [char]0xFFFE)
}

function Test-ValidUrl {
    param([string]$Line)
    $trimmed = Remove-InvisibleCharacters -Text $Line
    return $trimmed -and -not $trimmed.StartsWith("#") -and ($trimmed.StartsWith("http") -or $trimmed.StartsWith("www"))
}

# ===================================================================
# --- SETTINGS MANAGEMENT ---
# ===================================================================

function Get-DefaultSettings {
    return @{
        videoQuality      = "1080p"
        audioFormat       = "mp3"
        useHEVC           = $true
        downloadSubtitles = $true
        subtitleLanguages = @("en", "en-US")
        outputTemplate    = "[%(upload_date)s] %(title)s [%(id)s].%(ext)s"
        autoUpdate        = $true
        oneClickMode      = $true
        defaultDownloadType = "video"
        outputFolder      = ""
        cookieSource      = "none"
        maxRate           = "2M"
        concurrentFragments = 1
        retryCount        = 8
        outerRetryCount   = 3
    }
}

function Merge-SettingsFromFile {
    param([hashtable]$Settings, [string]$FilePath)
    if (-not (Test-Path $FilePath)) { return }
    $userSettings = Get-Content $FilePath | ConvertFrom-Json
    foreach ($key in $userSettings.PSObject.Properties.Name) {
        if ($Settings.ContainsKey($key)) {
            $Settings[$key] = $userSettings.$key
        }
    }
}

function Load-Settings {
    param([string]$ConfigPath)
    
    $settings = Get-DefaultSettings
    
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        try {
            Merge-SettingsFromFile -Settings $settings -FilePath $ConfigPath
            Show-ProgressUpdate "Settings loaded from: $ConfigPath" -Type "Success"
        } catch {
            Show-ProgressUpdate "Error loading settings file. Using defaults." -Type "Warning"
        }
    } elseif (Test-Path $script:DefaultConfigFile) {
        try {
            Merge-SettingsFromFile -Settings $settings -FilePath $script:DefaultConfigFile
            Show-ProgressUpdate "Settings loaded from: settings.json" -Type "Success"
        } catch {
            Show-ProgressUpdate "Error loading settings. Using defaults." -Type "Warning"
        }
    }
    
    return $settings
}

function Save-Settings {
    param([hashtable]$Settings)
    try {
        $ordered = [ordered]@{}
        foreach ($key in @(
            "videoQuality","audioFormat","useHEVC","downloadSubtitles","subtitleLanguages",
            "outputTemplate","autoUpdate","oneClickMode","defaultDownloadType","outputFolder",
            "cookieSource","maxRate","concurrentFragments","retryCount","outerRetryCount"
        )) {
            if ($Settings.ContainsKey($key)) {
                $ordered[$key] = $Settings[$key]
            }
        }
        $ordered | ConvertTo-Json -Depth 6 | Set-Content -Path $script:DefaultConfigFile
        Show-ProgressUpdate "[+] Settings saved to settings.json" -Type "Success"
    } catch {
        Show-ProgressUpdate "[!] Failed to save settings: $($_.Exception.Message)" -Type "Warning"
    }
}

function Show-SimpleSettingsPage {
    param([hashtable]$Settings)
    while ($true) {
        Write-Host ""
        Write-Host "=============== SIMPLE SETTINGS ===============" -ForegroundColor Cyan
        Write-Host "1) Video quality        : $($Settings.videoQuality)" -ForegroundColor White
        Write-Host "2) Output folder        : $(if ([string]::IsNullOrWhiteSpace($Settings.outputFolder)) { '[default downloads folder]' } else { $Settings.outputFolder })" -ForegroundColor White
        Write-Host "3) Subtitles            : $($Settings.downloadSubtitles)" -ForegroundColor White
        Write-Host "4) Cookie source        : $($Settings.cookieSource)" -ForegroundColor White
        Write-Host "5) One-click mode       : $($Settings.oneClickMode)" -ForegroundColor White
        Write-Host "6) Save and continue" -ForegroundColor Green
        Write-Host "===============================================" -ForegroundColor Cyan
        $choice = Read-Host "Choose (1-6)"
        switch ($choice) {
            "1" {
                $quality = Read-Host "Set quality (720p/1080p/1440p/4K)"
                if ($quality -in @("720p","1080p","1440p","4K")) {
                    $Settings.videoQuality = $quality
                } else {
                    Show-ProgressUpdate "[!] Invalid quality. Keeping current value." -Type "Warning"
                }
            }
            "2" {
                $folder = Read-Host "Set output folder path (leave empty for default)"
                $Settings.outputFolder = if ([string]::IsNullOrWhiteSpace($folder)) { "" } else { $folder.Trim() }
            }
            "3" {
                $toggle = Read-Host "Download subtitles? (y/n)"
                $Settings.downloadSubtitles = ($toggle -match "^(y|yes)$")
            }
            "4" {
                $cookie = Read-Host "Cookie source (none/chrome/edge/firefox)"
                if ($cookie -in @("none","chrome","edge","firefox")) {
                    $Settings.cookieSource = $cookie
                } else {
                    Show-ProgressUpdate "[!] Invalid cookie source. Keeping current value." -Type "Warning"
                }
            }
            "5" {
                $toggle = Read-Host "Enable one-click mode? (y/n)"
                $Settings.oneClickMode = ($toggle -match "^(y|yes)$")
            }
            "6" {
                Save-Settings -Settings $Settings
                return
            }
            default {
                Show-ProgressUpdate "[!] Invalid choice." -Type "Warning"
            }
        }
    }
}

function Get-BaseOutputDir {
    param([hashtable]$Settings)
    if ($Settings.outputFolder -and -not [string]::IsNullOrWhiteSpace($Settings.outputFolder)) {
        return $Settings.outputFolder
    }
    return $script:DownloadsDir
}

function Get-OutputDirForType {
    param(
        [hashtable]$Settings,
        [string]$DownloadType
    )
    $baseDir = Get-BaseOutputDir -Settings $Settings
    return if ($DownloadType -eq "audio") {
        Join-Path $baseDir "audio"
    } else {
        Join-Path $baseDir "videos"
    }
}

# ===================================================================
# --- INITIALIZATION & UPDATE FUNCTIONS ---
# ===================================================================

function Set-HiddenAttribute {
    param ([string]$Path)
    try {
        if (Test-Path $Path) {
            $item = Get-Item $Path -Force
            if (-not ($item.Attributes -band [System.IO.FileAttributes]::Hidden)) {
                $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
            }
        }
    } catch {
        # Silent fail
    }
}

function Install-YtDlp {
    Show-ProgressUpdate "[~] yt-dlp not found — downloading latest release..." -Type "Update"
    try {
        $apiUrl  = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
        $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'DigitalReaper' } -TimeoutSec 15 -ErrorAction Stop
        $asset   = $release.assets | Where-Object { $_.name -eq "yt-dlp.exe" } | Select-Object -First 1
        if (-not $asset) { throw "yt-dlp.exe asset not found in latest release." }

        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $script:YtDlpPath -TimeoutSec 120 -ErrorAction Stop

        $downloaded = Get-Item $script:YtDlpPath -ErrorAction SilentlyContinue
        if (-not $downloaded -or $downloaded.Length -eq 0) { throw "Downloaded file is empty." }

        Show-ProgressUpdate "[+] yt-dlp installed ($($release.tag_name))" -Type "Success"
        Set-Content -Path $script:VersionFilePath -Value $release.tag_name
        return $true
    } catch {
        Show-ProgressUpdate "[!] Failed to download yt-dlp: $($_.Exception.Message)" -Type "Error"
        return $false
    }
}

function Install-Ffmpeg {
    Show-ProgressUpdate "[~] ffmpeg not found — downloading static build (this may take a minute)..." -Type "Update"
    # Use the static (non-shared) GPL build so ffmpeg.exe and ffprobe.exe are
    # self-contained executables with no companion DLLs required.
    $zipUrl  = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
    $zipPath = Join-Path $env:TEMP "ffmpeg-reaper.zip"
    $extractPath = Join-Path $env:TEMP "ffmpeg-reaper"
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -TimeoutSec 300 -ErrorAction Stop

        $zipItem = Get-Item $zipPath -ErrorAction SilentlyContinue
        if (-not $zipItem -or $zipItem.Length -eq 0) { throw "Downloaded zip is empty." }

        if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
        Show-ProgressUpdate "[~] Extracting ffmpeg archive..." -Type "System"
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop

        # Locate ffmpeg.exe (lives in the bin/ subfolder of the top-level archive folder)
        $ffmpegExe = Get-ChildItem -Path $extractPath -Filter "ffmpeg.exe" -Recurse -ErrorAction SilentlyContinue |
                     Select-Object -First 1
        if (-not $ffmpegExe) { throw "ffmpeg.exe not found inside archive." }

        # Locate ffprobe.exe — yt-dlp needs it alongside ffmpeg.exe
        $ffprobeExe = Get-ChildItem -Path $extractPath -Filter "ffprobe.exe" -Recurse -ErrorAction SilentlyContinue |
                      Select-Object -First 1
        if (-not $ffprobeExe) { throw "ffprobe.exe not found inside archive." }

        Copy-Item $ffmpegExe.FullName  $script:FfmpegPath  -Force -ErrorAction Stop
        Copy-Item $ffprobeExe.FullName $script:FfprobePath -Force -ErrorAction Stop

        # Verify files are non-empty
        $installedFfmpeg  = Get-Item $script:FfmpegPath  -ErrorAction SilentlyContinue
        $installedFfprobe = Get-Item $script:FfprobePath -ErrorAction SilentlyContinue
        if (-not $installedFfmpeg  -or $installedFfmpeg.Length  -eq 0) { throw "Copied ffmpeg.exe is empty." }
        if (-not $installedFfprobe -or $installedFfprobe.Length -eq 0) { throw "Copied ffprobe.exe is empty." }

        # Functional verification — make sure both binaries actually run
        $null = & $script:FfmpegPath  -version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg.exe failed functional verification (exit code $LASTEXITCODE)." }
        $null = & $script:FfprobePath -version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "ffprobe.exe failed functional verification (exit code $LASTEXITCODE)." }

        Show-ProgressUpdate "[+] ffmpeg and ffprobe installed" -Type "Success"
        return $true
    } catch {
        Show-ProgressUpdate "[!] Failed to install ffmpeg: $($_.Exception.Message)" -Type "Error"
        # Remove any partial files so the next launch will retry cleanly
        Remove-Item $script:FfmpegPath  -Force -ErrorAction SilentlyContinue
        Remove-Item $script:FfprobePath -Force -ErrorAction SilentlyContinue
        return $false
    } finally {
        Remove-Item $zipPath     -Force -ErrorAction SilentlyContinue
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-DigitalReaper {
    Show-ProgressUpdate "[🔧] DIGITAL REAPER initializing..." -Type "System"
    
    if (-not (Test-Path $script:EngineDir)) {
        New-Item -Path $script:EngineDir -ItemType Directory -Force | Out-Null
        Show-ProgressUpdate "[+] Created engine directory" -Type "System"
    }
    
    if (-not (Test-Path $script:DownloadsDir)) {
        New-Item -Path $script:DownloadsDir -ItemType Directory -Force | Out-Null
        Show-ProgressUpdate "[+] Created downloads directory" -Type "Success"
    }

    Ensure-Directory -Path $script:AudioOutputDir
    Ensure-Directory -Path $script:VideoOutputDir

    # Create starter link files if they don't exist
    if (-not (Test-Path $script:AudioLinksFile)) {
        @(
            "# DIGITAL REAPER - Audio Links",
            "# Add one YouTube/SoundCloud/etc URL per line.",
            "# Lines starting with # are ignored.",
            "# Successfully downloaded links are removed automatically.",
            "# Failed links are kept so you can retry.",
            "#",
            "# Example:",
            "# https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        ) | Set-Content $script:AudioLinksFile
        Show-ProgressUpdate "[+] Created audioLinks.txt with usage guide" -Type "System"
    }

    if (-not (Test-Path $script:VideoLinksFile)) {
        @(
            "# DIGITAL REAPER - Video Links",
            "# Add one YouTube/etc URL per line.",
            "# Lines starting with # are ignored.",
            "# Successfully downloaded links are removed automatically.",
            "# Failed links are kept so you can retry.",
            "#",
            "# Example:",
            "# https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        ) | Set-Content $script:VideoLinksFile
        Show-ProgressUpdate "[+] Created videoLinks.txt with usage guide" -Type "System"
    }
    
    if (-not (Test-Path $script:YtDlpPath)) {
        if (-not (Install-YtDlp)) { return $false }
    }
    
    # Reinstall if either ffmpeg.exe or ffprobe.exe is missing
    if (-not (Test-Path $script:FfmpegPath) -or -not (Test-Path $script:FfprobePath)) {
        if (-not (Install-Ffmpeg)) { return $false }
    }
    
    Set-HiddenAttribute -Path $script:YtDlpPath
    Set-HiddenAttribute -Path $script:FfmpegPath
    Set-HiddenAttribute -Path $script:FfprobePath
    Set-HiddenAttribute -Path $script:EngineDir
    
    Show-ProgressUpdate "[+] All DIGITAL REAPER components ready" -Type "Success"
    return $true
}

function Update-YtDlpSilent {
    try {
        $url = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"

        # Use Invoke-WebRequest so we can inspect the status code for rate-limit signals
        $webResponse = Invoke-WebRequest -Uri $url -Headers @{ 'User-Agent' = 'DigitalReaper' } -TimeoutSec 10 -ErrorAction Stop
        if ($webResponse.StatusCode -eq 403 -or $webResponse.StatusCode -eq 429) {
            Show-ProgressUpdate "[!] GitHub API rate limit reached — skipping yt-dlp update check." -Type "Warning"
            return
        }
        $response = $webResponse.Content | ConvertFrom-Json
        $latestVersion = $response.tag_name

        # Read the currently installed version from file (fallback: empty string so we always update on first run)
        $installedVersion = ""
        if (Test-Path $script:VersionFilePath) {
            $installedVersion = (Get-Content $script:VersionFilePath -Raw).Trim()
        }

        if ($latestVersion -and $latestVersion -ne $installedVersion) {
            $downloadUrl = "https://github.com/yt-dlp/yt-dlp/releases/download/$latestVersion/yt-dlp.exe"
            $backupPath = "$script:YtDlpPath.backup"
            
            if (Test-Path $script:YtDlpPath) {
                Copy-Item $script:YtDlpPath $backupPath -Force
            }

            try {
                Invoke-WebRequest -Uri $downloadUrl -OutFile $script:YtDlpPath -TimeoutSec 30 -ErrorAction Stop
            } catch {
                # Download failed — restore the backup so the tool keeps working
                if (Test-Path $backupPath) {
                    Copy-Item $backupPath $script:YtDlpPath -Force
                }
                return
            }

            # Verify the downloaded file is non-empty before committing
            $downloaded = Get-Item $script:YtDlpPath -ErrorAction SilentlyContinue
            if (-not $downloaded -or $downloaded.Length -eq 0) {
                if (Test-Path $backupPath) {
                    Copy-Item $backupPath $script:YtDlpPath -Force
                }
                return
            }

            Set-HiddenAttribute -Path $script:YtDlpPath

            # Persist the new version so we don't re-download it next run
            Set-Content -Path $script:VersionFilePath -Value $latestVersion

            if (Test-Path $backupPath) {
                Remove-Item $backupPath -Force -ErrorAction SilentlyContinue
            }

            Show-ProgressUpdate "yt-dlp updated to $latestVersion" -Type "Success"
        }
    } catch {
        # Silent fail for updates
    }
}

# ===================================================================
# --- URL SANITIZATION ---
# ===================================================================

# ===================================================================
# --- YT-DLP ARGUMENT BUILDER & BATCH HELPERS ---
# ===================================================================

function Get-YtDlpArgs {
    param(
        [hashtable]$Settings,
        [string]$DownloadType,   # "audio" or "video"
        [string]$OutputDir,
        [switch]$UseFallbackFormat
    )

    $ytDlpArgs = New-Object System.Collections.Generic.List[string]

    # --- Anti-bot / stealth layer ---
    $userAgents = @(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:137.0) Gecko/20100101 Firefox/137.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_4_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36 Edg/136.0.0.0",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"
    )
    $randomUA = $userAgents[(Get-Random -Minimum 0 -Maximum $userAgents.Count)]
    $ytDlpArgs.Add("--user-agent")
    $ytDlpArgs.Add($randomUA)
    $ytDlpArgs.Add("--add-header")
    $ytDlpArgs.Add("Accept-Language:en-US,en;q=0.9")
    $ytDlpArgs.Add("--add-header")
    $ytDlpArgs.Add("Accept:text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
    $ytDlpArgs.Add("--sleep-requests")
    $ytDlpArgs.Add("2")
    $ytDlpArgs.Add("--extractor-retries")
    $ytDlpArgs.Add([string]$Settings.retryCount)

    $ytDlpArgs.Add("--ffmpeg-location")
    $ytDlpArgs.Add($script:EngineDir)
    $ytDlpArgs.Add("--socket-timeout")
    $ytDlpArgs.Add("30")
    $ytDlpArgs.Add("--fragment-retries")
    $ytDlpArgs.Add("infinite")
    $ytDlpArgs.Add("--retry-sleep")
    $ytDlpArgs.Add("fragment:exp=1:300")
    $ytDlpArgs.Add("--sleep-interval")
    $ytDlpArgs.Add("3")
    $ytDlpArgs.Add("--max-sleep-interval")
    $ytDlpArgs.Add("7")
    $ytDlpArgs.Add("--no-warnings")
    $ytDlpArgs.Add("--console-title")
    $ytDlpArgs.Add("--progress")
    $ytDlpArgs.Add("--continue")
    $ytDlpArgs.Add("--concurrent-fragments")
    $ytDlpArgs.Add([string]$Settings.concurrentFragments)

    if ($Settings.maxRate -and -not [string]::IsNullOrWhiteSpace($Settings.maxRate)) {
        $ytDlpArgs.Add("--limit-rate")
        $ytDlpArgs.Add($Settings.maxRate)
    }

    if ($Settings.cookieSource -and $Settings.cookieSource -ne "none") {
        $ytDlpArgs.Add("--cookies-from-browser")
        $ytDlpArgs.Add($Settings.cookieSource)
    }

    if ($DownloadType -eq "video" -and $Settings.downloadSubtitles) {
        $ytDlpArgs.Add("--write-auto-sub")
        $ytDlpArgs.Add("--write-sub")
        $ytDlpArgs.Add("--sub-lang")
        $ytDlpArgs.Add(($Settings.subtitleLanguages -join ","))
        $ytDlpArgs.Add("--convert-subs")
        $ytDlpArgs.Add("srt")
    }

    if ($DownloadType -eq "audio") {
        $ytDlpArgs.Add("--extract-audio")
        $ytDlpArgs.Add("--audio-format")
        $ytDlpArgs.Add($Settings.audioFormat)
        $ytDlpArgs.Add("--audio-quality")
        $ytDlpArgs.Add("0")
    } else {
        $codecPreference = if ($Settings.useHEVC) { "[vcodec^=hevc]/[vcodec^=h265]/" } else { "" }

        $height = switch ($Settings.videoQuality) {
            "720p"  { 720 }
            "1080p" { 1080 }
            "1440p" { 1440 }
            "4K"    { 2160 }
            default { 1080 }
        }

        $videoSelector = "bestvideo[height<=$height]"
        if ($codecPreference) {
            $videoSelector = "$codecPreference$videoSelector"
        }

        $format = if ($UseFallbackFormat) {
            "bestvideo+bestaudio/best"
        } else {
            "($videoSelector)+bestaudio/best[height<=$height]"
        }

        $ytDlpArgs.Add("-f")
        $ytDlpArgs.Add($format)
        $ytDlpArgs.Add("--merge-output-format")
        $ytDlpArgs.Add("mp4")
    }

    $outputTemplate = Join-Path -Path $OutputDir -ChildPath $Settings.outputTemplate
    $ytDlpArgs.Add("-o")
    $ytDlpArgs.Add($outputTemplate)

    return $ytDlpArgs
}

function Test-TransientDownloadError {
    param([string]$ErrorText)
    $patterns = @("429", "Too Many Requests", "timed out", "timeout", "Connection reset", "temporarily unavailable", "HTTP Error 500", "HTTP Error 502", "HTTP Error 503")
    foreach ($pattern in $patterns) {
        if ($ErrorText -match [regex]::Escape($pattern)) { return $true }
    }
    return $false
}

function Get-FriendlyErrorHint {
    param([string]$ErrorText)
    if ($ErrorText -match "Private video") { return "This video is private. Only the owner can download it." }
    if ($ErrorText -match "Sign in|age-restricted|confirm your age|login") { return "Login is needed for this video. Set the cookieSource setting to match your browser." }
    if ($ErrorText -match "not available in your country|geo") { return "This video is region-restricted in your current location." }
    if ($ErrorText -match "429|Too Many Requests") { return "Too many requests right now. Wait a bit and try again." }
    if ($ErrorText -match "timed out|timeout|Connection reset") { return "Network issue detected. Please check your connection and retry." }
    if ($ErrorText -match "Video unavailable") { return "Video unavailable. It may have been removed or blocked." }
    return "Download failed. Verify the link works in your browser and try again."
}

function Invoke-YtDlpForUrl {
    param(
        [hashtable]$Settings,
        [string]$DownloadType,
        [string]$OutputDir,
        [string]$Url
    )
    $maxAttempts = if ($Settings.outerRetryCount -and [int]$Settings.outerRetryCount -gt 0) { [int]$Settings.outerRetryCount } else { 3 }
    $attempt = 0
    $lastErrorText = ""
    $baseArgs = Get-YtDlpArgs -Settings $Settings -DownloadType $DownloadType -OutputDir $OutputDir

    while ($attempt -lt $maxAttempts) {
        $attempt++
        $attemptResult = Invoke-YtDlpAndCapture -Args ($baseArgs + $Url)
        $lastErrorText = $attemptResult.ErrorText
        if ($attemptResult.Success) {
            return [pscustomobject]@{ Success = $true; ErrorText = "" }
        }
        if ($attempt -lt $maxAttempts -and (Test-TransientDownloadError -ErrorText $lastErrorText)) {
            Show-ProgressUpdate "[~] Temporary issue. Retrying in 3s ($attempt/$maxAttempts)..." -Type "Warning"
            Start-Sleep -Seconds 3
            continue
        }
        break
    }

    if ($DownloadType -eq "video") {
        Show-ProgressUpdate "[~] Trying fallback format for this video..." -Type "Update"
        $fallbackArgs = Get-YtDlpArgs -Settings $Settings -DownloadType $DownloadType -OutputDir $OutputDir -UseFallbackFormat
        $fallbackResult = Invoke-YtDlpAndCapture -Args ($fallbackArgs + $Url)
        $lastErrorText = $fallbackResult.ErrorText
        if ($fallbackResult.Success) {
            return [pscustomobject]@{ Success = $true; ErrorText = "" }
        }
    }

    return [pscustomobject]@{
        Success = $false
        ErrorText = $lastErrorText
    }
}

function Invoke-YtDlpAndCapture {
    param([string[]]$Args)
    $outputLines = New-Object System.Collections.Generic.List[string]
    & $script:YtDlpPath $Args 2>&1 | ForEach-Object {
        $line = "$_"
        $outputLines.Add($line) | Out-Null
        Write-Host $line
    }
    return [pscustomobject]@{
        Success = ($LASTEXITCODE -eq 0)
        ErrorText = ($outputLines -join "`n")
    }
}

# ===================================================================
# --- SMART URL DETECTION ---
# ===================================================================

function Get-UrlsSmartMode {
    # If a config/manifest file was passed, and it contains a `links` field, use that first
    if ($ConfigFile -and (Test-Path $ConfigFile)) {
        try {
            $configData = Get-Content $ConfigFile | ConvertFrom-Json
            if ($configData.PSObject.Properties.Name -contains "links" -and $configData.links) {
                $urlsFromConfig = @()

                if ($configData.links -is [System.Collections.IEnumerable] -and -not ($configData.links -is [string])) {
                    foreach ($link in $configData.links) {
                        $link = [string]$link
                        $link = $link.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($link)) {
                            $urlsFromConfig += $link
                        }
                    }
                } else {
                    $singleLink = [string]$configData.links
                    $singleLink = $singleLink.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($singleLink)) {
                        $urlsFromConfig += $singleLink
                    }
                }

                if ($urlsFromConfig.Count -gt 0) {
                    Show-ProgressUpdate "[+] Loaded $($urlsFromConfig.Count) targets from manifest: $ConfigFile" -Type "System"
                    return $urlsFromConfig
                }
            }
        } catch {
            Show-ProgressUpdate "[!] Failed to read links from manifest: $ConfigFile. Falling back to standard input methods." -Type "Warning"
        }
    }

    if ($LinksFile -and (Test-Path $LinksFile)) {
        Show-ProgressUpdate "[+] Processing file from batch: $LinksFile" -Type "System"
        $script:SourceFile = $LinksFile
        return Get-UrlsFromFile -FilePath $LinksFile
    }
    
    if (Test-Path $script:DefaultLinksFile) {
        Show-ProgressUpdate "[+] Found links.txt in script directory" -Type "System"
        $script:SourceFile = $script:DefaultLinksFile
        return Get-UrlsFromFile -FilePath $script:DefaultLinksFile
    }
    
    Write-TypeWriter -Text "`n--- Select Input Method ---" -Color "Cyan" -Speed 30
    $inputMethod = ""
    while ($inputMethod -notin @("1", "2")) {
        Show-MenuOption -Prompt "Select Input Method" -Options "1=Manual URL, 2=Load from File"
        $inputMethod = Read-Host
        if ($inputMethod -notin @("1", "2")) { 
            Write-Pulse -Text "`n[!] Invalid command. Use 1 or 2." -Colors @("Red", "Yellow") -Cycles 2
        }
    }

    if ($inputMethod -eq "1") {
        $url = ""
        while ([string]::IsNullOrWhiteSpace($url)) {
            Write-Host ">> Enter Target URL (Video or Playlist): " -ForegroundColor "Yellow"
            $url = Read-Host
            if ([string]::IsNullOrWhiteSpace($url)) { 
                Write-Pulse -Text "`n[!] Abort: Target URL cannot be empty." -Colors @("Red", "Yellow") -Cycles 2
            }
        }
        return @($url)
    } else {
        $filePath = ""
        while ([string]::IsNullOrWhiteSpace($filePath) -or -not (Test-Path $filePath)) {
            Write-Host ">> Enter path to URLs file (.txt): " -ForegroundColor "Magenta"
            $filePath = Read-Host
            if ([string]::IsNullOrWhiteSpace($filePath)) { 
                Write-Pulse -Text "`n[!] File path cannot be empty." -Colors @("Red", "Yellow") -Cycles 1
            } elseif (-not (Test-Path $filePath)) {
                Write-Pulse -Text "`n[!] File not found: $filePath" -Colors @("Red", "Yellow") -Cycles 1
            }
        }
        $script:SourceFile = $filePath
        return Get-UrlsFromFile -FilePath $filePath
    }
}

function Process-LinkFile {
    param(
        [string]$FilePath,
        [hashtable]$Settings,
        [string]$DownloadType,
        [string]$OutputDir
    )

    if (-not (Test-Path $FilePath)) {
        return [pscustomobject]@{
            Success = 0
            Failure = 0
        }
    }

    Ensure-Directory -Path $OutputDir

    $allLines = @(Get-Content $FilePath)
    $linkEntries = @()

    for ($i = 0; $i -lt $allLines.Count; $i++) {
        $line = $allLines[$i]
        if (Test-ValidUrl -Line $line) {
            $originalUrl = Remove-InvisibleCharacters -Text $line

            $entry = [pscustomobject]@{
                Index        = $i
                OriginalUrl  = $originalUrl
                WasSuccess   = $false
            }
            $linkEntries += $entry
        }
    }

    if ($linkEntries.Count -eq 0) {
        Show-ProgressUpdate "[!] No valid URLs in $FilePath" -Type "Warning"
        return [pscustomobject]@{
            Success = 0
            Failure = 0
        }
    }

    $quality = if ($DownloadType -eq "video") { $Settings.videoQuality } else { "" }
    Show-DownloadBanner -TypeLabel $DownloadType.ToUpper() -Mode "BATCH" -TargetCount $linkEntries.Count -OutputDir $OutputDir -Quality $quality

    $successCount = 0
    $failureCount = 0
    $targetNum = 0

    foreach ($entry in $linkEntries) {
        $urlToUse = $entry.OriginalUrl
        $targetNum++
        try {
            Write-Host "  [ $targetNum/$($linkEntries.Count) ] " -NoNewline -ForegroundColor DarkGray
            Write-Host "ACQUIRING TARGET" -NoNewline -ForegroundColor Cyan
            Write-Host " >> " -NoNewline -ForegroundColor DarkGray
            Write-Host $urlToUse -ForegroundColor White
            
            $downloadResult = Invoke-YtDlpForUrl -Settings $Settings -DownloadType $DownloadType -OutputDir $OutputDir -Url $urlToUse
            if ($downloadResult.Success) {
                $successCount++
                $entry.WasSuccess = $true
                Write-Host "  [ $targetNum/$($linkEntries.Count) ] " -NoNewline -ForegroundColor DarkGray
                Write-Host "TARGET ACQUIRED" -ForegroundColor Green
            } else {
                $friendly = Get-FriendlyErrorHint -ErrorText $downloadResult.ErrorText
                throw "$friendly"
            }

        } catch {
            $failureCount++
            Write-Host "  [ $targetNum/$($linkEntries.Count) ] " -NoNewline -ForegroundColor DarkGray
            Write-Host "TARGET MISSED  >> $($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host ""
    }

    $successUrls = @($linkEntries | Where-Object { $_.WasSuccess } | ForEach-Object { $_.OriginalUrl })
    Remove-SuccessfulLinks -FilePath $FilePath -SuccessUrls $successUrls

    return [pscustomobject]@{
        Success = $successCount
        Failure = $failureCount
    }
}

# ===================================================================
# --- SHARED DOWNLOAD HELPERS ---
# ===================================================================

function Remove-SuccessfulLinks {
    param(
        [string]$FilePath,
        [string[]]$SuccessUrls
    )
    if (-not $FilePath -or -not (Test-Path $FilePath) -or -not $SuccessUrls -or $SuccessUrls.Count -eq 0) { return }
    $allLines = @(Get-Content $FilePath)
    $linesOut = New-Object System.Collections.Generic.List[string]
    foreach ($line in $allLines) {
        if (Test-ValidUrl -Line $line) {
            $cleanLine = Remove-InvisibleCharacters -Text $line
            if ($SuccessUrls -notcontains $cleanLine) {
                $linesOut.Add($line)
            }
        } else {
            $linesOut.Add($line)
        }
    }
    Set-Content -Path $FilePath -Value $linesOut.ToArray()
}

function Show-MissionSummary {
    param(
        [int]$SuccessCount,
        [int]$FailureCount,
        [string]$OutputDir,
        [switch]$Silent
    )
    $speed = if ($Silent) { 0 } else { 30 }
    Write-TypeWriter -Text "`n---[ DIGITAL REAPER - Mission Summary ]---" -Color "Cyan" -Speed $speed
    Write-Host "[+] Successful downloads: " -NoNewline -ForegroundColor "White"
    Write-Pulse -Text "$SuccessCount" -Colors @("Green", "Cyan") -Cycles 1 -Speed 300
    Write-Host "[!] Failed downloads:     " -NoNewline -ForegroundColor "White"
    Write-Pulse -Text "$FailureCount" -Colors @("Red", "Yellow") -Cycles 1 -Speed 300
    Write-Host "    Downloads saved to:   " -NoNewline -ForegroundColor "White"
    Write-Host "$OutputDir" -ForegroundColor "Yellow"

    if ($SuccessCount -gt 0) {
        Show-CompletionBanner
    } else {
        Write-Pulse -Text "`n[!] DIGITAL REAPER: All downloads failed." -Colors @("Red", "DarkRed") -Cycles 3
    }
}

# ===================================================================
# --- MAIN EXECUTION HELPERS ---
# ===================================================================

function Should-RunBatchMode {
    if ($LinksFile -or $ConfigFile) {
        return $false
    }

    # Only enter batch mode if a link file exists AND contains at least one real URL
    $hasAudioUrls = $false
    $hasVideoUrls = $false

    if (Test-Path $script:AudioLinksFile) {
        $hasAudioUrls = (Get-Content $script:AudioLinksFile | Where-Object { Test-ValidUrl -Line $_ }).Count -gt 0
    }

    if (Test-Path $script:VideoLinksFile) {
        $hasVideoUrls = (Get-Content $script:VideoLinksFile | Where-Object { Test-ValidUrl -Line $_ }).Count -gt 0
    }

    return $hasAudioUrls -or $hasVideoUrls
}

function Run-BatchMode {
    param(
        [hashtable]$Settings
    )

    # Lock file guard — prevent two instances from running simultaneously
    if (Test-Path $script:LockFilePath) {
        Show-ProgressUpdate "[!] Another instance of Digital Reaper is already running (lock file present). Exiting." -Type "Warning"
        return
    }
    try {
        Set-Content -Path $script:LockFilePath -Value $PID
        Set-HiddenAttribute -Path $script:LockFilePath

        $batchSuccess = 0
        $batchFailure = 0

        $audioDir = Get-OutputDirForType -Settings $Settings -DownloadType "audio"
        $videoDir = Get-OutputDirForType -Settings $Settings -DownloadType "video"
        Ensure-Directory -Path $audioDir
        Ensure-Directory -Path $videoDir

        if (Test-Path $script:AudioLinksFile) {
            $audioResult = Process-LinkFile -FilePath $script:AudioLinksFile -Settings $Settings -DownloadType "audio" -OutputDir $audioDir
            $batchSuccess += $audioResult.Success
            $batchFailure += $audioResult.Failure
        }

        if (Test-Path $script:VideoLinksFile) {
            $videoResult = Process-LinkFile -FilePath $script:VideoLinksFile -Settings $Settings -DownloadType "video" -OutputDir $videoDir
            $batchSuccess += $videoResult.Success
            $batchFailure += $videoResult.Failure
        }

        $summaryDir = Get-BaseOutputDir -Settings $Settings
        Show-MissionSummary -SuccessCount $batchSuccess -FailureCount $batchFailure -OutputDir $summaryDir -Silent:$Silent
    } finally {
        Remove-Item $script:LockFilePath -Force -ErrorAction SilentlyContinue
    }
}

function Run-InteractiveMode {
    param(
        [hashtable]$Settings,
        [switch]$ForceOneClick
    )

    $urls = @()
    $usedOneClick = $false
    $hasExplicitInputFiles = -not [string]::IsNullOrWhiteSpace($script:LinksFile) -or -not [string]::IsNullOrWhiteSpace($script:ConfigFile)
    $hasDefaultLinksFile = Test-Path $script:DefaultLinksFile
    $oneClickEnabled = $Settings.oneClickMode -or $ForceOneClick
    $shouldUseOneClickMode = $oneClickEnabled -and -not $hasExplicitInputFiles -and -not $hasDefaultLinksFile
    if ($shouldUseOneClickMode) {
        $usedOneClick = $true
        while ($urls.Count -eq 0) {
            Write-Host "Paste a link and press Enter." -ForegroundColor Yellow
            Write-Host "Type settings for quick options or file to load a .txt list." -ForegroundColor DarkGray
            $quickInput = (Read-Host).Trim()
            if ([string]::IsNullOrWhiteSpace($quickInput)) {
                Show-ProgressUpdate "[!] Please paste a link or command." -Type "Warning"
                continue
            }
            switch ($quickInput) {
                { $_ -ieq "settings" } {
                    Show-SimpleSettingsPage -Settings $Settings
                    continue
                }
                { $_ -ieq "file" } {
                    $filePath = Read-Host "Enter path to URLs file (.txt)"
                    if ([string]::IsNullOrWhiteSpace($filePath)) {
                        Show-ProgressUpdate "[!] File path cannot be empty." -Type "Warning"
                        continue
                    }
                    if (-not (Test-Path $filePath)) {
                        Show-ProgressUpdate "[!] File not found." -Type "Warning"
                        continue
                    }
                    $script:SourceFile = $filePath
                    $urls = Get-UrlsFromFile -FilePath $filePath
                    continue
                }
                default {
                    $urls = @($quickInput)
                }
            }
        }
    } else {
        $urls = Get-UrlsSmartMode
    }
    
    if ($urls.Count -eq 0) {
        Write-Pulse -Text "[!] No valid URLs found." -Colors @("Red", "DarkRed") -Cycles 2
        if (-not $Silent) { Read-Host "Press Enter to exit..." }
        exit 1
    }
    
    Show-ProgressUpdate "Loaded $($urls.Count) target(s) for processing" -Type "Success"

    # --- Ask user: audio or video ---
    $downloadType = if ($usedOneClick) {
        if ($Settings.defaultDownloadType -eq "audio") { "2" } else { "1" }
    } else {
        ""
    }
    if (-not $usedOneClick) {
        while ($downloadType -notin @("1", "2")) {
            Show-MenuOption -Prompt "Select Download Type" -Options "1=Video, 2=Audio Only"
            $downloadType = Read-Host
            if ($downloadType -notin @("1", "2")) {
                Write-Pulse -Text "`n[!] Invalid choice. Enter 1 for Video or 2 for Audio." -Colors @("Red", "Yellow") -Cycles 2
            }
        }
    }

    if ($downloadType -eq "2") {
        $resolvedType = "audio"
        $outputDir    = Get-OutputDirForType -Settings $Settings -DownloadType "audio"
    } else {
        $resolvedType = "video"
        $outputDir    = Get-OutputDirForType -Settings $Settings -DownloadType "video"
    }

    Ensure-Directory -Path $outputDir

    $quality = if ($resolvedType -eq "video") { $Settings.videoQuality } else { "" }
    Show-DownloadBanner -TypeLabel $resolvedType.ToUpper() -Mode "EXFILTRATION" -TargetCount $urls.Count -OutputDir $outputDir -Quality $quality

    $successCount = 0
    $failureCount = 0
    $successUrls  = @()
    $targetNum    = 0

    foreach ($url in $urls) {
        $targetNum++
        try {
            Write-Host "  [ $targetNum/$($urls.Count) ] " -NoNewline -ForegroundColor DarkGray
            Write-Host "ACQUIRING TARGET" -NoNewline -ForegroundColor Cyan
            Write-Host " >> " -NoNewline -ForegroundColor DarkGray
            Write-Host $url -ForegroundColor White

            $downloadResult = Invoke-YtDlpForUrl -Settings $Settings -DownloadType $resolvedType -OutputDir $outputDir -Url $url
            if ($downloadResult.Success) {
                $successCount++
                $successUrls += $url
                Write-Host "  [ $targetNum/$($urls.Count) ] " -NoNewline -ForegroundColor DarkGray
                Write-Host "TARGET ACQUIRED" -ForegroundColor Green
            } else {
                $friendly = Get-FriendlyErrorHint -ErrorText $downloadResult.ErrorText
                throw "$friendly"
            }
            
        } catch {
            $failureCount++
            Write-Host "  [ $targetNum/$($urls.Count) ] " -NoNewline -ForegroundColor DarkGray
            Write-Host "TARGET MISSED  >> $($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host ""
    }

    # Remove successfully downloaded links from the source file
    Remove-SuccessfulLinks -FilePath $script:SourceFile -SuccessUrls $successUrls

    Show-MissionSummary -SuccessCount $successCount -FailureCount $failureCount -OutputDir $outputDir -Silent:$Silent
}

function Show-ExitPrompt {
    while ($true) {
        Write-Host ""
        Write-Host "What do you want to do next?" -ForegroundColor Yellow
        Write-Host "1) Close terminal" -ForegroundColor White
        Write-Host "2) Return to DigitalReaper menu" -ForegroundColor White
        Write-Host "3) Download another item" -ForegroundColor White
        $choice = Read-Host "Choose (1-3)"
        if ($choice -in @("1","2","3")) { return $choice }
        Show-ProgressUpdate "[!] Invalid choice. Enter 1, 2, or 3." -Type "Warning"
    }
}

# ===================================================================
# --- MAIN EXECUTION ---
# ===================================================================

try {
    Clear-Host
    Show-StartupSequence

    if (-not (Initialize-DigitalReaper)) {
        Write-Pulse -Text "[!] DIGITAL REAPER initialization failed" -Colors @("Red", "DarkRed") -Cycles 3
        if (-not $Silent) { Read-Host "Press Enter to exit..." }
        exit 1
    }

    $settings = Load-Settings -ConfigPath $ConfigFile
    
    if ($settings.autoUpdate) {
        Update-YtDlpSilent
    }

    $nextMode = "auto"
    $shouldExit = $false
    while (-not $shouldExit) {
        if ($nextMode -eq "quick") {
            Run-InteractiveMode -Settings $settings -ForceOneClick
        } elseif (Should-RunBatchMode) {
            Run-BatchMode -Settings $settings
        } else {
            Run-InteractiveMode -Settings $settings
        }

        if ($Silent) { break }

        $postAction = Show-ExitPrompt
        switch ($postAction) {
            "1" { $shouldExit = $true }
            "2" { $nextMode = "auto" }
            "3" { $nextMode = "quick" }
        }
    }

} catch {
    Write-Host "`n[!] CRITICAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace:" -ForegroundColor DarkRed
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}

if (-not $Silent) {
    Write-Host "`n>> DIGITAL REAPER session ended." -ForegroundColor Yellow
}
