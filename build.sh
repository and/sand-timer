#!/bin/zsh
# Usage: ./build.sh                     build SandTimer.app
#        ./build.sh release             build, sign and package a shareable disk image (see below for notarizing)
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

VERSION=1.0.2
APP=build/SandTimer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "${1:-}" == "release" ]]; then
  # One app for both Apple Silicon and Intel Macs.
  swiftc -swift-version 5 -O -target arm64-apple-macos13 Sources/*.swift -o build/SandTimer-arm64
  swiftc -swift-version 5 -O -target x86_64-apple-macos13 Sources/*.swift -o build/SandTimer-x86_64
  lipo -create build/SandTimer-arm64 build/SandTimer-x86_64 -output "$APP/Contents/MacOS/SandTimer"
else
  swiftc -swift-version 5 -O Sources/*.swift -o "$APP/Contents/MacOS/SandTimer"
fi

# The icon is drawn by the app itself, so it always matches the timer.
rm -rf build/AppIcon.iconset
"$APP/Contents/MacOS/SandTimer" --iconset build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sand Timer</string>
  <key>CFBundleDisplayName</key><string>Sand Timer</string>
  <key>CFBundleIdentifier</key><string>local.sandtimer</string>
  <key>CFBundleExecutable</key><string>SandTimer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ "${1:-}" != "release" ]]; then
  codesign --force --sign - "$APP" >/dev/null 2>&1
  echo "Built $APP"
  exit
fi

# Release: sign with a Developer ID (hardened runtime, secure timestamp) and package a disk image to share.
# Notarizing is automatic when a credential profile exists; it is what lets the app open on other Macs
# without a security warning. Save one once with:
#   xcrun notarytool store-credentials sandtimer-notary --apple-id <you> --team-id <TEAMID>
# Override the profile with NOTARY_PROFILE, or set NOTARY_PROFILE= (empty) to skip notarizing.
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE-sandtimer-notary}"

# Submit one file and wait for Apple's verdict. Stapling is deliberately NOT
# done here: you submit a zip but staple the .app inside it, so the thing
# submitted and the thing stapled are often different files.
# On rejection, fetch the log — notarytool only reports "Invalid", and the
# reason is always in the log.
submit_for_notarization() {
  local target="$1"
  local submit_log="build/notary-submit.json"

  if ! xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json > "$submit_log"; then
    local id
    id=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$submit_log" 2>/dev/null || true)
    echo "Notarization failed for $target." >&2
    if [[ -n "$id" ]]; then
      echo "--- notarization log ---" >&2
      xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    else
      cat "$submit_log" >&2
    fi
    return 1
  fi
}
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

# Notarize the app before packaging, so the ticket travels inside the disk
# image. Stapling only the image leaves a dragged-out copy needing Apple's
# server to check it, which fails on a machine that is offline.
if [[ -n "$NOTARY_PROFILE" ]]; then
  rm -f build/SandTimer.zip
  ditto -c -k --keepParent "$APP" build/SandTimer.zip
  # The zip is only a carrier; the ticket is issued against the app inside it,
  # which is what gets stapled.
  submit_for_notarization build/SandTimer.zip
  xcrun stapler staple "$APP"
  echo "Notarized and stapled $APP"
fi

RELEASE=build/release
DMG="$RELEASE/SandTimer-$VERSION.dmg"
rm -rf "$RELEASE" build/dmg
mkdir -p "$RELEASE" build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Sand Timer" -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ -n "$NOTARY_PROFILE" ]]; then
  submit_for_notarization "$DMG"
  xcrun stapler staple "$DMG"
  echo "Notarized and stapled $DMG"

  # Prove it rather than assume it: this is what another Mac will check.
  echo "== Verifying"
  xcrun stapler validate "$APP"
  xcrun stapler validate "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
else
  echo "Not notarized (NOTARY_PROFILE is empty): other Macs will warn before opening it."
fi
shasum -a 256 "$DMG"
echo "Release ready: $DMG"
