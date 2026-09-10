#!/usr/bin/env bash
# Installs the Atoll <-> Codex CLI status hook.
#
# Codex reads command hooks from ~/.codex/hooks.json (same schema as Claude
# Code): event name -> [{ matcher?, hooks: [{ type, command, timeout }] }].
# This copies the shared bridge (hooks/cli/atoll-notch-status.py, installed next
# to itself so it reports for Codex) and merges the entries it needs. The merge
# is idempotent and keeps every other hook — including the Fantastic Island
# entries Codex users often already have.
#
# Events registered:
#   SessionStart / UserPromptSubmit -> busy, fresh task list
#   PreToolUse / PostToolUse        -> the running tool, the turn's tasks and
#                                      whether the tool failed (is_error /
#                                      non-zero exit / interrupted)
#   PermissionRequest               -> the agent is waiting on the user
#   Stop                            -> idle
#
# Usage: scripts/install-codex-hook.sh [--uninstall]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_ROOT/hooks/cli/atoll-notch-status.py"
CODEX_DIR="$HOME/.codex"
TARGET="$CODEX_DIR/atoll-notch-status.py"
HOOKS_JSON="$CODEX_DIR/hooks.json"

if [[ "${1:-}" == "--uninstall" ]]; then
    PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || echo /usr/bin/python3)}"
    "$PYTHON_BIN" - "$HOOKS_JSON" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        config = json.load(handle)
except (OSError, ValueError):
    config = {}
hooks = config.get("hooks")
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
    json.dump(config, handle, indent=2)
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
    echo "error: python3 not found (Codex hooks need it to run the bridge)" >&2
    exit 1
fi

mkdir -p "$CODEX_DIR"
cp "$SOURCE" "$TARGET"
chmod 755 "$TARGET"

if [[ -f "$HOOKS_JSON" ]]; then
    cp "$HOOKS_JSON" "$HOOKS_JSON.atoll-backup-$(date +%Y%m%d-%H%M%S)"
else
    echo '{}' > "$HOOKS_JSON"
fi

"$PYTHON_BIN" - "$HOOKS_JSON" "$PYTHON_BIN" <<'PY'
import json, sys

path, python_bin = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    config = json.load(handle)
if not isinstance(config, dict):
    config = {}

command = f'"{python_bin}" "$HOME/.codex/atoll-notch-status.py"'
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"]

hooks = config.setdefault("hooks", {})
for event in events:
    entries = hooks.get(event)
    if not isinstance(entries, list):
        entries = []
    # Drop our own previous entries, keep everything else (Fantastic Island,
    # user hooks, matchers).
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
    json.dump(config, handle, indent=2)
    handle.write("\n")
print("Merged Atoll hook entries into", path)
PY

echo "Installed Codex hook: $TARGET"
echo "Interpreter: $PYTHON_BIN"
echo "Codex reads hooks.json at startup: restart it (or start a new session)."
