#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER_PS1="$SCRIPT_DIR/digitalReaper.ps1"
UNIT_NAME="digital-reaper"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_FILE="$UNIT_DIR/$UNIT_NAME.service"
TIMER_FILE="$UNIT_DIR/$UNIT_NAME.timer"
PSEXE="$(command -v pwsh || true)"

if [[ ! -f "$REAPER_PS1" ]]; then
  echo "[!] digitalReaper.ps1 not found next to this script."
  exit 1
fi

if [[ -z "$PSEXE" ]]; then
  echo "[!] PowerShell (pwsh) is not installed."
  echo "    Install PowerShell 7+ and re-run this script."
  exit 1
fi

unit_exists() {
  [[ -f "$TIMER_FILE" && -f "$SERVICE_FILE" ]]
}

write_units() {
  local calendar="$1"
  local label="$2"
  mkdir -p "$UNIT_DIR"

  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Digital Reaper scheduled download pass

[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart="$PSEXE" -NoProfile -File "$REAPER_PS1" -Silent
EOF

  cat >"$TIMER_FILE" <<EOF
[Unit]
Description=Digital Reaper timer ($label)

[Timer]
OnCalendar=$calendar
Persistent=true
Unit=$UNIT_NAME.service

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT_NAME.timer" >/dev/null
}

schedule_menu() {
  echo ""
  echo "----------------------------------------------------------------"
  echo "  SCHEDULE SETUP"
  echo "----------------------------------------------------------------"
  echo ""
  echo "  NOTE: Add your links to audioLinks.txt or videoLinks.txt"
  echo "        before the timer fires for the first time."
  echo ""

  if unit_exists; then
    echo "[!] A $UNIT_NAME timer is already registered."
    read -r -p "Overwrite it? (y/n): " overwrite
    if [[ ! "${overwrite,,}" == "y" ]]; then
      echo ""
      echo "[INFO] Setup cancelled. Existing timer left unchanged."
      return
    fi
    systemctl --user disable --now "$UNIT_NAME.timer" >/dev/null 2>&1 || true
  fi

  echo "How often should Digital Reaper run?"
  echo ""
  echo "  1 = Every hour"
  echo "  2 = Every 4 hours"
  echo "  3 = Every 12 hours"
  echo "  4 = Once a day  (midnight)"
  echo "  5 = Once a week (Sunday midnight)"
  echo ""
  read -r -p "Enter choice (1-5): " choice

  case "$choice" in
    1) write_units "hourly" "every hour" ;;
    2) write_units "*-*-* 00/4:00:00" "every 4 hours" ;;
    3) write_units "*-*-* 00/12:00:00" "every 12 hours" ;;
    4) write_units "daily" "daily at midnight" ;;
    5) write_units "weekly" "weekly on Sunday at midnight" ;;
    *)
      echo ""
      echo "[!] Invalid choice. Setup cancelled."
      return
      ;;
  esac

  echo ""
  echo "================================================================"
  echo " [+] Timer \"$UNIT_NAME\" registered successfully!"
  echo "     Units : $UNIT_DIR"
  echo "================================================================"
  echo ""
  echo "  Runs only while you are logged in by default. To keep it going"
  echo "  after logout, run once:  loginctl enable-linger $USER"
  echo ""
  echo "  To view or edit: systemctl --user list-timers $UNIT_NAME.timer"
  echo "  To remove:       run this script and choose option 2"
  echo ""
}

remove_units() {
  echo ""
  echo "----------------------------------------------------------------"
  echo "  REMOVE SCHEDULED TIMER"
  echo "----------------------------------------------------------------"
  echo ""

  if ! unit_exists; then
    echo "[INFO] No $UNIT_NAME timer found. Nothing to remove."
    return
  fi

  read -r -p "Remove it? (y/n): " confirm
  if [[ ! "${confirm,,}" == "y" ]]; then
    echo ""
    echo "[INFO] Cancelled. Timer left in place."
    return
  fi

  systemctl --user disable --now "$UNIT_NAME.timer" >/dev/null 2>&1 || true
  rm -f "$TIMER_FILE" "$SERVICE_FILE"
  systemctl --user daemon-reload
  echo ""
  echo "[+] Timer removed."
}

run_now() {
  echo ""
  echo "----------------------------------------------------------------"
  echo "  RUNNING NOW (background / no window)"
  echo "----------------------------------------------------------------"
  echo ""
  if unit_exists; then
    echo "[INFO] Starting $UNIT_NAME.service..."
    systemctl --user start "$UNIT_NAME.service"
    echo "[INFO] Done. Logs: journalctl --user -u $UNIT_NAME.service"
  else
    echo "[INFO] No timer registered - running one silent pass directly..."
    echo "[INFO] Running $REAPER_PS1 -Silent"
    "$PSEXE" -NoProfile -File "$REAPER_PS1" -Silent
    echo "[INFO] Done."
  fi
}

show_status() {
  echo ""
  echo "----------------------------------------------------------------"
  echo "  TIMER STATUS"
  echo "----------------------------------------------------------------"
  echo ""
  echo "  Engine : $PSEXE"
  echo "  Units  : $UNIT_DIR"
  echo ""
  if unit_exists; then
    systemctl --user list-timers "$UNIT_NAME.timer" --no-pager || true
  else
    echo "[INFO] No $UNIT_NAME timer is registered."
  fi
  echo ""
  echo "  Last pass:"
  "$PSEXE" -NoProfile -File "$REAPER_PS1" -Status || true
}

while true; do
  echo ""
  echo "================================================================"
  echo "          DIGITAL REAPER - SCHEDULER"
  echo "================================================================"
  echo ""
  echo "  1 = Schedule  (register / update automated timer)"
  echo "  2 = Remove    (unregister the timer)"
  echo "  3 = Run Now   (one silent background run)"
  echo "  4 = Status    (timer state and last pass)"
  echo "  5 = Exit"
  echo ""
  echo "================================================================"
  echo ""
  read -r -p "Enter choice (1-5): " action || exit 0

  case "$action" in
    1) schedule_menu ;;
    2) remove_units ;;
    3) run_now ;;
    4) show_status ;;
    5) exit 0 ;;
    *)
      echo ""
      echo "[!] Invalid choice. Please enter 1-5."
      sleep 2
      ;;
  esac
done
