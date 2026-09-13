#!/usr/bin/env bash
# Installs the WeChat / QQ → Dynamic Island bridge.
#
# The bridge lives outside Atoll on purpose: it reads the system notification
# database (which needs Full Disk Access) and feeds Atoll through the public
# extension API, so the app itself is untouched and the permission is granted to
# a small helper instead of to Atoll.
#
#   scripts/install-notify-bridge.sh              install (sender only)
#   scripts/install-notify-bridge.sh --body       install, include the message
#   scripts/install-notify-bridge.sh --test       send one made-up message
#   scripts/install-notify-bridge.sh --uninstall  remove everything again

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/notify-bridge" && pwd)"
SUPPORT_DIR="$HOME/Library/Application Support/Atoll/notify-bridge"
APP_BUNDLE="$SUPPORT_DIR/AtollNotifyBridge.app"
AGENT_LABEL="com.atoll.notify-bridge"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Atoll"
STATE_FILE="$HOME/.atoll/notify-bridge-state.json"

body_flag=()
test_flag=()
for argument in "$@"; do
  case "$argument" in
    --body) body_flag=(--body) ;;
    --test) test_flag=(--test) ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "unknown option: $argument" >&2; exit 2 ;;
  esac
done

if [ "${UNINSTALL:-0}" = "1" ]; then
  echo "==> Stopping the bridge"
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  rm -f "$AGENT_PLIST"
  rm -rf "$APP_BUNDLE" "$STATE_FILE"
  echo "Removed $AGENT_LABEL, its app bundle and its cursor file."
  echo "You can also revoke the extension in Atoll → Settings → Extensions."
  exit 0
fi

export CLANG_MODULE_CACHE_PATH="$PACKAGE_DIR/.spm/modulecache"
export SWIFT_MODULECACHE_PATH="$PACKAGE_DIR/.spm/modulecache"
mkdir -p "$PACKAGE_DIR/.spm"

echo "==> Building the bridge"
cd "$PACKAGE_DIR"
build() {
  swift build -c release \
    --cache-path "$PACKAGE_DIR/.spm/cache" \
    --scratch-path "$PACKAGE_DIR/.spm/build" \
    --config-path "$PACKAGE_DIR/.spm/config" \
    --security-path "$PACKAGE_DIR/.spm/security" "$@"
}
# Some environments (sandboxes, locked-down CI) forbid SwiftPM's own sandbox.
build || build --disable-sandbox

BINARY="$PACKAGE_DIR/.spm/build/release/atoll-notify-bridge"
[ -x "$BINARY" ] || { echo "build produced no binary at $BINARY" >&2; exit 1; }

echo "==> Assembling AtollNotifyBridge.app"
# Atoll identifies an extension by the bundle identifier of the connecting
# process, and a bare executable has none — the connection would be refused. So
# the binary ships inside a minimal app bundle.
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/atoll-notify-bridge"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.atoll.notify-bridge</string>
	<key>CFBundleName</key>
	<string>Atoll Notify Bridge</string>
	<key>CFBundleDisplayName</key>
	<string>Atoll Notify Bridge</string>
	<key>CFBundleExecutable</key>
	<string>atoll-notify-bridge</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> Installing the launch agent"
mkdir -p "$(dirname "$AGENT_PLIST")" "$LOG_DIR"
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP_BUNDLE/Contents/MacOS/atoll-notify-bridge</string>
		<string>--interval</string>
		<string>2</string>
		${body_flag:+<string>--body</string>}
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$LOG_DIR/notify-bridge.log</string>
	<key>StandardErrorPath</key>
	<string>$LOG_DIR/notify-bridge.log</string>
</dict>
</plist>
PLIST

if [ "${#test_flag[@]}" -gt 0 ]; then
  echo "==> Sending one made-up message to Atoll"
  exec "$APP_BUNDLE/Contents/MacOS/atoll-notify-bridge" --test --debug
fi

echo "==> Starting the bridge"
launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL"

cat <<EOF

Installed.

  messages : $APP_BUNDLE
  agent    : $AGENT_PLIST
  log      : $LOG_DIR/notify-bridge.log
  cursor   : $STATE_FILE

Two things to do once:

  1. Full Disk Access — System Settings → Privacy & Security → Full Disk Access
     → + → $APP_BUNDLE/Contents/MacOS/atoll-notify-bridge
     (Without it the bridge cannot read the notification database.)

  2. Let Atoll authorise it — the first message shows an authorisation prompt in
     the island; approve it once.

Message bodies are off by default (the sender is shown). Re-run with --body to
include them, or --uninstall to remove everything.
EOF
