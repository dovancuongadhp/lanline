#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "${EUID}" -ne 0 ]]; then
  echo "Chạy: sudo ./install.sh"
  exit 1
fi
./build.sh

launchctl bootout system/com.lanlock.daemon 2>/dev/null || true
killall LanLock Lanline 2>/dev/null || true

CONSOLE_USER="$(stat -f %Su /dev/console || true)"
if [[ -n "${CONSOLE_USER}" && "${CONSOLE_USER}" != "root" ]]; then
  CONSOLE_UID="$(id -u "${CONSOLE_USER}")"
  launchctl bootout "gui/${CONSOLE_UID}/com.lanlock.app" 2>/dev/null || true
fi
rm -f /Library/LaunchAgents/com.lanlock.app.plist
rm -rf "/Library/Application Support/LanLock"

rm -rf /Applications/LanLock.app /Applications/Lanline.app
cp -R build/Lanline.app /Applications/Lanline.app
chown -R root:wheel /Applications/Lanline.app
chmod -R go-w /Applications/Lanline.app

mkdir -p /Library/Logs/LanLock
cat > /Library/LaunchDaemons/com.lanlock.daemon.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.lanlock.daemon</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Applications/Lanline.app/Contents/MacOS/lanlockd</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>2</integer>
	<key>StandardOutPath</key>
	<string>/Library/Logs/LanLock/daemon.log</string>
	<key>StandardErrorPath</key>
	<string>/Library/Logs/LanLock/daemon.log</string>
</dict>
</plist>
EOF
chown root:wheel /Library/LaunchDaemons/com.lanlock.daemon.plist
chmod 644 /Library/LaunchDaemons/com.lanlock.daemon.plist

launchctl bootstrap system /Library/LaunchDaemons/com.lanlock.daemon.plist
launchctl enable system/com.lanlock.daemon || true
launchctl kickstart -k system/com.lanlock.daemon

echo "Đã cài Lanline vào Applications. File đóng gói: dist/Lanline.dmg"
