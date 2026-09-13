#!/bin/bash
# Build a Release Atoll.app and install it to /Applications — no App Store,
# no notarization, no Xcode needed afterwards to *run* it.
#
# Usage:  ./scripts/install-local.sh
# Re-run it after pulling/making code changes to refresh the installed app.
set -euo pipefail

# Drops every copy in $1 matching $2 except the newest one.
#
# Written with find/sort rather than `ls -dt`: under `set -euo pipefail` an `ls`
# that matches nothing returns non-zero, and the pipeline then aborts the whole
# script — which is how an install once moved the app away and stopped before
# copying the new one in.
prune_older() {
  local dir="$1" name="$2" stale
  find "$dir" -maxdepth 1 -name "$name" -print0 2>/dev/null \
    | xargs -0 -r stat -f '%m %N' 2>/dev/null \
    | sort -rn | tail -n +2 | cut -d' ' -f2- \
    | while IFS= read -r stale; do
        echo "==> Removing older copy $(basename "$stale")"
        rm -rf "$stale"
      done || true
}

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

# Rollback copies live outside /Applications, which is for the app the user
# actually runs: repeated installs used to leave an 84 MB "Atoll.app.backup-*"
# next to it, and even one is one too many there. One copy is kept, in Atoll's
# own support folder, and the previous one is dropped.
BACKUP_DIR="$HOME/Library/Application Support/Atoll/backups"
BACKUP=""
if [ -d "$APP_DST" ]; then
  mkdir -p "$BACKUP_DIR"
  BACKUP="$BACKUP_DIR/Atoll-$(date +%Y%m%d-%H%M%S).app"
  echo "==> Backing up existing app to $BACKUP"
  mv "$APP_DST" "$BACKUP"
  prune_older "$BACKUP_DIR" 'Atoll-*.app'
fi
# Any backup an earlier version of this script left in /Applications goes too.
prune_older /Applications 'Atoll.app.backup-*'

echo "==> Installing to $APP_DST"
# Copy beside the destination first and only then swap it in: an interrupted or
# failing copy used to leave /Applications with no Atoll at all, because the old
# app had already been moved to the backup folder.
STAGING="$APP_DST.staging-$$"
rm -rf "$STAGING"
cp -R "$APP_SRC" "$STAGING"
if [ ! -x "$STAGING/Contents/MacOS/Atoll" ]; then
  echo "!! copy failed — keeping the installed app untouched" >&2
  rm -rf "$STAGING"
  if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
    mv "$BACKUP" "$APP_DST"
  fi
  exit 1
fi
rm -rf "$APP_DST"
mv "$STAGING" "$APP_DST"
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true
codesign --verify --deep --strict "$APP_DST"

echo "==> Launching"
open "$APP_DST"
echo "Done. Atoll now runs from $APP_DST without Xcode."
