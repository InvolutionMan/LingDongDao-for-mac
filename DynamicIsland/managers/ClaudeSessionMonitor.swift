import Foundation
import Combine
import SwiftUI
import Defaults

/// Turn state derived from the tail of a Claude Code transcript JSONL file.
enum ClaudeTurnState: Equatable {
    case busy
    case idle
    case unknown
}

/// Lifecycle of the Claude live activity: running while a turn is in flight,
/// completed for a short grace period (the checkmark beat), then idle.
enum ClaudeActivityPhase: Equatable {
    case idle
    case running(since: Date)
    case completed(at: Date, startedAt: Date?)
}

/// Classifies the tail of a Claude Code transcript (`~/.claude/projects/…/<id>.jsonl`)
/// into a `ClaudeTurnState`.
///
/// A turn looks like `user(prompt) → [assistant(stop_reason:"tool_use") ↔
/// user(tool_result)]* → assistant(stop_reason:"end_turn")`. Local slash-command
/// chatter (`/model`, `/clear`, …) is recorded as user records too, so those are
/// skipped. A trailing line that fails to parse is treated as a partially
/// flushed append and skipped, falling back to the previous record.
enum ClaudeSessionTail {
    /// Record types that carry no turn-state signal.
    private static let neutralTypes: Set<String> = [
        "attachment",
        "file-history-snapshot",
        "last-prompt",
        "mode",
        "permission-mode",
        "atis-latch",
        "ai-title",
        "cost-state",
        "summary",
        "queue-operation",
        "system"
    ]

    static func state(fromTail text: String) -> ClaudeTurnState {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let type = obj["type"] as? String
            if neutralTypes.contains(type ?? "") {
                continue
            }

            switch type {
            case "assistant":
                // "tool_use" = a tool is running or the model is being called;
                // anything else ("end_turn", "max_tokens", …) ends the turn.
                let message = obj["message"] as? [String: Any] ?? [:]
                return (message["stop_reason"] as? String) == "tool_use" ? .busy : .idle
            case "user":
                switch userRecordSignal(obj) {
                case .busy: return .busy
                case .neutral: continue
                }
            default:
                continue
            }
        }
        return .unknown
    }

    private enum UserRecordSignal {
        case busy
        case neutral
    }

    /// A user record is a submitted prompt or a tool result (the model keeps
    /// working) — or local slash-command output, which is not a turn.
    private static func userRecordSignal(_ obj: [String: Any]) -> UserRecordSignal {
        let message = obj["message"] as? [String: Any] ?? [:]
        let content = message["content"]

        if let blocks = content as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                return .busy
            }
            // A list of text blocks is a submitted prompt.
            return .busy
        }

        if let text = content as? String {
            if text.contains("<local-command") || text.contains("<command-name>") {
                return .neutral
            }
            return .busy
        }

        return .neutral
    }

    /// Token usage of the most recent assistant message. Claude reports
    /// `input_tokens` excluding the cached parts, so the hit rate is
    /// `cache_read / (input + cache_read + cache_creation)`.
    static func usage(fromTail text: String) -> CLIUsage? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            let parsed = CLIUsage(
                inputTokens: (usage["input_tokens"] as? NSNumber)?.intValue,
                cacheReadTokens: (usage["cache_read_input_tokens"] as? NSNumber)?.intValue,
                cacheWriteTokens: (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue,
                outputTokens: (usage["output_tokens"] as? NSNumber)?.intValue
            )
            return parsed.isEmpty ? nil : parsed
        }
        return nil
    }

    /// The model of the most recent assistant message, e.g. "claude-sonnet-4-5".
    static func model(fromTail text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String else { continue }
            return model
        }
        return nil
    }
}

/// Watches the Claude Code CLI and reports whether it is currently executing a
/// task, driving the timer-style closed-notch live activity.
///
/// Primary signal: `~/.claude/notch-status.json`, written in real time by the
/// bundled `atoll-notch-status` Claude Code hooks (`UserPromptSubmit` / `Stop`).
/// Fallback: transcript-tail heuristics (see `ClaudeSessionTail`), for when the
/// hooks are absent.
@MainActor
final class ClaudeSessionMonitor: ObservableObject {
    static let shared = ClaudeSessionMonitor()

    /// Snapshot from the status file or the transcript-tail fallback.
    struct ClaudeSessionSample {
        var busy: Bool
        var since: Date?
        var model: String?
        var thinkingLevel: String?
        var usage: CLIUsage?
    }

    @Published private(set) var phase: ClaudeActivityPhase = .idle

    /// Model Claude Code is currently using (the most recent assistant
    /// message's model), shown in the live activity. Nil when unknown.
    @Published private(set) var model: String?

    /// Claude Code's effort level (low / medium / high / max) — its thinking
    /// degree, read from `~/.claude/settings.json`. Nil when unknown.
    @Published private(set) var thinkingLevel: String?

    /// Token usage of Claude Code's latest assistant message (cache hit rate,
    /// tokens), read from the transcript. Nil when unknown.
    @Published private(set) var usage: CLIUsage?

    /// True while the activity should be on screen (running or showing the
    /// completion checkmark).
    var isActive: Bool { phase != .idle }

    private var pollingSource: DispatchSourceTimer?
    private var statusFileSource: DispatchSourceFileSystemObject?
    private var pendingIdleReturn: DispatchWorkItem?
    private let pollingQueue = DispatchQueue(label: "dynamicisland.claude-session-monitor", qos: .utility)
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
        }
    }

    private func apply(_ sample: ClaudeSessionSample) {
        let previousUsage = usage
        model = sample.model
        thinkingLevel = sample.thinkingLevel
        usage = sample.usage
        if sample.usage != previousUsage {
            let hit = sample.usage?.cacheHitRate.map(CLIUsage.percentText) ?? "-"
            CLIActivityDebugLog.record("claude usage: hit=\(hit) tokens=\(sample.usage?.totalTokens ?? 0)")
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

    /// (Re)arms the file watcher over `~/.claude/notch-status.json` so a fresh
    /// hook write flips the live activity immediately instead of waiting for
    /// the next poll tick.
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

    /// Busy requires a live `claude` process — a stale `busy` status file
    /// (claude killed mid-turn, before `Stop` could fire) must not stick.
    nonisolated static func pollOnce(now: Date = Date(), sessionsRoot: URL? = nil) -> ClaudeSessionSample {
        guard isClaudeProcessRunning() else {
            return ClaudeSessionSample(busy: false, since: nil, model: nil, thinkingLevel: nil, usage: nil)
        }
        // Tail details fill any field the status file predates.
        let tailText = newestSessionTailText(now: now, root: sessionsRoot)
        let tailModel = tailText.flatMap { ClaudeSessionTail.model(fromTail: $0) }
        let tailUsage = tailText.flatMap { ClaudeSessionTail.usage(fromTail: $0) }

        if let status = readStatusFile() {
            let model = status.model ?? tailModel
            return ClaudeSessionSample(
                busy: status.busy,
                since: status.since.map { Date(timeIntervalSince1970: $0 / 1000) },
                model: model,
                thinkingLevel: status.thinkingLevel ?? effortLevel(forModel: model),
                usage: tailUsage
            )
        }
        return ClaudeSessionSample(
            busy: tailText.map { ClaudeSessionTail.state(fromTail: $0) == .busy } ?? false,
            since: nil,
            model: tailModel,
            thinkingLevel: effortLevel(forModel: tailModel),
            usage: tailUsage
        )
    }

    nonisolated private static var statusFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/notch-status.json")
    }

    nonisolated private static var settingsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    nonisolated private static func readStatusFile() -> (busy: Bool, since: Double?, model: String?, thinkingLevel: String?)? {
        guard let data = try? Data(contentsOf: statusFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let busy = obj["busy"] as? Bool else { return nil }
        let since = (obj["since"] as? NSNumber)?.doubleValue
        let model = obj["model"] as? String
        let thinkingLevel = obj["thinkingLevel"] as? String
        return (busy, since, model, thinkingLevel)
    }

    /// Claude Code's thinking degree: the per-model override in
    /// `modelSettings[model].effortLevel`, else the global `effortLevel`.
    nonisolated static func effortLevel(forModel model: String?) -> String? {
        guard let data = try? Data(contentsOf: settingsFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let model, let perModel = obj["modelSettings"] as? [String: Any] {
            // Settings keys can carry a context-window suffix the transcript
            // omits (or vice versa): match exactly first, then by prefix.
            if let entry = perModel[model] as? [String: Any],
               let level = entry["effortLevel"] as? String {
                return level
            }
            for (key, value) in perModel {
                guard model.hasPrefix(key) || key.hasPrefix(model),
                      let entry = value as? [String: Any],
                      let level = entry["effortLevel"] as? String else { continue }
                return level
            }
        }
        return obj["effortLevel"] as? String
    }

    /// Tail text of the newest transcript that is still plausibly the active
    /// one (the newest is authoritative at any age; older files only count
    /// while still being appended to).
    nonisolated private static func newestSessionTailText(now: Date, root: URL?) -> String? {
        let files = newestSessionFiles(limit: 3, now: now, root: root)
        for (index, file) in files.enumerated() {
            if index > 0, now.timeIntervalSince(file.modified) > 120 { continue }
            guard let tail = tailData(of: file.url),
                  let text = String(data: tail, encoding: .utf8) else { continue }
            return text
        }
        return nil
    }

    nonisolated private static func isClaudeProcessRunning() -> Bool {
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
        // `pgrep -x claude` matches the CLI's process title; the -f form covers
        // installs launched through a wrapper script.
        return pgrepSucceeds(["-x", "claude"]) || pgrepSucceeds(["-f", "local/bin/claude"])
    }

    nonisolated private static func newestSessionFiles(limit: Int, now: Date, root: URL?) -> [(url: URL, modified: Date)] {
        let sessionsRoot = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
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

    /// Reads the tail of a transcript JSONL. 256 KB keeps the current turn's
    /// assistant records in view even during long tool runs.
    nonisolated private static func tailData(of file: URL, maxBytes: Int = 262_144) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let byteCount = min(maxBytes, size)
        guard byteCount > 0, (try? handle.seek(toOffset: UInt64(size - byteCount))) != nil else { return nil }
        return try? handle.read(upToCount: byteCount)
    }
}
