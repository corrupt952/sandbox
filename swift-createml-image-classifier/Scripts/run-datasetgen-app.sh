#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product datasetgen-app

APP=.build/DatasetGen.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/datasetgen-app "$APP/Contents/MacOS/DatasetGen"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>DatasetGen</string>
  <key>CFBundleIdentifier</key>
  <string>dev.zuki.sandbox.datasetgen</string>
  <key>CFBundleName</key>
  <string>DatasetGen</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.4</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
open "$APP"
