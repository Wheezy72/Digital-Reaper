param(
    [switch]$Silent
)

$scriptPath = Join-Path $PSScriptRoot "digitalReaper.ps1"
if (-not (Test-Path $scriptPath)) {
    Write-Error "digitalReaper.ps1 was not found in $PSScriptRoot"
    exit 1
}

& $scriptPath -SetupOnly -Silent:$Silent
exit $LASTEXITCODE
