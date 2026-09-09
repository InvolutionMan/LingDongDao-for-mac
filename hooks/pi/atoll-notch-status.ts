// Atoll notch status bridge — reports pi's busy/idle state, the current tool,
// the running task, token usage and provider errors in real time so the macOS
// Atoll notch can show a live "pi is working" activity with its own detail panel.
//
// The session JSONL pi writes is buffered (~16 KB flushes), so the file lags a
// running turn by seconds; these events are the only real-time source.
// Auto-discovered by pi from ~/.pi/agent/extensions/. Remove this file to
// uninstall, or run `/reload` inside pi after editing it.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { homedir } from "node:os";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

const statusPath = join(homedir(), ".pi", "agent", "notch-status.json");

type TaskState = "completed" | "running" | "upcoming";

interface Task {
  id: string;
  name: string;
  target?: string;
  state: TaskState;
}

function toolTarget(name: string, args: unknown): string | undefined {
  if (!args || typeof args !== "object") return undefined;
  const preferred: Record<string, string[]> = {
    bash: ["command", "cmd"],
    shell: ["command", "cmd"],
    read: ["path", "file_path", "filePath", "file"],
    write: ["path", "file_path", "filePath", "file"],
    edit: ["path", "file_path", "filePath", "file"],
    multi_edit: ["path", "file_path", "filePath", "file"],
    fetch_content: ["urls", "url", "query"],
    web_search: ["urls", "url", "query"],
    get_search_content: ["urls", "url", "query"],
  };
  const record = args as Record<string, unknown>;
  for (const key of preferred[name] ?? []) {
    const value = record[key];
    if (typeof value === "string" && value) return value;
    if (Array.isArray(value) && typeof value[0] === "string") return value[0] as string;
  }
  for (const value of Object.values(record)) {
    if (typeof value === "string" && value) return value;
  }
  return undefined;
}

export default function (pi: ExtensionAPI) {
  let busy = false;
  let since = Date.now();
  let tasks: Task[] = [];
  let usage: Record<string, unknown> | null = null;
  let model: string | undefined;
  let thinking: string | undefined;
  let error: string | undefined;

  // `pi.model` / `pi.thinkingLevel` do not exist on the extension API: the
  // model and thinking level arrive through the handler's context, and the
  // finalized assistant message also carries the model it was answered with.
  const resolveModel = (ctx?: ExtensionContext, fallback?: string): string | undefined =>
    ctx?.model?.id ?? fallback ?? model;

  const resolveThinking = (ctx?: ExtensionContext): string | undefined => {
    if (ctx?.thinkingLevel) return ctx.thinkingLevel;
    try {
      return pi.getThinkingLevel();
    } catch {
      return undefined;
    }
  };

  const write = () => {
    try {
      const running = tasks.find((task) => task.state === "running");
      const last = tasks[tasks.length - 1];
      const current = running ?? last;
      const payload: Record<string, unknown> = { busy, since };
      if (model) payload.model = model;
      if (thinking) payload.thinkingLevel = thinking;
      if (error) payload.error = error;
      if (current) {
        payload.tool = {
          name: current.name,
          target: current.target,
          pending: busy && running !== undefined,
        };
      }
      if (tasks.length) payload.tasks = tasks;
      if (usage) {
        payload.usage = usage;
        const input = typeof usage.input === "number" ? usage.input : 0;
        const cacheRead = typeof usage.cacheRead === "number" ? usage.cacheRead : 0;
        if (input + cacheRead > 0) {
          payload.cacheHitRate = cacheRead / (input + cacheRead);
        }
      }
      writeFileSync(statusPath, JSON.stringify(payload));
    } catch {
      // Best-effort status reporting; never break the agent over it.
    }
  };

  const resetTurn = () => {
    tasks = [];
    usage = null;
  };

  const completeRunning = () => {
    for (const task of tasks) {
      if (task.state === "running") task.state = "completed";
    }
  };

  pi.on("session_start", async (_event, ctx) => {
    busy = false;
    since = Date.now();
    error = undefined;
    model = resolveModel(ctx) ?? model;
    thinking = resolveThinking(ctx) ?? thinking;
    resetTurn();
    write();
  });

  pi.on("agent_start", async (_event, ctx) => {
    busy = true;
    since = Date.now();
    error = undefined;
    model = resolveModel(ctx) ?? model;
    thinking = resolveThinking(ctx) ?? thinking;
    // A new user request starts a fresh task list. (`turn_start` fires per
    // model call, so it must NOT clear the accumulated tasks.)
    resetTurn();
    write();
  });

  pi.on("agent_settled", async (_event, ctx) => {
    busy = false;
    model = resolveModel(ctx) ?? model;
    thinking = resolveThinking(ctx) ?? thinking;
    // The agent settled, so nothing is executing any more.
    completeRunning();
    write();
  });

  // pi can quit, start a new session, or reload extensions while a turn is
  // running; without this the notch would stay on "working" forever.
  pi.on("session_shutdown", async () => {
    busy = false;
    completeRunning();
    write();
  });

  // The assistant message carries every tool call it decided on (so the ones
  // that have not started yet show up as "upcoming"), its token usage, and —
  // when the provider failed — the error text the notch shows instead of a
  // task.
  pi.on("message_end", async (event, ctx) => {
    const message = event.message as {
      role?: string;
      model?: string;
      usage?: Record<string, unknown>;
      stopReason?: string;
      errorMessage?: string;
      content?: Array<{ type?: string; id?: string; name?: string; arguments?: unknown }>;
    };
    if (message?.role !== "assistant") return;

    model = resolveModel(ctx, message.model) ?? model;
    thinking = resolveThinking(ctx) ?? thinking;

    if (message.stopReason === "error" || message.stopReason === "aborted") {
      error =
        message.errorMessage ??
        (message.stopReason === "aborted" ? "Aborted" : "Provider error");
      write();
      return;
    }

    error = undefined;
    const total = typeof message.usage?.totalTokens === "number" ? message.usage.totalTokens : 0;
    if (message.usage && total > 0) {
      usage = message.usage;
    }

    const calls = (message.content ?? []).filter((block) => block?.type === "toolCall");
    for (const call of calls) {
      const id = call.id ?? String(Math.random());
      if (tasks.some((task) => task.id === id)) continue;
      tasks.push({
        id,
        name: call.name ?? "tool",
        target: toolTarget(call.name ?? "", call.arguments),
        state: "upcoming" as TaskState,
      });
    }
    write();
  });

  pi.on("tool_execution_start", async (event) => {
    const existing = tasks.find((task) => task.id === event.toolCallId);
    if (existing) {
      existing.state = "running";
    } else {
      tasks.push({
        id: event.toolCallId,
        name: event.toolName,
        target: toolTarget(event.toolName, event.args),
        state: "running",
      });
    }
    write();
  });

  pi.on("tool_execution_end", async (event) => {
    const existing = tasks.find((task) => task.id === event.toolCallId);
    if (existing) {
      existing.state = "completed";
    }
    write();
  });

  pi.on("model_select", async (event, ctx) => {
    // The event carries the model that was just picked; the context may still
    // describe the previous one.
    model = event.model?.id ?? resolveModel(ctx) ?? model;
    thinking = resolveThinking(ctx) ?? thinking;
    write();
  });

  pi.on("thinking_level_select", async (event, ctx) => {
    thinking = event.level ?? resolveThinking(ctx) ?? thinking;
    write();
  });
}
