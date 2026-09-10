// Contract test for the Atoll <-> pi status hook.
//
// Runs the real hook against a mock ExtensionAPI and asserts the JSON it writes
// to $HOME/.pi/agent/notch-status.json, so the hook can be verified without
// spending model requests.
//
//   node --experimental-strip-types hooks/pi/atoll-notch-status.test.mjs
//
// (Node 23+ strips the types on import; the hook only uses `import type`.)
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const home = mkdtempSync(join(tmpdir(), "atoll-hook-test-"));
mkdirSync(join(home, ".pi", "agent"), { recursive: true });
// The hook resolves its status path from `os.homedir()` at import time.
process.env.HOME = home;

const { default: installHook } = await import("./atoll-notch-status.ts");

const statusPath = join(home, ".pi", "agent", "notch-status.json");
const status = () => JSON.parse(readFileSync(statusPath, "utf8"));

function mockPi() {
  const handlers = new Map();
  return {
    handlers,
    on(event, handler) {
      handlers.set(event, handler);
    },
    // Mirrors the real ExtensionAPI: there is no `model` / `thinkingLevel`
    // property, only these accessors.
    getThinkingLevel() {
      return "medium";
    },
  };
}

const ctx = { model: { id: "test/model-1" }, thinkingLevel: "high" };

const fire = (pi, event, payload, context = ctx) => {
  const handler = pi.handlers.get(event);
  assert.ok(handler, `hook does not handle "${event}"`);
  return handler(payload, context);
};

const assistant = (content, extra = {}) => ({
  message: {
    role: "assistant",
    model: "test/model-1",
    usage: { input: 1000, output: 200, cacheRead: 3000, totalTokens: 4200 },
    stopReason: "toolUse",
    content,
    ...extra,
  },
});

const call = (id, name, args) => ({ type: "toolCall", id, name, arguments: args });

test("hook writes model and thinking level from the handler context", async () => {
  const pi = mockPi();
  installHook(pi);
  await fire(pi, "session_start", { type: "session_start", reason: "startup" });

  const s = status();
  assert.equal(s.busy, false);
  assert.equal(s.model, "test/model-1");
  assert.equal(s.thinkingLevel, "high");
});

test("agent_start clears the previous request's tasks", async () => {
  const pi = mockPi();
  installHook(pi);
  await fire(pi, "agent_start", { type: "agent_start" });
  await fire(pi, "message_end", assistant([call("c1", "read", { path: "~/.zshrc" })]));
  assert.equal(status().tasks.length, 1);

  await fire(pi, "agent_start", { type: "agent_start" });
  const s = status();
  assert.equal(s.busy, true);
  assert.deepEqual(s.tasks, undefined);
  assert.deepEqual(s.tool, undefined);
});

test("tool calls move upcoming -> running -> completed across turns", async () => {
  const pi = mockPi();
  installHook(pi);
  await fire(pi, "agent_start", { type: "agent_start" });

  // One assistant message decides on two calls: both are upcoming at first.
  await fire(pi, "message_end", assistant([call("c1", "read", { path: "a.ts" }), call("c2", "bash", { command: "npm test" })]));
  assert.deepEqual(
    status().tasks.map((t) => [t.name, t.target, t.state]),
    [["read", "a.ts", "upcoming"], ["bash", "npm test", "upcoming"]]
  );

  await fire(pi, "tool_execution_start", { toolCallId: "c1", toolName: "read", args: { path: "a.ts" } });
  assert.deepEqual(status().tasks.map((t) => t.state), ["running", "upcoming"]);
  assert.equal(status().tool.name, "read");
  assert.equal(status().tool.pending, true);

  await fire(pi, "tool_execution_end", { toolCallId: "c1", toolName: "read" });
  assert.deepEqual(status().tasks.map((t) => t.state), ["completed", "upcoming"]);

  // A later model call may add another tool without dropping the first ones.
  await fire(pi, "message_end", assistant([call("c3", "edit", { path: "b.ts" })]));
  assert.deepEqual(status().tasks.map((t) => [t.name, t.state]), [
    ["read", "completed"],
    ["bash", "upcoming"],
    ["edit", "upcoming"],
  ]);

  await fire(pi, "agent_settled", { type: "agent_settled" });
  const s = status();
  assert.equal(s.busy, false);
  assert.deepEqual(s.tasks.map((t) => t.state), ["completed", "upcoming", "upcoming"]);
  assert.equal(s.cacheHitRate, 0.75); // 3000 cacheRead / (1000 input + 3000)
});

test("a tool that fails marks the turn as failed", async () => {
  const pi = mockPi();
  installHook(pi);
  await fire(pi, "agent_start", { type: "agent_start" });
  await fire(pi, "tool_execution_start", { toolCallId: "c1", toolName: "bash", args: { command: "npm test" } });

  await fire(pi, "tool_execution_end", { toolCallId: "c1", toolName: "bash", isError: true });
  assert.equal(status().failed, true);

  // A later tool that succeeds clears it again: the turn recovered.
  await fire(pi, "tool_execution_start", { toolCallId: "c2", toolName: "edit", args: { path: "a.ts" } });
  await fire(pi, "tool_execution_end", { toolCallId: "c2", toolName: "edit", isError: false });
  assert.equal(status().failed, undefined);

  // …and a new request starts clean.
  await fire(pi, "tool_execution_end", { toolCallId: "c3", toolName: "bash", isError: true });
  assert.equal(status().failed, true);
  await fire(pi, "agent_start", { type: "agent_start" });
  assert.equal(status().failed, undefined);
});

test("provider errors are reported instead of a task", async () => {
  const pi = mockPi();
  installHook(pi);
  await fire(pi, "agent_start", { type: "agent_start" });
  await fire(pi, "message_end", assistant([], {
    stopReason: "error",
    errorMessage: '429: {"message":"Rate limit exceeded: free-models-per-day"}',
  }));

  const s = status();
  assert.equal(s.error, '429: {"message":"Rate limit exceeded: free-models-per-day"}');
  // Error responses carry zeroed usage; it must not clobber real numbers.
  assert.equal(s.usage, undefined);
  assert.equal(s.cacheHitRate, undefined);
});

test("a later success clears the error", async () => {
  const pi = mockPi();
  installHook(pi);
  await fire(pi, "agent_start", { type: "agent_start" });
  await fire(pi, "message_end", assistant([], { stopReason: "error", errorMessage: "boom" }));
  assert.equal(status().error, "boom");

  await fire(pi, "message_end", assistant([call("c1", "read", { path: "a.ts" })]));
  assert.equal(status().error, undefined);
});

test("session_shutdown stops the activity", async () => {
  const pi = mockPi();
  installHook(pi);
  await fire(pi, "agent_start", { type: "agent_start" });
  await fire(pi, "tool_execution_start", { toolCallId: "c1", toolName: "bash", args: { command: "sleep 60" } });
  await fire(pi, "session_shutdown", { type: "session_shutdown", reason: "quit" });

  const s = status();
  assert.equal(s.busy, false);
  assert.deepEqual(s.tasks.map((t) => t.state), ["completed"]);
});

test("model_select and thinking_level_select update the header", async () => {
  const pi = mockPi();
  installHook(pi);
  await fire(pi, "model_select", { type: "model_select", model: { id: "test/model-2" } });
  assert.equal(status().model, "test/model-2");

  await fire(pi, "thinking_level_select", { type: "thinking_level_select", level: "xhigh" });
  assert.equal(status().thinkingLevel, "xhigh");
});

test.after(() => rmSync(home, { recursive: true, force: true }));
