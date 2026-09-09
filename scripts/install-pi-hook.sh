#!/usr/bin/env bash
# Installs the Atoll <-> pi status hook.
#
# pi loads every file in ~/.pi/agent/extensions/ at startup, so this copies the
# canonical hook from the repo there. A running pi session picks it up with
# /reload (or a restart).
#
# The hook writes ~/.pi/agent/notch-status.json on every agent/tool event:
#   { busy, since, model, thinkingLevel,
#     tool: { name, target, pending },
#     tasks: [ { id, name, target, state } ],   # state: upcoming|running|completed
#     usage: {...}, cacheHitRate }
# Atoll's PiSessionMonitor reads it every second and on every write, which is
# what fills the notch's pi live activity and its detail panel (tool, task list,
# cache hit rate, tokens).
#
# Usage: scripts/install-pi-hook.sh [--uninstall]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_ROOT/hooks/pi/atoll-notch-status.ts"
TARGET_DIR="$HOME/.pi/agent/extensions"
TARGET="$TARGET_DIR/atoll-notch-status.ts"

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -f "$TARGET"
    echo "Removed $TARGET (restart pi to unload the hook)."
    exit 0
fi

if [[ ! -f "$SOURCE" ]]; then
    echo "Hook source not found: $SOURCE" >&2
    exit 1
fi

mkdir -p "$TARGET_DIR"
cp "$SOURCE" "$TARGET"
echo "Installed pi hook: $TARGET"
echo "Reload it in a running pi session with /reload, or restart pi."
