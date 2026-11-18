#!/bin/bash
# 编译并打包成 UsageMonitor.app（菜单栏应用，不显示 Dock 图标）
set -euo pipefail
cd "$(dirname "$0")"

APP=build/UsageMonitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library \
  -target arm64-apple-macosx14.0 \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/UsageMonitor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>UsageMonitor</string>
  <key>CFBundleDisplayName</key><string>AI 用量监控</string>
  <key>CFBundleIdentifier</key><string>local.usagemonitor</string>
  <key>CFBundleExecutable</key><string>UsageMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
