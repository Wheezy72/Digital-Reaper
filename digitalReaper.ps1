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

$script:DownloadsDir      = Join-Path $script:ScriptDir "downloads"
$script:DefaultLinksFile  = Join-Path $script:ScriptDir "links.txt"
$script:DefaultConfigFile = Join-Path $script:ScriptDir "settings.json"

# Dedicated audio/video link files + output folders
$script:AudioLinksFile = Join-Path $script:ScriptDir "audioLinks.txt"
$script:VideoLinksFile = Join-Path $script:ScriptDir "videoLinks.txt"
$script:AudioOutputDir = Join-Path $script:DownloadsDir "audio"
$script:VideoOutputDir = Join-Path $script:DownloadsDir "videos"

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

function Show-CompletionBanner {
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "               MISSION STATUS: COMPLETE           " -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host ""

    $prodByWheezy = @'
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
                $line = $line.Trim()
                $urls += $line
                Show-ProgressUpdate "Target acquired: $line" -Type "Target"
            }
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

function Test-ValidUrl {
    param([string]$Line)
    $trimmed = $Line.Trim()
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
        outputTemplate    = "%(uploader)s/[%(upload_date)s] %(title)s [%(id)s].%(ext)s"
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
        Show-ProgressUpdate "[!] yt-dlp.exe not found in engine/!" -Type "Error"
        Show-ProgressUpdate "[>] Run initDigitalReaper.ps1 first or download yt-dlp.exe manually into the engine folder." -Type "Warning"
        return $false
    }
    
    if (-not (Test-Path $script:FfmpegPath)) {
        Show-ProgressUpdate "[!] ffmpeg.exe not found in engine/!" -Type "Error"
        Show-ProgressUpdate "[>] Run initDigitalReaper.ps1 first or place ffmpeg.exe manually into the engine folder." -Type "Warning"
        return $false
    }
    
    Set-HiddenAttribute -Path $script:YtDlpPath
    Set-HiddenAttribute -Path $script:FfmpegPath
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

    Show-ProgressUpdate "[+] Anti-bot stealth layer active" -Type "System"
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
    $ytDlpArgs.Add("--no-call-home")
    $ytDlpArgs.Add("--console-title")

    Show-ProgressUpdate "[+] REAPER output optimization enabled" -Type "Success"

    if ($DownloadType -eq "video" -and $Settings.downloadSubtitles) {
        Show-ProgressUpdate "Subtitle extraction enabled" -Type "Success"
        $ytDlpArgs.Add("--write-auto-sub")
        $ytDlpArgs.Add("--write-sub")
        $ytDlpArgs.Add("--sub-lang")
        $ytDlpArgs.Add(($Settings.subtitleLanguages -join ","))
        $ytDlpArgs.Add("--convert-subs")
        $ytDlpArgs.Add("srt")
    }

    if ($DownloadType -eq "audio") {
        Write-TypeWriter -Text "[*] REAPER configuring for audio-only exfiltration..." -Color "Yellow" -Speed 30
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

        Write-TypeWriter -Text "[*] REAPER configuring for $($Settings.videoQuality) video stream..." -Color "Green" -Speed 30
        $format = "($codecPreference" + "bestvideo[height<=$height])+bestaudio/best[height<=$height]"

        $ytDlpArgs.Add("-f")
        $ytDlpArgs.Add($format)
        $ytDlpArgs.Add("--merge-output-format")
        $ytDlpArgs.Add("mp4")

        if ($Settings.useHEVC) {
            Show-ProgressUpdate "HEVC/H.265 codec preference enabled" -Type "Success"
        }
    }

    $outputTemplate = Join-Path -Path $OutputDir -ChildPath $Settings.outputTemplate
    $ytDlpArgs.Add("-o")
    $ytDlpArgs.Add($outputTemplate)

    Show-ProgressUpdate "Enhanced metadata filename structure enabled" -Type "Success"
    Write-Host "    Output: " -NoNewline -ForegroundColor "Gray"
    Write-Host $OutputDir -ForegroundColor "Yellow"

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
        return Get-UrlsFromFile -FilePath $LinksFile
    }
    
    if (Test-Path $script:DefaultLinksFile) {
        Show-ProgressUpdate "[+] Found links.txt in script directory" -Type "System"
        return Get-UrlsFromFile -FilePath $script:DefaultLinksFile
    }
    
    Write-TypeWriter -Text "`n--- Target Acquisition Protocol ---" -Color "Cyan" -Speed 30
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

    Show-ProgressUpdate "[+] Processing link file: $FilePath" -Type "System"
    Ensure-Directory -Path $OutputDir

    $allLines = Get-Content $FilePath
    $linkEntries = @()

    for ($i = 0; $i -lt $allLines.Count; $i++) {
        $line = $allLines[$i]
        if (Test-ValidUrl -Line $line) {
            $originalUrl = $line.Trim()

            $entry = [pscustomobject]@{
                Index        = $i
                OriginalUrl  = $originalUrl
                WasSuccess   = $false
            }
            $linkEntries += $entry

            Show-ProgressUpdate "Target acquired: $originalUrl" -Type "Target"
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

    Write-TypeWriter -Text "`n---[ DIGITAL REAPER - Beginning $DownloadType batch ]---" -Color "Red" -Speed 40
    Write-Host "Target Count: " -NoNewline -ForegroundColor "White"
    Write-Host "$($linkEntries.Count)" -ForegroundColor "Cyan"
    Write-Host "Output Folder:" -NoNewline -ForegroundColor "White"
    Write-Host " $OutputDir" -ForegroundColor "Yellow"
    if ($DownloadType -eq "video") {
        Write-Host "Quality:      " -NoNewline -ForegroundColor "White"
        Write-Host "$($Settings.videoQuality)" -ForegroundColor "Magenta"
    }
    Write-TypeWriter -Text "-----------------------------------------------" -Color "Red" -Speed 20

    $successCount = 0
    $failureCount = 0

    foreach ($entry in $linkEntries) {
        $urlToUse = $entry.OriginalUrl
        try {
            Show-ProgressUpdate "REAPER processing: $($entry.OriginalUrl)" -Type "Target"
            
            $currentArgs = @($ytDlpArgs) + $urlToUse

            & $script:YtDlpPath $currentArgs

            if ($LASTEXITCODE -eq 0) {
                $successCount++
                $entry.WasSuccess = $true
                Show-ProgressUpdate "[+] REAPER successfully harvested: $($entry.OriginalUrl)" -Type "Success"
            } else {
                throw "REAPER exfiltration engine reported failure for: $($entry.OriginalUrl)"
            }

        } catch {
            $failureCount++
            Show-ProgressUpdate "[!] REAPER target failed: $($entry.OriginalUrl)" -Type "Error"
            Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor DarkRed
        }
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

    $linesOut | Set-Content $FilePath

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
    Write-Host "[+] Successful extractions: " -NoNewline -ForegroundColor "White"
    Write-Pulse -Text "$batchSuccess" -Colors @("Green", "Cyan") -Cycles 1 -Speed 300
    Write-Host "[!] Failed extractions:     " -NoNewline -ForegroundColor "White"
    Write-Pulse -Text "$batchFailure" -Colors @("Red", "Yellow") -Cycles 1 -Speed 300
    Write-Host "Downloads saved to:        " -NoNewline -ForegroundColor "White"
    Write-Host "$script:DownloadsDir" -ForegroundColor "Yellow"

    if ($batchSuccess -gt 0) {
        Show-CompletionBanner
    } else {
        Write-Pulse -Text "`n[!] DIGITAL REAPER MISSION COMPROMISED: All batch targets failed." -Colors @("Red", "DarkRed") -Cycles 3
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

    Write-TypeWriter -Text "`n---[ DIGITAL REAPER - Beginning $resolvedType exfiltration ]---" -Color "Red" -Speed 40
    Write-Host "Target Count: " -NoNewline -ForegroundColor "White"
    Write-Host "$($urls.Count)" -ForegroundColor "Cyan"
    Write-Host "Output Folder:" -NoNewline -ForegroundColor "White" 
    Write-Host " $outputDir" -ForegroundColor "Yellow"
    if ($resolvedType -eq "video") {
        Write-Host "Quality:      " -NoNewline -ForegroundColor "White"
        Write-Host "$($Settings.videoQuality)" -ForegroundColor "Magenta"
    }
    Write-TypeWriter -Text "-----------------------------------------------" -Color "Red" -Speed 20

    $successCount = 0
    $failureCount = 0

    foreach ($url in $urls) {
        try {
            Show-ProgressUpdate "REAPER processing: $url" -Type "Target"
            
            $currentArgs = @($ytDlpArgs) + $url
            
            & $script:YtDlpPath $currentArgs
            
            if ($LASTEXITCODE -eq 0) {
                $successCount++
                Show-ProgressUpdate "[+] REAPER successfully harvested: $url" -Type "Success"
            } else {
                throw "REAPER exfiltration engine reported failure for: $url"
            }
            
        } catch {
            $failureCount++
            Show-ProgressUpdate "[!] REAPER target failed: $url" -Type "Error"
            Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor DarkRed
        }
    }

    Write-TypeWriter -Text "`n---[ DIGITAL REAPER - Mission Summary ]---" -Color "Cyan" -Speed 30
    Write-Host "[+] Successful extractions: " -NoNewline -ForegroundColor "White"
    Write-Pulse -Text "$successCount" -Colors @("Green", "Cyan") -Cycles 1 -Speed 300
    Write-Host "[!] Failed extractions:     " -NoNewline -ForegroundColor "White"
    Write-Pulse -Text "$failureCount" -Colors @("Red", "Yellow") -Cycles 1 -Speed 300
    Write-Host "Downloads saved to:        " -NoNewline -ForegroundColor "White"
    Write-Host "$outputDir" -ForegroundColor "Yellow"

    if ($successCount -gt 0) {
        Show-CompletionBanner
    } else {
        Write-Pulse -Text "`n[!] DIGITAL REAPER MISSION COMPROMISED: All targets failed." -Colors @("Red", "DarkRed") -Cycles 3
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
