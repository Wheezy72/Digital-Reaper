<#
========================================================================
    DIGITAL REAPER - YouTube Downloader
    Custom tool for grabbing content with style
    Made by Wheezy for the culture
========================================================================
#>

param(
    [string]$LinksFile = "",
    [string]$ConfigFile = ""
)

# ===================================================================
# --- SCRIPT CONFIGURATION ---
# ===================================================================

$YTDLP_CURRENT_VERSION = "2024.12.06"

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
    }
}

function Load-Settings {
    param([string]$ConfigPath)
    
    $settings = Get-DefaultSettings
    
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        try {
            $userSettings = Get-Content $ConfigPath | ConvertFrom-Json
            foreach ($key in $userSettings.PSObject.Properties.Name) {
                if ($settings.ContainsKey($key)) {
                    $settings[$key] = $userSettings.$key
                }
            }
            Show-ProgressUpdate "Settings loaded from: $ConfigPath" -Type "Success"
        } catch {
            Show-ProgressUpdate "Error loading settings file. Using defaults." -Type "Warning"
        }
    } elseif (Test-Path $script:DefaultConfigFile) {
        try {
            $userSettings = Get-Content $script:DefaultConfigFile | ConvertFrom-Json
            foreach ($key in $userSettings.PSObject.Properties.Name) {
                if ($settings.ContainsKey($key)) {
                    $settings[$key] = $userSettings.$key
                }
            }
            Show-ProgressUpdate "Settings loaded from: settings.json" -Type "Success"
        } catch {
            Show-ProgressUpdate "Error loading settings. Using defaults." -Type "Warning"
        }
    }
    
    return $settings
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
        $response = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'DigitalReaper' } -TimeoutSec 10 -ErrorAction SilentlyContinue
        $latestVersion = $response.tag_name
        
        if ($latestVersion -and $latestVersion -ne $YTDLP_CURRENT_VERSION) {
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

function Get-SanitizedUrls {
    param([array]$Urls)

    $sanitizedUrls = @()
    foreach ($url in $Urls) {
        $clean = $url.Trim()
        if (-not [string]::IsNullOrWhiteSpace($clean)) {
            $sanitizedUrls += $clean
        }
    }

    return $sanitizedUrls
}

# ===================================================================
# --- YT-DLP ARGUMENT BUILDER & BATCH HELPERS ---
# ===================================================================

function Get-YtDlpArgs {
    param(
        [hashtable]$Settings,
        [string]$DownloadType,   # "audio" or "video"
        [string]$OutputDir
    )

    $ytDlpArgs = New-Object System.Collections.Generic.List[string]

    # --- Anti-bot / stealth layer ---
    $userAgents = @(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
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
    $ytDlpArgs.Add("5")

    $ytDlpArgs.Add("--ffmpeg-location")
    $ytDlpArgs.Add($script:EngineDir)
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

        $format = "($codecPreference" + "bestvideo[height<=$height])+bestaudio/best[height<=$height]"

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

    $ytDlpArgs = Get-YtDlpArgs -Settings $Settings -DownloadType $DownloadType -OutputDir $OutputDir

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
            
            $currentArgs = @($ytDlpArgs) + $urlToUse

            & $script:YtDlpPath $currentArgs

            if ($LASTEXITCODE -eq 0) {
                $successCount++
                $entry.WasSuccess = $true
                Write-Host "  [ $targetNum/$($linkEntries.Count) ] " -NoNewline -ForegroundColor DarkGray
                Write-Host "TARGET ACQUIRED" -ForegroundColor Green
            } else {
                throw "yt-dlp exited with code $LASTEXITCODE"
            }

        } catch {
            $failureCount++
            Write-Host "  [ $targetNum/$($linkEntries.Count) ] " -NoNewline -ForegroundColor DarkGray
            Write-Host "TARGET MISSED  >> $($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host ""
    }

    $linesOut = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $allLines.Count; $i++) {
        $entryAtIndex = $linkEntries | Where-Object { $_.Index -eq $i } | Select-Object -First 1
        if ($entryAtIndex) {
            if (-not $entryAtIndex.WasSuccess) {
                $linesOut.Add($allLines[$i])
            }
        } else {
            $linesOut.Add($allLines[$i])
        }
    }

    Set-Content -Path $FilePath -Value $linesOut.ToArray()

    return [pscustomobject]@{
        Success = $successCount
        Failure = $failureCount
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

    $batchSuccess = 0
    $batchFailure = 0

    if (Test-Path $script:AudioLinksFile) {
        $audioResult = Process-LinkFile -FilePath $script:AudioLinksFile -Settings $Settings -DownloadType "audio" -OutputDir $script:AudioOutputDir
        $batchSuccess += $audioResult.Success
        $batchFailure += $audioResult.Failure
    }

    if (Test-Path $script:VideoLinksFile) {
        $videoResult = Process-LinkFile -FilePath $script:VideoLinksFile -Settings $Settings -DownloadType "video" -OutputDir $script:VideoOutputDir
        $batchSuccess += $videoResult.Success
        $batchFailure += $videoResult.Failure
    }

    Write-TypeWriter -Text "`n---[ DIGITAL REAPER - Mission Summary ]---" -Color "Cyan" -Speed 30
    Write-Host "[+] Successful downloads: " -NoNewline -ForegroundColor "White"
    Write-Pulse -Text "$batchSuccess" -Colors @("Green", "Cyan") -Cycles 1 -Speed 300
    Write-Host "[!] Failed downloads:     " -NoNewline -ForegroundColor "White"
    Write-Pulse -Text "$batchFailure" -Colors @("Red", "Yellow") -Cycles 1 -Speed 300
    Write-Host "    Downloads saved to:   " -NoNewline -ForegroundColor "White"
    Write-Host "$script:DownloadsDir" -ForegroundColor "Yellow"

    if ($batchSuccess -gt 0) {
        Show-CompletionBanner
    } else {
        Write-Pulse -Text "`n[!] DIGITAL REAPER: All downloads failed." -Colors @("Red", "DarkRed") -Cycles 3
    }
}

function Run-InteractiveMode {
    param(
        [hashtable]$Settings
    )

    $urls = Get-UrlsSmartMode
    
    if ($urls.Count -eq 0) {
        Write-Pulse -Text "[!] No valid URLs found." -Colors @("Red", "DarkRed") -Cycles 2
        Read-Host "Press Enter to exit..."
        exit 1
    }
    
    Show-ProgressUpdate "Loaded $($urls.Count) target(s) for processing" -Type "Success"

    # --- Ask user: audio or video ---
    $downloadType = ""
    while ($downloadType -notin @("1", "2")) {
        Show-MenuOption -Prompt "Select Download Type" -Options "1=Video, 2=Audio Only"
        $downloadType = Read-Host
        if ($downloadType -notin @("1", "2")) {
            Write-Pulse -Text "`n[!] Invalid choice. Enter 1 for Video or 2 for Audio." -Colors @("Red", "Yellow") -Cycles 2
        }
    }

    if ($downloadType -eq "2") {
        $resolvedType = "audio"
        $outputDir    = $script:AudioOutputDir
    } else {
        $resolvedType = "video"
        $outputDir    = $script:VideoOutputDir
    }

    Ensure-Directory -Path $outputDir
    $ytDlpArgs = Get-YtDlpArgs -Settings $Settings -DownloadType $resolvedType -OutputDir $outputDir

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

            $currentArgs = @($ytDlpArgs) + $url
            
            & $script:YtDlpPath $currentArgs
            
            if ($LASTEXITCODE -eq 0) {
                $successCount++
                $successUrls += $url
                Write-Host "  [ $targetNum/$($urls.Count) ] " -NoNewline -ForegroundColor DarkGray
                Write-Host "TARGET ACQUIRED" -ForegroundColor Green
            } else {
                throw "yt-dlp exited with code $LASTEXITCODE"
            }
            
        } catch {
            $failureCount++
            Write-Host "  [ $targetNum/$($urls.Count) ] " -NoNewline -ForegroundColor DarkGray
            Write-Host "TARGET MISSED  >> $($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host ""
    }

    # Remove successfully downloaded links from the source file
    if ($script:SourceFile -and (Test-Path $script:SourceFile) -and $successUrls.Count -gt 0) {
        $allLines = @(Get-Content $script:SourceFile)
        $linesOut = New-Object System.Collections.Generic.List[string]
        foreach ($line in $allLines) {
            if (Test-ValidUrl -Line $line) {
                $cleanLine = Remove-InvisibleCharacters -Text $line
                if ($successUrls -notcontains $cleanLine) {
                    $linesOut.Add($line)
                }
            } else {
                $linesOut.Add($line)
            }
        }
        Set-Content -Path $script:SourceFile -Value $linesOut.ToArray()
    }

    Write-TypeWriter -Text "`n---[ DIGITAL REAPER - Mission Summary ]---" -Color "Cyan" -Speed 30
    Write-Host "[+] Successful downloads: " -NoNewline -ForegroundColor "White"
    Write-Pulse -Text "$successCount" -Colors @("Green", "Cyan") -Cycles 1 -Speed 300
    Write-Host "[!] Failed downloads:     " -NoNewline -ForegroundColor "White"
    Write-Pulse -Text "$failureCount" -Colors @("Red", "Yellow") -Cycles 1 -Speed 300
    Write-Host "    Downloads saved to:   " -NoNewline -ForegroundColor "White"
    Write-Host "$outputDir" -ForegroundColor "Yellow"

    if ($successCount -gt 0) {
        Show-CompletionBanner
    } else {
        Write-Pulse -Text "`n[!] DIGITAL REAPER: All downloads failed." -Colors @("Red", "DarkRed") -Cycles 3
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
        Read-Host "Press Enter to exit..."
        exit 1
    }

    $settings = Load-Settings -ConfigPath $ConfigFile
    
    if ($settings.autoUpdate) {
        Update-YtDlpSilent
    }

    if (Should-RunBatchMode) {
        Run-BatchMode -Settings $settings
    } else {
        Run-InteractiveMode -Settings $settings
    }

} catch {
    Write-Host "`n[!] CRITICAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace:" -ForegroundColor DarkRed
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}

Write-Host -NoNewline "`n>> DIGITAL REAPER session complete. Press Enter to go dark..." -ForegroundColor "Yellow"
Read-Host | Out-Null
