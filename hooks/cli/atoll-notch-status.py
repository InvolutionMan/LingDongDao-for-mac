#!/usr/bin/env python3
"""Atoll notch status bridge for Claude Code and the Codex CLI.

Both CLIs run command hooks configured in a settings file — Claude Code reads
~/.claude/settings.json, Codex reads ~/.codex/hooks.json — and both pass that
event's JSON on stdin with the same field names (hook_event_name, tool_name,
tool_input, tool_response, is_error, transcript_path, …).

This one script serves both: it writes its files *next to itself*, so the copy
in ~/.claude reports for Claude Code and the copy in ~/.codex for Codex:

    <dir>/notch-status.json       { busy, since, tool, tasks, failed, error }
    <dir>/atoll-notch-state.json  the same data plus the task list, kept
                                  between hook invocations (one process each)

Install with scripts/install-claude-hook.sh / scripts/install-codex-hook.sh;
delete those files and the settings entries to uninstall.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
STATE_PATH = SCRIPT_DIR / "atoll-notch-state.json"
STATUS_PATH = SCRIPT_DIR / "notch-status.json"

# Tool name -> the lowercase names Atoll's panel knows. Covers Claude Code's
# TitleCase names and Codex's snake_case ones.
TOOL_NAMES = {
    "read": "read",
    "readfile": "read",
    "view": "read",
    "write": "write",
    "writefile": "write",
    "edit": "edit",
    "multiedit": "edit",
    "notebookedit": "edit",
    "applypatch": "edit",
    "strreplace": "edit",
    "bash": "bash",
    "shell": "bash",
    "exec": "bash",
    "execcommand": "bash",
    "bashoutput": "bash",
    "killshell": "bash",
    "grep": "grep",
    "glob": "glob",
    "search": "grep",
    "webfetch": "fetch_content",
    "websearch": "web_search",
    "searchquery": "web_search",
    "task": "task",
    "agent": "task",
    "todowrite": "todo",
    "updateplan": "todo",
}

# tool_input keys that describe what the tool acts on, in priority order.
TARGET_KEYS = {
    "read": ("file_path", "path", "file"),
    "write": ("file_path", "path", "file"),
    "edit": ("file_path", "path", "file"),
    "bash": ("command", "cmd"),
    "grep": ("pattern", "query"),
    "glob": ("pattern", "glob"),
    "fetch_content": ("url",),
    "web_search": ("query",),
    "task": ("description", "prompt"),
}

MAX_TASKS = 24


def normalize_event(raw: str) -> str:
    """`PostToolUse`, `post_tool_use` and `post-tool-use` all collapse."""
    return raw.replace("_", "").replace("-", "").lower()


def normalize_tool_name(raw: str) -> str:
    key = raw.replace("_", "").replace("-", "").lower()
    return TOOL_NAMES.get(key, raw.lower() or "tool")


def first_string(value: object) -> str | None:
    if isinstance(value, str) and value:
        return value
    if isinstance(value, list):
        for item in value:
            if isinstance(item, str) and item:
                return item
    return None


def tool_target(name: str, tool_input: object) -> str | None:
    if not isinstance(tool_input, dict):
        return None

    # Todo lists: the item being worked on is the useful "target".
    if name == "todo":
        todos = tool_input.get("todos") or tool_input.get("plan")
        if isinstance(todos, list):
            for todo in todos:
                if isinstance(todo, dict) and todo.get("status") in ("in_progress", "inProgress"):
                    content = todo.get("activeForm") or todo.get("content") or todo.get("step")
                    if isinstance(content, str) and content:
                        return content
            if todos:
                return f"{len(todos)} todos"

    for key in TARGET_KEYS.get(name, ()):
        found = first_string(tool_input.get(key))
        if found:
            return found

    # Codex's apply_patch carries the file path inside the patch text.
    patch = first_string(tool_input.get("patch")) or first_string(tool_input.get("input"))
    if patch:
        fallback: str | None = None
        for line in patch.splitlines():
            if not line.startswith("*** "):
                continue
            marker = line[4:].strip()
            if "File:" in marker:            # *** Update File: src/app.ts
                return marker.split("File:", 1)[1].strip()
            if marker not in ("Begin Patch", "End Patch") and fallback is None:
                fallback = marker
        if fallback:
            return fallback

    for value in tool_input.values():
        found = first_string(value)
        if found:
            return found
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
    if state.get("failed"):
        payload["failed"] = True
    if state.get("error"):
        payload["error"] = state["error"]

    SCRIPT_DIR.mkdir(parents=True, exist_ok=True)
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


def payload_failed(event: dict) -> bool:
    """A tool failure, whichever way the CLI reports it."""
    if event.get("is_error") is True:
        return True
    response = event.get("tool_response")
    if isinstance(response, dict):
        if response.get("is_error") is True or response.get("isError") is True:
            return True
        exit_code = response.get("exit_code", response.get("exitCode"))
        if isinstance(exit_code, int) and exit_code != 0:
            return True
        if response.get("interrupted") is True:
            return True
    return False


def transcript_error(path: object) -> str | None:
    """The last assistant record's API error, if the turn died on one.

    Claude Code appends `isApiErrorMessage` records when the provider fails
    (connection, timeout, rate limit); those never reach a tool hook.
    """
    if not isinstance(path, str) or not path:
        return None
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - 131_072))
            tail = handle.read().decode("utf-8", errors="ignore")
    except OSError:
        return None

    for line in reversed(tail.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict) or record.get("type") != "assistant":
            continue
        if record.get("isApiErrorMessage"):
            message = record.get("message")
            text = None
            if isinstance(message, dict):
                content = message.get("content")
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and isinstance(block.get("text"), str):
                            text = block["text"]
                            break
            return text or "Provider error"
        # The last assistant record is a normal answer: no API failure.
        return None
    return None


def handle(event: dict) -> dict:
    hook = normalize_event(str(event.get("hook_event_name") or ""))
    now_ms = int(time.time() * 1000)
    state = load_state()
    tasks = [task for task in state.get("tasks", []) if isinstance(task, dict)]

    if hook == "sessionstart":
        state = {"busy": False, "since": now_ms, "tasks": []}

    elif hook == "userpromptsubmit":
        # A new prompt starts a fresh task list.
        state = {"busy": True, "since": now_ms, "tasks": []}

    elif hook == "pretooluse":
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

    elif hook in ("posttooluse", "posttoolusefailure"):
        name = normalize_tool_name(str(event.get("tool_name") or ""))
        target = tool_target(name, event.get("tool_input"))
        existing = find_task(tasks, event.get("tool_use_id"), name, target)
        if existing is not None:
            existing["state"] = "completed"
        state["tasks"] = tasks[-MAX_TASKS:]
        # `PostToolUseFailure` is an outright failure; a plain PostToolUse only
        # counts as one when the response says so.
        state["failed"] = hook == "posttoolusefailure" or payload_failed(event)

    elif hook in ("stop", "sessionend"):
        # The turn finished (or the session ended): nothing is executing.
        for task in tasks:
            if task.get("state") == "running":
                task["state"] = "completed"
        state["busy"] = False
        state["tasks"] = tasks[-MAX_TASKS:]
        error = transcript_error(event.get("transcript_path"))
        if error:
            state["error"] = error

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
