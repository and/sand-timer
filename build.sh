#!/bin/zsh
# Usage: ./build.sh                     build SandTimer.app
#        ./build.sh test [word]         run the unit and integration tests (optionally only those matching a word)
#        ./build.sh test-unit [word]    run only the unit tests (no windows)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

if [[ "${1:-}" == "test" || "${1:-}" == "test-unit" ]]; then
  APP_SOURCES=(Sources/Model.swift Sources/SandPhysics.swift Sources/Sounds.swift Sources/HourglassRenderer.swift Sources/HourglassView.swift)
  echo "== Unit tests"
  swiftc -swift-version 5 -O "${APP_SOURCES[@]}" Tests/TestKit.swift Tests/Unit/*.swift -o build/unit-tests
  unit_status=0
  ./build/unit-tests "${2:-}" || unit_status=$?
  integration_status=0
  if [[ "$1" == "test" ]]; then
    echo "\n== Integration tests (opens the timer in windows briefly)"
    swiftc -swift-version 5 -O "${APP_SOURCES[@]}" Tests/TestKit.swift Tests/Integration/*.swift -o build/integration-tests
    ./build/integration-tests "${2:-}" || integration_status=$?
  fi
  exit $(( unit_status || integration_status ))
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
