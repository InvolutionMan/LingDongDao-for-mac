import Foundation
import Combine
import SwiftUI
import Defaults

/// Turn state derived from the tail of a pi session JSONL file.
enum PiTurnState: Equatable {
    case busy
    case idle
    case unknown
}

/// Lifecycle of the pi live activity: running while a turn is in flight,
/// completed for a short grace period (the checkmark beat), then idle.
enum PiActivityPhase: Equatable {
    case idle
    case running(since: Date)
    case completed(at: Date, startedAt: Date?)
}

/// One tool call of the current turn, as a task with a state.
struct PiTaskItem: Equatable, Identifiable {
    enum State: Equatable {
        case completed
        case running
        case upcoming
    }

    let id: String
    let name: String
    let target: String?
    var state: State
}

/// Live detail shown in the hover-expanded pi activity: what pi is reading or
/// running right now, the turn's task list, and the latest response's usage.
struct PiLiveDetail: Equatable {
    /// What the user asked for — the request that started this turn. Shown at
    /// the top of the card so the panel says what the task is *for*, not just
    /// which tool is running.
    var goal: String?
    var toolName: String?
    var toolTarget: String?
    /// True when the tool call has no result yet (still executing).
    var toolIsPending: Bool = false
    /// The current turn's tool calls: done, running and still queued.
    var tasks: [PiTaskItem] = []
    var cacheHitRate: Double?
    var totalTokens: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    /// Provider failure text (e.g. a 429) reported by the pi hook, so the
    /// notch can say why pi stopped instead of looking merely idle.
    var errorMessage: String?
    /// The turn's last tool finished with an error (failed command, read, …),
    /// which counts as a failed task for the finish sound.
    var toolFailed: Bool = false
    /// Set while pi is blocked waiting for the user (permission prompt,
    /// approval dialog): the notch plays the confirmation sound and says so.
    var confirmation: String?

    var isEmpty: Bool {
        goal == nil && toolName == nil && totalTokens == nil && cacheHitRate == nil && tasks.isEmpty
            && errorMessage == nil && !toolFailed && confirmation == nil
    }

    /// Longest goal kept from a session, so a pasted wall of text cannot bloat
    /// the panel or the monitor's memory.
    static let goalLimit = 400
}

/// Classifies the tail of a pi session JSONL into a `PiTurnState`.
///
/// A turn looks like `user → [assistant(stopReason:"toolUse") ↔ toolResult]* →
/// assistant(stopReason:"stop")`. Pi's session writer buffers records (flushing
/// roughly every 16 KB or at process exit), so the tail can lag the live turn;
/// this heuristic is only the fallback when the status-file extension isn't
/// reporting. A trailing line that fails to parse is treated as a partially
/// flushed append and skipped, falling back to the previous record.
enum PiSessionTail {
    static func state(fromTail text: String) -> PiTurnState {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if obj["type"] as? String == "message" {
                let message = obj["message"] as? [String: Any] ?? [:]
                switch message["role"] as? String {
                case "toolResult":
                    // Tool finished; the next model call is already in flight.
                    return .busy
                case "assistant":
                    // "toolUse" = a tool is running or the model is being called;
                    // any other stopReason ("stop", "aborted", …) ends the turn.
                    return (message["stopReason"] as? String) == "toolUse" ? .busy : .idle
                case "user":
                    // Submitted and not answered yet — the model is thinking.
                    return .busy
                default:
                    continue
                }
            }

            // `!command` runs hand control back to the user.
            if obj["type"] as? String == "bashExecution" {
                return .idle
            }
        }
        return .unknown
    }

    /// The model of the most recent assistant message, falling back to the
    /// most recent `model_change` record (session-level model switch). Reversed
    /// scan: whichever record is closest to the tail wins.
    static func model(fromTail text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if obj["type"] as? String == "message",
               let message = obj["message"] as? [String: Any],
               message["role"] as? String == "assistant",
               let model = message["model"] as? String {
                return model
            }

            if obj["type"] as? String == "model_change",
               let model = obj["modelId"] as? String {
                return model
            }
        }
        return nil
    }

    /// The most recent `thinking_level_change` record — pi's current thinking
    /// degree (off / minimal / low / medium / high / max).
    static func thinkingLevel(fromTail text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if obj["type"] as? String == "thinking_level_change",
               let level = obj["thinkingLevel"] as? String {
                return level
            }
        }
        return nil
    }

    /// The plain text of a user message, or nil when it carries none (tool
    /// results and system reminders also arrive as user messages).
    static func userText(in message: [String: Any]) -> String? {
        guard let content = message["content"] else {
            return (message["text"] as? String)?.trimmedForGoal
        }
        if let text = content as? String { return text.trimmedForGoal }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let joined = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        return joined.trimmedForGoal
    }

    /// Live detail for the hover-expanded panel: the tool pi is running (or the
    /// last one it ran), its target, and the latest response's token usage.
    static func detail(fromTail text: String) -> PiLiveDetail? {
        var calls: [(id: String?, name: String?, target: String?)] = []
        var completedIDs = Set<String>()
        var usage: [String: Any]?
        var goal: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Cheap pre-filter: most records are text/thinking and carry none
            // of the fields we need, and the tail can be hundreds of KB.
            guard line.contains("toolCall") || line.contains("toolResult")
                    || line.contains("\"usage\"") || line.contains("\"role\":\"user\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "message" else { continue }

            let message = obj["message"] as? [String: Any] ?? [:]
            switch message["role"] as? String {
            case "user":
                // A new prompt starts a new turn: the task list is per-turn.
                calls.removeAll()
                completedIDs.removeAll()
                if let text = userText(in: message) {
                    goal = text
                }
            case "assistant":
                if let latestUsage = message["usage"] as? [String: Any] {
                    usage = latestUsage
                }
                if let content = message["content"] as? [[String: Any]] {
                    for block in content where block["type"] as? String == "toolCall" {
                        let name = block["name"] as? String
                        calls.append((
                            block["id"] as? String,
                            name,
                            toolTarget(name: name, arguments: block["arguments"] as? [String: Any])
                        ))
                    }
                }
            case "toolResult":
                if let id = message["toolCallId"] as? String {
                    completedIDs.insert(id)
                }
            default:
                continue
            }
        }

        // A call without a matching result is still running; otherwise the last
        // finished call is shown.
        let pending = calls.last { call in
            guard let id = call.id else { return false }
            return !completedIDs.contains(id)
        }
        let chosen = pending ?? calls.last

        var detail = PiLiveDetail()
        detail.goal = goal
        detail.toolName = chosen?.name
        detail.toolTarget = chosen?.target
        detail.toolIsPending = pending != nil

        // Turn task list: done → running → still queued. Only the first
        // un-resulted call is actually executing; the rest are queued.
        var runningAssigned = false
        detail.tasks = calls.compactMap { call in
            guard let name = call.name else { return nil }
            let id = call.id ?? UUID().uuidString
            let isCompleted = call.id.map { completedIDs.contains($0) } ?? false
            let state: PiTaskItem.State
            if isCompleted {
                state = .completed
            } else if runningAssigned {
                state = .upcoming
            } else {
                state = .running
                runningAssigned = true
            }
            return PiTaskItem(id: id, name: name, target: call.target, state: state)
        }

        if let usage {
            let input = (usage["input"] as? NSNumber)?.intValue
            let output = (usage["output"] as? NSNumber)?.intValue
            let cacheRead = (usage["cacheRead"] as? NSNumber)?.intValue
            detail.inputTokens = input
            detail.outputTokens = output
            detail.cacheReadTokens = cacheRead
            detail.totalTokens = (usage["totalTokens"] as? NSNumber)?.intValue
                ?? [input, output, cacheRead].compactMap { $0 }.reduce(0, +)
            if let input, let cacheRead, input + cacheRead > 0 {
                detail.cacheHitRate = Double(cacheRead) / Double(input + cacheRead)
            }
        }

        return detail.isEmpty ? nil : detail
    }

    /// A short, human-readable target for a tool call — the command for bash,
    /// the path for read/write/edit, the first URL for fetches.
    private static func toolTarget(name: String?, arguments: [String: Any]?) -> String? {
        guard let arguments else { return nil }

        let preferred: [String]
        switch name {
        case "bash", "shell":
            preferred = ["command", "cmd"]
        case "read", "write", "edit", "multi_edit":
            preferred = ["path", "file_path", "filePath", "file"]
        case "fetch_content", "web_search", "get_search_content":
            preferred = ["urls", "url", "query"]
        default:
            preferred = []
        }

        for key in preferred {
            if let value = arguments[key] as? String, !value.isEmpty { return value }
            if let values = arguments[key] as? [String], let first = values.first { return first }
        }
        for value in arguments.values {
            if let string = value as? String, !string.isEmpty { return string }
        }
        return nil
    }
}

/// Watches the pi CLI and reports whether it is currently executing a task,
/// driving the timer-style closed-notch live activity.
///
/// Primary signal: `~/.pi/agent/notch-status.json`, written in real time by the
/// bundled `atoll-notch-status` pi extension on `agent_start`/`agent_settled`.
/// Fallback: session-tail heuristics (see `PiSessionTail`), for when the
/// extension is absent.
@MainActor
final class PiSessionMonitor: ObservableObject {
    static let shared = PiSessionMonitor()

    /// Snapshot from the status file or the session-tail fallback.
    struct PiSessionSample {
        var busy: Bool
        var since: Date?
        var model: String?
        var thinkingLevel: String?
        var detail: PiLiveDetail?
    }

    @Published private(set) var phase: PiActivityPhase = .idle

    /// Model pi is currently using (or used for the last response), shown in
    /// the live activity. Nil when unknown.
    @Published private(set) var model: String?

    /// pi's current thinking degree (off / minimal / low / medium / high / max),
    /// shown in the live activity. Nil when unknown.
    @Published private(set) var thinkingLevel: String?

    /// Hover-expanded detail: current tool activity and token usage.
    @Published private(set) var detail: PiLiveDetail?

    /// True while the activity should be on screen (running or showing the
    /// completion checkmark).
    var isActive: Bool { phase != .idle }

    private var pollingSource: DispatchSourceTimer?
    private var statusFileSource: DispatchSourceFileSystemObject?
    private var pendingIdleReturn: DispatchWorkItem?
    private let pollingQueue = DispatchQueue(label: "dynamicisland.pi-session-monitor", qos: .utility)
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
            detail = nil
        }
    }

    private func apply(_ sample: PiSessionSample) {
        let previousDetail = detail
        model = sample.model
        thinkingLevel = sample.thinkingLevel
        detail = sample.detail
        // Waiting for the user's confirmation is an edge, not a state: chime
        // once per prompt.
        if let confirm = sample.detail?.confirmation, confirm != previousDetail?.confirmation {
            CLIFinishSound.play(.confirmation, reason: confirm)
        }

        // One line per change (not per poll) so the support log shows whether the
        // pi extension's tool/task data actually reached the app.
        if sample.detail != previousDetail {
            CLIActivityDebugLog.record(
                "pi detail: tasks=\(sample.detail?.tasks.count ?? 0) running=\(sample.detail?.tasks.filter { $0.state == .running }.count ?? 0) tool=\(sample.detail?.toolName ?? "-") error=\(sample.detail?.errorMessage != nil ? 1 : 0) toolFailed=\(sample.detail?.toolFailed == true ? 1 : 0) hit=\(sample.detail?.cacheHitRate.map(CLIUsage.percentText) ?? "-")"
            )
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
            // Finish chime: the hook marks provider failures (connection,
            // timeout, output, rate limit) as `error`, so a turn that ends with
            // one gets the failure sound instead of the success sound. A sample
            // with no detail at all means the process vanished, which is neither
            // and stays silent.
            if let detail = sample.detail {
                // A provider error (connection, timeout, output, rate limit) or
                // a turn whose last tool failed both count as a failure.
                let succeeded = detail.errorMessage == nil && !detail.toolFailed
                CLIFinishSound.play(
                    succeeded ? .success : .failure,
                    reason: succeeded ? nil : (detail.errorMessage ?? "tool failed")
                )
                CLIActivityDebugLog.record(
                    "finish: \(succeeded ? "success" : "failure") error=\(detail.errorMessage != nil ? 1 : 0) toolFailed=\(detail.toolFailed ? 1 : 0)"
                )
            } else {
                CLIActivityDebugLog.record("finish sound skipped: pi process gone without a status")
            }
            // A provider error keeps the activity (and its panel) on screen
            // long enough to be read.
            scheduleIdleReturn(after: sample.detail?.errorMessage == nil ? 2.6 : 12)
        }
        // busy=false while already completed or idle: hold the completion beat.
    }

    /// Keeps the completion checkmark on screen briefly, then returns to idle.
    private func scheduleIdleReturn(after delay: TimeInterval = 2.6) {
        pendingIdleReturn?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Smooth-close back to the idle pill, like the timer's completion close.
            withAnimation(.easeInOut(duration: 1.0)) {
                self?.phase = .idle
            }
            self?.pendingIdleReturn = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        pendingIdleReturn = work
    }

    /// (Re)arms the file watcher over `~/.pi/agent/notch-status.json` so an
    /// `agent_start`/`agent_settled` write flips the live activity immediately
    /// instead of waiting for the next poll tick. Called after every poll, so
    /// the watcher arms as soon as the status file exists and is dropped while
    /// it is missing (a later poll re-arms it when the file comes back).
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
                // watcher keeps the next `agent_settled` write instantaneous.
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

    /// Busy requires a live `pi` process — a stale `busy` status file (pi killed
    /// mid-turn, before `agent_settled` could fire) must not stick.
    nonisolated static func pollOnce(now: Date = Date(), sessionsRoot: URL? = nil) -> PiSessionSample {
        guard isPiProcessRunning() else {
            return PiSessionSample(busy: false, since: nil, model: nil, thinkingLevel: nil, detail: nil)
        }
        // Tail details fill any field the status file predates (older
        // extension versions wrote only busy/since).
        let tailText = newestSessionTailText(now: now, root: sessionsRoot)
        let tailModel = tailText.flatMap { PiSessionTail.model(fromTail: $0) }
        let tailThinking = tailText.flatMap { PiSessionTail.thinkingLevel(fromTail: $0) }
        let tailDetail = tailText.flatMap { PiSessionTail.detail(fromTail: $0) }

        if let status = readStatusFile() {
            return PiSessionSample(
                busy: status.busy,
                since: status.since.map { Date(timeIntervalSince1970: $0 / 1000) },
                model: status.model ?? tailModel,
                thinkingLevel: status.thinkingLevel ?? tailThinking,
                detail: status.detail ?? tailDetail
            )
        }
        return PiSessionSample(
            busy: tailText.map { PiSessionTail.state(fromTail: $0) == .busy } ?? false,
            since: nil,
            model: tailModel,
            thinkingLevel: tailThinking,
            detail: tailDetail
        )
    }

    nonisolated private static var statusFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/notch-status.json")
    }

    nonisolated private static func readStatusFile() -> (busy: Bool, since: Double?, model: String?, thinkingLevel: String?, detail: PiLiveDetail?)? {
        guard let data = try? Data(contentsOf: statusFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let busy = obj["busy"] as? Bool else { return nil }
        let since = (obj["since"] as? NSNumber)?.doubleValue
        let model = obj["model"] as? String
        let thinkingLevel = obj["thinkingLevel"] as? String
        return (busy, since, model, thinkingLevel, detail(fromStatus: obj))
    }

    /// Parses the rich fields the pi extension writes (tool / tasks / usage),
    /// which are real-time while the session file still lags behind.
    nonisolated private static func detail(fromStatus obj: [String: Any]) -> PiLiveDetail? {
        var detail = PiLiveDetail()

        if let tool = obj["tool"] as? [String: Any] {
            detail.toolName = tool["name"] as? String
            detail.toolTarget = tool["target"] as? String
            detail.toolIsPending = (tool["pending"] as? Bool) ?? false
        }

        if let tasks = obj["tasks"] as? [[String: Any]] {
            detail.tasks = tasks.compactMap { task in
                guard let name = task["name"] as? String else { return nil }
                let state: PiTaskItem.State
                switch task["state"] as? String {
                case "completed": state = .completed
                case "running": state = .running
                default: state = .upcoming
                }
                return PiTaskItem(
                    id: task["id"] as? String ?? UUID().uuidString,
                    name: name,
                    target: task["target"] as? String,
                    state: state
                )
            }
        }

        if let usage = obj["usage"] as? [String: Any] {
            detail.inputTokens = (usage["input"] as? NSNumber)?.intValue
            detail.outputTokens = (usage["output"] as? NSNumber)?.intValue
            detail.cacheReadTokens = (usage["cacheRead"] as? NSNumber)?.intValue
            detail.totalTokens = (usage["totalTokens"] as? NSNumber)?.intValue
                ?? [detail.inputTokens, detail.outputTokens, detail.cacheReadTokens].compactMap { $0 }.reduce(0, +)
        }

        if let hit = obj["cacheHitRate"] as? NSNumber {
            detail.cacheHitRate = hit.doubleValue
        }

        if let error = obj["error"] as? String, !error.isEmpty {
            detail.errorMessage = error
        }

        detail.toolFailed = (obj["failed"] as? Bool) ?? false
        if let confirm = obj["confirm"] as? String, !confirm.isEmpty {
            detail.confirmation = confirm
        }

        return detail.isEmpty ? nil : detail
    }

    /// Tail text of the newest session file that is still plausibly the active
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

    /// Live `pi` processes, matched the way `pgrep -x pi` does: the CLI rewrites
    /// its process title (`process.title = "pi"`), which lives in the argv region
    /// (`KERN_PROCARGS`) — the kernel's `p_comm` still reads "node" there, so
    /// matching on `KERN_PROC` alone never finds it.
    nonisolated static func piProcessPIDs() -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // The process table can grow between the size probe and the read
        // (sysctl then fails with ENOMEM); retry once with a padded buffer.
        for padding in [0, Int(MemoryLayout<kinfo_proc>.size * 8)] {
            var count = (size + padding) / MemoryLayout<kinfo_proc>.size
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
            var actualSize = count * MemoryLayout<kinfo_proc>.size
            guard sysctl(&mib, 4, &procs, &actualSize, nil, 0) == 0 else { continue }

            count = actualSize / MemoryLayout<kinfo_proc>.size
            var pids: [Int32] = []
            for i in 0..<count {
                let pid = procs[i].kp_proc.p_pid
                if pid > 0, hasProcessTitle("pi", for: pid) {
                    pids.append(pid)
                }
            }
            return pids
        }
        return []
    }

    /// True when the process's title (the NUL-terminated strings of its argv
    /// region) contains exactly `title`.
    nonisolated private static func hasProcessTitle(_ title: String, for pid: Int32) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return false }
        return buffer.withUnsafeBufferPointer { raw in
            guard let base = raw.baseAddress else { return false }
            let data = Data(bytes: base, count: size)
            return data.split(separator: 0, omittingEmptySubsequences: true)
                .contains { String(decoding: $0, as: UTF8.self) == title }
        }
    }

    nonisolated private static func isPiProcessRunning() -> Bool {
        !piProcessPIDs().isEmpty
    }

    nonisolated private static func newestSessionFiles(limit: Int, now: Date, root: URL?) -> [(url: URL, modified: Date)] {
        let sessionsRoot = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions")
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

    /// Reads the tail of a session JSONL. 64 KB keeps the most recent turn's
    /// model / thinking records in view even when a long tool run has appended
    /// many tool-result messages (each only a few hundred bytes).
    nonisolated private static func tailData(of file: URL, maxBytes: Int = 262_144) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let byteCount = min(maxBytes, size)
        guard byteCount > 0, (try? handle.seek(toOffset: UInt64(size - byteCount))) != nil else { return nil }
        return try? handle.read(upToCount: byteCount)
    }
}

extension String {
    /// Trims a captured user request and caps it, so a pasted wall of text does
    /// not travel through the monitors or the panel.
    var trimmedForGoal: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > PiLiveDetail.goalLimit
            ? String(trimmed.prefix(PiLiveDetail.goalLimit)) + "…"
            : trimmed
    }
}
