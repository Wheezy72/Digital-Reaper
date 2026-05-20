#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_PS1="$SCRIPT_DIR/setup.ps1"

if [[ ! -f "$SETUP_PS1" ]]; then
  echo "[!] setup.ps1 not found."
  exit 1
fi

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[!] PowerShell (pwsh) is not installed."
  echo "    Install PowerShell 7+ and re-run this script."
  echo "    Docs: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux"
  exit 1
fi

pwsh -NoProfile -File "$SETUP_PS1"
