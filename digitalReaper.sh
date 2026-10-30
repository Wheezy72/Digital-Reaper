#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER_PS1="$SCRIPT_DIR/digitalReaper.ps1"

if [[ ! -f "$REAPER_PS1" ]]; then
  echo "[!] digitalReaper.ps1 not found next to this launcher."
  exit 1
fi

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[!] PowerShell (pwsh) is not installed."
  echo "    Install PowerShell 7+ and re-run this script."
  echo "    Docs: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux"
  exit 1
fi

# /doctor runs the diagnostics pass and keeps the window readable afterwards
if [[ "${1:-}" == "/doctor" || "${1:-}" == "--doctor" ]]; then
  status=0
  pwsh -NoProfile -File "$REAPER_PS1" -Doctor || status=$?
  read -r -p "Press Enter to close..." _
  exit "$status"
fi

if [[ $# -gt 0 ]]; then
  target="$1"
  echo "[+] Processing dropped file: $target"
  case "$target" in
    *.json)
      echo "[+] Detected manifest/config file..."
      exec pwsh -NoProfile -File "$REAPER_PS1" -ConfigFile "$target"
      ;;
    *)
      exec pwsh -NoProfile -File "$REAPER_PS1" -LinksFile "$target"
      ;;
  esac
fi

echo "[+] Starting DIGITAL REAPER in interactive mode..."
exec pwsh -NoProfile -File "$REAPER_PS1"
