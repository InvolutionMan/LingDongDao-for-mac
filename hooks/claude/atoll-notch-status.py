#!/usr/bin/env python3
"""Atoll notch status bridge for Claude Code.

Claude Code runs this for every registered hook event (see the entries in
~/.claude/settings.json), passing that event's JSON on stdin. Each run updates a
small state file and rewrites ~/.claude/notch-status.json, which Atoll's
ClaudeSessionMonitor polls to drive the closed-notch live activity:

    { busy, since, tool: {name,target,pending}, tasks: [{id,name,target,state}] }

Tool calls are the unit of "behaviour", exactly like the pi hook: the tool that
is running right now is what the notch shows, and finished ones drop off the
list. TodoWrite additionally surfaces the todo it just marked in_progress.

Install with scripts/install-claude-hook.sh; delete this file and the
settings.json entries it added to uninstall.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

CLAUDE_DIR = Path.home() / ".claude"
STATE_PATH = CLAUDE_DIR / "atoll-notch-state.json"
STATUS_PATH = CLAUDE_DIR / "notch-status.json"

# Claude Code tool name -> the lowercase names Atoll's panel knows.
TOOL_NAMES = {
    "read": "read",
    "write": "write",
    "edit": "edit",
    "multiedit": "edit",
    "notebookedit": "edit",
    "bash": "bash",
    "bashoutput": "bash",
    "killshell": "bash",
    "grep": "grep",
    "glob": "glob",
    "webfetch": "fetch_content",
    "websearch": "web_search",
    "task": "task",
    "agent": "task",
    "todowrite": "todo",
}

# tool_input keys that describe what the tool acts on, in priority order.
TARGET_KEYS = {
    "read": ("file_path", "path"),
    "write": ("file_path", "path"),
    "edit": ("file_path", "path"),
    "bash": ("command",),
    "grep": ("pattern",),
    "glob": ("pattern",),
    "fetch_content": ("url",),
    "web_search": ("query",),
    "task": ("description", "prompt"),
}

MAX_TASKS = 24


def normalize_tool_name(raw: str) -> str:
    return TOOL_NAMES.get(raw.replace("_", "").lower(), raw.lower() or "tool")


def tool_target(name: str, tool_input: object) -> str | None:
    if not isinstance(tool_input, dict):
        return None

    # TodoWrite: the item currently being worked on is the useful "target".
    if name == "todo":
        for todo in tool_input.get("todos") or []:
            if isinstance(todo, dict) and todo.get("status") == "in_progress":
                content = todo.get("activeForm") or todo.get("content")
                if isinstance(content, str) and content:
                    return content
        todos = tool_input.get("todos")
        if isinstance(todos, list) and todos:
            return f"{len(todos)} todos"

    for key in TARGET_KEYS.get(name, ()):
        value = tool_input.get(key)
        if isinstance(value, str) and value:
            return value
    for value in tool_input.values():
        if isinstance(value, str) and value:
            return value
    return None


def load_state() -> dict:
    try:
        with STATE_PATH.open(encoding="utf-8") as handle:
            state = json.load(handle)
        if isinstance(state, dict):
            state.setdefault("busy", False)
            state.setdefault("since", int(time.time() * 1000))
            state.setdefault("tasks", [])
            return state
    except (OSError, ValueError):
        pass
    return {"busy": False, "since": int(time.time() * 1000), "tasks": []}


def write_status(state: dict) -> None:
    tasks = [task for task in state.get("tasks", []) if isinstance(task, dict)]
    running = next((task for task in tasks if task.get("state") == "running"), None)
    current = running or (tasks[-1] if tasks else None)

    payload: dict = {"busy": bool(state.get("busy")), "since": int(state.get("since", 0))}
    if current:
        payload["tool"] = {
            "name": current.get("name"),
            "target": current.get("target"),
            "pending": bool(state.get("busy")) and running is not None,
        }
    if tasks:
        payload["tasks"] = tasks[-MAX_TASKS:]

    CLAUDE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATUS_PATH.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, separators=(",", ":"))
    tmp.replace(STATUS_PATH)

    with STATE_PATH.open("w", encoding="utf-8") as handle:
        json.dump(state, handle, separators=(",", ":"))


def find_task(tasks: list[dict], tool_use_id: str | None, name: str, target: str | None) -> dict | None:
    if tool_use_id:
        for task in reversed(tasks):
            if task.get("id") == tool_use_id:
                return task
    for task in reversed(tasks):
        if task.get("name") == name and task.get("target") == target:
            return task
    return None


def handle(event: dict) -> dict:
    hook = event.get("hook_event_name")
    now_ms = int(time.time() * 1000)
    state = load_state()
    tasks = [task for task in state.get("tasks", []) if isinstance(task, dict)]

    if hook == "SessionStart":
        state = {"busy": False, "since": now_ms, "tasks": []}

    elif hook == "UserPromptSubmit":
        # A new prompt starts a fresh task list.
        state = {"busy": True, "since": now_ms, "tasks": []}

    elif hook == "PreToolUse":
        name = normalize_tool_name(str(event.get("tool_name") or ""))
        target = tool_target(name, event.get("tool_input"))
        tool_use_id = event.get("tool_use_id")
        existing = find_task(tasks, tool_use_id, name, target)
        if existing is not None:
            existing["state"] = "running"
        else:
            tasks.append(
                {
                    "id": tool_use_id or f"{name}-{now_ms}",
                    "name": name,
                    "target": target,
                    "state": "running",
                }
            )
        state["tasks"] = tasks[-MAX_TASKS:]
        state["busy"] = True

    elif hook == "PostToolUse":
        name = normalize_tool_name(str(event.get("tool_name") or ""))
        target = tool_target(name, event.get("tool_input"))
        existing = find_task(tasks, event.get("tool_use_id"), name, target)
        if existing is not None:
            existing["state"] = "completed"
        state["tasks"] = tasks[-MAX_TASKS:]

    elif hook in ("Stop", "SessionEnd"):
        # The turn finished (or the session ended): nothing is executing.
        for task in tasks:
            if task.get("state") == "running":
                task["state"] = "completed"
        state["busy"] = False
        state["tasks"] = tasks[-MAX_TASKS:]

    return state


def main() -> int:
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    try:
        event = json.loads(raw) if raw.strip() else {}
    except ValueError:
        event = {}
    if not isinstance(event, dict):
        event = {}
    try:
        write_status(handle(event))
    except OSError:
        # Best-effort status reporting; never break the agent over it.
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
