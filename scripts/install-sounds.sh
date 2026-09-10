#!/usr/bin/env bash
# Copies the CLI sound files into Atoll's own Application Support folder and
# points the app's Finish Sound settings at them.
#
# Sounds kept in ~/Downloads disappear whenever that folder is cleaned up, so
# Atoll reads them from:
#
#   ~/Library/Application Support/Atoll/Sounds/
#
# Usage: scripts/install-sounds.sh [source-dir]     (default: ~/Downloads)
#
# Recognised names in the source directory (first match wins):
#   success:      成功.mp3        success.mp3      success.m4a
#   failure:      错误.mp3        失败.mp3         error.mp3      failure.mp3
#   confirmation: 手动确认.mp3    确认.mp3         confirm.mp3    confirmation.mp3
set -euo pipefail

SRC="${1:-$HOME/Downloads}"
DEST="$HOME/Library/Application Support/Atoll/Sounds"
DOMAIN="com.Ebullioscopic.Atoll"

mkdir -p "$DEST"

copy_first() {
    local dest="$1"
    shift
    for name in "$@"; do
        if [[ -f "$SRC/$name" ]]; then
            cp "$SRC/$name" "$DEST/$dest"
            echo "  $name → $dest"
            return 0
        fi
    done
    echo "  (no source file found for $dest — keeping $(basename "$dest"))"
    return 0
}

echo "==> Copying sounds from $SRC to $DEST"
copy_first "成功.mp3"     成功.mp3     success.mp3     success.m4a
copy_first "错误.mp3"     错误.mp3     失败.mp3          error.mp3   failure.mp3
copy_first "手动确认.mp3" 手动确认.mp3 确认.mp3          confirm.mp3 confirmation.mp3

echo "==> Pointing Atoll's settings at that folder"
defaults write "$DOMAIN" cliSuccessSoundPath "$DEST/成功.mp3"
defaults write "$DOMAIN" cliFailureSoundPath "$DEST/错误.mp3"
defaults write "$DOMAIN" cliConfirmSoundPath "$DEST/手动确认.mp3"
defaults write "$DOMAIN" enableCLIFinishSound -bool true

echo
echo "Installed:"
ls -la "$DEST"
echo
echo "Restart Atoll for the new paths to take effect, then check"
echo "Settings → Media → Finish Sound (each row shows a green check when the file is found)."
