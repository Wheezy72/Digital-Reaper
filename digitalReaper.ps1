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

$SCRIPT_VERSION = "1.0.0"
$YTDLP_CURRENT_VERSION = "2024.12.06"

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:YtDlpPath = Join-Path $script:ScriptDir "yt-dlp.exe"
$script:FfmpegPath = Join-Path $script:ScriptDir "bin\ffmpeg.exe"
$script:BinDir = Join-Path $script:ScriptDir "bin"
$script:DownloadsDir = Join-Path $script:ScriptDir "downloads"
$script:DefaultLinksFile = Join-Path $script:ScriptDir "links.txt"
$script:DefaultConfigFile = Join-Path $script:ScriptDir "settings.json"

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
    $color = switch ($Type) {
        "Success" { "Green" }; "Warning" { "Yellow" }; "Error" { "Red" }
        "Target" { "Cyan" }; "System" { "Blue" }; "Update" { "Magenta" }
        default { "White" }
    }
    if ($Type -eq "Success") {
        Write-Pulse -Text "[$timestamp] $Status" -Colors @("Green", "White", "Green") -Cycles 1 -Speed 200
    } elseif ($Type -eq "Error") {
        Write-Pulse -Text "[$timestamp] $Status" -Colors @("Red", "DarkRed", "Red") -Cycles 2 -Speed 300
    } else {
        Write-Host "[$timestamp] $Status" -ForegroundColor $color
    }
}

function Show-StartupSequence {
    $digitalReaperArt = @'
@@@@@@@   @@@   @@@@@@@@  @@@  @@@@@@@   @@@@@@   @@@          @@@@@@@   @@@@@@@@   @@@@@@   @@@@@@@   @@@@@@@@  @@@@@@@   
@@@@@@@@  @@@  @@@@@@@@@  @@@  @@@@@@@  @@@@@@@@  @@@          @@@@@@@@  @@@@@@@@  @@@@@@@@  @@@@@@@@  @@@@@@@@  @@@@@@@@  
@@!  @@@  @@!  !@@        @@!    @@!    @@!  @@@  @@!          @@!  @@@  @@!       @@!  @@@  @@!  @@@  @@!       @@!  @@@  
!@!  @!@  !@!  !@!        !@!    !@!    !@!  @!@  !@!          !@!  @!@  !@!       !@!  @!@  !@!  @!@  !@!       !@!  @!@  
@!@  !@!  !!@  !@! @!@!@  !!@    @!!    @!@!@!@!  @!!          @!@!!@!   @!!!:!    @!@!@!@!  @!@@!@!   @!!!:!    @!@!!@!   
!@!  !!!  !!!  !!! !!@!!  !!!    !!!    !!!@!!!!  !!!          !!@!@!    !!!!!:    !!!@!!!!  !!@!!!    !!!!!:    !!@!@!    
!!:  !!!  !!:  :!!   !!:  !!:    !!:    !!:  !!!  !!:          !!: :!!   !!:       !!:  !!!  !!:       !!:       !!: :!!   
:!:  !:!  :!:  :!:   !::  :!:    :!:    :!:  !:!   :!:         :!:  !:!  :!:       :!:  !:!  :!:       :!:       :!:  !:!  
 :::: ::   ::   ::: ::::   ::     ::    ::   :::   :: ::::     ::   :::   :: ::::  ::   :::   ::        :: ::::  ::   :::  
:: :  :   :     :: :: :   :       :      :   : :  : :: : :      :   : :  : :: ::    :   : :   :        : :: ::    :   : :  
'@
    
    # Purple to Blue gradient display
    $lines = $digitalReaperArt -split "`n"
    $lineCount = $lines.Count
    
    for ($i = 0; $i -lt $lineCount; $i++) {
        $ratio = if ($lineCount -gt 1) { $i / ($lineCount - 1) } else { 0 }
        
        # Purple (128,0,128) to Blue (0,0,255) gradient
        $r = [math]::Round(128 + ((0 - 128) * $ratio))
        $g = [math]::Round(0 + ((0 - 0) * $ratio))
        $b = [math]::Round(128 + ((255 - 128) * $ratio))
        
        # Use PowerShell color fallback for compatibility
        $colors = @("Magenta", "DarkMagenta", "Blue", "DarkBlue", "Blue")
        $colorIndex = [math]::Floor($ratio * ($colors.Count - 1))
        $color = $colors[$colorIndex]
        
        Write-Host $lines[$i] -ForegroundColor $color
        Start-Sleep -Milliseconds 50
    }
    
    Write-Host ""
    Write-Host ""
}

function Show-CompletionBanner {
    Write-Host "`n"
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor "Green"
    Write-Host "                    MISSION STATUS: COMPLETE                     " -ForegroundColor "Green"
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor "Green"
    Write-Host ""
    
    $prodByWheezy = @'
    ____                 __   __             _       ____                         
   / __ \_______  ____/ /  / /_  __  __   | |     / / /_  ___  ___  ____  __  __
  / /_/ / ___/ __ \/ __  /  / __ \/ / / /   | | /| / / __ \/ _ \/ _ \/_  / / / / /
 / ____/ /  / /_/ / /_/ /  / /_/ / /_/ /    | |/ |/ / / / /  __/  __/ / /_/ /_/ / 
/_/   /_/   \____/\__,_/  /_.___/\__, /     |__/|__/_/ /_/\___/\___/ /___/\__, /  
                                /____/                                   /____/
'@
    
    # Purple to Blue gradient for completion banner
    $lines = $prodByWheezy -split "`n"
    $lineCount = $lines.Count
    
    for ($i = 0; $i -lt $lineCount; $i++) {
        $ratio = if ($lineCount -gt 1) { $i / ($lineCount - 1) } else { 0 }
        
        # Purple to Blue gradient
        $colors = @("Magenta", "DarkMagenta", "Blue", "DarkBlue", "Blue")
        $colorIndex = [math]::Floor($ratio * ($colors.Count - 1))
        $color = $colors[$colorIndex]
        
        Write-Host $lines[$i] -ForegroundColor $color
    }
    
    Write-Host ""
    Write-Host "[✓] GOING DARK. REAPER MISSION ACCOMPLISHED." -ForegroundColor "Red"
    Write-Host ""
}

function Get-UrlsFromFile {
    param ([string]$FilePath)
    $urls = @()
    if (Test-Path $FilePath) {
        $content = Get-Content $FilePath
        foreach ($line in $content) {
            $line = $line.Trim()
            if ($line -and !$line.StartsWith("#") -and ($line.StartsWith("http") -or $line.StartsWith("www"))) {
                $urls += $line
                Show-ProgressUpdate "Target acquired: $line" -Type "Target"
            }
        }
    }
    return $urls
}

function Show-MenuOption {
    param([string]$Prompt, [string]$Options, [string[]]$Colors = @("Yellow", "Magenta", "Cyan", "Green"))
    $optionParts = $Options -split ", "
    $colorIndex = 0
    
    Write-Host -NoNewline ">> $Prompt (" -ForegroundColor Yellow
    
    for ($i = 0; $i -lt $optionParts.Count; $i++) {
        $color = $Colors[$colorIndex % $Colors.Count]
        Write-Host -NoNewline $optionParts[$i] -ForegroundColor $color
        if ($i -lt $optionParts.Count - 1) {
            Write-Host -NoNewline ", " -ForegroundColor White
        }
        $colorIndex++
    }
    
    Write-Host -NoNewline "): " -ForegroundColor Yellow
}

# ===================================================================
# --- SETTINGS MANAGEMENT ---
# ===================================================================

function Get-DefaultSettings {
    return @{
        downloadType = "video"
        videoQuality = "1080p"
        audioFormat = "mp3"
        useHEVC = $true
        downloadSubtitles = $true
        subtitleLanguages = @("en", "en-US")
        outputTemplate = "%(uploader)s/[%(upload_date)s] %(title)s [%(id)s].%(ext)s"
        autoUpdate = $true
        silentMode = $false
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
    
    if (-not (Test-Path $script:BinDir)) {
        New-Item -Path $script:BinDir -ItemType Directory -Force | Out-Null
        Show-ProgressUpdate "[+] Created bin directory" -Type "System"
    }
    
    if (-not (Test-Path $script:DownloadsDir)) {
        New-Item -Path $script:DownloadsDir -ItemType Directory -Force | Out-Null
        Show-ProgressUpdate "[+] Created downloads directory" -Type "Success"
    }
    
    if (-not (Test-Path $script:YtDlpPath)) {
        Show-ProgressUpdate "[!] yt-dlp.exe not found! Please download it from https://github.com/yt-dlp/yt-dlp/releases" -Type "Error"
        return $false
    }
    
    if (-not (Test-Path $script:FfmpegPath)) {
        Show-ProgressUpdate "[!] ffmpeg.exe not found in bin folder! Please download it." -Type "Error"
        return $false
    }
    
    Set-HiddenAttribute -Path $script:YtDlpPath
    Set-HiddenAttribute -Path $script:FfmpegPath
    Set-HiddenAttribute -Path $script:BinDir
    
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
            
            Invoke-WebRequest -Uri $downloadUrl -OutFile $script:YtDlpPath -TimeoutSec 30 -ErrorAction SilentlyContinue
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
        # Remove query parameters (everything after ?) to fix download issues
        if ($url -match '^(https?://[^?]+)') {
            $cleanUrl = $matches[1]
            $sanitizedUrls += $cleanUrl
            Show-ProgressUpdate "Sanitized URL: $cleanUrl" -Type "System"
        } else {
            $sanitizedUrls += $url
        }
    }
    
    return $sanitizedUrls
}

# ===================================================================
# --- SMART URL DETECTION ---
# ===================================================================

function Get-UrlsSmartMode {
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
        Show-MenuOption -Prompt "Select Input Method" -Options "1=Manual URL, 2=Load from File" -Colors @("Yellow", "Magenta")
        $inputMethod = Read-Host
        if ($inputMethod -notin @("1", "2")) { 
            Write-Pulse -Text "`n[!] Invalid command. Use 1 or 2." -Colors @("Red", "Yellow") -Cycles 2
        }
    }

    if ($inputMethod -eq "1") {
        $url = ""
        while ([string]::IsNullOrWhiteSpace($url)) {
            Write-Host -NoNewline ">> Enter Target URL (Video or Playlist): " -ForegroundColor "Yellow"
            $url = Read-Host
            if ([string]::IsNullOrWhiteSpace($url)) { 
                Write-Pulse -Text "`n[!] Abort: Target URL cannot be empty." -Colors @("Red", "Yellow") -Cycles 2
            }
        }
        return @($url)
    } else {
        $filePath = ""
        while ([string]::IsNullOrWhiteSpace($filePath) -or -not (Test-Path $filePath)) {
            Write-Host -NoNewline ">> Enter path to URLs file (.txt): " -ForegroundColor "Magenta"
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

    $urls = Get-UrlsSmartMode
    
    if ($urls.Count -eq 0) {
        Write-Pulse -Text "[!] No valid URLs found." -Colors @("Red", "DarkRed") -Cycles 2
        Read-Host "Press Enter to exit..."
        exit 1
    }
    
    # SANITIZE URLs to fix download issues
    $urls = Get-SanitizedUrls -Urls $urls
    
    Show-ProgressUpdate "Loaded $($urls.Count) targets for processing" -Type "Success"

    # BUILD YT-DLP ARGUMENTS
    $ytDlpArgs = New-Object System.Collections.Generic.List[string]

    $ytDlpArgs.Add("--ffmpeg-location")
    $ytDlpArgs.Add($script:BinDir)
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

    if ($settings.downloadSubtitles) {
        Show-ProgressUpdate "Subtitle extraction enabled" -Type "Success"
        $ytDlpArgs.Add("--write-auto-sub")
        $ytDlpArgs.Add("--write-sub")
        $ytDlpArgs.Add("--sub-lang")
        $ytDlpArgs.Add(($settings.subtitleLanguages -join ","))
        $ytDlpArgs.Add("--convert-subs")
        $ytDlpArgs.Add("srt")
    }

    if ($settings.downloadType -eq "audio") {
        Write-TypeWriter -Text "[*] REAPER configuring for audio-only exfiltration..." -Color "Yellow" -Speed 30
        $ytDlpArgs.Add("--extract-audio")
        $ytDlpArgs.Add("--audio-format")
        $ytDlpArgs.Add($settings.audioFormat)
        $ytDlpArgs.Add("--audio-quality")
        $ytDlpArgs.Add("0")
    } else {
        $codecPreference = if ($settings.useHEVC) { "[vcodec^=hevc]/[vcodec^=h265]/" } else { "" }
        
        $height = switch ($settings.videoQuality) {
            "720p" { 720 }
            "1080p" { 1080 }
            "1440p" { 1440 }
            "4K" { 2160 }
            default { 1080 }
        }
        
        Write-TypeWriter -Text "[*] REAPER configuring for $($settings.videoQuality) video stream..." -Color "Green" -Speed 30
        $format = "($codecPreference" + "bestvideo[height<=$height])+bestaudio/best[height<=$height]"
        
        $ytDlpArgs.Add("-f")
        $ytDlpArgs.Add($format)
        $ytDlpArgs.Add("--merge-output-format")
        $ytDlpArgs.Add("mp4")

        if ($settings.useHEVC) {
            Show-ProgressUpdate "HEVC/H.265 codec preference enabled" -Type "Success"
        }
    }

    $outputTemplate = Join-Path -Path $script:DownloadsDir -ChildPath $settings.outputTemplate
    $ytDlpArgs.Add("-o")
    $ytDlpArgs.Add($outputTemplate)

    Show-ProgressUpdate "Enhanced metadata filename structure enabled" -Type "Success"
    Write-Host "    Output: " -NoNewline -ForegroundColor "Gray"
    Write-Host "$script:DownloadsDir" -ForegroundColor "Yellow"

    Write-TypeWriter -Text "`n---[ DIGITAL REAPER - Beginning Mass Exfiltration ]---" -Color "Red" -Speed 40
    Write-Host "Target Count: " -NoNewline -ForegroundColor "White"
    Write-Host "$($urls.Count)" -ForegroundColor "Cyan"
    Write-Host "Output Folder:" -NoNewline -ForegroundColor "White" 
    Write-Host " $script:DownloadsDir" -ForegroundColor "Yellow"
    Write-Host "Quality:      " -NoNewline -ForegroundColor "White"
    Write-Host "$($settings.videoQuality)" -ForegroundColor "Magenta"
    Write-TypeWriter -Text "-----------------------------------------------" -Color "Red" -Speed 20

    $successCount = 0
    $failureCount = 0

    foreach ($url in $urls) {
        try {
            Show-ProgressUpdate "REAPER processing: $url" -Type "Target"
            
            $currentArgs = $ytDlpArgs.ToArray()
            $currentArgs += $url
            
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
    Write-Host "$script:DownloadsDir" -ForegroundColor "Yellow"

    if ($successCount -gt 0) {
        Show-CompletionBanner
    } else {
        Write-Pulse -Text "`n[!] DIGITAL REAPER MISSION COMPROMISED: All targets failed." -Colors @("Red", "DarkRed") -Cycles 3
    }

} catch {
    Write-Host "`n[!] CRITICAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace:" -ForegroundColor DarkRed
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}

Write-Host -NoNewline "`n>> DIGITAL REAPER session complete. Press Enter to go dark..." -ForegroundColor "Yellow"
Read-Host | Out-Null
