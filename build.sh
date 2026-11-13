#!/bin/bash
# Builds TimelapseCam.app in this folder (release build, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="TimelapseCam.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/TimelapseCam" "$APP/Contents/MacOS/TimelapseCam"
cp "Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature identified by bundle ID rather than by this build's exact contents,
# so macOS keeps the camera permission across rebuilds instead of asking again each time.
codesign --force --deep --sign - -r='designated => identifier "com.satvik.timelapsecam"' "$APP"

echo "Built: $PWD/$APP"
echo "Run with: open \"$PWD/$APP\""
