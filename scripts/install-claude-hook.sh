#!/usr/bin/env bash
# Installs the Atoll <-> Claude Code status hook.
#
# Claude Code runs command hooks configured in ~/.claude/settings.json, so this
# copies hooks/claude/atoll-notch-status.py into ~/.claude/ and merges the hook
# entries the bridge needs into that file. The merge is idempotent: entries this
# script added before are replaced, every other hook (yours included) is kept.
# It also removes the older atoll-notch-status.sh hook, which would otherwise
# overwrite the new status file with a reduced payload.
#
# Events registered:
#   SessionStart / UserPromptSubmit   -> busy, fresh task list
#   PreToolUse / PostToolUse          -> the running tool and the turn's tasks
#   PostToolUseFailure                -> the turn is marked failed
#   PermissionRequest / Notification  -> the agent is waiting on the user
#   Stop / SessionEnd                 -> idle (+ an API error from the transcript)
#
# Usage: scripts/install-claude-hook.sh [--uninstall]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_ROOT/hooks/cli/atoll-notch-status.py"
CLAUDE_DIR="$HOME/.claude"
TARGET="$CLAUDE_DIR/atoll-notch-status.py"
SETTINGS="$CLAUDE_DIR/settings.json"

if [[ "${1:-}" == "--uninstall" ]]; then
    PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || echo /usr/bin/python3)}"
    "$PYTHON_BIN" - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        settings = json.load(handle)
except (OSError, ValueError):
    settings = {}
hooks = settings.get("hooks")
if isinstance(hooks, dict):
    for event, entries in list(hooks.items()):
        if not isinstance(entries, list):
            continue
        kept = [
            entry for entry in entries
            if not any(
                isinstance(hook, dict) and "atoll-notch-status" in str(hook.get("command", ""))
                for hook in (entry.get("hooks") or [])
            )
        ]
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
print("Removed Atoll hook entries from", path)
PY
    rm -f "$TARGET"
    echo "Removed $TARGET"
    exit 0
fi

if [[ ! -f "$SOURCE" ]]; then
    echo "Hook source not found: $SOURCE" >&2
    exit 1
fi

PYTHON_BIN="$(command -v python3 || true)"
if [[ -z "$PYTHON_BIN" && -x /usr/bin/python3 ]]; then
    PYTHON_BIN=/usr/bin/python3
fi
if [[ -z "$PYTHON_BIN" ]]; then
    echo "error: python3 not found (Claude Code hooks need it to run the bridge)" >&2
    exit 1
fi

mkdir -p "$CLAUDE_DIR"
cp "$SOURCE" "$TARGET"
chmod 755 "$TARGET"

if [[ -f "$SETTINGS" ]]; then
    cp "$SETTINGS" "$SETTINGS.atoll-backup-$(date +%Y%m%d-%H%M%S)"
else
    echo '{}' > "$SETTINGS"
fi

"$PYTHON_BIN" - "$SETTINGS" "$PYTHON_BIN" <<'PY'
import json, sys

path, python_bin = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    settings = json.load(handle)
if not isinstance(settings, dict):
    settings = {}

command = f'"{python_bin}" "$HOME/.claude/atoll-notch-status.py"'
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "SessionEnd"]

hooks = settings.setdefault("hooks", {})
for event in events:
    entries = hooks.get(event)
    if not isinstance(entries, list):
        entries = []
    # Drop our own previous entries (including the old shell hook) and keep
    # everything else, so user hooks and matchers survive a re-install.
    entries = [
        entry for entry in entries
        if not any(
            isinstance(hook, dict) and "atoll-notch-status" in str(hook.get("command", ""))
            for hook in (entry.get("hooks") or [])
        )
    ]
    entries.append({"hooks": [{"type": "command", "command": command, "timeout": 5}]})
    hooks[event] = entries

with open(path, "w", encoding="utf-8") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
print("Merged Atoll hook entries into", path)
PY

# The old shell bridge wrote only {busy,since} and would clobber the new file.
rm -f "$CLAUDE_DIR/atoll-notch-status.sh"

echo "Installed Claude Code hook: $TARGET"
echo "Interpreter: $PYTHON_BIN"
echo "Restart your Claude Code session: hooks are loaded when it starts."
