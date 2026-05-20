param(
    [switch]$Silent
)

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "digitalReaper.ps1"
if (-not (Test-Path $scriptPath)) {
    Write-Error "digitalReaper.ps1 was not found in $PSScriptRoot"
    exit 1
}

$hostExe = if ($PSVersionTable.PSEdition -eq "Core") {
    (Get-Command pwsh -ErrorAction Stop).Source
} else {
    (Get-Command powershell -ErrorAction Stop).Source
}

$setupArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $scriptPath,
    "-SetupOnly"
)
if ($Silent) {
    $setupArgs += "-Silent"
}

& $hostExe @setupArgs
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    Write-Error "DIGITAL REAPER setup failed with exit code $exitCode."
    exit $exitCode
}

Write-Host "[+] DIGITAL REAPER setup completed successfully." -ForegroundColor Green
exit 0
