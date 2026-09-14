#!/bin/zsh
# Usage: ./build.sh          build SandTimer.app
#        ./build.sh test     run the model tests
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

if [[ "${1:-}" == "test" ]]; then
  swiftc -swift-version 5 Sources/Model.swift Sources/SandPhysics.swift Tests/main.swift -o build/tests
  ./build/tests
  exit
fi

APP=build/SandTimer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -O Sources/*.swift -o "$APP/Contents/MacOS/SandTimer"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sand Timer</string>
  <key>CFBundleIdentifier</key><string>local.sandtimer</string>
  <key>CFBundleExecutable</key><string>SandTimer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
