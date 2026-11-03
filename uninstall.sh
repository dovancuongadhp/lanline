#!/bin/bash
set -euo pipefail
if [[ "${EUID}" -ne 0 ]]; then
  echo "Chạy: sudo ./uninstall.sh"
  exit 1
fi

CONSOLE_USER="$(stat -f %Su /dev/console || true)"
if [[ -n "${CONSOLE_USER}" && "${CONSOLE_USER}" != "root" ]]; then
  CONSOLE_UID="$(id -u "${CONSOLE_USER}")"
  launchctl bootout "gui/${CONSOLE_UID}/com.lanlock.app" 2>/dev/null || true
fi
launchctl bootout system/com.lanlock.daemon 2>/dev/null || true
killall LanLock 2>/dev/null || true

if [[ -x /Applications/LanLock.app/Contents/MacOS/lanlockd ]]; then
  /Applications/LanLock.app/Contents/MacOS/lanlockd --release || true
elif [[ -x "/Library/Application Support/LanLock/lanlockd" ]]; then
  "/Library/Application Support/LanLock/lanlockd" --release || true
fi

rm -f /Library/LaunchDaemons/com.lanlock.daemon.plist
rm -f /Library/LaunchAgents/com.lanlock.app.plist
rm -rf "/Library/Application Support/LanLock"
rm -rf /Applications/LanLock.app
rm -rf /Library/Logs/LanLock
rm -f /var/run/lanlock.sock /var/run/lanlock.status.json /var/run/lanlock.pf /var/run/lanlock.pftoken
echo "Đã gỡ LanLock. Wi‑Fi không tự bật; bật lại bằng tay nếu cần."
