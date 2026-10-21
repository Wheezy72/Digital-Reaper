<#
========================================================================
    DIGITAL REAPER -Video/Audio Downloader
    Custom tool for grabbing content with style
    Made by Wheezy for Wheezy
========================================================================
#>

param(
    [string]$LinksFile = "",
    [string]$ConfigFile = "",
    [switch]$Silent,
    [switch]$SetupOnly,
    [switch]$Doctor
)

# ===================================================================
# --- SCRIPT CONFIGURATION ---
# ===================================================================

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:EngineDir = Join-Path $script:ScriptDir "engine"
# Prefer automatic $IsWindows when available; fall back for older hosts.
$script:IsWindowsPlatform = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) {
    [bool]$IsWindows
}
else {
    try {
        [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
    }
    catch {
        ($PSVersionTable.PSEdition -eq "Desktop") -or ($env:OS -eq "Windows_NT")
    }
}
$script:YtDlpAssetName = if ($script:IsWindowsPlatform) { "yt-dlp.exe" } else { "yt-dlp_linux" }
$script:YtDlpBinaryName = if ($script:IsWindowsPlatform) { "yt-dlp.exe" } else { "yt-dlp" }
$script:FfmpegBinaryName = if ($script:IsWindowsPlatform) { "ffmpeg.exe" } else { "ffmpeg" }
$script:FfprobeBinaryName = if ($script:IsWindowsPlatform) { "ffprobe.exe" } else { "ffprobe" }
$script:YtDlpPath = Join-Path $script:EngineDir $script:YtDlpBinaryName
$script:FfmpegPath = Join-Path $script:EngineDir $script:FfmpegBinaryName
$script:FfprobePath = Join-Path $script:EngineDir $script:FfprobeBinaryName
$script:FfmpegLocation = $script:EngineDir

$script:DownloadsDir = Join-Path $script:ScriptDir "downloads"
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
$script:DefaultOuterRetryCount = 3
$script:LogFilePath = Join-Path $script:EngineDir "reaper.log"

# --- Bot-guard tuning -------------------------------------------------------
# Ordered YouTube player clients, tried ONLY after a bot check is hit. yt-dlp's
# own default order is used until then, because it ships calibrated per release.
# A client name this build does not know fails with "Unsupported client", which
# is classified below and simply advances to the next one.
$script:DefaultPlayerClientChain = @(
    "android_vr",
    "tv",
    "ios",
    "mweb",
    "web_safari"
)

# Failure classes, most specific first. Order matters: "Sign in to confirm your
# age" is an age gate, not a bot check, so LoginRequired must win that tie.
$script:FailurePatterns = @(
    [pscustomobject]@{ Kind = "BotCheck"; Pattern = "not a bot|confirm you.{0,4}re (not )?(a )?(bot|robot)|unusual traffic|prove you.{0,4}re not a robot|automated quer" },
    [pscustomobject]@{ Kind = "LoginRequired"; Pattern = "sign in|log in|login required|age-restricted|confirm your age|members-only|join this channel|private video|is private|premium" },
    [pscustomobject]@{ Kind = "RateLimit"; Pattern = "\b429\b|too many requests|rate.?limit" },
    [pscustomobject]@{ Kind = "GeoBlocked"; Pattern = "available in your country|geo.?restrict|blocked it in your country|not available in your region" },
    [pscustomobject]@{ Kind = "Unavailable"; Pattern = "video unavailable|video is unavailable|is unavailable|has been removed|no longer available|account associated with this video has been terminated" },
    [pscustomobject]@{ Kind = "Format"; Pattern = "requested format is not available|no video formats found|format is not available" },
    [pscustomobject]@{ Kind = "Transient"; Pattern = "page needs to be reloaded|please reload|try again later|something went wrong" },
    [pscustomobject]@{ Kind = "Forbidden"; Pattern = "http error 403|\b403\b.{0,20}forbidden|forbidden" },
    [pscustomobject]@{ Kind = "UnsupportedClient"; Pattern = "unsupported client|invalid player client|client .{0,20} is not supported" },
    [pscustomobject]@{ Kind = "Network"; Pattern = "timed out|timeout|connection reset|connection aborted|temporary failure in name resolution|getaddrinfo|eof occurred|unable to connect|network is unreachable|ssl" }
)

# Per-class retry policy. A class that is not listed here is never retried:
# repeating an identical request is what turns a bot check into a longer block.
$script:RetryPolicy = @{
    BotCheck          = @{ Retry = $true; BaseDelay = 5; MaxDelay = 60; Escalate = $true }
    UnsupportedClient = @{ Retry = $true; BaseDelay = 1; MaxDelay = 2; Escalate = $true }
    Forbidden         = @{ Retry = $true; BaseDelay = 5; MaxDelay = 30; Escalate = $true }
    Format            = @{ Retry = $true; BaseDelay = 2; MaxDelay = 5; Escalate = $true }
    RateLimit         = @{ Retry = $true; BaseDelay = 15; MaxDelay = 300; Escalate = $false }
    Network           = @{ Retry = $true; BaseDelay = 3; MaxDelay = 30; Escalate = $false }
    Transient         = @{ Retry = $true; BaseDelay = 3; MaxDelay = 15; Escalate = $false }
}

$script:FriendlyHints = @{
    BotCheck          = "YouTube wants a bot check. Set cookieSource (or cookieFile) and retry; if it keeps happening, wait a few minutes - hammering makes it worse."
    LoginRequired     = "Login needed for this video. Set cookieSource to your browser, or export a cookies.txt and point cookieFile at it."
    RateLimit         = "YouTube is rate-limiting this connection. Back off, or lower concurrentFragments and maxRate."
    GeoBlocked        = "This video is region-restricted in your current location."
    Unavailable       = "Video unavailable. It may have been removed, made private, or blocked."
    UnsupportedClient = "This yt-dlp build does not support that player client - moving to the next one."
    Forbidden         = "Server refused the request (HTTP 403) - usually a stale token or a client mismatch. Retrying with a different player client."
    Format            = "That quality is not offered for this video. Lower videoQuality or disable useHEVC."
    Transient         = "YouTube asked for the request to be sent again - retrying."
    Network           = "Network issue detected. Check your connection and retry."
    Other             = "Download failed. Verify the link works in your browser and try again."
}

# Session-wide bot-guard state (see Reset-BotGuard / Step-BotGuard).
$script:BotGuard = $null

# Cached results for the JS-runtime probe (see Get-JsRuntimeArgs).
$script:JsRuntimeArgs = $null
$script:JsRuntimeSupport = $null

# ===================================================================
# --- ENHANCED AESTHETIC FUNCTIONS ---
# ===================================================================

function Write-TypeWriter {
    param([string]$Text, [string]$Color = "White", [int]$Speed = 0, [switch]$NoNewLine)
    foreach ($char in $Text.ToCharArray()) {
        Write-Host -NoNewline $char -ForegroundColor $Color
        if ($Speed -gt 0) {
            Start-Sleep -Milliseconds $Speed
        }
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
    }
    elseif ($Type -eq "Error") {
        Write-Pulse -Text "[$timestamp] $Status" -Colors @("Red", "DarkRed", "Red") -Cycles 2 -Speed 300
    }
    else {
        $color = switch ($Type) {
            "Warning" { "Yellow" }; "Target" { "Cyan" }; "System" { "Blue" }; "Update" { "Magenta" }
            default { "White" }
        }
        Write-Host "[$timestamp] $Status" -ForegroundColor $color
    }
}

function Get-ConsoleWidth {
    try {
        return [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 1)
    }
    catch {
        return 100
    }
}

function Write-StatusLine {
    param(
        [string]$Text,
        [string]$Color = "DarkGray"
    )
    $width = Get-ConsoleWidth
    if ($Text.Length -gt $width) {
        $Text = $Text.Substring(0, $width - 3) + "..."
    }
    $padding = " " * [Math]::Max(0, $width - $Text.Length)
    Write-Host "`r$Text$padding" -NoNewline -ForegroundColor $Color
}

function Clear-StatusLine {
    $width = Get-ConsoleWidth
    Write-Host ("`r" + (" " * $width) + "`r") -NoNewline
}

function Invoke-WithStatusDots {
    param(
        [string]$Status,
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $frames = @(".", "..", "...")
    $frameIndex = 0

    try {
        while ($job.State -eq "Running") {
            Write-StatusLine -Text ("{0}{1}" -f $Status, $frames[$frameIndex]) -Color "DarkGray"
            $frameIndex = ($frameIndex + 1) % $frames.Count
            Start-Sleep -Milliseconds 350
        }

        $output = Receive-Job -Job $job
        if ($job.State -eq "Failed") {
            throw ($job.ChildJobs[0].JobStateInfo.Reason)
        }
        return $output
    }
    finally {
        Clear-StatusLine
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
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
    Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkGray
    Write-Host "  |  DIGITAL REAPER  >>  " -NoNewline -ForegroundColor Gray
    Write-Host "$TypeLabel $Mode" -ForegroundColor Cyan
    Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkGray
    Write-Host "  | Targets : " -NoNewline -ForegroundColor Gray
    Write-Host "$TargetCount" -ForegroundColor Cyan
    Write-Host "  | Output  : " -NoNewline -ForegroundColor Gray
    Write-Host $OutputDir -ForegroundColor Yellow
    if ($Quality) {
        Write-Host "  | Quality : " -NoNewline -ForegroundColor Gray
        Write-Host $Quality -ForegroundColor Magenta
    }
    Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkGray
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
        videoQuality        = "1080p"
        audioFormat         = "mp3"
        useHEVC             = $true
        downloadSubtitles   = $false
        subtitleLanguages   = @("en", "en-US")
        outputTemplate      = "[%(upload_date)s] %(title)s [%(id)s].%(ext)s"
        autoUpdate          = $true
        oneClickMode        = $true
        defaultDownloadType = "video"
        outputFolder        = ""
        cookieSource        = "none"
        maxRate             = "2M"
        concurrentFragments = 1
        retryCount          = 8
        outerRetryCount     = $script:DefaultOuterRetryCount
        cookieFile          = ""
        userAgent           = ""
        playerClients       = @()
        requestSleep        = 1
        minSleepInterval    = 1
        maxSleepInterval    = 3
        maxFragmentRetries  = 20
        botCooldownSeconds  = 60
        downloadArchive     = ""
        diagnosticsLog      = $true
        jsRuntime           = ""
    }
}

# Coerces a value from settings.json to the type of its default, so a quoted
# number ("3") or a bare string where a list belongs can no longer blow up deep
# inside the argument builder.
function ConvertTo-SettingValue {
    param($Value, $Reference)

    if ($null -eq $Value) { return $Reference }

    if ($Reference -is [System.Array]) {
        $items = @()
        if ($Value -is [System.Array]) { $items = @($Value) } else { $items = @($Value) }
        return @($items | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }

    if ($Reference -is [bool]) {
        if ($Value -is [bool]) { return $Value }
        return ([string]$Value -match '^(true|1|yes|on)$')
    }

    if ($Reference -is [int] -or $Reference -is [long] -or $Reference -is [double]) {
        $parsed = 0.0
        $styles = [System.Globalization.NumberStyles]::Float
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        if ([double]::TryParse([string]$Value, $styles, $culture, [ref]$parsed)) {
            if ($Reference -is [double]) { return $parsed }
            return [int]$parsed
        }
        return $Reference
    }

    return [string]$Value
}

function Merge-SettingsFromFile {
    param([hashtable]$Settings, [string]$FilePath)
    if (-not (Test-Path $FilePath)) { return }
    $userSettings = Get-Content $FilePath | ConvertFrom-Json
    foreach ($key in $userSettings.PSObject.Properties.Name) {
        if ($Settings.ContainsKey($key)) {
            $Settings[$key] = ConvertTo-SettingValue -Value $userSettings.$key -Reference $Settings[$key]
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
        }
        catch {
            Show-ProgressUpdate "Error loading settings file. Using defaults." -Type "Warning"
        }
    }
    elseif (Test-Path $script:DefaultConfigFile) {
        try {
            Merge-SettingsFromFile -Settings $settings -FilePath $script:DefaultConfigFile
            Show-ProgressUpdate "Settings loaded from: settings.json" -Type "Success"
        }
        catch {
            Show-ProgressUpdate "Error loading settings. Using defaults." -Type "Warning"
        }
    }
    
    return $settings
}

function Save-Settings {
    param([hashtable]$Settings)
    try {
        $ordered = [ordered]@{}
        foreach ($key in ($Settings.Keys | Sort-Object)) {
            $ordered[$key] = $Settings[$key]
        }
        $ordered | ConvertTo-Json -Depth 6 | Set-Content -Path $script:DefaultConfigFile
        Show-ProgressUpdate "[+] Settings saved to settings.json" -Type "Success"
    }
    catch {
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
                if ($quality -in @("720p", "1080p", "1440p", "4K")) {
                    $Settings.videoQuality = $quality
                }
                else {
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
                if ($cookie -in @("none", "chrome", "edge", "firefox")) {
                    $Settings.cookieSource = $cookie
                }
                else {
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
    if ($DownloadType -eq "audio") {
        return Join-Path $baseDir "audio"
    }
    return Join-Path $baseDir "videos"
}

# ===================================================================
# --- INITIALIZATION & UPDATE FUNCTIONS ---
# ===================================================================

function Set-HiddenAttribute {
    param ([string]$Path)
    if (-not $script:IsWindowsPlatform) {
        return
    }
    try {
        if (Test-Path $Path) {
            $item = Get-Item $Path -Force
            if (-not ($item.Attributes -band [System.IO.FileAttributes]::Hidden)) {
                $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
            }
        }
    }
    catch {
        # Silent fail
    }
}

function Set-ExecutablePermission {
    param([string]$Path)
    if ($script:IsWindowsPlatform) {
        return $true
    }

    try {
        & chmod +x $Path
        if ($LASTEXITCODE -ne 0) {
            throw "chmod returned exit code $LASTEXITCODE"
        }
        return $true
    }
    catch {
        Show-ProgressUpdate "[!] Failed to mark file executable: $Path ($($_.Exception.Message))" -Type "Error"
        return $false
    }
}

function Install-YtDlp {
    Show-ProgressUpdate "[~] yt-dlp not found — downloading latest release..." -Type "Update"
    try {
        $apiUrl = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
        $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'DigitalReaper' } -TimeoutSec 15 -ErrorAction Stop
        $asset = $release.assets | Where-Object { $_.name -eq $script:YtDlpAssetName } | Select-Object -First 1
        if (-not $asset) { throw "$($script:YtDlpAssetName) asset not found in latest release." }

        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $script:YtDlpPath -TimeoutSec 120 -ErrorAction Stop
        if (-not (Set-ExecutablePermission -Path $script:YtDlpPath)) {
            throw "Could not set executable permission on yt-dlp."
        }

        $downloaded = Get-Item $script:YtDlpPath -ErrorAction SilentlyContinue
        if (-not $downloaded -or $downloaded.Length -eq 0) { throw "Downloaded file is empty." }

        Show-ProgressUpdate "[+] yt-dlp installed ($($release.tag_name))" -Type "Success"
        Set-Content -Path $script:VersionFilePath -Value $release.tag_name
        return $true
    }
    catch {
        Show-ProgressUpdate "[!] Failed to download yt-dlp: $($_.Exception.Message)" -Type "Error"
        return $false
    }
}

function Install-Ffmpeg {
    if (-not $script:IsWindowsPlatform) {
        Show-ProgressUpdate "[~] Linux detected — checking for system ffmpeg/ffprobe..." -Type "Update"
        $systemFfmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
        $systemFfprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
        $missingTools = @()
        if (-not $systemFfmpeg) { $missingTools += "ffmpeg" }
        if (-not $systemFfprobe) { $missingTools += "ffprobe" }
        if ($missingTools.Count -gt 0) {
            Show-ProgressUpdate "[!] Missing required tool(s): $($missingTools -join ', ')." -Type "Error"
            Show-ProgressUpdate "[!] Install ffmpeg package using your package manager:" -Type "Error"
            Show-ProgressUpdate "    Ubuntu/Debian: sudo apt install ffmpeg" -Type "Warning"
            Show-ProgressUpdate "    Fedora:        sudo dnf install ffmpeg" -Type "Warning"
            Show-ProgressUpdate "    Arch:          sudo pacman -S ffmpeg" -Type "Warning"
            return $false
        }

        $script:FfmpegPath = $systemFfmpeg.Source
        $script:FfprobePath = $systemFfprobe.Source

        $null = & $script:FfmpegPath -version 2>&1
        if ($LASTEXITCODE -ne 0) {
            Show-ProgressUpdate "[!] ffmpeg failed functional verification (exit code $LASTEXITCODE)." -Type "Error"
            return $false
        }
        $null = & $script:FfprobePath -version 2>&1
        if ($LASTEXITCODE -ne 0) {
            Show-ProgressUpdate "[!] ffprobe failed functional verification (exit code $LASTEXITCODE)." -Type "Error"
            return $false
        }

        Show-ProgressUpdate "[+] Using system ffmpeg and ffprobe" -Type "Success"
        return $true
    }

    Show-ProgressUpdate "[~] ffmpeg not found — downloading static build (this may take a minute)..." -Type "Update"
    # Use the static (non-shared) GPL build so ffmpeg.exe and ffprobe.exe are
    # self-contained executables with no companion DLLs required.
    $zipUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
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
        $installedFfmpeg = Get-Item $script:FfmpegPath  -ErrorAction SilentlyContinue
        $installedFfprobe = Get-Item $script:FfprobePath -ErrorAction SilentlyContinue
        if (-not $installedFfmpeg -or $installedFfmpeg.Length -eq 0) { throw "Copied ffmpeg.exe is empty." }
        if (-not $installedFfprobe -or $installedFfprobe.Length -eq 0) { throw "Copied ffprobe.exe is empty." }

        # Functional verification — make sure both binaries actually run
        $null = & $script:FfmpegPath  -version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg.exe failed functional verification (exit code $LASTEXITCODE)." }
        $null = & $script:FfprobePath -version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "ffprobe.exe failed functional verification (exit code $LASTEXITCODE)." }

        Show-ProgressUpdate "[+] ffmpeg and ffprobe installed" -Type "Success"
        return $true
    }
    catch {
        Show-ProgressUpdate "[!] Failed to install ffmpeg: $($_.Exception.Message)" -Type "Error"
        # Remove any partial files so the next launch will retry cleanly
        Remove-Item $script:FfmpegPath  -Force -ErrorAction SilentlyContinue
        Remove-Item $script:FfprobePath -Force -ErrorAction SilentlyContinue
        return $false
    }
    finally {
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

    if ($script:IsWindowsPlatform) {
        $script:FfmpegLocation = $script:EngineDir
    }
    else {
        $script:FfmpegLocation = Split-Path -Parent $script:FfmpegPath
    }
    
    Set-HiddenAttribute -Path $script:YtDlpPath
    Set-HiddenAttribute -Path $script:FfmpegPath
    Set-HiddenAttribute -Path $script:FfprobePath
    Set-HiddenAttribute -Path $script:EngineDir
    
    Show-ProgressUpdate "[+] All DIGITAL REAPER components ready" -Type "Success"
    return $true
}

function Update-YtDlpSilent {
    $messages = Invoke-WithStatusDots -Status "Checking for yt-dlp updates" -ArgumentList @($script:VersionFilePath, $script:YtDlpPath, $script:YtDlpAssetName, $script:IsWindowsPlatform) -ScriptBlock {
        param(
            [string]$VersionFilePath,
            [string]$YtDlpPath,
            [string]$YtDlpAssetName,
            [bool]$IsWindowsPlatform
        )

        try {
            $url = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"

            # Use Invoke-WebRequest so we can inspect the status code for rate-limit signals
            $webResponse = Invoke-WebRequest -Uri $url -Headers @{ 'User-Agent' = 'DigitalReaper' } -TimeoutSec 10 -ErrorAction Stop
            if ($webResponse.StatusCode -eq 403 -or $webResponse.StatusCode -eq 429) {
                return [pscustomobject]@{ Type = "Warning"; Message = "[!] GitHub API rate limit reached — skipping yt-dlp update check." }
            }
            $response = $webResponse.Content | ConvertFrom-Json
            $latestVersion = $response.tag_name

            # Read the currently installed version from file (fallback: empty string so we always update on first run)
            $installedVersion = ""
            if (Test-Path $VersionFilePath) {
                $installedVersion = (Get-Content $VersionFilePath -Raw).Trim()
            }

            if ($latestVersion -and $latestVersion -ne $installedVersion) {
                $asset = $response.assets | Where-Object { $_.name -eq $YtDlpAssetName } | Select-Object -First 1
                if (-not $asset) {
                    return [pscustomobject]@{ Type = "Warning"; Message = "[!] Could not find $YtDlpAssetName in latest release assets — skipping update." }
                }

                $downloadUrl = $asset.browser_download_url
                $backupPath = "$YtDlpPath.backup"
                $incomingPath = if ($IsWindowsPlatform) { "$YtDlpPath.new.exe" } else { "$YtDlpPath.new" }

                # cleanup.bat hides engine\yt-dlp.exe, and a hidden file cannot be
                # opened for writing ("Access to the path ... is denied"). That made
                # every auto-update fail silently, which is how a four-month-old
                # yt-dlp turns into constant bot checks. Download beside it, verify,
                # then swap the file in.
                if (Test-Path $incomingPath) { Remove-Item $incomingPath -Force -ErrorAction SilentlyContinue }

                if (Test-Path $YtDlpPath) {
                    (Get-Item $YtDlpPath -Force).Attributes = [System.IO.FileAttributes]::Normal
                    Copy-Item $YtDlpPath $backupPath -Force
                }

                try {
                    Invoke-WebRequest -Uri $downloadUrl -OutFile $incomingPath -TimeoutSec 300 -ErrorAction Stop

                    $incoming = Get-Item $incomingPath -ErrorAction SilentlyContinue
                    if (-not $incoming -or $incoming.Length -eq 0) { throw "Downloaded yt-dlp is empty." }

                    if (-not $IsWindowsPlatform) {
                        & chmod +x $incomingPath
                        if ($LASTEXITCODE -ne 0) { throw "chmod failed on the downloaded yt-dlp." }
                    }

                    # The new binary has to run before it is allowed to replace a
                    # working one.
                    $null = & $incomingPath --version 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "Downloaded yt-dlp failed its version check." }

                    Remove-Item -Path $YtDlpPath -Force -ErrorAction SilentlyContinue
                    Move-Item -Path $incomingPath -Destination $YtDlpPath -Force -ErrorAction Stop
                    $installed = Get-Item $YtDlpPath -Force
                    $installed.Attributes = $installed.Attributes -bor [System.IO.FileAttributes]::Hidden
                    Set-Content -Path $VersionFilePath -Value $latestVersion
                    if (Test-Path $backupPath) { Remove-Item $backupPath -Force -ErrorAction SilentlyContinue }

                    return [pscustomobject]@{ Type = "Success"; Message = "yt-dlp updated to $latestVersion" }
                }
                catch {
                    if (Test-Path $incomingPath) { Remove-Item $incomingPath -Force -ErrorAction SilentlyContinue }
                    if ((Test-Path $backupPath) -and -not (Test-Path $YtDlpPath)) {
                        Copy-Item $backupPath $YtDlpPath -Force
                        $restored = Get-Item $YtDlpPath -Force
                        $restored.Attributes = $restored.Attributes -bor [System.IO.FileAttributes]::Hidden
                    }
                    # Report it: a stale yt-dlp is the main cause of sudden bot checks,
                    # and silence here costs the user months of failed extractions.
                    return [pscustomobject]@{ Type = "Warning"; Message = "[!] yt-dlp update failed: $($_.Exception.Message)" }
                }
            }
        }
        catch {
            # Silent fail for updates
        }
    }

    Set-HiddenAttribute -Path $script:YtDlpPath
    foreach ($message in @($messages)) {
        if ($message -and $message.PSObject.Properties.Name -contains "Message") {
            Show-ProgressUpdate $message.Message -Type $message.Type
        }
    }
}

# ===================================================================
# --- URL SANITIZATION ---
# ===================================================================

# ===================================================================
# --- PLAYLIST DETECTION & DOWNLOAD ---
# ===================================================================

function Test-PlaylistUrl {
    param([string]$Url)
    # YouTube playlist patterns: list= param, /playlist path, or music playlist
    if ($Url -match '[?&]list=') { return $true }
    if ($Url -match 'youtube\.com/playlist') { return $true }
    if ($Url -match 'music\.youtube\.com/playlist') { return $true }
    return $false
}

function Test-VideoInPlaylistUrl {
    param([string]$Url)
    # Check if it has a playlist marker
    if (-not (Test-PlaylistUrl -Url $Url)) { return $false }
    
    # Check if it also has video indicators
    if ($Url -match '[?&]v=') { return $true }
    if ($Url -match 'youtu\.be/') { return $true }
    if ($Url -match '/shorts/') { return $true }
    if ($Url -match '/watch\b') { return $true }
    
    return $false
}

function Get-PlaylistChoice {
    param([string]$Url)
    Write-Host ""
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " Playlist-formatted link detected:" -ForegroundColor Yellow
    Write-Host " $Url" -ForegroundColor Cyan
    Write-Host " Do you want to download the entire playlist or just this single item?" -ForegroundColor Yellow
    Write-Host " Options: 1=Whole Playlist, 2=Just Single Video/Audio" -ForegroundColor Gray
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    
    $choice = ""
    while ($choice -notin @("1", "2")) {
        Write-Host -NoNewline "> " -ForegroundColor Yellow
        $choice = (Read-Host).Trim()
        if ($choice -notin @("1", "2")) {
            Write-Pulse -Text "[!] Invalid choice. Enter 1 or 2." -Colors @("Red", "Yellow") -Cycles 1
        }
    }
    return $choice
}

function Get-PlaylistMetadata {
    param([string]$Url, [hashtable]$Settings)
    try {
        Show-ProgressUpdate "[~] Probing playlist metadata..." -Type "System"
        # The probe is a separate request and gets bot-checked on its own, so it
        # has to carry the same identity, cookies and pacing as the downloads.
        $probeArgs = @(Get-StealthArgs -Settings $Settings)
        $probeArgs += @("--flat-playlist", "--dump-single-json", "--skip-download", $Url)
        $probe = Invoke-YtDlpCaptureOutput -YtDlpArgs $probeArgs
        if (-not $probe.Success -or [string]::IsNullOrWhiteSpace($probe.StdOut)) {
            Write-ReaperLog -Settings $Settings -Message "Playlist probe failed :: $(Get-ErrorDigest -ErrorText $probe.StdErr)"
            return $null
        }
        $data = $probe.StdOut | ConvertFrom-Json
        $title = if ($data.title) { $data.title } else { "Playlist" }
        $entries = @()
        if ($data.entries) { $entries = @($data.entries) }
        return [pscustomobject]@{
            Title      = $title
            EntryCount = $entries.Count
            Entries    = $entries
        }
    }
    catch {
        Show-ProgressUpdate "[!] Could not read playlist info: $($_.Exception.Message)" -Type "Warning"
        return $null
    }
}

function Get-SafeFolderName {
    param([string]$Name)
    # Remove characters illegal in Windows folder names, collapse whitespace
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Name.ToCharArray()) {
        if ($invalidChars -notcontains $c) {
            [void]$sb.Append($c)
        }
    }
    $safe = ($sb.ToString() -replace '\s+', ' ').Trim()
    if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80).Trim() }
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'Playlist' }
    return $safe
}

function Invoke-PlaylistDownload {
    param(
        [hashtable]$Settings,
        [string]$DownloadType,
        [string]$Url
    )

    $meta = Get-PlaylistMetadata -Url $Url -Settings $Settings
    if (-not $meta -or $meta.EntryCount -eq 0) {
        Show-ProgressUpdate "[!] Could not detect playlist items. Falling back to normal download." -Type "Warning"
        return $null  # signal caller to fall back
    }

    $safeName = Get-SafeFolderName -Name $meta.Title
    $baseDir = Get-OutputDirForType -Settings $Settings -DownloadType $DownloadType
    $playlistDir = Join-Path $baseDir $safeName
    Ensure-Directory -Path $playlistDir

    # --- Playlist banner ---
    Write-Host ""
    Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkGray
    Write-Host "  |  DIGITAL REAPER  >>  " -NoNewline -ForegroundColor Gray
    Write-Host "PLAYLIST MODE" -ForegroundColor Magenta
    Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkGray
    Write-Host "  | Playlist : " -NoNewline -ForegroundColor Gray
    Write-Host $meta.Title -ForegroundColor Cyan
    Write-Host "  | Items    : " -NoNewline -ForegroundColor Gray
    Write-Host $meta.EntryCount -ForegroundColor Cyan
    Write-Host "  | Type     : " -NoNewline -ForegroundColor Gray
    Write-Host $DownloadType.ToUpper() -ForegroundColor Yellow
    Write-Host "  | Output   : " -NoNewline -ForegroundColor Gray
    Write-Host $playlistDir -ForegroundColor Yellow
    if ($DownloadType -eq "video") {
        Write-Host "  | Quality  : " -NoNewline -ForegroundColor Gray
        Write-Host $Settings.videoQuality -ForegroundColor Magenta
    }
    Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkGray
    Write-Host ""

    # One native yt-dlp pass for the whole playlist. The old code launched a fresh
    # yt-dlp process per item, which roughly tripled the request count and threw
    # away yt-dlp's own resume and back-off handling.
    $padWidth = [Math]::Max(2, $meta.EntryCount.ToString().Length)
    $indexFormat = "%(playlist_index)0" + $padWidth + "d"
    $itemTemplate = "$indexFormat - %(title)s [%(id)s].%(ext)s"

    $startedAt = Get-Date
    $downloadResult = Invoke-YtDlpForUrl -Settings $Settings -DownloadType $DownloadType `
        -OutputDir $playlistDir -Url $Url -OutputTemplate $itemTemplate `
        -ExtraArgs @("--yes-playlist", "--ignore-errors")

    # Report the state of the folder rather than the exit code: that survives a
    # resume, and "does this playlist exist locally" is the real question.
    $mediaExtensions = @(".mp4", ".mkv", ".webm", ".mp3", ".m4a", ".flac", ".opus", ".ogg", ".wav")
    $present = @(Get-ChildItem -Path $playlistDir -File -ErrorAction SilentlyContinue |
        Where-Object { $mediaExtensions -contains $_.Extension.ToLower() })
    $newThisRun = @($present | Where-Object { $_.LastWriteTime -ge $startedAt })
    $missing = [Math]::Max(0, $meta.EntryCount - $present.Count)

    if (-not $downloadResult.Success) {
        $friendly = Get-FriendlyErrorHint -ErrorText $downloadResult.ErrorText -Kind $downloadResult.Kind
        Write-Host "  TARGET MISSED  >> $friendly" -ForegroundColor Red
        if ($downloadResult.Digest) { Write-Host "  $($downloadResult.Digest)" -ForegroundColor DarkGray }
    }

    Write-Host ""
    Write-Host "  Playlist on disk: " -NoNewline -ForegroundColor Gray
    Write-Host "$($present.Count)/$($meta.EntryCount)" -NoNewline -ForegroundColor Cyan
    if ($newThisRun.Count -gt 0) {
        Write-Host " (+$($newThisRun.Count) new this run)" -ForegroundColor Green
    }
    else {
        Write-Host " (nothing new - already downloaded)" -ForegroundColor DarkGray
    }
    if ($missing -gt 0) {
        Write-Host "  $missing item(s) still missing - run it again to retry only those." -ForegroundColor Yellow
    }

    return [pscustomobject]@{
        Success   = $present.Count
        Failure   = $missing
        OutputDir = $playlistDir
    }
}

# ===================================================================
# --- YT-DLP ARGUMENT BUILDER & BATCH HELPERS ---
# ===================================================================

function Get-YtDlpArgs {
    param(
        [hashtable]$Settings,
        [string]$DownloadType,   # "audio" or "video"
        [string]$OutputDir,
        [string]$OutputTemplate = "",
        [switch]$UseFallbackFormat
    )

    $ytDlpArgs = New-Object System.Collections.Generic.List[string]

    # --- Anti-bot / stealth layer ---
    # Identity, cookies and pacing live in Get-StealthArgs so that the playlist
    # probe and the download itself behave identically - they used to differ,
    # which meant the probe got bot-checked on its own.
    foreach ($stealthArg in (Get-StealthArgs -Settings $Settings)) {
        $ytDlpArgs.Add($stealthArg)
    }

    $ytDlpArgs.Add("--ffmpeg-location")
    $ytDlpArgs.Add($script:FfmpegLocation)
    $ytDlpArgs.Add("--socket-timeout")
    $ytDlpArgs.Add("30")
    $ytDlpArgs.Add("--extractor-retries")
    $ytDlpArgs.Add([string]$Settings.retryCount)

    # Capped instead of infinite: an unbounded fragment retry lets a scheduled
    # silent run hang for hours on a dead stream.
    $ytDlpArgs.Add("--fragment-retries")
    $ytDlpArgs.Add((Get-InvariantNumber -Value $Settings.maxFragmentRetries -Default 20))
    $ytDlpArgs.Add("--retry-sleep")
    $ytDlpArgs.Add("fragment:exp=1:30")
    $ytDlpArgs.Add("--console-title")
    $ytDlpArgs.Add("--continue")

    # Cautious mode (entered after repeated bot checks) downloads single-threaded.
    $fragments = 1
    if (-not (Test-BotGuardCautious)) {
        $configuredFragments = [int](Get-InvariantNumber -Value $Settings.concurrentFragments -Default 1)
        if ($configuredFragments -gt 1) { $fragments = $configuredFragments }
    }
    $ytDlpArgs.Add("--concurrent-fragments")
    $ytDlpArgs.Add([string]$fragments)

    if ($Settings.maxRate -and -not [string]::IsNullOrWhiteSpace($Settings.maxRate)) {
        $ytDlpArgs.Add("--limit-rate")
        $ytDlpArgs.Add($Settings.maxRate)
    }

    if ($Settings.downloadArchive -and -not [string]::IsNullOrWhiteSpace([string]$Settings.downloadArchive)) {
        $ytDlpArgs.Add("--download-archive")
        $ytDlpArgs.Add([string]$Settings.downloadArchive)
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
    }
    else {
        $codecPreference = if ($Settings.useHEVC) { "[vcodec^=hevc]/[vcodec^=h265]/" } else { "" }

        $height = switch ($Settings.videoQuality) {
            "720p" { 720 }
            "1080p" { 1080 }
            "1440p" { 1440 }
            "4K" { 2160 }
            default { 1080 }
        }

        $videoSelector = "bestvideo[height<=$height]"
        if ($codecPreference) {
            $videoSelector = "$codecPreference$videoSelector"
        }

        $format = if ($UseFallbackFormat) {
            "bestvideo+bestaudio/best"
        }
        else {
            "($videoSelector)+bestaudio/best[height<=$height]"
        }

        $ytDlpArgs.Add("-f")
        $ytDlpArgs.Add($format)
        $ytDlpArgs.Add("--merge-output-format")
        $ytDlpArgs.Add("mp4")
    }

    $template = if ($OutputTemplate) { $OutputTemplate } else { $Settings.outputTemplate }
    $outputPath = Join-Path -Path $OutputDir -ChildPath $template
    $ytDlpArgs.Add("-o")
    $ytDlpArgs.Add($outputPath)

    return $ytDlpArgs
}

function Get-InvariantNumber {
    param($Value, [double]$Default = 0)
    $result = $Default
    $rawValue = [string]$Value
    if (-not [string]::IsNullOrWhiteSpace($rawValue)) {
        $parsed = 0.0
        $styles = [System.Globalization.NumberStyles]::Float
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        if ([double]::TryParse($rawValue, $styles, $culture, [ref]$parsed)) { $result = $parsed }
    }
    return $result.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

# -------------------------------------------------------------------
# --- BOT GUARD: shared identity, pacing and client escalation ------
# -------------------------------------------------------------------

function Get-BotGuardChain {
    param([hashtable]$Settings)
    $pinned = @()
    if ($Settings -and $Settings.playerClients) {
        $pinned = @($Settings.playerClients | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }
    if ($pinned.Count -gt 0) { return $pinned }
    return @($script:DefaultPlayerClientChain)
}

function Reset-BotGuard {
    param([hashtable]$Settings)
    # Index -1 means "no client override yet": yt-dlp keeps its own default order
    # until a bot check proves that order is not working for this network.
    $startIndex = -1
    if ($Settings -and $Settings.playerClients -and @($Settings.playerClients).Count -gt 0) { $startIndex = 0 }

    $script:BotGuard = @{
        Chain                = @(Get-BotGuardChain -Settings $Settings)
        Index                = $startIndex
        ConsecutiveBotChecks = 0
        Cautious             = $false
        CooledDown           = $false
    }
}

function Test-BotGuardCautious {
    if (-not $script:BotGuard) { return $false }
    return [bool]$script:BotGuard.Cautious
}

function Get-ActivePlayerClient {
    param([hashtable]$Settings)
    if (-not $script:BotGuard) { Reset-BotGuard -Settings $Settings }
    if ($script:BotGuard.Index -ge 0 -and $script:BotGuard.Index -lt $script:BotGuard.Chain.Count) {
        return [string]$script:BotGuard.Chain[$script:BotGuard.Index]
    }
    return $null
}

# Called only after a bot check or an unsupported-client error. Escalates in two
# steps (new player client, then one session cooldown) and then gives up, because
# identical retries are what escalate a soft check into a hard block.
function Step-BotGuard {
    param([hashtable]$Settings)

    if (-not $script:BotGuard) { Reset-BotGuard -Settings $Settings }
    $script:BotGuard.ConsecutiveBotChecks++

    # Two hits anywhere in the session mean this network looks suspicious.
    if ($script:BotGuard.ConsecutiveBotChecks -ge 2) { $script:BotGuard.Cautious = $true }

    $nextIndex = $script:BotGuard.Index + 1
    if ($nextIndex -lt $script:BotGuard.Chain.Count) {
        $script:BotGuard.Index = $nextIndex
        return [pscustomobject]@{
            CanRetry = $true
            Delay    = 2
            Message  = "Bot check hit - switching player client to '$($script:BotGuard.Chain[$nextIndex])'"
        }
    }

    if (-not $script:BotGuard.CooledDown) {
        $script:BotGuard.CooledDown = $true
        $coolDown = [int](Get-InvariantNumber -Value $Settings.botCooldownSeconds -Default 60)
        if ($coolDown -lt 15) { $coolDown = 15 }
        return [pscustomobject]@{
            CanRetry = $true
            Delay    = $coolDown
            Message  = "Every fallback client hit the bot check - cooling down for ${coolDown}s"
        }
    }

    return [pscustomobject]@{
        CanRetry = $false
        Delay    = 0
        Message  = "Bot check persists on every player client - cookies are required for this run."
    }
}

# Newer yt-dlp needs a JavaScript runtime to solve YouTube's player challenges.
# Without one it warns and quietly drops formats, which looks exactly like a bot
# check from the outside.
function Test-YtDlpSupportsJsRuntime {
    if ($null -ne $script:JsRuntimeSupport) { return [bool]$script:JsRuntimeSupport }

    try {
        $helpText = (& $script:YtDlpPath --help 2>&1 | Out-String)
        $script:JsRuntimeSupport = ($helpText -match '--js-runtimes')
    }
    catch {
        $script:JsRuntimeSupport = $false
    }
    return [bool]$script:JsRuntimeSupport
}

function Get-JsRuntimeArgs {
    param([hashtable]$Settings)

    if ($null -ne $script:JsRuntimeArgs) { return $script:JsRuntimeArgs }
    $script:JsRuntimeArgs = @()

    # An explicit setting wins, and is passed through untouched.
    if ($Settings -and $Settings.jsRuntime -and -not [string]::IsNullOrWhiteSpace([string]$Settings.jsRuntime)) {
        $script:JsRuntimeArgs = @("--js-runtimes", [string]$Settings.jsRuntime)
        return $script:JsRuntimeArgs
    }

    # Older engines reject the flag outright, so check before using it.
    if (-not (Test-YtDlpSupportsJsRuntime)) { return $script:JsRuntimeArgs }

    foreach ($candidate in @("deno", "node")) {
        $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            # runtime:path is used so a scheduled task with a different PATH still works.
            $script:JsRuntimeArgs = @("--js-runtimes", "$candidate`:$($command.Source)")
            break
        }
    }

    return $script:JsRuntimeArgs
}

# Shared by the download and the playlist probe so both look like one session.
function Get-StealthArgs {
    param([hashtable]$Settings)

    $stealthArgs = New-Object System.Collections.Generic.List[string]

    # yt-dlp already sends the User-Agent that matches the player client it talks
    # to. Overriding it (the old random-UA pool) is itself a bot-check trigger, so
    # it now only happens when the user pins one explicitly.
    if ($Settings.userAgent -and -not [string]::IsNullOrWhiteSpace([string]$Settings.userAgent)) {
        $stealthArgs.Add("--user-agent")
        $stealthArgs.Add([string]$Settings.userAgent)
    }

    $stealthArgs.Add("--add-header")
    $stealthArgs.Add("Accept-Language:en-US,en;q=0.9")

    $client = Get-ActivePlayerClient -Settings $Settings
    if ($client) {
        $stealthArgs.Add("--extractor-args")
        $stealthArgs.Add("youtube:player_client=$client")
    }

    # An exported cookies.txt survives browser encryption changes, so it wins
    # over live extraction when the user has provided one.
    $cookieFile = [string]$Settings.cookieFile
    if (-not [string]::IsNullOrWhiteSpace($cookieFile) -and (Test-Path $cookieFile)) {
        $stealthArgs.Add("--cookies")
        $stealthArgs.Add($cookieFile)
    }
    elseif ($Settings.cookieSource -and $Settings.cookieSource -ne "none") {
        $stealthArgs.Add("--cookies-from-browser")
        $stealthArgs.Add([string]$Settings.cookieSource)
    }

    foreach ($runtimeArg in (Get-JsRuntimeArgs -Settings $Settings)) {
        $stealthArgs.Add([string]$runtimeArg)
    }

    $stealthArgs.Add("--sleep-requests")
    $stealthArgs.Add((Get-InvariantNumber -Value $Settings.requestSleep -Default 1))

    $minSleep = Get-InvariantNumber -Value $Settings.minSleepInterval -Default 1
    $maxSleep = Get-InvariantNumber -Value $Settings.maxSleepInterval -Default 3
    if (Test-BotGuardCautious) {
        $minSleep = "10"
        $maxSleep = "20"
    }
    $stealthArgs.Add("--sleep-interval")
    $stealthArgs.Add($minSleep)
    $stealthArgs.Add("--max-sleep-interval")
    $stealthArgs.Add($maxSleep)

    return $stealthArgs
}

# -------------------------------------------------------------------
# --- FAILURE CLASSIFICATION ----------------------------------------
# -------------------------------------------------------------------

function Get-FailureKind {
    param([string]$ErrorText)
    if ([string]::IsNullOrWhiteSpace($ErrorText)) { return "Other" }

    # One run can emit several errors (a client that 403s, then a format error).
    # The last ERROR line is the one that actually stopped it, so it is matched
    # first and the full text is only a fallback.
    $primary = Get-ErrorDigest -ErrorText $ErrorText
    foreach ($candidate in @($primary, $ErrorText)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        foreach ($entry in $script:FailurePatterns) {
            if ($candidate -match $entry.Pattern) { return [string]$entry.Kind }
        }
    }
    return "Other"
}

# Pulls the one useful line out of yt-dlp's stderr, minus PowerShell's
# NativeCommandError decoration and the ANSI/indentation noise.
function Get-ErrorDigest {
    param([string]$ErrorText)
    if ([string]::IsNullOrWhiteSpace($ErrorText)) { return "" }

    $lines = @()
    foreach ($line in ($ErrorText -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '^(At line:|CategoryInfo|FullyQualifiedErrorId|\+ CategoryInfo|\+ )') { continue }
        if ($trimmed -match '^[\+~-]{3,}') { continue }
        $lines += $trimmed
    }

    $picked = ""
    $errorLines = @($lines | Where-Object { $_ -match '(ERROR|WARNING)' })
    if ($errorLines.Count -gt 0) { $picked = $errorLines[-1] }
    elseif ($lines.Count -gt 0) { $picked = $lines[-1] }

    $picked = $picked -replace '^\S*yt-dlp[^:]*:\s*', ''
    $picked = $picked -replace '^ERROR:\s*', ''
    if ($picked.Length -gt 200) { $picked = $picked.Substring(0, 200).TrimEnd() + "..." }
    return $picked
}

function Get-FriendlyErrorHint {
    param([string]$ErrorText, [string]$Kind = "")
    if ([string]::IsNullOrWhiteSpace($Kind)) { $Kind = Get-FailureKind -ErrorText $ErrorText }
    if ($script:FriendlyHints.ContainsKey($Kind)) { return $script:FriendlyHints[$Kind] }
    return $script:FriendlyHints["Other"]
}

function Get-BackoffDelay {
    param([int]$Attempt, [double]$BaseDelay, [double]$MaxDelay)
    $delay = $BaseDelay * [Math]::Pow(2, [Math]::Max(0, $Attempt - 1))
    if ($delay -gt $MaxDelay) { $delay = $MaxDelay }
    $delay += (Get-Random -Minimum 0 -Maximum 3)
    return [int][Math]::Round($delay)
}

function Write-ReaperLog {
    param([string]$Message, [hashtable]$Settings)
    if (-not $Settings -or -not $Settings.diagnosticsLog) { return }
    try {
        if (-not (Test-Path $script:EngineDir)) { return }
        if (Test-Path $script:LogFilePath) {
            $logItem = Get-Item $script:LogFilePath -ErrorAction SilentlyContinue
            if ($logItem -and $logItem.Length -gt 1MB) {
                Move-Item -Path $script:LogFilePath -Destination "$($script:LogFilePath).old" -Force -ErrorAction SilentlyContinue
            }
        }
        $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        Add-Content -Path $script:LogFilePath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Diagnostics must never break a download.
    }
}

# -------------------------------------------------------------------
# --- DOWNLOAD EXECUTION --------------------------------------------
# -------------------------------------------------------------------

# Args are rebuilt on every attempt so that a policy change made by the bot
# guard (new player client, single-threaded) actually reaches the next call.
function Invoke-YtDlpForUrl {
    param(
        [hashtable]$Settings,
        [string]$DownloadType,
        [string]$OutputDir,
        [string]$Url,
        [string]$OutputTemplate = "",
        [switch]$NoPlaylist,
        [switch]$UseFallbackFormat,
        [string[]]$ExtraArgs = @()
    )

    $maxAttempts = [int](Get-InvariantNumber -Value $Settings.outerRetryCount -Default $script:DefaultOuterRetryCount)
    if ($maxAttempts -lt 1) { $maxAttempts = 1 }
    if ($maxAttempts -gt 10) { $maxAttempts = 10 }

    $attempt = 0
    $lastErrorText = ""
    $lastKind = "Other"

    while ($attempt -lt $maxAttempts) {
        $attempt++

        # Rebuilt per attempt, and copied into a local list: a List returned from a
        # function is flattened to a fixed-size array, which cannot take .Add().
        $ytArgs = New-Object System.Collections.Generic.List[string]
        foreach ($argItem in (Get-YtDlpArgs -Settings $Settings -DownloadType $DownloadType -OutputDir $OutputDir -OutputTemplate $OutputTemplate -UseFallbackFormat:$UseFallbackFormat)) {
            $ytArgs.Add([string]$argItem)
        }
        if ($NoPlaylist) { $ytArgs.Add("--no-playlist") }
        foreach ($extraArg in $ExtraArgs) { $ytArgs.Add([string]$extraArg) }
        $ytArgs.Add($Url)

        $attemptResult = Invoke-YtDlpAndCapture -YtDlpArgs $ytArgs.ToArray()
        if ($attemptResult.Success) {
            if ($script:BotGuard) { $script:BotGuard.ConsecutiveBotChecks = 0 }
            return [pscustomobject]@{ Success = $true; ErrorText = ""; Kind = ""; Digest = ""; Attempts = $attempt }
        }

        $lastErrorText = [string]$attemptResult.ErrorText
        $lastKind = Get-FailureKind -ErrorText $lastErrorText

        $policy = $null
        if ($script:RetryPolicy.ContainsKey($lastKind)) { $policy = $script:RetryPolicy[$lastKind] }
        if (-not $policy -or -not $policy.Retry -or $attempt -ge $maxAttempts) { break }

        if ($policy.Escalate) {
            $step = Step-BotGuard -Settings $Settings
            if (-not $step.CanRetry) {
                Show-ProgressUpdate "[!] $($step.Message)" -Type "Error"
                break
            }
            Show-ProgressUpdate "[~] $($step.Message) (attempt $attempt/$maxAttempts)..." -Type "Warning"
            Start-Sleep -Seconds ([int]$step.Delay)
            continue
        }

        $delay = Get-BackoffDelay -Attempt $attempt -BaseDelay $policy.BaseDelay -MaxDelay $policy.MaxDelay
        Show-ProgressUpdate "[~] $lastKind detected. Retrying in ${delay}s ($attempt/$maxAttempts)..." -Type "Warning"
        Start-Sleep -Seconds $delay
    }

    # A different format selector cannot fix a wall or a login gate, so only try
    # the fallback when the failure could actually be format-related.
    if ($DownloadType -eq "video" -and -not $UseFallbackFormat -and $lastKind -notin @("BotCheck", "LoginRequired", "GeoBlocked", "Unavailable")) {
        Show-ProgressUpdate "[~] Trying fallback format for this video..." -Type "Update"
        $fallbackArgs = New-Object System.Collections.Generic.List[string]
        foreach ($argItem in (Get-YtDlpArgs -Settings $Settings -DownloadType $DownloadType -OutputDir $OutputDir -OutputTemplate $OutputTemplate -UseFallbackFormat)) {
            $fallbackArgs.Add([string]$argItem)
        }
        if ($NoPlaylist) { $fallbackArgs.Add("--no-playlist") }
        foreach ($extraArg in $ExtraArgs) { $fallbackArgs.Add([string]$extraArg) }
        $fallbackArgs.Add($Url)

        $fallbackResult = Invoke-YtDlpAndCapture -YtDlpArgs $fallbackArgs.ToArray()
        if ($fallbackResult.Success) {
            if ($script:BotGuard) { $script:BotGuard.ConsecutiveBotChecks = 0 }
            return [pscustomobject]@{ Success = $true; ErrorText = ""; Kind = ""; Digest = ""; Attempts = $attempt }
        }
        $lastErrorText = [string]$fallbackResult.ErrorText
        $lastKind = Get-FailureKind -ErrorText $lastErrorText
    }

    $finalDigest = Get-ErrorDigest -ErrorText $lastErrorText
    Write-ReaperLog -Settings $Settings -Message "[$lastKind] $Url :: $finalDigest"

    return [pscustomobject]@{
        Success   = $false
        ErrorText = $lastErrorText
        Kind      = $lastKind
        Digest    = $finalDigest
        Attempts  = $attempt
    }
}

# Windows argv quoting, so a path with spaces (the default Windows profile has
# one) survives being handed straight to the process. Applied per argument.
function ConvertTo-CommandLineArgument {
    param([string]$Value)
    if ($null -eq $Value) { $Value = "" }
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

# stdout stays attached to the console so yt-dlp's live progress, speed and ETA
# keep working, while stderr is captured. That capture is what makes failure
# classification possible at all - the previous version never saw an error text.
# The process is started through .NET instead of "& ... 2> file" because under
# Windows PowerShell 5.1 (what digitalReaper.bat uses) a native stderr redirect
# also dumps a NativeCommandError block into the console.
function Invoke-YtDlpAndCapture {
    param([string[]]$YtDlpArgs)

    if (-not (Test-Path $script:YtDlpPath)) {
        return [pscustomobject]@{
            Success   = $false
            ExitCode  = -1
            ErrorText = "ERROR: yt-dlp is missing. Run setup.bat to install the engine."
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:YtDlpPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardOutput = $false
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $startInfo.Arguments = (@($YtDlpArgs | ForEach-Object { ConvertTo-CommandLineArgument -Value ([string]$_) }) -join ' ')

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        # Read before waiting: a full stderr pipe would otherwise deadlock the child.
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode

        return [pscustomobject]@{
            Success   = ($exitCode -eq 0)
            ExitCode  = $exitCode
            ErrorText = [string]$errorText
        }
    }
    catch {
        return [pscustomobject]@{
            Success   = $false
            ExitCode  = -1
            ErrorText = "ERROR: could not start yt-dlp: $($_.Exception.Message)"
        }
    }
    finally {
        if ($process) { $process.Dispose() }
    }
}

function Enter-ReaperLock {
    if (Test-Path $script:LockFilePath) {
        if (Test-StaleReaperLock) {
            Show-ProgressUpdate "[~] Clearing a stale lock left by a previous run." -Type "Warning"
            Remove-Item $script:LockFilePath -Force -ErrorAction SilentlyContinue
        }
        else {
            return $false
        }
    }

    try {
        Set-Content -Path $script:LockFilePath -Value $PID
        Set-HiddenAttribute -Path $script:LockFilePath
        return $true
    }
    catch {
        # Never block a download because the lock file could not be written.
        return $true
    }
}

function Exit-ReaperLock {
    if (-not (Test-Path $script:LockFilePath)) { return }
    try {
        $raw = ([string](Get-Content -Path $script:LockFilePath -Raw -ErrorAction Stop)).Trim()
        if ($raw -ne [string]$PID) { return }
    }
    catch { return }
    Remove-Item -Path $script:LockFilePath -Force -ErrorAction SilentlyContinue
}

# Metadata probes need stdout, which Invoke-YtDlpAndCapture deliberately leaves
# on the console. Merging the two streams with 2>&1 used to feed a lone warning
# straight into ConvertFrom-Json and fail the whole probe.
function Invoke-YtDlpCaptureOutput {
    param([string[]]$YtDlpArgs)

    if (-not (Test-Path $script:YtDlpPath)) {
        return [pscustomobject]@{ Success = $false; ExitCode = -1; StdOut = ""; StdErr = "ERROR: yt-dlp is missing." }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:YtDlpPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $startInfo.Arguments = (@($YtDlpArgs | ForEach-Object { ConvertTo-CommandLineArgument -Value ([string]$_) }) -join ' ')

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        # One stream is read asynchronously so a full pipe cannot deadlock the child.
        $errorTask = $process.StandardError.ReadToEndAsync()
        $stdOut = $process.StandardOutput.ReadToEnd()
        $stdErr = $errorTask.Result
        $process.WaitForExit()

        return [pscustomobject]@{
            Success  = ($process.ExitCode -eq 0)
            ExitCode = $process.ExitCode
            StdOut   = [string]$stdOut
            StdErr   = [string]$stdErr
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; ExitCode = -1; StdOut = ""; StdErr = "ERROR: could not start yt-dlp: $($_.Exception.Message)" }
    }
    finally {
        if ($process) { $process.Dispose() }
    }
}

# A crashed run used to leave engine/reaper.lock behind and block every later
# scheduled run, so the lock is now validated against a live PID.
function Test-StaleReaperLock {
    if (-not (Test-Path $script:LockFilePath)) { return $true }

    $raw = ""
    try { $raw = ([string](Get-Content -Path $script:LockFilePath -Raw -ErrorAction Stop)).Trim() }
    catch { return $true }

    $lockPid = 0
    if (-not [int]::TryParse($raw, [ref]$lockPid)) { return $true }
    if ($lockPid -eq $PID) { return $true }
    if ($lockPid -le 0) { return $true }

    $owner = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
    return ($null -eq $owner)
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
                }
                else {
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
        }
        catch {
            Show-ProgressUpdate "[!] Failed to read links from manifest: $ConfigFile. Falling back to standard input methods." -Type "Warning"
        }
    }

    if ($LinksFile -and (Test-Path $LinksFile)) {
        Show-ProgressUpdate "[+] Processing file from batch: $LinksFile" -Type "System"
        $script:SourceFile = $LinksFile
        return Get-UrlsFromFile -FilePath $LinksFile
    }
    
    
    if ($Silent) { return @() }

    Write-Host ""
    Write-Host "--- Select Input Method ---" -ForegroundColor Cyan
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
    }
    else {
        $filePath = ""
        while ([string]::IsNullOrWhiteSpace($filePath) -or -not (Test-Path $filePath)) {
            Write-Host ">> Enter path to URLs file (.txt): " -ForegroundColor "Magenta"
            $filePath = Read-Host
            if ([string]::IsNullOrWhiteSpace($filePath)) { 
                Write-Pulse -Text "`n[!] File path cannot be empty." -Colors @("Red", "Yellow") -Cycles 1
            }
            elseif (-not (Test-Path $filePath)) {
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
                Index       = $i
                OriginalUrl = $originalUrl
                WasSuccess  = $false
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
            }
            else {
                $friendly = Get-FriendlyErrorHint -ErrorText $downloadResult.ErrorText -Kind $downloadResult.Kind
                throw "$friendly"
            }

        }
        catch {
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
        }
        else {
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
    $successColor = if ($SuccessCount -gt 0) { "Green" } else { "DarkGray" }
    $failureColor = if ($FailureCount -gt 0) { "Red" } else { "DarkGray" }
    Write-Host "[+] Successful downloads: " -NoNewline -ForegroundColor "White"
    Write-Host "$SuccessCount" -ForegroundColor $successColor
    Write-Host "[!] Failed downloads:     " -NoNewline -ForegroundColor "White"
    Write-Host "$FailureCount" -ForegroundColor $failureColor
    Write-Host "    Downloads saved to:   " -NoNewline -ForegroundColor "White"
    Write-Host "$OutputDir" -ForegroundColor "Yellow"

    if ($SuccessCount -gt 0) {
        Show-CompletionBanner
    }
    else {
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

    # The session lock is taken once in the main block, so batch, interactive and
    # scheduled runs can no longer overlap.
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
}

function Run-InteractiveMode {
    param(
        [hashtable]$Settings,
        [switch]$ForceOneClick
    )

    $urls = @()
    $usedOneClick = $false
    $forceNoPlaylistUrls = @{}
    $hasExplicitInputOrConfig = -not [string]::IsNullOrWhiteSpace($LinksFile) -or -not [string]::IsNullOrWhiteSpace($ConfigFile)

    # Unattended runs (scheduler.bat calls this with -Silent) would otherwise block
    # on Read-Host forever and keep holding the session lock.
    if ($Silent -and -not $hasExplicitInputOrConfig) {
        Show-ProgressUpdate "[~] Silent run with no queued links - nothing to download." -Type "System"
        return
    }
    $oneClickEnabled = $Settings.oneClickMode -or $ForceOneClick
    $shouldUseOneClickMode = $oneClickEnabled -and -not $hasExplicitInputOrConfig
    if ($shouldUseOneClickMode) {
        $usedOneClick = $true
        while ($urls.Count -eq 0) {
            Write-Host "Paste a YouTube/media link and press Enter." -ForegroundColor Yellow
            Write-Host "Type ""file"" to choose a .txt link file, or ""settings"" for quick options." -ForegroundColor DarkGray
            $quickInput = (Read-Host).Trim()
            if ([string]::IsNullOrWhiteSpace($quickInput)) {
                Show-ProgressUpdate "[!] Please paste a link or command." -Type "Warning"
                continue
            }
            switch ($quickInput) {
                "settings" {
                    Show-SimpleSettingsPage -Settings $Settings
                    continue
                }
                "file" {
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
    }
    else {
        $urls = Get-UrlsSmartMode
    }
    
    if ($urls.Count -eq 0) {
        Write-Pulse -Text "[!] No valid URLs found." -Colors @("Red", "DarkRed") -Cycles 2
        if (-not $Silent) { Read-Host "Press Enter to exit..." }
        exit 1
    }
    
    Show-ProgressUpdate "Loaded $($urls.Count) target(s) for processing" -Type "Success"

    # --- Ask user: audio or video ---
    $downloadType = if ($usedOneClick -or $Silent) {
        if ($Settings.defaultDownloadType -eq "audio") { "2" } else { "1" }
    }
    else {
        ""
    }
    if (-not $usedOneClick -and -not $Silent) {
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
        $outputDir = Get-OutputDirForType -Settings $Settings -DownloadType "audio"
    }
    else {
        $resolvedType = "video"
        $outputDir = Get-OutputDirForType -Settings $Settings -DownloadType "video"
    }

    Ensure-Directory -Path $outputDir

    # --- Smart playlist detection ---
    # If there's exactly 1 URL and it looks like a playlist, route to playlist mode
    if ($urls.Count -eq 1 -and (Test-PlaylistUrl -Url $urls[0])) {
        $downloadAsPlaylist = $true
        if (-not $Silent -and (Test-VideoInPlaylistUrl -Url $urls[0])) {
            $choice = Get-PlaylistChoice -Url $urls[0]
            if ($choice -eq "2") {
                $downloadAsPlaylist = $false
                $forceNoPlaylistUrls[$urls[0]] = $true
            }
        }

        if ($downloadAsPlaylist) {
            Show-ProgressUpdate "[+] Playlist URL detected - entering PLAYLIST MODE" -Type "Update"
            $plResult = Invoke-PlaylistDownload -Settings $Settings -DownloadType $resolvedType -Url $urls[0]
            if ($plResult) {
                # Remove the playlist URL only when every item landed, otherwise the
                # next run can never fill the gaps.
                if ($plResult.Failure -eq 0 -and $plResult.Success -gt 0) {
                    Remove-SuccessfulLinks -FilePath $script:SourceFile -SuccessUrls @($urls[0])
                }
                Show-MissionSummary -SuccessCount $plResult.Success -FailureCount $plResult.Failure -OutputDir $plResult.OutputDir -Silent:$Silent
                return
            }
            # If playlist probe failed, fall through to normal single-URL download
            Show-ProgressUpdate "[~] Falling back to standard download..." -Type "Warning"
        }
    }

    $quality = if ($resolvedType -eq "video") { $Settings.videoQuality } else { "" }
    Show-DownloadBanner -TypeLabel $resolvedType.ToUpper() -Mode "EXFILTRATION" -TargetCount $urls.Count -OutputDir $outputDir -Quality $quality

    $successCount = 0
    $failureCount = 0
    $successUrls = @()
    $targetNum = 0

    foreach ($url in $urls) {
        $targetNum++

        # Check each URL for playlist — handle inline
        $downloadAsPlaylist = $true
        if ($urls.Count -gt 1 -and (Test-PlaylistUrl -Url $url)) {
            if (-not $Silent -and (Test-VideoInPlaylistUrl -Url $url)) {
                $choice = Get-PlaylistChoice -Url $url
                if ($choice -eq "2") {
                    $downloadAsPlaylist = $false
                    $forceNoPlaylistUrls[$url] = $true
                }
            }

            if ($downloadAsPlaylist) {
                Show-ProgressUpdate "[+] Playlist detected in batch: $url" -Type "Update"
                $plResult = Invoke-PlaylistDownload -Settings $Settings -DownloadType $resolvedType -Url $url
                if ($plResult) {
                    $successCount += $plResult.Success
                    $failureCount += $plResult.Failure
                    if ($plResult.Failure -eq 0 -and $plResult.Success -gt 0) { $successUrls += $url }
                    continue
                }
            }
        }

        try {
            Write-Host "  [ $targetNum/$($urls.Count) ] " -NoNewline -ForegroundColor DarkGray
            Write-Host "ACQUIRING TARGET" -NoNewline -ForegroundColor Cyan
            Write-Host " >> " -NoNewline -ForegroundColor DarkGray
            Write-Host $url -ForegroundColor White

            $downloadResult = if ($forceNoPlaylistUrls.ContainsKey($url)) {
                Invoke-YtDlpForUrl -Settings $Settings -DownloadType $resolvedType -OutputDir $outputDir -Url $url -NoPlaylist
            }
            else {
                Invoke-YtDlpForUrl -Settings $Settings -DownloadType $resolvedType -OutputDir $outputDir -Url $url
            }
            if ($downloadResult.Success) {
                $successCount++
                $successUrls += $url
                Write-Host "  [ $targetNum/$($urls.Count) ] " -NoNewline -ForegroundColor DarkGray
                Write-Host "TARGET ACQUIRED" -ForegroundColor Green
            }
            else {
                $friendly = Get-FriendlyErrorHint -ErrorText $downloadResult.ErrorText -Kind $downloadResult.Kind
                throw "$friendly"
            }
            
        }
        catch {
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
        if ($choice -in @("1", "2", "3")) { return $choice }
        Show-ProgressUpdate "[!] Invalid choice. Enter 1, 2, or 3." -Type "Warning"
    }
}

# ===================================================================
# --- DOCTOR / SELF-CHECK ---
# ===================================================================

function Write-DoctorLine {
    param([string]$Status, [string]$Label, [string]$Detail = "")

    $color = switch ($Status) {
        "OK" { "Green" }
        "WARN" { "Yellow" }
        "FAIL" { "Red" }
        default { "DarkGray" }
    }

    Write-Host ("  [" + $Status.PadRight(5) + "] ") -NoNewline -ForegroundColor $color
    Write-Host ($Label.PadRight(22)) -NoNewline -ForegroundColor White
    if ($Detail) { Write-Host $Detail -ForegroundColor DarkGray } else { Write-Host "" }
}

# Diagnostic pass: never installs, never downloads media, never takes the lock.
# Returns 0 when nothing is broken, 1 when at least one hard check failed.
function Invoke-Doctor {
    param([hashtable]$Settings)

    $failures = 0
    $warnings = 0

    Write-Host ""
    Write-Host "=============== DIGITAL REAPER - DOCTOR ===============" -ForegroundColor Cyan
    Write-Host ""

    # --- engine binaries ---
    $binaries = @(
        @{ Name = "yt-dlp"; Path = $script:YtDlpPath },
        @{ Name = "ffmpeg"; Path = $script:FfmpegPath },
        @{ Name = "ffprobe"; Path = $script:FfprobePath }
    )
    $engineReady = $true
    foreach ($binary in $binaries) {
        if (-not (Test-Path $binary.Path)) {
            Write-DoctorLine "FAIL" $binary.Name "missing - run setup.bat"
            $failures++
            $engineReady = $false
            continue
        }
        $item = Get-Item $binary.Path -Force -ErrorAction SilentlyContinue
        if (-not $item -or $item.Length -eq 0) {
            Write-DoctorLine "FAIL" $binary.Name "file is empty - re-run setup.bat"
            $failures++
            $engineReady = $false
            continue
        }
        Write-DoctorLine "OK" $binary.Name ("{0:N1} MB" -f ($item.Length / 1MB))
    }

    if (-not $engineReady) {
        Write-Host ""
        Write-Host "  Engine is incomplete - skipping the checks that need it." -ForegroundColor Yellow
        Write-Host "  Run setup.bat (or setup.sh), then try again." -ForegroundColor Yellow
        Write-Host ""
        return 1
    }

    # --- yt-dlp version and freshness ---
    $version = (& $script:YtDlpPath --version 2>&1 | Out-String).Trim()
    Write-DoctorLine "OK" "yt-dlp version" $version

    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest" `
            -Headers @{ 'User-Agent' = 'DigitalReaper' } -TimeoutSec 15 -ErrorAction Stop
        if ($release.tag_name -and $release.tag_name -ne $version) {
            Write-DoctorLine "WARN" "yt-dlp freshness" "latest is $($release.tag_name) - updates on next run when autoUpdate is on"
            $warnings++
        }
        else {
            Write-DoctorLine "OK" "yt-dlp freshness" "up to date"
        }
    }
    catch {
        Write-DoctorLine "WARN" "yt-dlp freshness" "could not reach GitHub - $($_.Exception.Message)"
        $warnings++
    }

    if (Test-Path $script:VersionFilePath) {
        $recorded = ([string](Get-Content $script:VersionFilePath -Raw -ErrorAction SilentlyContinue)).Trim()
        if ($recorded -and $recorded -ne $version) {
            Write-DoctorLine "WARN" "version.txt" "records $recorded but the binary is $version"
            $warnings++
        }
    }

    # --- JS runtime (newer yt-dlp needs one for YouTube challenges) ---
    $runtimeArgs = @(Get-JsRuntimeArgs -Settings $Settings)
    if ($runtimeArgs.Count -ge 2) {
        Write-DoctorLine "OK" "js runtime" ([string]$runtimeArgs[1])
    }
    elseif (Test-YtDlpSupportsJsRuntime) {
        Write-DoctorLine "WARN" "js runtime" "none found - install deno (or node), otherwise formats go missing"
        $warnings++
    }
    else {
        Write-DoctorLine "INFO" "js runtime" "not required by this yt-dlp build"
    }

    # --- cookies ---
    $cookieFile = [string]$Settings.cookieFile
    if (-not [string]::IsNullOrWhiteSpace($cookieFile)) {
        if (Test-Path $cookieFile) {
            Write-DoctorLine "OK" "cookies" "file: $cookieFile"
        }
        else {
            Write-DoctorLine "FAIL" "cookies" "cookieFile does not exist: $cookieFile"
            $failures++
        }
    }
    elseif ($Settings.cookieSource -and $Settings.cookieSource -ne "none") {
        Write-DoctorLine "OK" "cookies" "read from $($Settings.cookieSource)"
    }
    else {
        Write-DoctorLine "INFO" "cookies" "none configured - only needed once a bot check shows up"
    }

    # --- player client order ---
    $chain = @(Get-BotGuardChain -Settings $Settings)
    $pinned = @($Settings.playerClients | Where-Object { $_ }).Count -gt 0
    $chainLabel = ($chain -join " -> ")
    if ($pinned) { $chainLabel += " (pinned)" } else { $chainLabel += " (fallback order)" }
    Write-DoctorLine "INFO" "player clients" $chainLabel

    # --- output folder ---
    $targetDir = Get-OutputDirForType -Settings $Settings -DownloadType "video"
    try {
        Ensure-Directory -Path $targetDir
        $probeFile = Join-Path $targetDir ".doctor-write-test"
        Set-Content -Path $probeFile -Value "ok" -ErrorAction Stop
        Remove-Item -Path $probeFile -Force -ErrorAction SilentlyContinue
        Write-DoctorLine "OK" "output folder" $targetDir
    }
    catch {
        Write-DoctorLine "FAIL" "output folder" "$targetDir is not writable"
        $failures++
    }

    # --- session lock ---
    if (Test-Path $script:LockFilePath) {
        if (Test-StaleReaperLock) {
            Remove-Item -Path $script:LockFilePath -Force -ErrorAction SilentlyContinue
            Write-DoctorLine "WARN" "session lock" "stale lock from a dead run removed"
            $warnings++
        }
        else {
            $holder = ([string](Get-Content $script:LockFilePath -Raw -ErrorAction SilentlyContinue)).Trim()
            Write-DoctorLine "FAIL" "session lock" "another instance is running (pid $holder)"
            $failures++
        }
    }
    else {
        Write-DoctorLine "OK" "session lock" "free"
    }

    # --- live extraction, metadata only ---
    $probeUrl = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
    $probeArgs = @("--skip-download", "--socket-timeout", "20", "--print", "%(id)s") + $runtimeArgs + @($probeUrl)
    $probe = Invoke-YtDlpCaptureOutput -YtDlpArgs $probeArgs
    if ($probe.Success -and -not [string]::IsNullOrWhiteSpace($probe.StdOut)) {
        Write-DoctorLine "OK" "live extraction" "returned $($probe.StdOut.Trim())"
        if ($probe.StdErr -match 'PO Token') {
            Write-DoctorLine "INFO" "po token" "not configured - some formats are skipped on web clients"
        }
    }
    else {
        $kind = Get-FailureKind -ErrorText $probe.StdErr
        $digest = Get-ErrorDigest -ErrorText $probe.StdErr
        Write-DoctorLine "FAIL" "live extraction" "$kind - $digest"
        Write-DoctorLine "INFO" "hint" (Get-FriendlyErrorHint -ErrorText $probe.StdErr -Kind $kind)
        $failures++
    }

    # --- last logged issue ---
    if (Test-Path $script:LogFilePath) {
        $logLines = @(Get-Content $script:LogFilePath -ErrorAction SilentlyContinue)
        if ($logLines.Count -gt 0) {
            Write-DoctorLine "INFO" "last logged issue" ([string]$logLines[-1])
        }
    }

    # --- summary ---
    Write-Host ""
    Write-Host "  -----------------------------------------------------" -ForegroundColor DarkGray
    if ($failures -gt 0) {
        Write-Host "  Result: FAILED - fix the [FAIL] lines above." -ForegroundColor Red
    }
    elseif ($warnings -gt 0) {
        Write-Host "  Result: usable, with warnings." -ForegroundColor Yellow
    }
    else {
        Write-Host "  Result: all checks passed." -ForegroundColor Green
    }
    Write-Host ("  Failures: $failures    Warnings: $warnings") -ForegroundColor Gray
    Write-Host ""

    if ($failures -gt 0) { return 1 }
    return 0
}

# ===================================================================
# --- MAIN EXECUTION ---
# ===================================================================

try {
    Clear-Host

    # /doctor is a diagnostic pass, not a run: no install, no lock, no download.
    if ($Doctor) {
        $doctorSettings = Load-Settings -ConfigPath $ConfigFile
        Reset-BotGuard -Settings $doctorSettings
        $doctorExit = [int](Invoke-Doctor -Settings $doctorSettings)
        exit $doctorExit
    }

    Show-StartupSequence

    if (-not (Initialize-DigitalReaper)) {
        Write-Pulse -Text "[!] DIGITAL REAPER initialization failed" -Colors @("Red", "DarkRed") -Cycles 3
        if (-not $Silent) { Read-Host "Press Enter to exit..." }
        exit 1
    }

    if ($SetupOnly) {
        Show-ProgressUpdate "[+] Setup complete. You can now run Digital Reaper." -Type "Success"
        exit 0
    }

    $settings = Load-Settings -ConfigPath $ConfigFile
    Reset-BotGuard -Settings $settings

    # One session lock for every mode (batch, interactive, scheduled).
    if (-not (Enter-ReaperLock)) {
        Show-ProgressUpdate "[!] Another instance of Digital Reaper is already running (lock file present). Exiting." -Type "Warning"
        if (-not $Silent) { Read-Host "Press Enter to exit..." }
        exit 1
    }
    
    if ($settings.autoUpdate) {
        Update-YtDlpSilent
    }

    $nextMode = "auto"
    $shouldExit = $false
    while (-not $shouldExit) {
        if ($nextMode -eq "quick") {
            Run-InteractiveMode -Settings $settings -ForceOneClick
        }
        elseif (Should-RunBatchMode) {
            Run-BatchMode -Settings $settings
        }
        else {
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

}
catch {
    Write-Host "`n[!] CRITICAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace:" -ForegroundColor DarkRed
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}
finally {
    Exit-ReaperLock
}

if (-not $Silent) {
    Write-Host "`n>> DIGITAL REAPER session ended." -ForegroundColor Yellow
}
