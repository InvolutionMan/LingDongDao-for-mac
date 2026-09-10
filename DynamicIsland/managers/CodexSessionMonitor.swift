import Foundation
import Combine
import SwiftUI
import Defaults

/// Turn state derived from the tail of a Codex rollout JSONL file.
enum CodexTurnState: Equatable {
    case busy
    case idle
    case unknown
}

/// Lifecycle of the Codex live activity: running while a turn is in flight,
/// completed for a short grace period (the checkmark beat), then idle.
enum CodexActivityPhase: Equatable {
    case idle
    case running(since: Date)
    case completed(at: Date, startedAt: Date?)
}

/// Classifies the tail of a Codex rollout JSONL (`~/.codex/sessions/…/rollout-*.jsonl`)
/// into a `CodexTurnState`.
///
/// A turn looks like `task_started → [user_message / agent_message / reasoning /
/// response_item(message|function_call|function_call_output)*] → task_complete`.
/// The writer may buffer records, so the tail can lag the live turn; this
/// heuristic is only the fallback when the status-file extension isn't
/// reporting. A trailing line that fails to parse is treated as a partially
/// flushed append and skipped, falling back to the previous record.
enum CodexSessionTail {
    /// Record types that carry no turn-state signal; a trailing run of them
    /// (token_count after task_complete, turn_context/session_meta between
    /// runs) must not resurrect busy state from earlier in the file.
    private static let neutralTopLevelTypes: Set<String> = ["session_meta", "turn_context", "world_state"]

    static func state(fromTail text: String) -> CodexTurnState {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let type = obj["type"] as? String
            if neutralTopLevelTypes.contains(type ?? "") {
                continue
            }

            let payload = obj["payload"] as? [String: Any] ?? [:]
            let payloadType = payload["type"] as? String

            switch (type, payloadType) {
            // Turn-end markers: the run is over, whatever the reason.
            case ("event_msg", "task_complete"),
                 ("event_msg", "turn_aborted"),
                 ("event_msg", "thread_rolled_back"):
                return .idle
            // Turn-start / in-turn activity: the run is still in flight.
            case ("event_msg", "task_started"),
                 ("event_msg", "user_message"),
                 ("event_msg", "agent_message"),
                 ("event_msg", "agent_reasoning"),
                 ("event_msg", "view_image_tool_call"),
                 ("event_msg", "exec_command_end"),
                 ("event_msg", "patch_apply_end"),
                 ("event_msg", "mcp_tool_call_end"),
                 ("event_msg", "web_search_end"),
                 ("event_msg", "item_completed"),
                 ("event_msg", "dynamic_tool_call_request"),
                 ("event_msg", "dynamic_tool_call_response"),
                 ("response_item", "message"),
                 ("response_item", "reasoning"),
                 ("response_item", "function_call"),
                 ("response_item", "function_call_output"),
                 ("response_item", "custom_tool_call"),
                 ("response_item", "custom_tool_call_output"),
                 ("response_item", "web_search_call"),
                 ("response_item", "tool_search_call"),
                 ("response_item", "tool_search_output"):
                return .busy
            // Heartbeats and session plumbing: carry no turn-state signal.
            case ("event_msg", "token_count"),
                 ("event_msg", "context_compacted"),
                 ("event_msg", "thread_settings_applied"):
                continue
            default:
                continue
            }
        }
        return .unknown
    }

    /// The model of the most recent `turn_context` record (written at each
    /// turn start), e.g. "gpt-5.4". Reversed scan: closest to the tail wins.
    static func model(fromTail text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "turn_context",
                  let payload = obj["payload"] as? [String: Any] else { continue }
            if let model = payload["model"] as? String {
                return model
            }
        }
        return nil
    }

    /// The reasoning effort of the most recent `turn_context` record — Codex's
    /// thinking degree (low / medium / high / xhigh), e.g. "medium".
    static func thinkingLevel(fromTail text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "turn_context",
                  let payload = obj["payload"] as? [String: Any] else { continue }
            if let level = CodexSessionTail.reasoningEffort(from: payload) {
                return level
            }
        }
        return nil
    }

    private static func reasoningEffort(from payload: [String: Any]) -> String? {
        if let collaboration = payload["collaboration_mode"] as? [String: Any],
           let settings = collaboration["settings"] as? [String: Any],
           let level = settings["reasoning_effort"] as? String {
            return level
        }
        return payload["reasoning_effort"] as? String
    }

    /// The `task_started` timestamp nearest the tail — the turn start used for
    /// the elapsed counter when the status file does not report one.
    static func since(fromTail text: String) -> Date? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "task_started" else { continue }
            guard let ts = obj["timestamp"] as? String,
                  let date = CodexSessionTail.iso8601Date(from: ts) else { continue }
            return date
        }
        return nil
    }

    /// Token usage of the most recent model call, from the newest
    /// `token_count` event's `last_token_usage`. Codex reports `input_tokens`
    /// *including* the cached part, so it is normalised to pi/Claude semantics
    /// (input = uncached prompt tokens) before the hit rate is computed.
    static func usage(fromTail text: String) -> CLIUsage? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { continue }

            let cached = (last["cached_input_tokens"] as? NSNumber)?.intValue
            let inputTotal = (last["input_tokens"] as? NSNumber)?.intValue
            let uncached = inputTotal.map { max(0, $0 - (cached ?? 0)) }
            let usage = CLIUsage(
                inputTokens: uncached,
                cacheReadTokens: cached,
                outputTokens: (last["output_tokens"] as? NSNumber)?.intValue,
                reportedTotalTokens: (last["total_tokens"] as? NSNumber)?.intValue
            )
            return usage.isEmpty ? nil : usage
        }
        return nil
    }

    static func iso8601Date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// Watches the Codex CLI and reports whether it is currently executing a task,
/// driving the timer-style closed-notch live activity.
///
/// Primary signal: `~/.codex/notch-status.json`, written in real time by a
/// `codex` hooks/extension counterpart of the bundled `atoll-notch-status` pi
/// extension (on task start/settled). Fallback: Codex rollout-tail heuristics
/// (see `CodexSessionTail`), for when the status file is absent.
@MainActor
final class CodexSessionMonitor: ObservableObject {
    static let shared = CodexSessionMonitor()

    /// Snapshot from the status file or the rollout-tail fallback.
    struct CodexSessionSample {
        var busy: Bool
        var since: Date?
        var model: String?
        var thinkingLevel: String?
        var usage: CLIUsage?
        var activity: CLIToolActivity?
    }

    @Published private(set) var phase: CodexActivityPhase = .idle

    /// Model Codex is currently using (the most recent turn's model), shown in
    /// the live activity. Nil when unknown.
    @Published private(set) var model: String?

    /// Codex's current thinking degree (reasoning effort: low / medium /
    /// high / xhigh), shown in the live activity. Nil when unknown.
    @Published private(set) var thinkingLevel: String?

    /// Token usage of Codex's latest model call (cache hit rate, tokens), read
    /// from the rollout's `token_count` events. Nil when unknown.
    @Published private(set) var usage: CLIUsage?

    /// What Codex is executing right now — the running tool, the turn's tasks
    /// and whether it failed, written by the Codex hook (~/.codex/hooks.json).
    @Published private(set) var activity: CLIToolActivity?

    /// True while the activity should be on screen (running or showing the
    /// completion checkmark).
    var isActive: Bool { phase != .idle }

    /// True while a turn is in flight — the panel says "Working…" instead of
    /// "No tool activity yet" in the gap between two tool calls.
    var isBusy: Bool {
        if case .running = phase { return true }
        return false
    }

    private var pollingSource: DispatchSourceTimer?
    private var statusFileSource: DispatchSourceFileSystemObject?
    private var pendingIdleReturn: DispatchWorkItem?
    private let pollingQueue = DispatchQueue(label: "dynamicisland.codex-session-monitor", qos: .utility)
    private var cancellables = Set<AnyCancellable>()

    /// Status changes are made inside `withAnimation` so the notch content swap
    /// (idle pill ⇄ live activity) gets the same animated transitions as the timer.
    func startMonitoring() {
        guard pollingSource == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: pollingQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            let result = Self.pollOnce()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(result)
                self.refreshStatusWatcher()
            }
        }
        timer.resume()
        pollingSource = timer
        refreshStatusWatcher()
    }

    func stopMonitoring() {
        pollingSource?.cancel()
        pollingSource = nil
        statusFileSource?.cancel()
        statusFileSource = nil
        pendingIdleReturn?.cancel()
        pendingIdleReturn = nil
        withAnimation(.smooth) {
            phase = .idle
            model = nil
            thinkingLevel = nil
            usage = nil
            activity = nil
        }
    }

    private func apply(_ sample: CodexSessionSample) {
        let previousUsage = usage
        let previousActivity = activity
        model = sample.model
        thinkingLevel = sample.thinkingLevel
        usage = sample.usage
        activity = sample.activity
        // Waiting for the user's confirmation is an edge, not a state: chime
        // once per prompt.
        if let confirm = sample.activity?.confirmation, confirm != previousActivity?.confirmation {
            CLIFinishSound.play(.confirmation, reason: confirm)
        }
        if sample.activity != previousActivity {
            let line = sample.activity?.current.map {
                "\($0.name) \($0.target ?? "-") \($0.isRunning ? "running" : "idle")"
            } ?? "none"
            CLIActivityDebugLog.record("codex activity: \(line)")
        }
        if sample.usage != previousUsage {
            let hit = sample.usage?.cacheHitRate.map(CLIUsage.percentText) ?? "-"
            CLIActivityDebugLog.record("codex usage: hit=\(hit) tokens=\(sample.usage?.totalTokens ?? 0)")
        }

        if sample.busy {
            // A new turn during the completion beat cancels the dismissal.
            pendingIdleReturn?.cancel()
            pendingIdleReturn = nil
            let previousStart: Date?
            if case .running(let existing) = phase { previousStart = existing } else { previousStart = nil }
            let since = sample.since ?? previousStart ?? Date()
            // Same animated swap as the timer start: idle pill ⇄ running activity.
            withAnimation(.smooth) {
                phase = .running(since: since)
            }
        } else if case .running(let startedAt) = phase {
            // Elapsed counter ⇄ completion checkmark, mirroring the timer's finish beat.
            withAnimation(.smooth(duration: 0.3)) {
                phase = .completed(at: Date(), startedAt: startedAt)
            }
            // Finish chime: the Codex hook reports failed tools (is_error /
            // non-zero exit / interrupted), so the sound matches the outcome.
            let succeeded = sample.activity?.finishedSuccessfully ?? true
            CLIFinishSound.play(
                succeeded ? .success : .failure,
                reason: succeeded ? nil : (sample.activity?.errorMessage ?? "tool failed")
            )
            CLIActivityDebugLog.record(
                "codex finish: \(succeeded ? "success" : "failure") error=\(sample.activity?.errorMessage != nil ? 1 : 0) toolFailed=\(sample.activity?.toolFailed == true ? 1 : 0)"
            )
            scheduleIdleReturn()
        }
        // busy=false while already completed or idle: hold the completion beat.
    }

    /// Keeps the completion checkmark on screen briefly, then returns to idle.
    private func scheduleIdleReturn() {
        let work = DispatchWorkItem { [weak self] in
            // Smooth-close back to the idle pill, like the timer's completion close.
            withAnimation(.easeInOut(duration: 1.0)) {
                self?.phase = .idle
            }
            self?.pendingIdleReturn = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
        pendingIdleReturn = work
    }

    /// (Re)arms the file watcher over `~/.codex/notch-status.json` so a fresh
    /// status write flips the live activity immediately instead of waiting for
    /// the next poll tick. Called after every poll, so the watcher arms as soon
    /// as the status file exists and is dropped while it is missing (a later
    /// poll re-arms it when the file comes back).
    private func refreshStatusWatcher() {
        if FileManager.default.fileExists(atPath: Self.statusFileURL.path) {
            if statusFileSource == nil {
                armStatusWatcher()
            }
        } else {
            statusFileSource?.cancel()
            statusFileSource = nil
        }
    }

    private func armStatusWatcher() {
        let fd = open(Self.statusFileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: pollingQueue
        )
        source.setEventHandler { [weak self] in
            let result = Self.pollOnce()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(result)
                // Drop and re-arm: an atomic rewrite may have replaced the file
                // underneath this fd (now watching an unlinked inode), so a fresh
                // watcher keeps the next status write instantaneous.
                self.statusFileSource?.cancel()
                self.statusFileSource = nil
                self.refreshStatusWatcher()
            }
        }
        source.setCancelHandler {
            close(fd)
        }

        statusFileSource = source
        source.resume()
    }

    /// Busy requires a live `codex` process — a stale `busy` status file (codex
    /// killed mid-turn, before `task_complete` could fire) must not stick.
    nonisolated static func pollOnce(now: Date = Date(), sessionsRoot: URL? = nil) -> CodexSessionSample {
        guard isCodexProcessRunning() else {
            return CodexSessionSample(busy: false, since: nil, model: nil, thinkingLevel: nil, usage: nil, activity: nil)
        }
        // Tail details fill any field the status file predates.
        let tailText = newestSessionTailText(now: now, root: sessionsRoot)
        let tailModel = tailText.flatMap { CodexSessionTail.model(fromTail: $0) }
        let tailThinking = tailText.flatMap { CodexSessionTail.thinkingLevel(fromTail: $0) }
        let tailUsage = tailText.flatMap { CodexSessionTail.usage(fromTail: $0) }

        if let status = readStatusFile() {
            return CodexSessionSample(
                busy: status.busy,
                since: status.since.map { Date(timeIntervalSince1970: $0 / 1000) },
                model: status.model ?? tailModel,
                thinkingLevel: status.thinkingLevel ?? tailThinking,
                usage: tailUsage,
                activity: status.activity
            )
        }
        return CodexSessionSample(
            busy: tailText.map { CodexSessionTail.state(fromTail: $0) == .busy } ?? false,
            since: tailText.flatMap { CodexSessionTail.since(fromTail: $0) },
            model: tailModel,
            thinkingLevel: tailThinking,
            usage: tailUsage,
            activity: nil
        )
    }

    nonisolated private static var statusFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/notch-status.json")
    }

    nonisolated private static func readStatusFile() -> (
        busy: Bool, since: Double?, model: String?, thinkingLevel: String?, activity: CLIToolActivity?
    )? {
        guard let data = try? Data(contentsOf: statusFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let busy = obj["busy"] as? Bool else { return nil }
        let since = (obj["since"] as? NSNumber)?.doubleValue
        let model = obj["model"] as? String
        let thinkingLevel = obj["thinkingLevel"] as? String
        return (busy, since, model, thinkingLevel, CLIToolActivity.from(status: obj))
    }

    /// Tail text of the newest rollout file that is still plausibly the active
    /// one (the newest is authoritative at any age; older files only count
    /// while still being appended to).
    nonisolated private static func newestSessionTailText(now: Date, root: URL?) -> String? {
        let files = newestSessionFiles(limit: 3, now: now, root: root)
        for (index, file) in files.enumerated() {
            // A long tool run appends nothing for minutes; the newest file is
            // authoritative at any age, but an abandoned older session can't
            // fake activity.
            if index > 0, now.timeIntervalSince(file.modified) > 120 { continue }
            guard let tail = tailData(of: file.url),
                  let text = String(data: tail, encoding: .utf8) else { continue }
            return text
        }
        return nil
    }

    nonisolated private static func isCodexProcessRunning() -> Bool {
        func pgrepSucceeds(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        // `pgrep -x codex` matches the CLI's exact process title; the -f form
        // covers the desktop/extension-host workloads running under ~/.codex.
        return pgrepSucceeds(["-x", "codex"]) || pgrepSucceeds(["-f", "codex"])
    }

    nonisolated private static func newestSessionFiles(limit: Int, now: Date, root: URL?) -> [(url: URL, modified: Date)] {
        let sessionsRoot = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, modified))
        }
        return files
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map { ($0.url, $0.modified) }
    }

    /// Reads the tail of a rollout JSONL. 256 KB keeps the current turn's
    /// model / reasoning-effort records in view even when long tool runs have
    /// appended many `function_call_output` messages (48 of 53 historical
    /// sessions resolve at this window, vs. 30 at 64 KB).
    nonisolated private static func tailData(of file: URL, maxBytes: Int = 262_144) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let byteCount = min(maxBytes, size)
        guard byteCount > 0, (try? handle.seek(toOffset: UInt64(size - byteCount))) != nil else { return nil }
        return try? handle.read(upToCount: byteCount)
    }
}
