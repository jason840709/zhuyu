#!/bin/bash
# Build 逐語.app with the Swift compiler from Xcode or the Command Line Tools.
# Usage: bash build.sh            → build/逐語.app
#        bash build.sh --ui-acceptance   (adds the screenshot hook used for UI checks)
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
OUT="$PROJECT_DIR/build"
APP="$OUT/逐語.app"
BUILD_FLAGS=(-swift-version 6 -O -parse-as-library)
if [ "${1:-}" = "--ui-acceptance" ]; then BUILD_FLAGS+=(-D UI_ACCEPTANCE); fi
CACHE="${MODULE_CACHE:-$OUT/module-cache}"  # override with MODULE_CACHE=/path if needed
mkdir -p "$CACHE" "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/xcrun swiftc \
  -target arm64-apple-macos26.0 -module-cache-path "$CACHE" \
  -module-name Zhuyu "${BUILD_FLAGS[@]}" "$PROJECT_DIR"/Sources/*.swift \
  -o "$APP/Contents/MacOS/Zhuyu"
cp "$PROJECT_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_DIR/Assets/AppIcon.icns" "$PROJECT_DIR/Assets/AppIcon.png" \
   "$PROJECT_DIR/Assets/VersionHistory.json" "$APP/Contents/Resources/"
# Ad-hoc signature so macOS can remember microphone and screen-audio permission.
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
echo "Built: $APP"
