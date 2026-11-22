<#
========================================================================
    DIGITAL REAPER: LINK HARVESTER
    Custom tool for grabbing content with style
    Made by Wheezy for Wheezy
========================================================================
#>

param(
    [string]$LinksFile = "",
    [string]$ConfigFile = "",
    [switch]$Silent,
    [switch]$SetupOnly,
    [switch]$Doctor,
    [switch]$Status,
    [switch]$DryRun,
    [string]$VideoQuality = "",
    [string]$AudioFormat = "",
    [string]$OutputFolder = "",
    [switch]$Rollback
)

# Windows PowerShell 5.1 can still negotiate TLS 1.0, which GitHub rejects. Without
# this, a fresh install fails on the very first download with a confusing error.
try {
    $currentProtocol = [Net.ServicePointManager]::SecurityProtocol
    if (($currentProtocol -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
        [Net.ServicePointManager]::SecurityProtocol = $currentProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
}
catch {
    # Older .NET builds may not expose Tls12; nothing to do.
}

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
$script:YtDlpAssetName = if ($script:IsWindowsPlatform) {
    "yt-dlp.exe"
}
else {
    # The Linux releases are per-architecture and the plain name is x86_64 only,
    # so an ARM box would download a binary it cannot execute.
    $architecture = $null
    try { $architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { }
    switch ($architecture) {
        "Arm64" { "yt-dlp_linux_aarch64" }
        "Arm"   { "yt-dlp_linux_armv7l" }
        default { "yt-dlp_linux" }
    }
}
$script:YtDlpBinaryName = if ($script:IsWindowsPlatform) { "yt-dlp.exe" } else { "yt-dlp" }
$script:FfmpegBinaryName = if ($script:IsWindowsPlatform) { "ffmpeg.exe" } else { "ffmpeg" }
$script:FfprobeBinaryName = if ($script:IsWindowsPlatform) { "ffprobe.exe" } else { "ffprobe" }
$script:YtDlpPath = Join-Path $script:EngineDir $script:YtDlpBinaryName
$script:FfmpegPath = Join-Path $script:EngineDir $script:FfmpegBinaryName
$script:FfprobePath = Join-Path $script:EngineDir $script:FfprobeBinaryName
$script:FfmpegLocation = $script:EngineDir

# Shown in messages, so each platform reads its own path separator and setup script.
$script:SetupHint = if ($script:IsWindowsPlatform) { "setup.bat" } else { "setup.sh" }
$script:LogDisplayPath = if ($script:IsWindowsPlatform) { "engine\reaper.log" } else { "engine/reaper.log" }
$script:LockDisplayPath = if ($script:IsWindowsPlatform) { "engine\reaper.lock" } else { "engine/reaper.lock" }

# ffmpeg comes from the distro on Linux, so take it from PATH when engine/ has
# none. Resolved here rather than in Install-Ffmpeg because -Doctor runs before
# initialization and would otherwise report a missing engine on a healthy box.
if (-not $script:IsWindowsPlatform -and -not (Test-Path $script:FfmpegPath)) {
    $systemFfmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    $systemFfprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($systemFfmpeg) { $script:FfmpegPath = $systemFfmpeg.Source }
    if ($systemFfprobe) { $script:FfprobePath = $systemFfprobe.Source }
}

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

# Records the engine process this run spawned, so a run that dies mid-download can
# be cleaned up on the next launch. This is the only leftover detector that works
# off Windows: Linux reparents an orphan to init, so "is the parent alive" never
# sees it.
$script:EnginePidRecordFile = Join-Path $script:EngineDir "yt-dlp.pid"

# One warning per run about the record: a spawn happens for every item, and a wall
# of identical lines would bury the first one.
$script:EnginePidRecordWarned = $false

# Version file — persists the installed yt-dlp version across runs
$script:VersionFilePath = Join-Path $script:EngineDir "version.txt"
$script:DefaultOuterRetryCount = 3
$script:LogFilePath = Join-Path $script:EngineDir "reaper.log"
# Machine-readable outcome of the last completed run, so a silent or scheduled pass
# can be asked what it did without digging through the log.
$script:RunStateFile = Join-Path $script:EngineDir "last-run.json"

# Every finished download records its video id against the file on disk, so a
# re-pasted link is skipped even when its title - and therefore its file name -
# changed between runs. Audio and video are kept apart: one must not shadow the other.
$script:DownloadIndexFile = Join-Path $script:EngineDir "downloaded-index.tsv"

# yt-dlp appends "id<TAB>final path" here after each finished move. That beats
# guessing which file in the folder belongs to this attempt from timestamps.
$script:MoveRecordFile = Join-Path $script:EngineDir "last-move.tsv"

# Set by Confirm-DownloadedMedia when a link was skipped rather than fetched.
$script:LastItemSkipped = $false

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
    # A missing quality is not a bot signal: retry with backoff, never escalate the
    # player client or the session-wide cautious mode for it.
    Format            = @{ Retry = $true; BaseDelay = 2; MaxDelay = 5; Escalate = $false }
    RateLimit         = @{ Retry = $true; BaseDelay = 15; MaxDelay = 300; Escalate = $false }
    Network           = @{ Retry = $true; BaseDelay = 3; MaxDelay = 30; Escalate = $false }
    Transient         = @{ Retry = $true; BaseDelay = 3; MaxDelay = 15; Escalate = $false }
    # A file that "finished" but cannot be read back is resumed on the next
    # attempt: --continue re-fetches only the part that is missing.
    Incomplete        = @{ Retry = $true; BaseDelay = 2; MaxDelay = 5; Escalate = $false }
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
    Incomplete        = "The download finished but the file could not be read back (truncated, empty, or missing a stream). The link stays queued, so the next run resumes it."
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

function Format-Elapsed {
    param([TimeSpan]$Span)
    # "hh" is the 0-23 hour component, so a run longer than a day used to display
    # 02:30:00 for 26.5 hours. Total hours keep the value honest.
    $totalHours = [int][Math]::Floor($Span.TotalHours)
    if ($totalHours -ge 1) { return ("{0:00}:{1:00}:{2:00}" -f $totalHours, $Span.Minutes, $Span.Seconds) }
    return $Span.ToString("mm\:ss")
}

function Format-FileSize {
    param([double]$Bytes)
    if ($Bytes -le 0) { return "-" }
    if ($Bytes -ge 1GB) { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N0} KB" -f ($Bytes / 1KB)) }
    return ("{0:N0} B" -f $Bytes)
}

# One line, one colour, no repainting. The old pulse rewrote the same line once per
# colour (three times in a log) and could overwrite a label already on the line.
function Write-Line {
    param([string]$Text = "", [string]$Color = "Gray")
    Write-Host $Text -ForegroundColor $Color
}

# Every section rule in the UI comes from here, so the boxes line up on every
# screen instead of drifting between 50 and 62 columns.
function Write-Rule {
    param([string]$Color = "DarkGray")
    Write-Line -Text ("  " + ("-" * 62)) -Color $Color
}

function Show-ProgressUpdate {
    param([string]$Status, [string]$Type = "Info")

    $color = switch ($Type) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        "Target"  { "Cyan" }
        "Update"  { "Magenta" }
        "System"  { "DarkGray" }
        default   { "Gray" }
    }

    # Timestamps only where they carry information: problems and background steps.
    if ($Type -in @("Warning", "Error", "System")) {
        Write-Host ("[" + (Get-Date -Format "HH:mm:ss") + "] ") -NoNewline -ForegroundColor DarkGray
    }
    Write-Line -Text $Status -Color $color
}

function Show-ItemStart {
    param([int]$Index, [int]$Total, [string]$Label)

    # Fixed-width counter (13 columns including indent) so the result line below
    # always lands under the label, whatever the item count is.
    $counter = "[{0,3}/{1,3}]" -f $Index, $Total
    Write-Host ("  " + $counter + "  ") -NoNewline -ForegroundColor DarkGray
    Write-Line -Text $Label -Color "White"
}

function Show-ItemResult {
    param([string]$Status, [string]$Elapsed = "", [string]$Detail = "", [int]$Warnings = 0)

    $ok = ($Status -eq "ok")
    $label = if ($ok) { "ok  " } else { "fail" }
    $color = if ($ok) { "Green" } else { "Red" }

    Write-Host ("  " + (" " * 9) + "  ") -NoNewline
    Write-Host ($label + "  ") -NoNewline -ForegroundColor $color
    if ($Elapsed) { Write-Host ($Elapsed + "  ") -NoNewline -ForegroundColor DarkGray }

    if ($Detail) {
        Write-Line -Text $Detail -Color $(if ($ok) { "DarkGray" } else { "Yellow" })
    }
    elseif ($Warnings -gt 0) {
        Write-Line -Text ("$Warnings warning(s) - logged to $script:LogDisplayPath") -Color "DarkGray"
    }
    else {
        Write-Host ""
    }
}

function Get-RecentFileBytes {
    param([string]$Path, [datetime]$Since)

    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $total = 0
    foreach ($file in (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($file.LastWriteTime -ge $Since) { $total += $file.Length }
    }
    return $total
}

# A download that reports success can still be unusable: a full disk, a killed
# ffmpeg or a truncated merge leaves a broken file behind, and yt-dlp only answers
# for its own exit code. Links are retired the moment an item is called ok, so an
# unchecked file would be recorded as acquired and the URL dropped for good.
$script:VideoMediaExtensions = @(".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v")
$script:AudioMediaExtensions = @(".mp3", ".m4a", ".flac", ".opus", ".ogg", ".oga", ".wav", ".aac")

function Get-NewMediaFiles {
    param([string]$Path, [datetime]$Since, [string]$DownloadType)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $extensions = if ($DownloadType -eq "audio") { $script:AudioMediaExtensions } else { $script:VideoMediaExtensions }
    # Two seconds of slack: FAT/exFAT timestamps only have that much resolution. A
    # file missed here is reported as "nothing new" rather than as a failure, which
    # is the safe direction - it never deletes anything on a guess.
    $threshold = $Since.AddSeconds(-2)
    return @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $extensions -contains $_.Extension.ToLower() -and $_.LastWriteTime -ge $threshold })
}

# yt-dlp skips a link when its file name already exists, which stops working the
# moment a title changes. The index remembers the video id behind each finished
# file, so the same link is recognised without a request and without relying on
# the name.
function Get-MediaIdFromUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return "" }
    $patterns = @(
        'youtu\.be/([A-Za-z0-9_-]{11})',
        'youtube\.com/(?:watch\?(?:[^#]*&)?v=|shorts/|embed/|live/|v/)([A-Za-z0-9_-]{11})'
    )
    foreach ($pattern in $patterns) {
        if ($Url -match $pattern) { return $Matches[1] }
    }
    return ""
}

function Read-DownloadIndex {
    $entries = @()
    if (-not (Test-Path -LiteralPath $script:DownloadIndexFile)) { return $entries }
    foreach ($line in @(Get-Content -LiteralPath $script:DownloadIndexFile -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 3
        if ($parts.Count -lt 3) { continue }
        $entries += [pscustomobject]@{ Type = $parts[0]; Id = $parts[1]; Path = $parts[2] }
    }
    return $entries
}

function Write-DownloadIndex {
    param($Entries)
    try {
        $lines = @(foreach ($entry in @($Entries)) { "$($entry.Type)`t$($entry.Id)`t$($entry.Path)" })
        Set-Content -LiteralPath $script:DownloadIndexFile -Value $lines -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Bookkeeping must never fail the download it describes.
    }
}

# Returns the file this link already produced, or "" when it still has to be
# fetched. A recorded path that no longer exists is dropped: the user deleted or
# moved the file, and silently retiring the link would lose it for good.
function Find-DownloadedMedia {
    param([string]$Url, [string]$DownloadType)

    $id = Get-MediaIdFromUrl -Url $Url
    if (-not $id) { return "" }
    $entries = @(Read-DownloadIndex)
    $entry = $entries | Where-Object { $_.Type -eq $DownloadType -and $_.Id -eq $id } | Select-Object -First 1
    if (-not $entry) { return "" }
    if (Test-Path -LiteralPath $entry.Path) { return $entry.Path }

    Write-DownloadIndex -Entries @($entries | Where-Object { -not ($_.Type -eq $DownloadType -and $_.Id -eq $id) })
    return ""
}

# yt-dlp writes one "id<TAB>path" line per finished item. Read once, then use the
# paths for the read-back check and the ids for the repeat index.
function Get-MoveRecords {
    $records = @()
    if ([string]::IsNullOrWhiteSpace($script:MoveRecordFile) -or -not (Test-Path -LiteralPath $script:MoveRecordFile)) { return $records }
    foreach ($line in @(Get-Content -LiteralPath $script:MoveRecordFile -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -lt 2) { continue }
        $id = $parts[0].Trim()
        $path = $parts[1].Trim()
        if (-not $id -or -not $path) { continue }
        $records += [pscustomobject]@{ Id = $id; Path = $path }
    }
    return $records
}

# Only a file that is still on disk is worth remembering; the rest was deleted or
# moved by the user, and the link has to stay downloadable.
function Import-MoveRecords {
    param([string]$DownloadType, $Records)

    $present = @(@($Records) | Where-Object { $_ -and (Test-Path -LiteralPath $_.Path) })
    if ($present.Count -eq 0) { return }
    $entries = @(Read-DownloadIndex)
    foreach ($record in $present) {
        $entries = @($entries | Where-Object { -not ($_.Type -eq $DownloadType -and $_.Id -eq $record.Id) })
        $entries += [pscustomobject]@{ Type = $DownloadType; Id = $record.Id; Path = $record.Path }
    }
    Write-DownloadIndex -Entries $entries
}

# Interrupted transfers are left by yt-dlp as <name>.part and resumed next run.
# Reporting them makes a half-finished download visible instead of it looking like
# a file that simply came out smaller.
function Get-PartFileReport {
    param([string[]]$Path)

    $count = 0
    $bytes = [int64]0
    foreach ($folder in @($Path)) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($part in @(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter "*.part" -ErrorAction SilentlyContinue)) {
            $count++
            $bytes += $part.Length
        }
    }
    return [pscustomobject]@{ Count = $count; Bytes = $bytes }
}

function Test-MediaFileIntegrity {
    param([string]$Path, [string]$DownloadType)

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) { return [pscustomobject]@{ Ok = $false; Reason = "the file is missing" } }
    if ($item.Length -le 0) { return [pscustomobject]@{ Ok = $false; Reason = "the file is empty" } }

    # Without ffprobe there is no verdict, so the size check has to be enough.
    if (-not $script:FfprobePath -or -not (Test-Path -LiteralPath $script:FfprobePath)) {
        return [pscustomobject]@{ Ok = $true; Reason = "" }
    }

    # Started through .NET for the same reason yt-dlp is: under Windows PowerShell
    # 5.1 a native stderr redirect raises NativeCommandError, which would make the
    # verdict depend on $ErrorActionPreference instead of ffprobe's exit code.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:FfprobePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    Set-ProcessArguments -StartInfo $startInfo -Arguments @(
        "-v", "error",
        "-show_entries", "format=duration",
        "-show_entries", "stream=codec_type",
        "-of", "default=noprint_wrappers=1",
        "-i", $Path
    )

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $errorTask = $process.StandardError.ReadToEndAsync()
        $probeText = $process.StandardOutput.ReadToEnd()
        $probeError = $errorTask.Result
        $process.WaitForExit()
        $probeExit = $process.ExitCode
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Reason = "ffprobe could not run - $($_.Exception.Message)" }
    }
    finally {
        if ($process) { $process.Dispose() }
    }

    # A truncated MP4 loses its moov atom, so ffprobe refuses to read it at all.
    if ($probeExit -ne 0) {
        $detail = @($probeError -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        $detailText = ""
        if ($detail.Count -gt 0) {
            $detailText = ([string]$detail[0] -replace '^\s*\[[^\]]*\]\s*', '').Trim()
            if ($detailText.Length -gt 120) { $detailText = $detailText.Substring(0, 120).TrimEnd() + "..." }
        }
        $reason = "ffprobe cannot read it (truncated or corrupt container)"
        if ($detailText) { $reason = "$reason - $detailText" }
        return [pscustomobject]@{ Ok = $false; Reason = $reason }
    }

    $probeLines = @($probeText -split "`r?`n")

    $streamTypes = @()
    $duration = $null
    foreach ($lineText in $probeLines) {
        $text = [string]$lineText
        if ($text -match '^\s*codec_type=(\S+)') { $streamTypes += $matches[1].ToLower() }
        elseif ($text -match '^\s*duration=([0-9]+(?:\.[0-9]+)?)') { $duration = [double]$matches[1] }
    }

    $expected = if ($DownloadType -eq "audio") { "audio" } else { "video" }
    if ($streamTypes -notcontains $expected) {
        return [pscustomobject]@{ Ok = $false; Reason = "no $expected stream in the finished file" }
    }
    if ($null -ne $duration -and $duration -le 0) {
        return [pscustomobject]@{ Ok = $false; Reason = "the file reports zero duration" }
    }

    return [pscustomobject]@{ Ok = $true; Reason = "" }
}

# Returns $null when the finished download is usable, or a failure record for the
# retry loop. Only files created by this run are examined, and an unusable one is
# removed first: a final file left on disk would make yt-dlp answer "already
# downloaded" on the resume attempt and report success without fetching a byte.
function Confirm-DownloadedMedia {
    param(
        [string]$OutputDir,
        [datetime]$Since,
        [string]$DownloadType,
        [string]$Url,
        [hashtable]$Settings
    )

    $script:LastItemSkipped = $false

    # yt-dlp reports the exact file it finished, so verify that file instead of
    # guessing from timestamps. The scan stays as the fallback for a record that
    # was not written.
    $records = @(Get-MoveRecords)
    if ($records.Count -gt 0) {
        $found = @(foreach ($record in $records) {
            $item = Get-Item -LiteralPath $record.Path -ErrorAction SilentlyContinue
            if ($item) { $item }
        })
        $candidates = @($found | Sort-Object LastWriteTime -Descending)
        if ($candidates.Count -eq 0) {
            # yt-dlp called the file finished and it is not there. That is never a
            # success: the link would be retired with nothing on disk.
            return [pscustomobject]@{
                Kind      = "Incomplete"
                ErrorText = "ERROR: yt-dlp reported a finished file that is no longer on disk."
            }
        }
    }
    else {
        $candidates = @(Get-NewMediaFiles -Path $OutputDir -Since $Since -DownloadType $DownloadType |
            Sort-Object LastWriteTime -Descending)
    }
    if ($candidates.Count -eq 0) {
        # Nothing was written: yt-dlp answered "has already been downloaded", so this
        # folder already holds the video and the repeat is ignored. Retire the link
        # and say so, instead of leaving it looking like a failure. An interrupted
        # download is not this case: yt-dlp resumes its .part file instead.
        Show-ProgressUpdate "[=] Already downloaded - skipped" -Type "System"
        $script:LastItemSkipped = $true
        return $null
    }

    foreach ($candidate in $candidates) {
        $check = Test-MediaFileIntegrity -Path $candidate.FullName -DownloadType $DownloadType
        if ($check.Ok) { continue }

        $reason = "$($candidate.Name) - $($check.Reason)"
        Write-ReaperLog -Settings $Settings -Message "[Incomplete] $Url :: $reason"
        Show-ProgressUpdate "[!] Discarded unusable file: $reason" -Type "Warning"
        Remove-Item -LiteralPath $candidate.FullName -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            Kind      = "Incomplete"
            ErrorText = "ERROR: the finished file is unusable - $reason"
        }
    }

    # Remember which ids are on disk, so a re-pasted link is recognised next time.
    Import-MoveRecords -DownloadType $DownloadType -Records $records

    return $null
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
    $width = Get-ConsoleWidth
    Write-Host ""

    # The art is ~90 columns wide; below 95 it wraps into noise, so print a
    # compact mark instead. Same identity, no broken rows.
    if ($width -lt 95) {
        Write-Host "  ==========================================================" -ForegroundColor DarkRed
        Write-Host "    DIGITAL REAPER: LINK HARVESTER" -ForegroundColor DarkRed
        Write-Host "  ==========================================================" -ForegroundColor DarkRed
        Write-Host ""
        return
    }

    Write-Host "________  .__       .__  __         .__    __________                                   " -ForegroundColor DarkRed
    Write-Host "\______ \ |__| ____ |__|/  |______  |  |   \______   \ ____ _____  ______   ___________ " -ForegroundColor DarkRed
    Write-Host " |    |  \|  |/ ___\|  \   __\__  \ |  |    |       _// __ \\__  \ \____ \_/ __ \_  __ \" -ForegroundColor DarkRed
    Write-Host " |    ``   \  / /_/  >  ||  |  / __ \|  |__  |    |   \  ___/ / __ \|  |_> >  ___/|  | \/" -ForegroundColor DarkRed
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
            $downloadUrl = ConvertTo-DownloadUrl -Text $line
            if ($downloadUrl) { $urls += $downloadUrl }
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
    Write-Rule
    Write-Host ("   " + $Prompt) -ForegroundColor Yellow
    Write-Host ("   " + $Options) -ForegroundColor Gray
    Write-Rule
    Write-Host -NoNewline "   > " -ForegroundColor Yellow
}

function Ensure-Directory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    # .NET, not Test-Path/New-Item: those read [ ] in a folder name as a wildcard,
    # so a playlist titled "[Official] Mix" silently matched nothing.
    [void][System.IO.Directory]::CreateDirectory($Path)
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
    Write-Rule
    Write-Host ("   REAPER  " + $Mode) -ForegroundColor Cyan
    Write-Host ("   targets  " + $TargetCount + "   type  " + $TypeLabel.ToLower() + $(if ($Quality) { "   quality  " + $Quality } else { "" })) -ForegroundColor Gray
    Write-Host ("   output   " + $OutputDir) -ForegroundColor Gray
    Write-Rule
    Write-Host ""
}

function Remove-InvisibleCharacters {
    param([string]$Text)
    # Strip BOM (U+FEFF) and other invisible/zero-width characters
    return $Text.Trim().TrimStart([char]0xFEFF, [char]0x200B, [char]0x200C, [char]0x200D, [char]0xFFFE)
}

# Turns whatever a paste produced into a URL yt-dlp can use, or $null when the
# text is not a link. Share links arrive as "youtu.be/xyz", as "HTTPS://youtu.be/xyz"
# and as "www.youtube.com/watch?v=..." just as often as with a lowercase scheme;
# every one of those used to be ignored, so batch mode never saw them and their
# link-file lines could never be cleaned up.
function ConvertTo-DownloadUrl {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $value = Remove-InvisibleCharacters -Text $Text
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    if ($value.StartsWith("#")) { return $null }

    if ($value -match '^(?i)https?://') { return $value }
    # Protocol-relative paste: "//www.youtube.com/watch?v=..."
    if ($value -match '^//[^\s/]+\.[^\s/]+') { return "https:$value" }
    if ($value -match '^www\.[^\s/]+\.[^\s/]+') { return "https://$value" }
    # Scheme-less share link: "youtu.be/abc123", "m.youtube.com/watch?v=...".
    # The slash is required so a stray "notes.txt" is not read as a link.
    if ($value -match '^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}/\S*$') { return "https://$value" }

    return $null
}

function Test-ValidUrl {
    param([string]$Line)
    return [bool](ConvertTo-DownloadUrl -Text $Line)
}

# Link files keep the line the user wrote while the download uses the normalised
# URL, so removal has to accept either spelling of the same link.
function Test-UrlMatchesLine {
    param(
        [string]$Line,
        [string[]]$Urls
    )
    if (-not $Urls -or $Urls.Count -eq 0) { return $false }
    $cleanLine = Remove-InvisibleCharacters -Text $Line
    if ($Urls -contains $cleanLine) { return $true }
    $normalized = ConvertTo-DownloadUrl -Text $cleanLine
    return [bool]($normalized -and ($Urls -contains $normalized))
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
        outputTemplate      = "%(title)s.%(ext)s"
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
        $items = @($Value)
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
            $backupPath = "$ConfigPath.broken"
            Copy-Item -Path $ConfigPath -Destination $backupPath -Force -ErrorAction SilentlyContinue
            Show-ProgressUpdate "[!] Could not read $ConfigPath - using defaults (copy kept at $backupPath)" -Type "Warning"
        }
    }
    elseif (Test-Path $script:DefaultConfigFile) {
        try {
            Merge-SettingsFromFile -Settings $settings -FilePath $script:DefaultConfigFile
        }
        catch {
            $backupPath = "$($script:DefaultConfigFile).broken"
            Copy-Item -Path $script:DefaultConfigFile -Destination $backupPath -Force -ErrorAction SilentlyContinue
            Show-ProgressUpdate "[!] settings.json is not valid JSON - using defaults (copy kept at settings.json.broken)" -Type "Warning"
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
        $json = $ordered | ConvertTo-Json -Depth 6
        $tempPath = "$($script:DefaultConfigFile).tmp"
        Set-Content -Path $tempPath -Value $json -ErrorAction Stop
        Move-Item -Path $tempPath -Destination $script:DefaultConfigFile -Force -ErrorAction Stop
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

# Command-line overrides win over settings.json, so a one-off run does not need the
# file edited (and remembered to be changed back).
function Apply-CliOverrides {
    param([hashtable]$Settings)

    if (-not [string]::IsNullOrWhiteSpace($VideoQuality)) {
        $allowedQuality = @("720p", "1080p", "1440p", "4K")
        if ($VideoQuality -in $allowedQuality) {
            $Settings.videoQuality = $VideoQuality
        }
        else {
            Show-ProgressUpdate "[!] Ignoring -VideoQuality '$VideoQuality' (use 720p, 1080p, 1440p or 4K)." -Type "Warning"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($AudioFormat)) {
        $requestedFormat = $AudioFormat.ToLowerInvariant()
        $allowedFormats = @("mp3", "m4a", "flac", "opus", "wav")
        if ($requestedFormat -in $allowedFormats) {
            $Settings.audioFormat = $requestedFormat
        }
        else {
            Show-ProgressUpdate "[!] Ignoring -AudioFormat '$AudioFormat' (use mp3, m4a, flac, opus or wav)." -Type "Warning"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputFolder)) {
        $Settings.outputFolder = $OutputFolder.Trim()
    }

    return $Settings
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

# Swaps the kept build back in. Kept separate from the update path so it can also
# run on its own: a release that breaks extraction is undone with -Rollback.
function Restore-YtDlpBackup {
    param([switch]$Quiet)

    $backupPath = "$($script:YtDlpPath).backup"
    if (-not (Test-Path -LiteralPath $backupPath)) {
        if (-not $Quiet) { Show-ProgressUpdate "[!] No previous yt-dlp is kept - nothing to roll back to." -Type "Warning" }
        return 1
    }

    $swapPath = "$($script:YtDlpPath).swap"
    try {
        if (Test-Path -LiteralPath $script:YtDlpPath) {
            if ($script:IsWindowsPlatform) { (Get-Item $script:YtDlpPath -Force).Attributes = [System.IO.FileAttributes]::Normal }
            Copy-Item -LiteralPath $script:YtDlpPath -Destination $swapPath -Force
        }
        Copy-Item -LiteralPath $backupPath -Destination $script:YtDlpPath -Force
        if (-not (Set-ExecutablePermission -Path $script:YtDlpPath)) { throw "could not make yt-dlp executable" }

        # The restored build has to run before the swap counts as done.
        $version = [string]((& $script:YtDlpPath --version 2>&1) | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($version)) { throw "the kept yt-dlp did not run" }

        if (Test-Path -LiteralPath $swapPath) { Move-Item -LiteralPath $swapPath -Destination $backupPath -Force }
        Set-HiddenAttribute -Path $script:YtDlpPath

        # version.txt follows the binary, otherwise the next update check compares
        # against a version that is no longer installed.
        Set-Content -Path $script:VersionFilePath -Value $version
        if (-not $Quiet) {
            Show-ProgressUpdate "[+] Rolled back to yt-dlp $version. Set autoUpdate false to keep it." -Type "Success"
        }
        return 0
    }
    catch {
        if (Test-Path -LiteralPath $swapPath) {
            Copy-Item -LiteralPath $swapPath -Destination $script:YtDlpPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $swapPath -Force -ErrorAction SilentlyContinue
        }
        if (-not $Quiet) { Show-ProgressUpdate "[!] Rollback failed: $($_.Exception.Message)" -Type "Error" }
        return 1
    }
}

function Install-YtDlp {
    Show-ProgressUpdate "[~] yt-dlp not found - downloading latest release..." -Type "Update"

    # Stage next to the target with a .exe extension (PowerShell will not execute
    # an unknown extension), verify it runs, then swap it in. A half-written file
    # must never end up as the binary the whole tool depends on.
    $incomingPath = if ($script:IsWindowsPlatform) { "$($script:YtDlpPath).new.exe" } else { "$($script:YtDlpPath).new" }

    try {
        $apiUrl = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
        $release = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'DigitalReaper' } -TimeoutSec 20 -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -eq 3) { throw }
                Show-ProgressUpdate "[!] Release lookup failed, retrying ($attempt/3)..." -Type "Warning"
                Start-Sleep -Seconds (2 * $attempt)
            }
        }

        $asset = $release.assets | Where-Object { $_.name -eq $script:YtDlpAssetName } | Select-Object -First 1
        if (-not $asset) { throw "$($script:YtDlpAssetName) asset not found in latest release." }

        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                if (Test-Path $incomingPath) { Remove-Item $incomingPath -Force -ErrorAction SilentlyContinue }
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $incomingPath -TimeoutSec 300 -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -eq 3) { throw }
                Show-ProgressUpdate "[!] Download failed, retrying ($attempt/3)..." -Type "Warning"
                Start-Sleep -Seconds (2 * $attempt)
            }
        }

        $incoming = Get-Item $incomingPath -ErrorAction SilentlyContinue
        if (-not $incoming -or $incoming.Length -eq 0) { throw "Downloaded file is empty." }

        if (-not (Set-ExecutablePermission -Path $incomingPath)) {
            throw "Could not set executable permission on yt-dlp."
        }

        # Prove it runs before it replaces anything.
        $null = & $incomingPath --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Downloaded yt-dlp failed its version check." }

        Remove-Item -Path $script:YtDlpPath -Force -ErrorAction SilentlyContinue
        Move-Item -Path $incomingPath -Destination $script:YtDlpPath -Force -ErrorAction Stop
        Set-HiddenAttribute -Path $script:YtDlpPath
        Set-Content -Path $script:VersionFilePath -Value $release.tag_name

        Show-ProgressUpdate "[+] yt-dlp installed ($($release.tag_name))" -Type "Success"
        return $true
    }
    catch {
        if (Test-Path $incomingPath) { Remove-Item $incomingPath -Force -ErrorAction SilentlyContinue }
        Show-ProgressUpdate "[!] Failed to install yt-dlp: $($_.Exception.Message)" -Type "Error"
        Show-ProgressUpdate "    Check the internet connection, then run $script:SetupHint again." -Type "Warning"
        return $false
    }
}

# ffmpeg is taken from PATH on Linux, but a first run should end ready to use
# rather than stop and ask for a package install, so a missing binary is fetched
# as a static build into engine/ - no root, no package manager - the same way
# Windows gets one. The Linux assets are per-architecture, and the plain "linux64"
# name is x86_64 only, so an ARM box must not receive it.
function Get-FfmpegLinuxAssetName {
    $architecture = $null
    try { $architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { }
    switch ($architecture) {
        "X64"   { "ffmpeg-master-latest-linux64-gpl.tar.xz" }
        "Arm64" { "ffmpeg-master-latest-linuxarm64-gpl.tar.xz" }
        default { $null }
    }
}

function Install-FfmpegStatic {
    param([string[]]$MissingTools)

    $assetName = Get-FfmpegLinuxAssetName
    if (-not $assetName) {
        Show-ProgressUpdate "[!] No prebuilt ffmpeg is published for this CPU architecture." -Type "Warning"
        return $false
    }

    Show-ProgressUpdate "[~] $($MissingTools -join ' and ') not on PATH - downloading a static build (no root needed, this may take a minute)..." -Type "Update"

    # Keep the engine copies in their own variables: $script:FfmpegPath may still
    # point at a distribution binary in /usr/bin, and a failed install must never
    # delete anything outside engine/.
    $engineFfmpeg = Join-Path $script:EngineDir $script:FfmpegBinaryName
    $engineFfprobe = Join-Path $script:EngineDir $script:FfprobeBinaryName
    $archiveUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/$assetName"
    $archivePath = Join-Path ([System.IO.Path]::GetTempPath()) "ffmpeg-reaper.tar.xz"
    $extractPath = Join-Path ([System.IO.Path]::GetTempPath()) "ffmpeg-reaper"

    try {
        # PowerShell has no tar.xz support built in, and GNU tar detects the
        # compression on extraction by itself.
        $tar = Get-Command tar -ErrorAction SilentlyContinue
        if (-not $tar) { throw "tar is required to unpack the archive." }

        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                if (Test-Path $archivePath) { Remove-Item $archivePath -Force -ErrorAction SilentlyContinue }
                Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -TimeoutSec 600 -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -eq 3) { throw }
                Show-ProgressUpdate "[!] ffmpeg download failed, retrying ($attempt/3)..." -Type "Warning"
                Start-Sleep -Seconds (2 * $attempt)
            }
        }

        $archive = Get-Item $archivePath -ErrorAction SilentlyContinue
        if (-not $archive -or $archive.Length -eq 0) { throw "Downloaded archive is empty." }

        if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
        New-Item -Path $extractPath -ItemType Directory -Force | Out-Null
        Show-ProgressUpdate "[~] Extracting ffmpeg archive..." -Type "System"
        $null = & $tar.Source -xf $archivePath -C $extractPath 2>&1
        if ($LASTEXITCODE -ne 0) { throw "tar could not unpack the archive (exit code $LASTEXITCODE)." }

        # Both binaries live together in the bin/ folder of the top-level folder.
        $ffmpegSource = Get-ChildItem -Path $extractPath -Filter $script:FfmpegBinaryName -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $ffmpegSource) { throw "$($script:FfmpegBinaryName) not found inside the archive." }
        $ffprobeSource = Get-ChildItem -Path $extractPath -Filter $script:FfprobeBinaryName -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $ffprobeSource) { throw "$($script:FfprobeBinaryName) not found inside the archive." }

        if (-not (Test-Path $script:EngineDir)) { New-Item -Path $script:EngineDir -ItemType Directory -Force | Out-Null }
        Copy-Item $ffmpegSource.FullName  $engineFfmpeg  -Force -ErrorAction Stop
        Copy-Item $ffprobeSource.FullName $engineFfprobe -Force -ErrorAction Stop
        if (-not (Set-ExecutablePermission -Path $engineFfmpeg)) { throw "Could not mark ffmpeg as executable." }
        if (-not (Set-ExecutablePermission -Path $engineFfprobe)) { throw "Could not mark ffprobe as executable." }

        # Prove the copies run before they become the binaries everything else uses.
        $script:FfmpegPath = $engineFfmpeg
        $script:FfprobePath = $engineFfprobe
        $null = & $script:FfmpegPath -version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed functional verification (exit code $LASTEXITCODE)." }
        $null = & $script:FfprobePath -version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "ffprobe failed functional verification (exit code $LASTEXITCODE)." }

        Show-ProgressUpdate "[+] ffmpeg and ffprobe installed" -Type "Success"
        return $true
    }
    catch {
        Show-ProgressUpdate "[!] Automatic ffmpeg install failed: $($_.Exception.Message)" -Type "Error"
        # Remove partial copies so the next launch retries cleanly, and drop back to
        # a distribution binary when one is still on PATH.
        Remove-Item $engineFfmpeg  -Force -ErrorAction SilentlyContinue
        Remove-Item $engineFfprobe -Force -ErrorAction SilentlyContinue
        $script:FfmpegPath = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
        $script:FfprobePath = (Get-Command ffprobe -ErrorAction SilentlyContinue).Source
        return $false
    }
    finally {
        Remove-Item $archivePath -Force -ErrorAction SilentlyContinue
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-Ffmpeg {
    if (-not $script:IsWindowsPlatform) {
        Show-ProgressUpdate "[~] Linux detected - checking for system ffmpeg/ffprobe..." -Type "Update"
        $systemFfmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
        $systemFfprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
        $missingTools = @()
        if (-not $systemFfmpeg) { $missingTools += "ffmpeg" }
        if (-not $systemFfprobe) { $missingTools += "ffprobe" }
        if ($missingTools.Count -gt 0) {
            if (Install-FfmpegStatic -MissingTools $missingTools) { return $true }

            Show-ProgressUpdate "[!] Missing required tool(s): $($missingTools -join ', ')." -Type "Error"
            Show-ProgressUpdate "[!] Install the ffmpeg package instead:" -Type "Error"
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

    Show-ProgressUpdate "[~] ffmpeg not found - downloading static build (this may take a minute)..." -Type "Update"
    # Use the static (non-shared) GPL build so ffmpeg.exe and ffprobe.exe are
    # self-contained executables with no companion DLLs required.
    $zipUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
    $zipPath = Join-Path $env:TEMP "ffmpeg-reaper.zip"
    $extractPath = Join-Path $env:TEMP "ffmpeg-reaper"
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -TimeoutSec 300 -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -eq 3) { throw }
                Show-ProgressUpdate "[!] ffmpeg download failed, retrying ($attempt/3)..." -Type "Warning"
                Start-Sleep -Seconds (2 * $attempt)
            }
        }

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

# Starting the tool from a launcher on PATH used to mean creating a wrapper and
# editing PATH by hand. Setup does both now: dr.cmd in %LOCALAPPDATA%\DigitalReaper\bin
# on Windows, an executable dr in ~/.local/bin on Linux. Idempotent, and a failure
# is only a warning.
function Get-CommandShortcutContent {
    param(
        [string]$LauncherPath,
        [switch]$Posix
    )
    if ($Posix) { return "#!/usr/bin/env bash`nexec `"$LauncherPath`" `"`$@`"`n" }
    return "@echo off`r`ncall `"$LauncherPath`" %*`r`n"
}

function Install-CommandShortcut {
    $onWindows = [bool]$script:IsWindowsPlatform
    $launcher = Join-Path $PSScriptRoot $(if ($onWindows) { "digitalReaper.bat" } else { "digitalReaper.sh" })
    if (-not (Test-Path $launcher)) { return }

    try {
        if ($onWindows) {
            $binDir = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "DigitalReaper\bin"
            $shortcutPath = Join-Path $binDir "dr.cmd"
            $content = Get-CommandShortcutContent -LauncherPath $launcher
        }
        else {
            $binDir = Join-Path $HOME ".local/bin"
            $shortcutPath = Join-Path $binDir "dr"
            $content = Get-CommandShortcutContent -LauncherPath $launcher -Posix
        }

        Ensure-Directory -Path $binDir
        $changed = $false

        $existing = if (Test-Path $shortcutPath) { [string](Get-Content -Path $shortcutPath -Raw -ErrorAction SilentlyContinue) } else { "" }
        if ($existing -ne $content) {
            Set-Content -Path $shortcutPath -Value $content -Encoding ASCII -NoNewline
            if (-not $onWindows) { $null = & chmod 755 $shortcutPath 2>&1 }
            $changed = $true
        }

        if ($onWindows) {
            $userPath = [string][Environment]::GetEnvironmentVariable("Path", "User")
            $entries = @($userPath -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $alreadyListed = @($entries | Where-Object { $_.Trim().TrimEnd("\") -eq $binDir.TrimEnd("\") }).Count -gt 0
            if (-not $alreadyListed) {
                [Environment]::SetEnvironmentVariable("Path", ((@($entries) + $binDir) -join ";"), "User")
                $env:Path = "$env:Path;$binDir"
                $changed = $true
            }
        }
        else {
            $alreadyListed = @($env:PATH -split ":" | Where-Object { $_ -and $_.TrimEnd("/") -eq $binDir.TrimEnd("/") }).Count -gt 0
            if (-not $alreadyListed) {
                # No profile editing from here, just the line worth adding.
                Show-ProgressUpdate "[~] Add $binDir to PATH to run 'dr' from anywhere." -Type "Warning"
            }
        }

        if ($changed) {
            $howTo = if ($onWindows) { "Win+R, type dr, Enter" } else { "run dr in a terminal" }
            Show-ProgressUpdate "[+] Installed the 'dr' launcher - $howTo." -Type "System"
        }
    }
    catch {
        Show-ProgressUpdate "[~] Could not install the 'dr' launcher: $($_.Exception.Message)" -Type "Warning"
    }
}

function Initialize-DigitalReaper {
    Show-ProgressUpdate "DIGITAL REAPER initializing..." -Type "System"
    
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

    if (-not $Silent) { Install-CommandShortcut }

    # Create starter link files if they don't exist
    if (-not (Test-Path $script:AudioLinksFile)) {
        @(
            "# Audio links - one URL per line",
            "# Finished links are removed, failed ones stay for another run"
        ) | Set-Content $script:AudioLinksFile
        Show-ProgressUpdate "[+] Created audioLinks.txt" -Type "System"
    }

    if (-not (Test-Path $script:VideoLinksFile)) {
        @(
            "# Video links - one URL per line",
            "# Finished links are removed, failed ones stay for another run"
        ) | Set-Content $script:VideoLinksFile
        Show-ProgressUpdate "[+] Created videoLinks.txt" -Type "System"
    }
    
    if (-not (Test-Path $script:YtDlpPath)) {
        if (-not (Install-YtDlp)) { return $false }
    }
    else {
        # "The file exists" is not the same as "the tool works": a truncated or
        # quarantined binary would otherwise fail later, mid-download.
        $null = & $script:YtDlpPath --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            # The one case where the kept build is the fix, and trying it costs
            # nothing: no network, no download.
            if ((Restore-YtDlpBackup -Quiet) -eq 0) {
                Show-ProgressUpdate "[!] yt-dlp was not runnable - restored the previous build." -Type "Warning"
                $null = & $script:YtDlpPath --version 2>&1
            }
            if ($LASTEXITCODE -ne 0) {
                Show-ProgressUpdate "[!] yt-dlp is present but not runnable - reinstalling" -Type "Warning"
                Remove-Item -Path $script:YtDlpPath -Force -ErrorAction SilentlyContinue
                if (-not (Install-YtDlp)) { return $false }
            }
        }
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

            # Invoke-WebRequest throws on 4xx, so the rate-limit signal has to be
            # read from the exception: testing $webResponse.StatusCode afterwards
            # never fired and the failure disappeared into the silent catch below.
            try {
                $webResponse = Invoke-WebRequest -Uri $url -Headers @{ 'User-Agent' = 'DigitalReaper' } -TimeoutSec 10 -ErrorAction Stop
            }
            catch {
                $statusCode = 0
                try {
                    if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
                }
                catch { }
                if ($statusCode -eq 403 -or $statusCode -eq 429) {
                    return [pscustomobject]@{ Type = "Warning"; Message = "[!] GitHub API rate limit reached - skipping yt-dlp update check." }
                }
                return [pscustomobject]@{ Type = "Warning"; Message = "[!] Update check failed: $($_.Exception.Message)" }
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
                    return [pscustomobject]@{ Type = "Warning"; Message = "[!] Could not find $YtDlpAssetName in latest release assets - skipping update." }
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
                    # Only Windows refuses to overwrite a hidden file. On Linux the
                    # attribute means nothing and .NET will not set it.
                    if ($IsWindowsPlatform) {
                        (Get-Item $YtDlpPath -Force).Attributes = [System.IO.FileAttributes]::Normal
                    }
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
                    Set-HiddenAttribute -Path $YtDlpPath
                    Set-Content -Path $VersionFilePath -Value $latestVersion
                    # The previous build stays beside the new one. The next update
                    # replaces it, and -Rollback (or a binary that will not run) can
                    # put it back without any network access.

                    return [pscustomobject]@{ Type = "Success"; Message = "yt-dlp updated to $latestVersion" }
                }
                catch {
                    if (Test-Path $incomingPath) { Remove-Item $incomingPath -Force -ErrorAction SilentlyContinue }
                    if ((Test-Path $backupPath) -and -not (Test-Path $YtDlpPath)) {
                        Copy-Item $backupPath $YtDlpPath -Force
                        Set-HiddenAttribute -Path $YtDlpPath
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
    Write-Rule
    Write-Host "   Playlist-formatted link detected:" -ForegroundColor Yellow
    Write-Host ("   " + $Url) -ForegroundColor Cyan
    Write-Host "   Download the whole playlist, or just this single item?" -ForegroundColor Yellow
    Write-Host "   1=Whole Playlist, 2=Just Single Video/Audio" -ForegroundColor Gray
    Write-Rule
    
    $choice = ""
    while ($choice -notin @("1", "2")) {
        Write-Host -NoNewline "> " -ForegroundColor Yellow
        $choice = (Read-Host).Trim()
        if ($choice -notin @("1", "2")) {
            Show-ProgressUpdate "[!] Invalid choice. Enter 1 or 2." -Type "Warning"
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
            PlaylistId = [string]$data.id
            EntryCount = $entries.Count
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

    # Two playlists can share a title ("Music", "Favorites"), so a new folder
    # carries the playlist ID and cannot merge with another one. A folder created
    # before the ID was added is reused as-is, otherwise every existing playlist
    # would re-download into a fresh folder once.
    $legacyDir = Join-Path $baseDir $safeName
    $playlistDir = $legacyDir
    if ($meta.PlaylistId) {
        # Parentheses, not brackets: [ ] in a folder name are PowerShell wildcards.
        $idTag = " (" + (Get-SafeFolderName -Name $meta.PlaylistId) + ")"
        $budget = 80 - $idTag.Length
        if ($safeName.Length -gt $budget) {
            $cut = $safeName.Substring(0, [Math]::Max(1, $budget))
            $space = $cut.LastIndexOf(" ")
            if ($space -gt 0) { $cut = $cut.Substring(0, $space) }
            $safeName = $cut.Trim()
        }
        $idDir = Join-Path $baseDir ($safeName + $idTag)
        if (-not (Test-Path -LiteralPath $idDir) -and (Test-Path -LiteralPath $legacyDir)) { $playlistDir = $legacyDir } else { $playlistDir = $idDir }
    }
    Ensure-Directory -Path $playlistDir

    Write-Host ""
    Write-Rule
    Write-Host "   REAPER  PLAYLIST" -ForegroundColor Cyan
    Write-Host ("   " + $meta.Title) -ForegroundColor White
    Write-Host ("   items  " + $meta.EntryCount + "   type  " + $DownloadType + $(if ($DownloadType -eq "video") { "   quality  " + $Settings.videoQuality } else { "" })) -ForegroundColor Gray
    Write-Host ("   output " + $playlistDir) -ForegroundColor Gray
    Write-Rule
    Write-Host ""

    # One native yt-dlp pass for the whole playlist. The old code launched a fresh
    # yt-dlp process per item, which roughly tripled the request count and threw
    # away yt-dlp's own resume and back-off handling.
    $padWidth = [Math]::Max(2, $meta.EntryCount.ToString().Length)
    $indexFormat = "%(playlist_index)0" + $padWidth + "d"
    $itemTemplate = "$indexFormat - %(title)s.%(ext)s"

    $startedAt = Get-Date
    $downloadResult = Invoke-YtDlpForUrl -Settings $Settings -DownloadType $DownloadType `
        -OutputDir $playlistDir -Url $Url -OutputTemplate $itemTemplate `
        -ExtraArgs @("--yes-playlist", "--ignore-errors")

    # Report the state of the folder rather than the exit code: that survives a
    # resume, and "does this playlist exist locally" is the real question.
    $mediaExtensions = @(".mp4", ".mkv", ".webm", ".mp3", ".m4a", ".flac", ".opus", ".ogg", ".wav")
    $present = @(Get-ChildItem -LiteralPath $playlistDir -File -ErrorAction SilentlyContinue |
        Where-Object { $mediaExtensions -contains $_.Extension.ToLower() })
    $newThisRun = @($present | Where-Object { $_.LastWriteTime -ge $startedAt })
    $missing = [Math]::Max(0, $meta.EntryCount - $present.Count)
    # A resumed folder can already hold every item, or leftovers from an earlier
    # run; never report more files than the playlist has entries.
    $landed = [Math]::Min($present.Count, $meta.EntryCount)

    if (-not $downloadResult.Success) {
        $friendly = Get-FriendlyErrorHint -ErrorText $downloadResult.ErrorText -Kind $downloadResult.Kind
        Write-Host "   miss  " -NoNewline -ForegroundColor Red
        Write-Line -Text $friendly -Color "Yellow"
        if ($downloadResult.Digest) {
            Write-Host ("         " + $downloadResult.Digest) -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    $onDisk = "   on disk  " + $landed + "/" + $meta.EntryCount
    if ($newThisRun.Count -gt 0) { $onDisk += "   (+" + $newThisRun.Count + " new)" }
    Write-Host $onDisk -ForegroundColor $(if ($missing -eq 0) { "Green" } else { "Yellow" })
    if ($missing -gt 0) {
        Write-Host ("   ! " + $missing + " item(s) still missing - run it again to retry only those.") -ForegroundColor Yellow
    }

    return [pscustomobject]@{
        Success   = $landed
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
        [switch]$UseFallbackFormat,
        [int]$HeightOverride = 0
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
    $ytDlpArgs.Add((Format-InvariantNumber -Value $Settings.maxFragmentRetries -Default 20))
    $ytDlpArgs.Add("--retry-sleep")
    $ytDlpArgs.Add("fragment:exp=1:30")
    $ytDlpArgs.Add("--console-title")
    $ytDlpArgs.Add("--continue")

    # Our own UI owns the console now: yt-dlp prints only its single progress
    # line, everything else lands on stderr and is surfaced when it matters.
    $ytDlpArgs.Add("--quiet")
    $ytDlpArgs.Add("--progress")
    $ytDlpArgs.Add("--progress-template")
    $ytDlpArgs.Add("download:  %(progress._percent_str)s  %(progress._speed_str)s  ETA %(progress._eta_str)s")

    # Cautious mode (entered after repeated bot checks) downloads single-threaded.
    $fragments = 1
    if (-not (Test-BotGuardCautious)) {
        $configuredFragments = [int](Format-InvariantNumber -Value $Settings.concurrentFragments -Default 1)
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

        # A height override comes from the quality ladder: a retry asks for a lower
        # resolution than the configured one without editing the settings.
        $height = if ($HeightOverride -gt 0) {
            $HeightOverride
        }
        else {
            switch ($Settings.videoQuality) {
                "720p" { 720 }
                "1080p" { 1080 }
                "1440p" { 1440 }
                "4K" { 2160 }
                default { 1080 }
            }
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

    # after_move is a late stage, so this does not turn the download into a
    # simulate run. The record names the file and its video id, which is what the
    # read-back check and the repeat index use instead of file timestamps.
    if ($script:MoveRecordFile) {
        $ytDlpArgs.Add("--print-to-file")
        $ytDlpArgs.Add("after_move:%(id)s`t%(filepath)s")
        $ytDlpArgs.Add($script:MoveRecordFile)
    }

    return $ytDlpArgs
}

# Returns a culture-invariant *string* for yt-dlp's argument list. The name says
# "format", not "get": a caller that needs arithmetic has to cast it first.
function Format-InvariantNumber {
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
        StartIndex           = $startIndex
        Index                = $startIndex
        ConsecutiveBotChecks = 0
        ConsecutiveSuccesses = 0
        Cautious             = $false
        CooledDown           = $false
    }
}

function Test-BotGuardCautious {
    if (-not $script:BotGuard) { return $false }
    return [bool]$script:BotGuard.Cautious
}

# A clean download proves the network is usable again, so penalties earned by an
# earlier video must not follow the rest of the run. The old code cleared only the
# consecutive-check counter, which left cautious mode and the escalated player
# client switched on forever - one unlucky video slowed every later download.
function Register-BotGuardSuccess {
    if (-not $script:BotGuard) { return }
    $script:BotGuard.ConsecutiveBotChecks = 0
    $script:BotGuard.ConsecutiveSuccesses++
    if ($script:BotGuard.ConsecutiveSuccesses -lt 2) { return }
    $script:BotGuard.Cautious = $false
    $script:BotGuard.CooledDown = $false
    $script:BotGuard.Index = $script:BotGuard.StartIndex
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
    $script:BotGuard.ConsecutiveSuccesses = 0

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
        $coolDown = [int](Format-InvariantNumber -Value $Settings.botCooldownSeconds -Default 60)
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
    $stealthArgs.Add((Format-InvariantNumber -Value $Settings.requestSleep -Default 1))

    $minSleep = Format-InvariantNumber -Value $Settings.minSleepInterval -Default 1
    $maxSleep = Format-InvariantNumber -Value $Settings.maxSleepInterval -Default 3
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

# Warnings are counted in the UI, so the first one is worth keeping. Without this
# the "warning(s)" text pointed at a log that never contained any.
function Write-WarningLog {
    param([string]$Url, [string]$WarningText, [int]$Count, [hashtable]$Settings)
    if ($Count -le 0 -or [string]::IsNullOrWhiteSpace($WarningText)) { return }
    $first = ""
    foreach ($line in ($WarningText -split "`r?`n")) {
        if ($line -match 'WARNING') { $first = $line.Trim(); break }
    }
    if ($first.Length -gt 200) { $first = $first.Substring(0, 200).TrimEnd() + "..." }
    Write-ReaperLog -Settings $Settings -Message "warnings($Count) $Url :: $first"
}

# Written at the end of every batch, interactive and playlist run. The log already
# records one line per run, but a scheduled pass has nobody to ask follow-up
# questions, so the failures keep their URL and their hint here.
function Write-RunState {
    param(
        [hashtable]$Settings,
        [string]$Mode,
        [int]$SuccessCount,
        [int]$FailureCount,
        [int]$SkippedCount = 0,
        [string[]]$Failures = @(),
        [double]$TotalBytes = 0,
        [TimeSpan]$Elapsed = [TimeSpan]::Zero,
        [string]$OutputDir = ""
    )

    try {
        if (-not (Test-Path $script:EngineDir)) { return }
        $state = [ordered]@{
            finishedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            mode       = $Mode
            ok         = $SuccessCount
            failed     = $FailureCount
            skipped    = $SkippedCount
            bytes      = [int64]$TotalBytes
            seconds    = [int][Math]::Round($Elapsed.TotalSeconds)
            outputDir  = $OutputDir
            dryRun     = [bool]$DryRun
            failures   = @($Failures | Select-Object -First 20)
        }
        $json = $state | ConvertTo-Json -Depth 4
        Set-Content -Path $script:RunStateFile -Value $json -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # A bookkeeping file must never fail the run it describes.
    }
}

function Show-LastRunStatus {
    Write-Host ""
    Write-Rule
    Write-Host "   LAST RUN" -ForegroundColor Cyan
    Write-Rule

    if (-not (Test-Path $script:RunStateFile)) {
        Write-Line -Text "   No completed run recorded yet." -Color "DarkGray"
        Write-Rule
        Write-Host ""
        return 0
    }

    try {
        $state = Get-Content -Path $script:RunStateFile -Raw | ConvertFrom-Json
    }
    catch {
        Show-ProgressUpdate "[!] $script:RunStateFile is unreadable - it is rewritten at the end of the next run." -Type "Warning"
        return 0
    }

    $okCount = [int]$state.ok
    $failedCount = [int]$state.failed
    $skippedCount = [int]$state.skipped
    Write-Line ("   finished   " + $state.finishedAt) -Color "Gray"
    Write-Line ("   mode       " + $state.mode) -Color "Gray"
    Write-Line ("   acquired   " + $okCount) -Color $(if ($okCount -gt 0) { "Green" } else { "DarkGray" })
    Write-Line ("   missed     " + $failedCount) -Color $(if ($failedCount -gt 0) { "Red" } else { "DarkGray" })
    if ($skippedCount -gt 0) {
        Write-Line ("   skipped    " + $skippedCount) -Color "DarkGray"
    }
    if ([double]$state.bytes -gt 0) {
        Write-Line ("   size       " + (Format-FileSize -Bytes ([double]$state.bytes))) -Color "Gray"
    }
    if ([int]$state.seconds -gt 0) {
        Write-Line ("   elapsed    " + (Format-Elapsed -Span ([TimeSpan]::FromSeconds([double]$state.seconds)))) -Color "Gray"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$state.outputDir)) {
        Write-Line ("   output     " + $state.outputDir) -Color "Gray"
    }
    if ($state.dryRun) {
        Write-Line "   (dry run - nothing was downloaded)" -Color "Yellow"
    }

    $runFailures = @($state.failures | Where-Object { $_ })
    if ($runFailures.Count -gt 0) {
        Write-Rule
        foreach ($entry in ($runFailures | Select-Object -First 5)) {
            Write-Line ("   ! " + $entry) -Color "Yellow"
        }
        if ($runFailures.Count -gt 5) {
            Write-Line ("   ! ...and " + ($runFailures.Count - 5) + " more in $script:RunStateFile") -Color "DarkGray"
        }
    }

    Write-Rule
    Write-Host ""

    if ($failedCount -gt 0) { return 1 }
    return 0
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
# One yt-dlp invocation plus the read-back check, shared by the quality ladder and
# the last-resort format so both report a failure the same way.
function Invoke-YtDlpAttempt {
    param(
        [hashtable]$Settings,
        [string]$DownloadType,
        [string]$OutputDir,
        [string]$Url,
        [string]$OutputTemplate = "",
        [switch]$NoPlaylist,
        [switch]$UseFallbackFormat,
        [int]$HeightOverride = 0,
        [string[]]$ExtraArgs = @(),
        [datetime]$VerifySince
    )

    $ytArgs = New-Object System.Collections.Generic.List[string]
    foreach ($argItem in (Get-YtDlpArgs -Settings $Settings -DownloadType $DownloadType -OutputDir $OutputDir -OutputTemplate $OutputTemplate -UseFallbackFormat:$UseFallbackFormat -HeightOverride $HeightOverride)) {
        $ytArgs.Add([string]$argItem)
    }
    if ($NoPlaylist) { $ytArgs.Add("--no-playlist") }
    foreach ($extraArg in $ExtraArgs) { $ytArgs.Add([string]$extraArg) }
    $ytArgs.Add($Url)

    $capture = Invoke-YtDlpAndCapture -YtDlpArgs $ytArgs.ToArray()
    if (-not $capture.Success) {
        $errorText = [string]$capture.ErrorText
        return [pscustomobject]@{
            Success   = $false
            ErrorText = $errorText
            Kind      = (Get-FailureKind -ErrorText $errorText)
            Digest    = (Get-ErrorDigest -ErrorText $errorText)
            Warnings  = 0
        }
    }

    # "Exit code 0" is not the same as "the file is usable".
    $mediaFailure = Confirm-DownloadedMedia -OutputDir $OutputDir -Since $VerifySince -DownloadType $DownloadType -Url $Url -Settings $Settings
    if ($mediaFailure) {
        $errorText = [string]$mediaFailure.ErrorText
        return [pscustomobject]@{
            Success   = $false
            ErrorText = $errorText
            Kind      = [string]$mediaFailure.Kind
            Digest    = (Get-ErrorDigest -ErrorText $errorText)
            Warnings  = 0
        }
    }

    Register-BotGuardSuccess
    $warningCount = ([regex]::Matches([string]$capture.ErrorText, '(?m)^\s*WARNING')).Count
    Write-WarningLog -Url $Url -WarningText ([string]$capture.ErrorText) -Count $warningCount -Settings $Settings
    return [pscustomobject]@{
        Success   = $true
        Skipped   = [bool]$script:LastItemSkipped
        ErrorText = [string]$capture.ErrorText
        Kind      = ""
        Digest    = ""
        Warnings  = $warningCount
    }
}

# Resolutions to step down through when the requested quality is not offered.
# Two rungs is enough to recover a typical "requested format is not available"
# without turning one bad video into six downloads.
function Get-QualityLadder {
    param(
        [string]$VideoQuality,
        [int]$HeightOverride = 0
    )

    $heights = @(2160, 1440, 1080, 720, 480, 360)
    $current = if ($HeightOverride -gt 0) {
        $HeightOverride
    }
    else {
        switch ($VideoQuality) {
            "720p" { 720 }
            "1080p" { 1080 }
            "1440p" { 1440 }
            "4K" { 2160 }
            default { 1080 }
        }
    }

    return @($heights | Where-Object { $_ -lt $current } | Select-Object -First 2)
}

function Invoke-YtDlpForUrl {
    param(
        [hashtable]$Settings,
        [string]$DownloadType,
        [string]$OutputDir,
        [string]$Url,
        [string]$OutputTemplate = "",
        [switch]$NoPlaylist,
        [switch]$UseFallbackFormat,
        [string[]]$ExtraArgs = @(),
        [int]$HeightOverride = 0
    )

    # A link whose file is already on disk is skipped without a request. Playlist
    # URLs are left alone: one item's id is not the list.
    if (-not $DryRun -and -not (Test-PlaylistUrl -Url $Url)) {
        $indexedPath = Find-DownloadedMedia -Url $Url -DownloadType $DownloadType
        if ($indexedPath) {
            Show-ProgressUpdate "[=] Already downloaded - skipped" -Type "System"
            return [pscustomobject]@{
                Success   = $true
                Skipped   = $true
                ErrorText = ""
                Kind      = ""
                Digest    = ""
                Warnings  = 0
            }
        }
    }

    # Each item starts a fresh record; a playlist fills it with one line per item.
    if (-not $DryRun -and $script:MoveRecordFile) {
        Remove-Item -LiteralPath $script:MoveRecordFile -Force -ErrorAction SilentlyContinue
    }

    $maxAttempts = [int](Format-InvariantNumber -Value $Settings.outerRetryCount -Default $script:DefaultOuterRetryCount)
    if ($maxAttempts -lt 1) { $maxAttempts = 1 }
    if ($maxAttempts -gt 10) { $maxAttempts = 10 }

    $attempt = 0
    $lastErrorText = ""
    $lastKind = "Other"

    # Files older than this were already on disk before the download started, so
    # they are never treated as the product of this attempt.
    $verifySince = Get-Date

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

        if ($DryRun) {
            # Nothing is spawned and no link is retired: the point is to show exactly
            # what this item would ask yt-dlp for.
            $rendered = (@($ytArgs.ToArray()) | ForEach-Object { ConvertTo-CommandLineArgument -Value ([string]$_) }) -join ' '
            Show-ProgressUpdate "[~] would run: $script:YtDlpBinaryName $rendered" -Type "System"
            return [pscustomobject]@{ Success = $true; ErrorText = ""; Kind = ""; Digest = ""; Warnings = 0; DryRun = $true }
        }

        $attemptResult = Invoke-YtDlpAndCapture -YtDlpArgs $ytArgs.ToArray()
        if ($attemptResult.Success) {
            # "Exit code 0" is not the same as "the file is usable".
            $mediaFailure = Confirm-DownloadedMedia -OutputDir $OutputDir -Since $verifySince -DownloadType $DownloadType -Url $Url -Settings $Settings
            if ($mediaFailure) {
                $lastErrorText = [string]$mediaFailure.ErrorText
                $lastKind = [string]$mediaFailure.Kind
            }
            else {
                Register-BotGuardSuccess
                $warningCount = ([regex]::Matches([string]$attemptResult.ErrorText, '(?m)^\s*WARNING')).Count
                Write-WarningLog -Url $Url -WarningText ([string]$attemptResult.ErrorText) -Count $warningCount -Settings $Settings
                return [pscustomobject]@{
                    Success   = $true
                    Skipped   = [bool]$script:LastItemSkipped
                    ErrorText = [string]$attemptResult.ErrorText
                    Kind      = ""
                    Digest    = ""
                    Warnings  = $warningCount
                }
            }
        }
        else {
            $lastErrorText = [string]$attemptResult.ErrorText
            $lastKind = Get-FailureKind -ErrorText $lastErrorText
        }

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

    # A different selector cannot fix a wall or a login gate, so only try a lower
    # quality when the failure could actually be format-related. Incomplete is
    # excluded too: a broken file is not a format problem, and downloading it
    # again under a different selector would just waste a request.
    $blockingKinds = @("BotCheck", "LoginRequired", "GeoBlocked", "Unavailable", "Incomplete")
    if ($DownloadType -eq "video" -and -not $UseFallbackFormat -and $lastKind -notin $blockingKinds) {
        # Step down before giving up on the video: a 4K request whose 2160p stream is
        # missing should land at 1440p, not silently at whatever "best" happens to be.
        foreach ($rung in (Get-QualityLadder -VideoQuality $Settings.videoQuality -HeightOverride $HeightOverride)) {
            if ($lastKind -in $blockingKinds) { break }
            Show-ProgressUpdate "[~] $($rung)p did not work - retrying at a lower quality..." -Type "Update"
            $rungOutcome = Invoke-YtDlpAttempt -Settings $Settings -DownloadType $DownloadType -OutputDir $OutputDir -Url $Url -OutputTemplate $OutputTemplate -NoPlaylist:$NoPlaylist -HeightOverride $rung -ExtraArgs $ExtraArgs -VerifySince $verifySince
            if ($rungOutcome.Success) { return $rungOutcome }
            $lastErrorText = [string]$rungOutcome.ErrorText
            $lastKind = [string]$rungOutcome.Kind
        }

        if ($lastKind -notin $blockingKinds) {
            Show-ProgressUpdate "[~] Trying fallback format for this video..." -Type "Update"
            $fallbackOutcome = Invoke-YtDlpAttempt -Settings $Settings -DownloadType $DownloadType -OutputDir $OutputDir -Url $Url -OutputTemplate $OutputTemplate -NoPlaylist:$NoPlaylist -UseFallbackFormat -ExtraArgs $ExtraArgs -VerifySince $verifySince
            if ($fallbackOutcome.Success) { return $fallbackOutcome }
            $lastErrorText = [string]$fallbackOutcome.ErrorText
            $lastKind = [string]$fallbackOutcome.Kind
        }
    }

    $finalDigest = Get-ErrorDigest -ErrorText $lastErrorText
    Write-ReaperLog -Settings $Settings -Message "[$lastKind] $Url :: $finalDigest"

    return [pscustomobject]@{
        Success   = $false
        ErrorText = $lastErrorText
        Kind      = $lastKind
        Digest    = $finalDigest
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

# ArgumentList hands every argument to the OS verbatim, which is the only way a
# path containing spaces or quotes survives on Linux (background quotes are not
# re-parsed there the way Windows' command-line rules allow). Windows PowerShell
# 5.1 has no ArgumentList, so it keeps the quoted single-string form.
function Set-ProcessArguments {
    param(
        [System.Diagnostics.ProcessStartInfo]$StartInfo,
        [string[]]$Arguments
    )

    $listProperty = $StartInfo.PSObject.Properties['ArgumentList']
    if ($listProperty) {
        foreach ($argument in @($Arguments)) { [void]$listProperty.Value.Add([string]$argument) }
        return
    }

    $StartInfo.Arguments = (@($Arguments | ForEach-Object { ConvertTo-CommandLineArgument -Value ([string]$_) }) -join ' ')
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
            ErrorText = "ERROR: yt-dlp is missing. Run $script:SetupHint to install the engine."
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:YtDlpPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    Set-ProcessArguments -StartInfo $startInfo -Arguments $YtDlpArgs

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        Register-EngineProcess -Process $process

        # Both pipes must be drained. Leaving stdout inherited looked simpler, but
        # nothing reads it, so a verbose run fills the pipe buffer and deadlocks as
        # soon as the tool itself is piped or redirected (e.g. a scheduled task).
        # stderr is read in the background, stdout is pumped back to the console in
        # chunks, which keeps yt-dlp's carriage-return progress line intact.
        $errorTask = $process.StandardError.ReadToEndAsync()
        $buffer = New-Object char[] 8192
        while ($true) {
            $read = $process.StandardOutput.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            Write-Host (-join $buffer[0..($read - 1)]) -NoNewline
        }

        $errorText = $errorTask.Result
        $process.WaitForExit()
        $exitCode = $process.ExitCode

        return [pscustomobject]@{
            Success   = ($exitCode -eq 0)
            ErrorText = [string]$errorText
        }
    }
    catch {
        return [pscustomobject]@{
            Success   = $false
            ErrorText = "ERROR: could not start yt-dlp: $($_.Exception.Message)"
        }
    }
    finally {
        if ($process) {
            # Only forget the PID once the process really ended. If it is still
            # running, the next launch needs the record to clean it up.
            if ($process.HasExited) { Unregister-EngineProcess -Process $process }
            $process.Dispose()
        }
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

    # CreateNew makes "someone else got here first" atomic. A plain Test-Path
    # followed by Set-Content let two launches in the same second both believe
    # they owned the lock, and both then wrote over each other's PID.
    try {
        $stream = [System.IO.File]::Open($script:LockFilePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$PID)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $stream.Dispose()
        }
        Set-HiddenAttribute -Path $script:LockFilePath
        return $true
    }
    catch [System.IO.IOException] {
        return $false
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

function Get-ComparableProcessPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    try {
        $target = [System.IO.File]::ResolveLinkTarget($Path, $true)
        if ($target) { return $target.FullName }
    }
    catch { }
    try { return [System.IO.Path]::GetFullPath($Path) }
    catch { return $Path }
}

# yt-dlp re-executes itself for some extractors, so a leftover is a process tree,
# not one process. Kill(entireProcessTree) takes the children with it where the
# runtime has that overload; Windows PowerShell 5.1 falls back to a single kill.
function Stop-EngineProcessTree {
    param([int]$ProcessId)
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return }
    try {
        # .NET 5+ (PowerShell 7, so both launchers) kills the whole tree.
        $process.Kill($true)
        return
    }
    catch { }

    # Windows PowerShell 5.1 has no tree overload: kill the process, then the
    # children it left behind (Windows keeps the dead parent id on the child).
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    if (-not $script:IsWindowsPlatform) { return }
    try {
        foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction Stop)) {
            Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}

# Bookkeeping must never break a download, but it must not pretend to work either:
# a record that cannot be written means a crash leaves a yt-dlp nobody can find.
function Show-EngineRecordProblem {
    param([string]$Message)
    if ($script:EnginePidRecordWarned) { return }
    $script:EnginePidRecordWarned = $true
    Show-ProgressUpdate "[!] $Message" -Type "Warning"
}

function Register-EngineProcess {
    param([System.Diagnostics.Process]$Process)
    if (-not $Process) { return }
    try {
        $startedAt = $Process.StartTime.ToUniversalTime().Ticks
        Set-Content -LiteralPath $script:EnginePidRecordFile -Value ("{0} {1}" -f $Process.Id, $startedAt) -Encoding ASCII -ErrorAction Stop
    }
    catch {
        Show-EngineRecordProblem "Could not write the engine PID record ($script:EnginePidRecordFile): $($_.Exception.Message). A leftover yt-dlp from this run will not be cleaned up."
    }
}

function Unregister-EngineProcess {
    param([System.Diagnostics.Process]$Process)
    if (-not $Process -or -not (Test-Path -LiteralPath $script:EnginePidRecordFile)) { return }
    try {
        $fields = ([string](Get-Content -LiteralPath $script:EnginePidRecordFile -Raw -ErrorAction Stop)).Trim() -split '\s+'
        $recordedId = 0
        if ($fields.Count -ge 1 -and [int]::TryParse($fields[0], [ref]$recordedId) -and $recordedId -eq $Process.Id) {
            Remove-Item -LiteralPath $script:EnginePidRecordFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Show-EngineRecordProblem "Could not clear the engine PID record ($script:EnginePidRecordFile): $($_.Exception.Message). The next run may report a leftover that no longer exists."
    }
}

# The record names the exact process this tool started, and its start time makes a
# recycled PID safe to ignore. Works the same on Windows and Linux.
# Every branch that cannot act says why: on Linux the process API is the runtime's,
# so a silent failure here would be a silent failure of the whole sweep.
function Stop-RecordedEngineProcess {
    param([string]$RecordFile = $script:EnginePidRecordFile)
    if (-not $RecordFile -or -not (Test-Path -LiteralPath $RecordFile)) { return }

    $record = ""
    try { $record = [string](Get-Content -LiteralPath $RecordFile -Raw -ErrorAction Stop) }
    catch {
        Show-EngineRecordProblem "Could not read the engine PID record ($RecordFile): $($_.Exception.Message). A leftover yt-dlp cannot be cleaned up."
        return
    }

    $fields = $record.Trim() -split '\s+'
    $recordedId = 0
    $recordedStart = [long]0
    $validRecord = ($fields.Count -ge 1) -and [int]::TryParse($fields[0], [ref]$recordedId) -and $recordedId -gt 0
    if (-not $validRecord) {
        Show-EngineRecordProblem "Engine PID record ($RecordFile) is not a '<pid> <start>' pair, so a leftover yt-dlp cannot be identified. Deleting it."
        Remove-Item -LiteralPath $RecordFile -Force -ErrorAction SilentlyContinue
        return
    }
    if ($fields.Count -ge 2) { [void][long]::TryParse($fields[1], [ref]$recordedStart) }

    $candidate = Get-Process -Id $recordedId -ErrorAction SilentlyContinue
    if (-not $candidate) {
        # The record outlived a process that already finished: nothing to stop.
        Remove-Item -LiteralPath $RecordFile -Force -ErrorAction SilentlyContinue
        return
    }

    $sameProcess = $true
    if ($recordedStart -gt 0) {
        try {
            $drift = [Math]::Abs($candidate.StartTime.ToUniversalTime().Ticks - $recordedStart)
            $sameProcess = $drift -lt [TimeSpan]::FromSeconds(2).Ticks
        }
        catch {
            Show-EngineRecordProblem "Cannot read the start time of pid $recordedId on this system, so a recycled PID cannot be ruled out and the recorded yt-dlp is left alone."
            Remove-Item -LiteralPath $RecordFile -Force -ErrorAction SilentlyContinue
            return
        }
    }

    if (-not $sameProcess) {
        Show-ProgressUpdate "[~] Engine PID record names pid $recordedId, but that is a different process now (recycled PID) - ignoring." -Type "System"
        Remove-Item -LiteralPath $RecordFile -Force -ErrorAction SilentlyContinue
        return
    }

    # Even with a matching record, only this install's engine binary is fair game.
    $candidatePath = ""
    try { $candidatePath = [string]$candidate.Path } catch { }
    $enginePath = Get-ComparableProcessPath -Path $script:YtDlpPath
    if ($candidatePath -and (Get-ComparableProcessPath -Path $candidatePath) -ne $enginePath) {
        Show-EngineRecordProblem "Recorded pid $recordedId is '$candidatePath', not this install's engine - leaving it alone."
        Remove-Item -LiteralPath $RecordFile -Force -ErrorAction SilentlyContinue
        return
    }

    Stop-EngineProcessTree -ProcessId $candidate.Id
    Start-Sleep -Milliseconds 300
    if (Get-Process -Id $candidate.Id -ErrorAction SilentlyContinue) {
        Show-ProgressUpdate "[!] A leftover yt-dlp (pid $($candidate.Id)) refused to stop - stop it by hand before the next download." -Type "Warning"
    }
    else {
        Show-ProgressUpdate "[~] Stopped a leftover yt-dlp (pid $($candidate.Id)) from an earlier run." -Type "Warning"
    }

    Remove-Item -LiteralPath $RecordFile -Force -ErrorAction SilentlyContinue
}

# Closing the window or killing a run leaves the engine's yt-dlp behind. The next
# run then downloads the same video through a second yt-dlp into the same .part
# file, which doubles the traffic and can corrupt the merge.
#
# Two detectors: the PID record above (every platform, including the Linux
# launcher where an orphan is reparented to init), and the Windows sweep below,
# which also finds engine processes the record never saw. Both run while the
# session lock is held, so anything they find is a leftover.
function Stop-OrphanedEngineProcesses {
    Stop-RecordedEngineProcess

    if (-not $script:IsWindowsPlatform) { return }
    try {
        $engineName = [System.IO.Path]::GetFileName($script:YtDlpPath)
        $candidates = @(Get-CimInstance Win32_Process -Filter "Name='$engineName'" -ErrorAction Stop)
    }
    catch {
        # WMI unavailable: never block a download over diagnostics.
        return
    }

    foreach ($candidate in $candidates) {
        if ($candidate.ProcessId -eq $PID) { continue }
        # Another install, or a download whose run is still alive, is not ours to touch.
        if (-not $candidate.ExecutablePath -or $candidate.ExecutablePath -ne $script:YtDlpPath) { continue }
        if (Get-Process -Id $candidate.ParentProcessId -ErrorAction SilentlyContinue) { continue }
        Stop-Process -Id $candidate.ProcessId -Force -ErrorAction SilentlyContinue
        Show-ProgressUpdate "[~] Stopped a leftover yt-dlp (pid $($candidate.ProcessId)) from an earlier run." -Type "Warning"
    }
}

# Metadata probes need stdout, which Invoke-YtDlpAndCapture deliberately leaves
# on the console. Merging the two streams with 2>&1 used to feed a lone warning
# straight into ConvertFrom-Json and fail the whole probe.
function Invoke-YtDlpCaptureOutput {
    param([string[]]$YtDlpArgs)

    if (-not (Test-Path $script:YtDlpPath)) {
        return [pscustomobject]@{ Success = $false; StdOut = ""; StdErr = "ERROR: yt-dlp is missing." }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:YtDlpPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    Set-ProcessArguments -StartInfo $startInfo -Arguments $YtDlpArgs

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        Register-EngineProcess -Process $process
        # One stream is read asynchronously so a full pipe cannot deadlock the child.
        $errorTask = $process.StandardError.ReadToEndAsync()
        $stdOut = $process.StandardOutput.ReadToEnd()
        $stdErr = $errorTask.Result
        $process.WaitForExit()

        return [pscustomobject]@{
            Success = ($process.ExitCode -eq 0)
            StdOut  = [string]$stdOut
            StdErr  = [string]$stdErr
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; StdOut = ""; StdErr = "ERROR: could not start yt-dlp: $($_.Exception.Message)" }
    }
    finally {
        if ($process) {
            if ($process.HasExited) { Unregister-EngineProcess -Process $process }
            $process.Dispose()
        }
    }
}

# A crashed run (or a closed window) leaves engine/reaper.lock behind, so the lock
# has to be validated before it is trusted. "Is that PID alive" is NOT enough:
# Windows recycles PIDs, and a recycled number belonging to some unrelated app used
# to look like a running instance and block every launch.
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
    if ($null -eq $owner) { return $true }

    $lockWritten = $null
    try {
        $lockWritten = (Get-Item $script:LockFilePath -Force).LastWriteTime
    }
    catch {
        $lockWritten = $null
    }

    if ($null -ne $lockWritten) {
        try {
            # The real owner was already running when it wrote the lock. A process
            # that started afterwards cannot be it - that is a recycled PID.
            if ($owner.StartTime -gt $lockWritten.AddSeconds(10)) { return $true }
            return $false
        }
        catch {
            # StartTime can be unreadable for protected processes; fall through to age.
        }
    }

    # Last resort: never let an abandoned lock block forever.
    if ($null -ne $lockWritten) {
        $age = (Get-Date) - $lockWritten
        if ($age.TotalHours -gt 12) { return $true }
    }
    return $false
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
            Write-Host ""
            Show-ProgressUpdate "[!] Invalid command. Use 1 or 2." -Type "Warning"
        }
    }

    if ($inputMethod -eq "1") {
        $url = ""
        while ([string]::IsNullOrWhiteSpace($url)) {
            Write-Host ">> Enter Target URL (Video or Playlist): " -ForegroundColor "Yellow"
            $url = [string](Read-Host)
            # Upgrade a scheme-less paste, but keep anything else as typed so
            # yt-dlp's own pseudo-URLs (ytsearch:) still work.
            $normalizedUrl = ConvertTo-DownloadUrl -Text $url
            if ($normalizedUrl) { $url = $normalizedUrl } else { $url = $url.Trim() }
            if ([string]::IsNullOrWhiteSpace($url)) { 
                Write-Host ""
                Show-ProgressUpdate "[!] Target URL cannot be empty." -Type "Warning"
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
                Write-Host ""
                Show-ProgressUpdate "[!] File path cannot be empty." -Type "Warning"
            }
            elseif (-not (Test-Path $filePath)) {
                Write-Host ""
                Show-ProgressUpdate "[!] File not found: $filePath" -Type "Warning"
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
            Success  = 0
            Failure  = 0
            Failures = @()
            Bytes    = 0
        }
    }

    Ensure-Directory -Path $OutputDir

    $allLines = @(Get-Content $FilePath)
    $linkEntries = @()

    foreach ($line in $allLines) {
        # The line stays exactly as written for the removal step; only the
        # download gets the normalised URL.
        $downloadUrl = ConvertTo-DownloadUrl -Text $line
        if ($downloadUrl) {
            $linkEntries += [pscustomobject]@{
                OriginalUrl = Remove-InvisibleCharacters -Text $line
                DownloadUrl = $downloadUrl
            }
        }
    }

    if ($linkEntries.Count -eq 0) {
        Show-ProgressUpdate "[!] No valid URLs in $FilePath" -Type "Warning"
        return [pscustomobject]@{
            Success  = 0
            Failure  = 0
            Failures = @()
            Bytes    = 0
        }
    }

    $quality = if ($DownloadType -eq "video") { $Settings.videoQuality } else { "" }
    Show-DownloadBanner -TypeLabel $DownloadType.ToUpper() -Mode "BATCH" -TargetCount $linkEntries.Count -OutputDir $OutputDir -Quality $quality

    $successCount = 0
    $failureCount = 0
    $skippedCount = 0
    $targetNum = 0
    $failures = @()
    $startedAt = Get-Date

    foreach ($entry in $linkEntries) {
        $urlToUse = $entry.DownloadUrl
        $targetNum++
        try {
            Show-ItemStart -Index $targetNum -Total $linkEntries.Count -Label $urlToUse
            $itemStart = Get-Date
            
            $downloadResult = Invoke-YtDlpForUrl -Settings $Settings -DownloadType $DownloadType -OutputDir $OutputDir -Url $urlToUse
            $itemElapsed = Format-Elapsed -Span ((Get-Date) - $itemStart)
            if ($downloadResult.Success) {
                if ($downloadResult.Skipped) {
                    $skippedCount++
                    Show-ItemResult -Status "ok" -Elapsed $itemElapsed -Detail "already on disk - skipped"
                }
                else {
                    $successCount++
                    if ($DryRun) {
                        Show-ItemResult -Status "ok" -Elapsed $itemElapsed -Detail "dry run - link stays queued"
                    }
                    else {
                        Show-ItemResult -Status "ok" -Elapsed $itemElapsed -Warnings $downloadResult.Warnings
                    }
                }
                # Unhook the link the moment it lands. Waiting for the end of the
                # file meant an interrupted, or a multi-hour, run left finished
                # links queued in audioLinks.txt / videoLinks.txt.
                Remove-SuccessfulLinks -FilePath $FilePath -SuccessUrls @($entry.OriginalUrl)
            }
            else {
                $friendly = Get-FriendlyErrorHint -ErrorText $downloadResult.ErrorText -Kind $downloadResult.Kind
                $failureCount++
                $failures += ("$urlToUse - $friendly")
                Show-ItemResult -Status "fail" -Elapsed $itemElapsed -Detail $friendly
            }

        }
        catch {
            $failureCount++
            $failures += ("$urlToUse - " + $_.Exception.Message)
            Show-ItemResult -Status "fail" -Detail $_.Exception.Message
        }
        Write-Host ""
    }

    return [pscustomobject]@{
        Success  = $successCount
        Failure  = $failureCount
        Skipped  = $skippedCount
        Failures = $failures
        Bytes    = (Get-RecentFileBytes -Path $OutputDir -Since $startedAt)
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
    if (-not $FilePath -or -not (Test-Path -LiteralPath $FilePath) -or -not $SuccessUrls -or $SuccessUrls.Count -eq 0) { return }
    # A dry run must leave every queue exactly as it found it.
    if ($DryRun) { return }
    # Read raw and write UTF-8 so a link file with non-ASCII comments survives the
    # rewrite instead of coming back as ANSI mojibake. LiteralPath because a
    # user-chosen folder such as "Downloads [old]" would otherwise be a wildcard.
    $allLines = @([string](Get-Content -LiteralPath $FilePath -Raw) -split "`r?`n")
    $linesOut = New-Object System.Collections.Generic.List[string]
    foreach ($line in $allLines) {
        if (Test-ValidUrl -Line $line) {
            if (-not (Test-UrlMatchesLine -Line $line -Urls $SuccessUrls)) {
                $linesOut.Add($line)
            }
        }
        else {
            $linesOut.Add($line)
        }
    }
    try {
        Set-Content -LiteralPath $FilePath -Value $linesOut.ToArray() -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # A link file held open by an editor used to abort the run here, after the
        # downloads had already happened. Warn instead of dying.
        Show-ProgressUpdate "[!] Could not remove finished link(s) from $FilePath - $($_.Exception.Message)" -Type "Warning"
    }
}

function Show-MissionSummary {
    param(
        [int]$SuccessCount,
        [int]$FailureCount,
        [int]$SkippedCount = 0,
        [string]$OutputDir,
        [string[]]$Failures = @(),
        [double]$TotalBytes = 0,
        [TimeSpan]$Elapsed = [TimeSpan]::Zero
    )

    Write-Host ""
    Write-Rule
    Write-Host "   MISSION SUMMARY" -ForegroundColor Cyan
    Write-Rule

    if ($DryRun) {
        Write-Host "   mode       dry run (nothing downloaded, links untouched)" -ForegroundColor Yellow
    }

    if ($DryRun) {
        Write-Host ("   would fetch " + $SuccessCount) -ForegroundColor "Yellow"
    }
    else {
        Write-Host ("   acquired   " + $SuccessCount) -ForegroundColor $(if ($SuccessCount -gt 0) { "Green" } else { "DarkGray" })
    }
    Write-Host ("   missed     " + $FailureCount) -ForegroundColor $(if ($FailureCount -gt 0) { "Red" } else { "DarkGray" })
    if ($SkippedCount -gt 0) {
        Write-Host ("   skipped    " + $SkippedCount) -ForegroundColor "DarkGray"
    }
    if ($TotalBytes -gt 0) {
        Write-Host ("   size       " + (Format-FileSize -Bytes $TotalBytes)) -ForegroundColor Gray
    }
    if ($Elapsed.TotalSeconds -gt 0) {
        Write-Host ("   elapsed    " + (Format-Elapsed -Span $Elapsed)) -ForegroundColor Gray
    }
    Write-Host ("   output     " + $OutputDir) -ForegroundColor Gray

    if ($Failures.Count -gt 0) {
        Write-Rule
        foreach ($entry in ($Failures | Select-Object -First 5)) {
            Write-Host ("   ! " + $entry) -ForegroundColor Yellow
        }
        if ($Failures.Count -gt 5) {
            Write-Host ("   ! ...and " + ($Failures.Count - 5) + " more in $script:LogDisplayPath") -ForegroundColor DarkGray
        }
    }

    Write-Rule
    Write-Host ""

    # A skip is a finished item: the file is already on disk, so nothing failed.
    if ($SuccessCount -gt 0 -or $SkippedCount -gt 0) {
        Show-CompletionBanner
    }
    elseif ($FailureCount -gt 0) {
        Show-ProgressUpdate "[!] All downloads failed." -Type "Error"
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
    $script:LastRunFailures = 0
    $batchSuccess = 0
    $batchFailure = 0
    $batchSkipped = 0
    $batchFailures = @()
    $batchBytes = 0
    $startedAt = Get-Date

    $audioDir = Get-OutputDirForType -Settings $Settings -DownloadType "audio"
    $videoDir = Get-OutputDirForType -Settings $Settings -DownloadType "video"
    Ensure-Directory -Path $audioDir
    Ensure-Directory -Path $videoDir

    if (Test-Path $script:AudioLinksFile) {
        $audioResult = Process-LinkFile -FilePath $script:AudioLinksFile -Settings $Settings -DownloadType "audio" -OutputDir $audioDir
        $batchSuccess += $audioResult.Success
        $batchFailure += $audioResult.Failure
        $batchSkipped += $audioResult.Skipped
        $batchFailures += $audioResult.Failures
        $batchBytes += $audioResult.Bytes
    }

    if (Test-Path $script:VideoLinksFile) {
        $videoResult = Process-LinkFile -FilePath $script:VideoLinksFile -Settings $Settings -DownloadType "video" -OutputDir $videoDir
        $batchSuccess += $videoResult.Success
        $batchFailure += $videoResult.Failure
        $batchSkipped += $videoResult.Skipped
        $batchFailures += $videoResult.Failures
        $batchBytes += $videoResult.Bytes
    }

    $summaryDir = Get-BaseOutputDir -Settings $Settings
    Show-MissionSummary -SuccessCount $batchSuccess -FailureCount $batchFailure -SkippedCount $batchSkipped -OutputDir $summaryDir `
        -Failures $batchFailures -TotalBytes $batchBytes -Elapsed ((Get-Date) - $startedAt)

    # Scheduled runs report into a hidden window, so leave one line behind that
    # says whether last night's pass actually did anything.
    Write-RunState -Settings $Settings -Mode "batch" -SuccessCount $batchSuccess -FailureCount $batchFailure -SkippedCount $batchSkipped `
        -Failures $batchFailures -TotalBytes $batchBytes -Elapsed ((Get-Date) - $startedAt) -OutputDir $summaryDir
    Write-ReaperLog -Settings $Settings -Message "batch run: $batchSuccess ok, $batchSkipped skipped, $batchFailure failed"
    $script:LastRunFailures = $batchFailure
}

function Run-InteractiveMode {
    param(
        [hashtable]$Settings,
        [switch]$ForceOneClick
    )

    # Only a file-based run has a link file to clean up afterwards. Without this
    # reset, a URL typed in a later menu round could be removed from whichever
    # file the previous round happened to use.
    $script:SourceFile = ""
    $script:LastRunFailures = 0

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
            Write-Host "Paste a media link and press Enter." -ForegroundColor Yellow
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
                    $urls = @(Get-UrlsFromFile -FilePath $filePath | Where-Object { $_ })
                    continue
                }
                default {
                    $urls = @($quickInput)
                }
            }
        }
    }
    else {
        $urls = @(Get-UrlsSmartMode | Where-Object { $_ })
    }

    # One normalisation point for every input path, so the playlist check, the
    # download and the post-run cleanup all agree on the same URL. Anything that
    # is not link-shaped is passed through untouched (ytsearch:/similar input).
    $urls = @(foreach ($candidate in $urls) {
        $candidateText = [string]$candidate
        if ([string]::IsNullOrWhiteSpace($candidateText)) { continue }
        $normalizedCandidate = ConvertTo-DownloadUrl -Text $candidateText
        if ($normalizedCandidate) { $normalizedCandidate } else { $candidateText.Trim() }
    })
    
    if ($urls.Count -eq 0) {
        Show-ProgressUpdate "[!] No valid URLs found." -Type "Error"
        if (-not $Silent) { Read-Host "Press Enter to exit..." }
        exit 1
    }
    
    Show-ProgressUpdate "Loaded $($urls.Count) target(s) for processing" -Type "Success"

    # --- Ask user: audio or video ---
    # A pasted link now asks too, so one link can go straight to audio or video
    # without editing a link file first. Enter keeps the configured default, so
    # one-click runs still take one keystroke.
    $defaultType = if ($Settings.defaultDownloadType -eq "audio") { "2" } else { "1" }
    $downloadType = if ($Silent) { $defaultType } else { "" }
    if (-not $Silent) {
        $typeOptions = @("1=Video, 2=Audio Only")
        while ($downloadType -notin @("1", "2")) {
            Show-MenuOption -Prompt "Select Download Type" -Options $typeOptions
            $typeChoice = ([string](Read-Host)).Trim()
            if ([string]::IsNullOrWhiteSpace($typeChoice)) {
                $downloadType = $defaultType
            }
            elseif ($typeChoice -in @("1", "2")) {
                $downloadType = $typeChoice
            }
            else {
                Write-Host ""
                Show-ProgressUpdate "[!] Invalid choice. Enter 1 for Video or 2 for Audio." -Type "Warning"
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
                Show-MissionSummary -SuccessCount $plResult.Success -FailureCount $plResult.Failure -OutputDir $plResult.OutputDir
                Write-RunState -Settings $Settings -Mode "playlist" -SuccessCount $plResult.Success -FailureCount $plResult.Failure -OutputDir $plResult.OutputDir
                Write-ReaperLog -Settings $Settings -Message "playlist run: $($plResult.Success) ok, $($plResult.Failure) failed :: $($plResult.OutputDir)"
                $script:LastRunFailures = $plResult.Failure
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
    $skippedCount = 0
    $failures = @()
    $targetNum = 0
    $startedAt = Get-Date

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
                    if ($plResult.Failure -eq 0 -and $plResult.Success -gt 0) {
                        Remove-SuccessfulLinks -FilePath $script:SourceFile -SuccessUrls @($url)
                    }
                    continue
                }
            }
        }

        try {
            Show-ItemStart -Index $targetNum -Total $urls.Count -Label $url
            $itemStart = Get-Date

            $downloadResult = if ($forceNoPlaylistUrls.ContainsKey($url)) {
                Invoke-YtDlpForUrl -Settings $Settings -DownloadType $resolvedType -OutputDir $outputDir -Url $url -NoPlaylist
            }
            else {
                Invoke-YtDlpForUrl -Settings $Settings -DownloadType $resolvedType -OutputDir $outputDir -Url $url
            }
            $itemElapsed = Format-Elapsed -Span ((Get-Date) - $itemStart)
            if ($downloadResult.Success) {
                if ($downloadResult.Skipped) {
                    $skippedCount++
                    Show-ItemResult -Status "ok" -Elapsed $itemElapsed -Detail "already on disk - skipped"
                }
                else {
                    $successCount++
                    if ($DryRun) {
                        Show-ItemResult -Status "ok" -Elapsed $itemElapsed -Detail "dry run - link stays queued"
                    }
                    else {
                        Show-ItemResult -Status "ok" -Elapsed $itemElapsed -Warnings $downloadResult.Warnings
                    }
                }
                # Retire the link as soon as it finishes, not at the end of the run:
                # a stopped run should never keep links that already downloaded.
                Remove-SuccessfulLinks -FilePath $script:SourceFile -SuccessUrls @($url)
            }
            else {
                $friendly = Get-FriendlyErrorHint -ErrorText $downloadResult.ErrorText -Kind $downloadResult.Kind
                $failureCount++
                $failures += ("$url - $friendly")
                Show-ItemResult -Status "fail" -Elapsed $itemElapsed -Detail $friendly
            }
            
        }
        catch {
            $failureCount++
            $failures += ("$url - " + $_.Exception.Message)
            Show-ItemResult -Status "fail" -Detail $_.Exception.Message
        }
        Write-Host ""
    }

    Show-MissionSummary -SuccessCount $successCount -FailureCount $failureCount -SkippedCount $skippedCount -OutputDir $outputDir `
        -Failures $failures -TotalBytes (Get-RecentFileBytes -Path $outputDir -Since $startedAt) -Elapsed ((Get-Date) - $startedAt)

    Write-RunState -Settings $Settings -Mode "interactive" -SuccessCount $successCount -FailureCount $failureCount -SkippedCount $skippedCount `
        -Failures $failures -TotalBytes (Get-RecentFileBytes -Path $outputDir -Since $startedAt) -Elapsed ((Get-Date) - $startedAt) -OutputDir $outputDir
    Write-ReaperLog -Settings $Settings -Message "run: $successCount ok, $skippedCount skipped, $failureCount failed :: $outputDir"
    $script:LastRunFailures = $failureCount
}

function Show-ExitPrompt {
    param(
        [int]$FailureCount = 0,
        [int]$TimeoutSeconds = -1
    )

    # "Run again" only earns its place when the last run left work behind: it
    # retries the links that are still queued (or the explicit -LinksFile) as a
    # batch, which "Download another item" cannot do. After a clean run it did
    # exactly the same thing as option 3, so offering both was a duplicate.
    $leftQueued = if ($LinksFile -or $ConfigFile) { $true } else { Should-RunBatchMode }
    $offerRetry = ($FailureCount -gt 0) -and $leftQueued

    $options = @(
        @{ Key = "close"; Label = "Close terminal" }
    )
    if ($offerRetry) {
        $options += @{ Key = "retry"; Label = "Run again (retry the queued links)" }
    }
    $options += @{ Key = "quick"; Label = "Download another item" }

    # A clean run has nothing to retry, so an untouched window should close itself
    # instead of waiting forever; a run with work left should pick the useful option.
    $cleanRun = ($FailureCount -le 0)
    $autoKey = if ($cleanRun) { "close" } elseif ($offerRetry) { "retry" } else { "quick" }
    # -1 means "use the default wait": 60s after a clean run, 30s when work is left.
    # 0 answers immediately without reading keys (tests and non-console hosts).
    if ($TimeoutSeconds -lt 0) { $TimeoutSeconds = if ($cleanRun) { 60 } else { 30 } }
    $timedInput = ($TimeoutSeconds -gt 0) -and
        ($script:ExitPromptAutoContinue -ne $false) -and
        -not [Console]::IsInputRedirected

    while ($true) {
        Write-Host ""
        Write-Host "What do you want to do next?" -ForegroundColor Yellow
        for ($i = 0; $i -lt $options.Count; $i++) {
            Write-Host (("{0}) {1}" -f ($i + 1), $options[$i].Label)) -ForegroundColor White
        }

        if ($timedInput) {
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            $picked = $null
            while (-not $picked -and (Get-Date) -lt $deadline) {
                if ([Console]::KeyAvailable) {
                    $pressed = [Console]::ReadKey($true)
                    $index = 0
                    if ([int]::TryParse([string]$pressed.KeyChar, [ref]$index) -and $index -ge 1 -and $index -le $options.Count) {
                        $picked = $options[$index - 1].Key
                    }
                    elseif ($pressed.Key -eq [ConsoleKey]::Escape) {
                        $picked = "close"
                    }
                }
                if (-not $picked) {
                    Start-Sleep -Milliseconds 250
                }
            }
            if (-not $picked) { $picked = $autoKey }
            Write-Host ""
            return $picked
        }

        if ($TimeoutSeconds -le 0) { return $autoKey }

        $choice = Read-Host ("Choose (1-{0})" -f $options.Count)
        $index = 0
        if ([int]::TryParse(([string]$choice).Trim(), [ref]$index) -and $index -ge 1 -and $index -le $options.Count) {
            return $options[$index - 1].Key
        }
        Show-ProgressUpdate ("[!] Invalid choice. Enter 1-{0}." -f $options.Count) -Type "Warning"
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

# Clear-Host throws "The handle is invalid" when stdout is a pipe or a file (cron,
# CI, a scheduled task, or simply piping the output), which killed the whole run
# before it started. Clearing the screen is cosmetic, so it must never be fatal.
function Clear-Console {
    try {
        if (-not [Console]::IsOutputRedirected) { Clear-Host }
    }
    catch {
        # No console to clear - keep going.
    }
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
            Write-DoctorLine "FAIL" $binary.Name "missing - run $script:SetupHint"
            $failures++
            $engineReady = $false
            continue
        }
        $item = Get-Item $binary.Path -Force -ErrorAction SilentlyContinue
        if (-not $item -or $item.Length -eq 0) {
            Write-DoctorLine "FAIL" $binary.Name "file is empty - re-run $script:SetupHint"
            $failures++
            $engineReady = $false
            continue
        }
        Write-DoctorLine "OK" $binary.Name ("{0:N1} MB" -f ($item.Length / 1MB))
    }

    if (-not $engineReady) {
        Write-Host ""
        Write-Host "  Engine is incomplete - skipping the checks that need it." -ForegroundColor Yellow
        Write-Host "  Run $script:SetupHint, then try again." -ForegroundColor Yellow
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
        Set-Content -LiteralPath $probeFile -Value "ok" -ErrorAction Stop
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
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
    $probeArgs = @(Get-StealthArgs -Settings $Settings) + @("--skip-download", "--socket-timeout", "20", "--print", "%(id)s", $probeUrl)
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

    # --- leftover yt-dlp cleanup ---
    # The sweep needs two things: a record it can write, and process start times it
    # can read. Neither comes from WMI on Linux, so this check is how a Linux user
    # confirms the sweep can do its job there instead of failing silently.
    if (Test-Path -LiteralPath $script:EnginePidRecordFile) {
        $pending = ([string](Get-Content -LiteralPath $script:EnginePidRecordFile -Raw -ErrorAction SilentlyContinue)).Trim()
        Write-DoctorLine "WARN" "pid record" "a leftover may be pending ('$pending') - the next run stops it"
        $warnings++
    }

    $recordProbeError = ""
    try {
        $selfStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
        Set-Content -LiteralPath $script:EnginePidRecordFile -Value ("{0} {1}" -f $PID, $selfStart) -Encoding ASCII -ErrorAction Stop
        Remove-Item -LiteralPath $script:EnginePidRecordFile -Force -ErrorAction Stop
    }
    catch {
        $recordProbeError = $_.Exception.Message
    }

    $startTimeError = ""
    try { $null = (Get-Process -Id $PID).StartTime }
    catch { $startTimeError = $_.Exception.Message }

    if ($recordProbeError) {
        Write-DoctorLine "FAIL" "leftover sweep" "cannot write $($script:EnginePidRecordFile) - $recordProbeError"
        $failures++
    }
    elseif ($startTimeError) {
        Write-DoctorLine "FAIL" "leftover sweep" "cannot read process start times - $startTimeError"
        $failures++
    }
    else {
        Write-DoctorLine "OK" "leftover sweep" "pid record and process start times available"
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
    Clear-Console

    # -Rollback swaps the kept yt-dlp build back in and exits. It touches nothing
    # else, so it works even when the current binary is too broken to update.
    if ($Rollback) {
        exit ([int](Restore-YtDlpBackup))
    }

    # -Status reports the last completed run and touches nothing else, so it works
    # before the engine is installed and from a cron job that already failed.
    if ($Status) {
        exit ([int](Show-LastRunStatus))
    }

    # /doctor is a diagnostic pass, not a run: no install, no lock, no download.
    if ($Doctor) {
        $doctorSettings = Load-Settings -ConfigPath $ConfigFile
        Reset-BotGuard -Settings $doctorSettings
        $doctorExit = [int](Invoke-Doctor -Settings $doctorSettings)
        exit $doctorExit
    }

    Show-StartupSequence

    if (-not (Initialize-DigitalReaper)) {
        Show-ProgressUpdate "[!] DIGITAL REAPER initialization failed" -Type "Error"
        if (-not $Silent) { Read-Host "Press Enter to exit..." }
        exit 1
    }

    if ($SetupOnly) {
        Show-ProgressUpdate "[+] Setup complete. You can now run Digital Reaper." -Type "Success"
        exit 0
    }

    $settings = Load-Settings -ConfigPath $ConfigFile
    $settings = Apply-CliOverrides -Settings $settings
    Reset-BotGuard -Settings $settings

    # One session lock for every mode (batch, interactive, scheduled).
    if (-not (Enter-ReaperLock)) {
        $holder = ""
        try { $holder = ([string](Get-Content $script:LockFilePath -Raw -ErrorAction SilentlyContinue)).Trim() } catch { }
        Show-ProgressUpdate "[!] Another instance is already running (pid $holder). Exiting." -Type "Warning"
        Show-ProgressUpdate "    If no other window is open, delete $script:LockDisplayPath and start again." -Type "Warning"
        if (-not $Silent) { Read-Host "Press Enter to exit..." }
        exit 1
    }
    
    # Clear leftovers before anything spawns, so two yt-dlp processes never fight
    # over the same output file.
    Stop-OrphanedEngineProcesses

    # A dry run downloads nothing, so it should not spend time replacing the engine
    # either.
    if ($settings.autoUpdate -and -not $DryRun) {
        Update-YtDlpSilent
    }

    $nextMode = "auto"
    $shouldExit = $false
    $freshAttempt = $false
    while (-not $shouldExit) {
        # A run started from the end-of-run menu gets what a relaunch gives it: a
        # clean bot-guard (default player-client order, no cautious sleeps, no
        # cooldown), no leftover yt-dlp, and a pending engine update. Runs used to
        # inherit the exhausted state of the previous one, which pinned the last
        # fallback client and kept failing until the window was closed.
        if ($freshAttempt) {
            Reset-BotGuard -Settings $settings
            Stop-OrphanedEngineProcesses
            if ($settings.autoUpdate -and -not $DryRun) { Update-YtDlpSilent }
        }

        $runDirs = @(
            (Get-OutputDirForType -Settings $settings -DownloadType "audio"),
            (Get-OutputDirForType -Settings $settings -DownloadType "video")
        )
        $pendingParts = Get-PartFileReport -Path $runDirs
        if ($pendingParts.Count -gt 0) {
            Show-ProgressUpdate ("[~] {0} interrupted download(s) on disk ({1}) - resuming those still queued." -f $pendingParts.Count, (Format-FileSize -Bytes ([double]$pendingParts.Bytes))) -Type "Update"
        }

        if ($nextMode -eq "quick") {
            Run-InteractiveMode -Settings $settings -ForceOneClick
        }
        elseif (Should-RunBatchMode) {
            Run-BatchMode -Settings $settings
        }
        else {
            Run-InteractiveMode -Settings $settings
        }

        # A .part still sitting there means an item did not finish; saying so is
        # the difference between "resumed later" and "silently lost".
        $leftParts = Get-PartFileReport -Path $runDirs
        if ($leftParts.Count -gt 0) {
            Show-ProgressUpdate ("[!] {0} interrupted download(s) still pending - they resume on the next run." -f $leftParts.Count) -Type "Warning"
        }

        if ($Silent) { break }

        $postAction = Show-ExitPrompt -FailureCount $script:LastRunFailures
        switch ($postAction) {
            "close" { $shouldExit = $true }
            "retry" { $nextMode = "auto"; $freshAttempt = $true }
            "quick" { $nextMode = "quick"; $freshAttempt = $true }
        }
    }

}
catch {
    Write-Host "`n[!] CRITICAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace:" -ForegroundColor DarkRed
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    # A scheduled or cron run has nobody reading the window, so the failure has to
    # reach the caller as an exit code.
    exit 1
}
finally {
    Exit-ReaperLock
}

if (-not $Silent) {
    Write-Host "`n>> DIGITAL REAPER session ended." -ForegroundColor Yellow
}
