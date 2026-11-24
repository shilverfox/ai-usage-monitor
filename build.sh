#!/bin/bash
# 编译并打包成 UsageMonitor.app（菜单栏应用，不显示 Dock 图标）
# 编译成功后自动安装到 /Applications 并重启运行中的实例
set -euo pipefail
cd "$(dirname "$0")"

APP=build/UsageMonitor.app
DEST=/Applications/UsageMonitor.app
PATTERN="UsageMonitor.app/Contents/MacOS/UsageMonitor"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# 编译失败会在这里退出，此时 /Applications 里的旧版本不受影响
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

# ---- 安装到 /Applications ----
# 必须先停掉运行中的实例，否则覆盖后签名与内存映像不一致
if pgrep -f "$PATTERN" >/dev/null 2>&1; then
  echo "Stopping running instance..."
  pkill -f "$PATTERN" 2>/dev/null || true
  sleep 1
fi

# 必须先删目标目录：cp -R 到已存在的目录会嵌套成 UsageMonitor.app/UsageMonitor.app
if [ -d "$DEST" ]; then
  rm -rf "$DEST"
fi

if cp -R "$APP" "$DEST" 2>/dev/null; then
  echo "Installed $DEST"
  open "$DEST"
  echo "Restarted from $DEST"
else
  echo "WARN: 无法写入 /Applications，仅保留 $APP"
  open "$APP"
fi
