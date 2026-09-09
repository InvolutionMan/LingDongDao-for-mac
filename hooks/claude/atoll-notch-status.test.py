#!/usr/bin/env python3
"""Contract test for the Atoll <-> Claude Code status hook.

Runs the real hook as a subprocess (exactly how Claude Code invokes it), with
$HOME pointed at a temp directory, and asserts the JSON it writes.

    python3 hooks/claude/atoll-notch-status.test.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HOOK = Path(__file__).resolve().parent / "atoll-notch-status.py"

failures: list[str] = []


def fire(event: dict, home: Path) -> dict:
    env = dict(os.environ, HOME=str(home))
    subprocess.run(
        [sys.executable, str(HOOK)],
        input=json.dumps(event),
        text=True,
        env=env,
        check=True,
        capture_output=True,
    )
    return json.loads((home / ".claude" / "notch-status.json").read_text(encoding="utf-8"))


def check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  ok   {label}")
    else:
        failures.append(f"{label}{(' — ' + detail) if detail else ''}")
        print(f"  FAIL {label} {detail}")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="atoll-claude-hook-") as tmp:
        home = Path(tmp)
        (home / ".claude").mkdir(parents=True)

        print("user prompt starts a fresh turn")
        status = fire({"hook_event_name": "UserPromptSubmit", "prompt": "fix the bug"}, home)
        check("busy", status["busy"] is True)
        check("no tool yet", "tool" not in status)
        check("no tasks yet", "tasks" not in status)

        print("PreToolUse reports the running tool")
        status = fire(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Read",
                "tool_use_id": "t1",
                "tool_input": {"file_path": "Sources/main.swift"},
            },
            home,
        )
        check("tool name normalised", status["tool"]["name"] == "read", json.dumps(status))
        check("tool target", status["tool"]["target"] == "Sources/main.swift")
        check("tool pending", status["tool"]["pending"] is True)
        check("task running", status["tasks"][0]["state"] == "running")

        print("PostToolUse completes it")
        status = fire(
            {
                "hook_event_name": "PostToolUse",
                "tool_name": "Read",
                "tool_use_id": "t1",
                "tool_input": {"file_path": "Sources/main.swift"},
            },
            home,
        )
        check("task completed", status["tasks"][0]["state"] == "completed")
        check("tool not pending", status["tool"]["pending"] is False)

        print("a second tool keeps the finished one and shows as running")
        fire(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Bash",
                "tool_use_id": "t2",
                "tool_input": {"command": "swift test"},
            },
            home,
        )
        status = fire(
            {
                "hook_event_name": "PostToolUse",
                "tool_name": "Bash",
                "tool_use_id": "t2",
                "tool_input": {"command": "swift test"},
            },
            home,
        )
        check("two tasks", len(status["tasks"]) == 2, json.dumps(status["tasks"]))
        check("first completed", status["tasks"][0]["state"] == "completed")
        check("second completed", status["tasks"][1]["state"] == "completed")

        print("TodoWrite surfaces the in-progress todo")
        status = fire(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "TodoWrite",
                "tool_use_id": "t3",
                "tool_input": {
                    "todos": [
                        {"content": "write the hook", "status": "completed", "activeForm": "Writing the hook"},
                        {"content": "test it", "status": "in_progress", "activeForm": "Testing the hook"},
                    ]
                },
            },
            home,
        )
        check("todo normalised", status["tool"]["name"] == "todo")
        check("todo target is the active item", status["tool"]["target"] == "Testing the hook", json.dumps(status["tool"]))

        print("Stop closes the turn")
        status = fire({"hook_event_name": "Stop"}, home)
        check("not busy", status["busy"] is False)
        check("no task left running", all(task["state"] == "completed" for task in status["tasks"]))

        print("SessionStart resets the list")
        status = fire({"hook_event_name": "SessionStart", "source": "startup"}, home)
        check("not busy", status["busy"] is False)
        check("tasks cleared", "tasks" not in status)

        print("an unmatched PostToolUse is ignored")
        status = fire(
            {
                "hook_event_name": "PostToolUse",
                "tool_name": "Edit",
                "tool_use_id": "never-seen",
                "tool_input": {"file_path": "a.swift"},
            },
            home,
        )
        check("no phantom task", "tasks" not in status and "tool" not in status, json.dumps(status))

        print("WebFetch / WebSearch map to the fetch tools")
        status = fire(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "WebFetch",
                "tool_use_id": "t4",
                "tool_input": {"url": "https://example.com"},
            },
            home,
        )
        check("webfetch name", status["tool"]["name"] == "fetch_content", json.dumps(status["tool"]))
        check("webfetch target", status["tool"]["target"] == "https://example.com")

    print()
    if failures:
        print(f"FAILED ({len(failures)}):")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("all hook checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
