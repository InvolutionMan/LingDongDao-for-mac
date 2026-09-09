#!/bin/bash
# Build a Release Atoll.app and install it to /Applications — no App Store,
# no notarization, no Xcode needed afterwards to *run* it.
#
# Usage:  ./scripts/install-local.sh
# Re-run it after pulling/making code changes to refresh the installed app.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_DEVELOPER="${XCODE_DEVELOPER:-$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)/Contents/Developer}"
DERIVED_DATA="$PROJECT_DIR/.build/ReleaseDerived"
APP_DST="/Applications/Atoll.app"

if [ ! -d "$XCODE_DEVELOPER" ]; then
  echo "error: Xcode not found. Set XCODE_DEVELOPER=/path/to/Xcode.app/Contents/Developer" >&2
  exit 1
fi

echo "==> Building Release (DEVELOPER_DIR=$XCODE_DEVELOPER)"
DEVELOPER_DIR="$XCODE_DEVELOPER" xcodebuild \
  -project "$PROJECT_DIR/DynamicIsland.xcodeproj" \
  -scheme DynamicIsland \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  build

APP_SRC="$DERIVED_DATA/Build/Products/Release/Atoll.app"
[ -d "$APP_SRC" ] || { echo "error: build product not found at $APP_SRC" >&2; exit 1; }

echo "==> Quitting running Atoll"
osascript -e 'quit app "Atoll"' 2>/dev/null || true
pkill -f "Atoll.app/Contents/MacOS/Atoll" 2>/dev/null || true
sleep 2

if [ -d "$APP_DST" ]; then
  BACKUP="$APP_DST.backup-$(date +%Y%m%d-%H%M%S)"
  echo "==> Backing up existing app to $BACKUP"
  mv "$APP_DST" "$BACKUP"
fi

echo "==> Installing to $APP_DST"
cp -R "$APP_SRC" "$APP_DST"
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true
codesign --verify --deep --strict "$APP_DST"

echo "==> Launching"
open "$APP_DST"
echo "Done. Atoll now runs from $APP_DST without Xcode."
