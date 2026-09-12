#!/usr/bin/env python3
"""Contract test for the Atoll <-> CLI status hook.

The bridge writes its files next to itself, so this copies it into a temp home
twice — once as Claude Code's copy, once as Codex's — and runs each as the real
CLI would: JSON on stdin, one process per event.

    python3 hooks/cli/atoll-notch-status.test.py
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HOOK = Path(__file__).resolve().parent / "atoll-notch-status.py"

failures: list[str] = []


def check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  ok   {label}")
    else:
        failures.append(f"{label}{(' — ' + detail) if detail else ''}")
        print(f"  FAIL {label} {detail}")


class Cli:
    """One installed copy of the bridge (Claude's or Codex's)."""

    def __init__(self, home: Path, folder: str) -> None:
        self.dir = home / folder
        self.dir.mkdir(parents=True, exist_ok=True)
        self.script = self.dir / "atoll-notch-status.py"
        shutil.copy2(HOOK, self.script)

    def fire(self, event: dict) -> dict:
        env = dict(os.environ, HOME=str(self.dir.parent))
        subprocess.run(
            [sys.executable, str(self.script)],
            input=json.dumps(event),
            text=True,
            env=env,
            check=True,
            capture_output=True,
        )
        return json.loads((self.dir / "notch-status.json").read_text(encoding="utf-8"))


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="atoll-cli-hook-") as tmp:
        home = Path(tmp)
        claude = Cli(home, ".claude")
        codex = Cli(home, ".codex")

        print("Claude Code: a prompt starts a fresh turn, tools are tracked")
        status = claude.fire({"hook_event_name": "UserPromptSubmit", "prompt": "fix the bug"})
        check("busy", status["busy"] is True)
        check("no tool yet", "tool" not in status)
        check("the prompt is the goal", status.get("goal") == "fix the bug", json.dumps(status))

        status = claude.fire(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Read",
                "tool_use_id": "t1",
                "tool_input": {"file_path": "Sources/main.swift"},
            }
        )
        check("tool name normalised", status["tool"]["name"] == "read", json.dumps(status))
        check("tool target", status["tool"]["target"] == "Sources/main.swift")
        check("task running", status["tasks"][0]["state"] == "running")

        status = claude.fire(
            {"hook_event_name": "PostToolUse", "tool_name": "Read", "tool_use_id": "t1", "tool_input": {"file_path": "Sources/main.swift"}}
        )
        check("task completed", status["tasks"][0]["state"] == "completed")
        check("a clean tool is not a failure", "failed" not in status)

        print("Claude Code: PostToolUseFailure marks the turn failed")
        claude.fire({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_use_id": "t2", "tool_input": {"command": "npm test"}})
        status = claude.fire(
            {"hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "tool_use_id": "t2", "tool_input": {"command": "npm test"}}
        )
        check("failed flag set", status.get("failed") is True, json.dumps(status))
        check("task still closed", status["tasks"][-1]["state"] == "completed")

        status = claude.fire({"hook_event_name": "Stop"})
        check("idle after Stop", status["busy"] is False)
        check("failure survives Stop", status.get("failed") is True)

        print("Claude Code: a later success clears the failure")
        claude.fire({"hook_event_name": "UserPromptSubmit", "prompt": "again"})
        claude.fire({"hook_event_name": "PreToolUse", "tool_name": "Read", "tool_use_id": "t3", "tool_input": {"file_path": "a.ts"}})
        status = claude.fire({"hook_event_name": "PostToolUse", "tool_name": "Read", "tool_use_id": "t3", "tool_input": {"file_path": "a.ts"}})
        check("failed cleared", status.get("failed") in (None, False), json.dumps(status))

        print("Claude Code: an API error in the transcript is reported on Stop")
        transcript = home / "transcript.jsonl"
        transcript.write_text(
            json.dumps({"type": "user", "message": {"role": "user", "content": "hi"}}) + "\n"
            + json.dumps(
                {
                    "type": "assistant",
                    "isApiErrorMessage": True,
                    "message": {"role": "assistant", "content": [{"type": "text", "text": "Rate limit exceeded: free-models-per-day"}]},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        status = claude.fire({"hook_event_name": "Stop", "transcript_path": str(transcript)})
        check("error captured", status.get("error") == "Rate limit exceeded: free-models-per-day", json.dumps(status))

        print("confirmation: a permission prompt chimes, the answer clears it")
        claude.fire({"hook_event_name": "UserPromptSubmit", "prompt": "delete the file"})
        status = claude.fire(
            {
                "hook_event_name": "PermissionRequest",
                "tool_name": "Bash",
                "tool_input": {"command": "rm -rf build"},
            }
        )
        check("confirm label", status.get("confirm") == "bash rm -rf build", json.dumps(status))

        status = claude.fire(
            {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_use_id": "p1", "tool_input": {"command": "rm -rf build"}}
        )
        check("cleared once the tool runs", "confirm" not in status, json.dumps(status))

        status = claude.fire({"hook_event_name": "Notification", "message": "Claude needs your permission to use Bash"})
        check("notification with permission -> confirm", status.get("confirm", "").startswith("Claude needs your permission"), json.dumps(status))

        status = claude.fire({"hook_event_name": "Notification", "message": "Background task finished"})
        check("chatter is not a confirmation", "confirm" not in status, json.dumps(status))

        print("Codex: snake_case events and is_error are understood")
        status = codex.fire({"hook_event_name": "session_start"})
        check("session start is idle", status["busy"] is False)

        codex.fire({"hook_event_name": "user_prompt_submit", "prompt": "run the tests"})
        status = codex.fire(
            {"hook_event_name": "pre_tool_use", "tool_name": "shell", "tool_use_id": "c1", "tool_input": {"command": ["npm", "test"]}}
        )
        check("shell -> bash", status["tool"]["name"] == "bash", json.dumps(status))
        check("command array target", status["tool"]["target"] == "npm")

        status = codex.fire(
            {
                "hook_event_name": "post_tool_use",
                "tool_name": "shell",
                "tool_use_id": "c1",
                "tool_input": {"command": ["npm", "test"]},
                "tool_response": {"exit_code": 1, "stderr": "1 failing"},
            }
        )
        check("non-zero exit -> failed", status.get("failed") is True, json.dumps(status))

        status = codex.fire({"hook_event_name": "stop"})
        check("idle after stop", status["busy"] is False)

        print("Codex: apply_patch and update_plan are normalised")
        status = codex.fire(
            {
                "hook_event_name": "pre_tool_use",
                "tool_name": "apply_patch",
                "tool_use_id": "c2",
                "tool_input": {"patch": "*** Begin Patch\n*** Update File: src/app.ts\n@@\n-x\n+y\n*** End Patch"},
            }
        )
        check("apply_patch -> edit", status["tool"]["name"] == "edit", json.dumps(status))
        check("patch target", status["tool"]["target"] == "src/app.ts", json.dumps(status))

        codex.fire(
            {
                "hook_event_name": "post_tool_use",
                "tool_name": "apply_patch",
                "tool_use_id": "c2",
                "tool_input": {"patch": "*** Begin Patch\n*** Update File: src/app.ts\n*** End Patch"},
            }
        )

        status = codex.fire(
            {
                "hook_event_name": "pre_tool_use",
                "tool_name": "update_plan",
                "tool_use_id": "c3",
                "tool_input": {"plan": [{"step": "write the hook", "status": "completed"}, {"step": "test it", "status": "in_progress"}]},
            }
        )
        check("update_plan -> todo", status["tool"]["name"] == "todo", json.dumps(status))
        check("in-progress step", status["tool"]["target"] == "test it", json.dumps(status))

        print("the goal survives later tool events, and is capped")
        status = codex.fire(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Bash",
                "tool_use_id": "c9",
                "tool_input": {"command": "ls"},
            }
        )
        codex_prompt = "run the tests"
        check("goal kept after a tool event", status.get("goal") == codex_prompt, json.dumps(status))

        long_prompt = "x" * 900
        status = claude.fire({"hook_event_name": "UserPromptSubmit", "prompt": long_prompt})
        goal = status.get("goal") or ""
        check("long goal capped", len(goal) == 401 and goal.endswith("…"), f"len={len(goal)}")

        print("each CLI keeps its own files")
        check("claude status exists", (claude.dir / "notch-status.json").exists())
        check("codex status exists", (codex.dir / "notch-status.json").exists())
        check(
            "no cross-talk",
            json.loads((codex.dir / "notch-status.json").read_text())["tool"]["name"] == "todo",
        )

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
