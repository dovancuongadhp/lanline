#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/LanLock.app"
rm -rf "$APP" build/AppIcon.iconset build/drawicons
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset dist

swiftc -O -o "$APP/Contents/MacOS/lanlockd" \
  Sources/Shared/Logic.swift \
  Sources/Shared/ControlClient.swift \
  Sources/Daemon/Engine.swift \
  Sources/Daemon/Server.swift \
  Sources/Daemon/SelfTest.swift \
  Sources/Daemon/main.swift

swiftc -O -parse-as-library \
  -framework SwiftUI -framework AppKit -framework LocalAuthentication -framework Security \
  -o "$APP/Contents/MacOS/LanLock" \
  Sources/Shared/Logic.swift \
  Sources/Shared/ControlClient.swift \
  Sources/App/LanLockApp.swift

swiftc -O -framework AppKit -o build/drawicons Sources/Tools/DrawIcons.swift
build/drawicons build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Support/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - "$APP/Contents/MacOS/lanlockd"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/lanlockd" --self-test

hdiutil detach "/Volumes/LanLock" >/dev/null 2>&1 || true
rm -rf build/dmg
mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "LanLock" -srcfolder build/dmg -ov -format UDZO "dist/LanLock.dmg" >/dev/null
echo "Đã build $APP và dist/LanLock.dmg"
