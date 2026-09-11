import AppKit
import Combine
import Defaults
import SwiftUI

/// Reads a DSH session (`dst`, i.e. `dsh --profile dsh-tui`) and classifies it
/// exactly like the pi hook reports: the tool running now, the turn's task list,
/// cache hit rate and whether the turn failed.
///
/// DSH has no hook to install — its session file *is* the source. It is written
/// as zstd-compressed JSONL, one small frame per flush, so only the tail is
/// decompressed (a few KB, ~5 ms) instead of the whole (multi-megabyte) file.
///
/// Records used:
///   turn/start · turn/end{reason}      → busy, and whether the turn failed
///   tool/call · tool/result{isError}   → the running tool, the turn's tasks
///   request/header{config}             → model + reasoning effort (per request)
///   model/selection                    → model + reasoning effort (on a switch)
///   assistant/message{usage}           → tokens and cache hit rate
///   llm/retry{failure}                 → provider failures worth surfacing
///   todo/write                         → the plan, when there is one
enum DshSessionTail {
    /// Everything the notch needs from a tail slice.
    struct Sample {
        var busy: Bool
        var model: String?
        var thinkingLevel: String?
        /// Whether the slice contained a record naming the model at all. Both
        /// such records are rare, so `nil` model usually means "it is further
        /// back", which the caller answers with its own memory + a deep scan.
        var sawModelInfo: Bool
        var detail: PiLiveDetail?
    }

    /// One `tool/call` record plus whether a result has landed for it.
    private struct ToolCall {
        let id: String
        let name: String
        let target: String?
        var completed: Bool
        var failed: Bool
    }

    // MARK: - Record parsing

    private static func records(fromTail text: String) -> [[String: Any]] {
        var objects: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            objects.append(object)
        }
        return objects
    }

    private static func payload(_ record: [String: Any]) -> [String: Any] {
        record["data"] as? [String: Any] ?? [:]
    }

    /// DSH reports tool arguments as a JSON *string*; the interesting ones are
    /// the same keys pi uses, plus the DSH-only tools.
    static func toolTarget(name: String, arguments: String?) -> String? {
        guard let arguments, let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return arguments.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
        }

        let keys: [String: [String]] = [
            "bash": ["command", "cmd"],
            "read": ["path", "file_path", "filePath"],
            "write": ["path", "file_path", "filePath"],
            "edit": ["path", "file_path", "filePath"],
            "read_image": ["path", "file_path"],
            "grep": ["pattern", "query"],
            "glob": ["pattern"],
            "web_fetch": ["url", "query"],
            "job_output": ["job_id", "id", "jobId"],
            "ask_user_question": ["question", "prompt"],
            "todo_write": ["todos", "plan"],
            "copy": ["source", "path"],
        ]

        for key in keys[name] ?? [] {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? [String], let first = value.first { return first }
            // todo_write: surface the item being worked on.
            if let todos = object[key] as? [[String: Any]],
               let active = todos.first(where: { ($0["status"] as? String) == "in_progress" }),
               let text = (active["content"] ?? active["activeForm"]) as? String {
                return text
            }
        }
        for value in object.values {
            if let value = value as? String, !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Model + thinking level

    /// DSH names the active model in two records: `model/selection` (written when
    /// the model or the reasoning effort is switched) and `request/header`, the
    /// config of every LLM request. The latter is the one that keeps reappearing
    /// near the tail, but it is still only written once per request — on a long
    /// turn it sits hundreds of kilobytes behind the end of the file.
    ///
    /// Returns nil for any record that does not name a model.
    static func modelInfo(from record: [String: Any]) -> (model: String, effort: String?)? {
        switch record["type"] as? String {
        case "model/selection":
            let data = payload(record)
            guard let model = data["model"] as? String, !model.isEmpty else { return nil }
            return (model, data["reasoningEffort"] as? String)
        case "request/header":
            let header = payload(record)["header"] as? [String: Any]
            let config = header?["config"] as? [String: Any]
            guard let model = config?["model"] as? String, !model.isEmpty else { return nil }
            return (model, config?["reasoningEffort"] as? String)
        default:
            return nil
        }
    }

    /// Same, for a single JSONL line (used when scanning much further back).
    static func modelInfo(fromLine line: String) -> (model: String, effort: String?)? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return modelInfo(from: object)
    }

    /// The newest model record in a whole block of JSONL, e.g. a deep scan
    /// window: later records win, and an effort-less record keeps the effort
    /// reported before it.
    static func newestModelInfo(in text: String) -> (model: String, effort: String?)? {
        var found: (model: String, effort: String?)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"model/selection\"") || line.contains("\"request/header\"") else { continue }
            guard let info = modelInfo(fromLine: String(line)) else { continue }
            found = (info.model, info.effort ?? found?.effort)
        }
        return found
    }

    private static func usage(from object: [String: Any]) -> CLIUsage? {
        let input = (object["inputTokens"] as? NSNumber)?.intValue
        let output = (object["outputTokens"] as? NSNumber)?.intValue
        let cacheRead = (object["cacheReadTokens"] as? NSNumber)?.intValue
        let total = (object["totalTokens"] as? NSNumber)?.intValue
        let parsed = CLIUsage(
            inputTokens: input,
            cacheReadTokens: cacheRead,
            outputTokens: output,
            reportedTotalTokens: total
        )
        return parsed.isEmpty ? nil : parsed
    }

    // MARK: - Classification

    /// Classifies the tail of a session file.
    static func sample(fromTail text: String) -> Sample? {
        let records = records(fromTail: text)
        guard !records.isEmpty else { return nil }

        // Start from the current turn: everything after the last turn boundary.
        // Window = the last turn: start at its `turn/start`, or — when that has
        // scrolled out of the tail — just after the previous `turn/end`, i.e.
        // inside the turn that is still running. With no boundary at all the
        // window sits inside a running turn.
        let boundaryIndex = records.lastIndex {
            let type = $0["type"] as? String
            return type == "turn/start" || type == "turn/end"
        }
        var startIndex = 0
        var busy: Bool? = true
        if let boundaryIndex {
            let isStart = (records[boundaryIndex]["type"] as? String) == "turn/start"
            busy = isStart
            if isStart {
                startIndex = boundaryIndex
            } else {
                // Finished turn: include its tool calls by rewinding to its own
                // `turn/start`, so the task list and usage are complete.
                startIndex = records[..<boundaryIndex].lastIndex {
                    ($0["type"] as? String) == "turn/start"
                } ?? boundaryIndex
            }
        }
        let current = records[startIndex...]
        var endReason: String?
        var failureMessage: String?
        var latestUsage: CLIUsage?
        var calls: [ToolCall] = []
        var pendingTodos: String?

        // The model is *not* part of the turn window: `model/selection` is
        // written when it is switched and `request/header` once per request, so
        // on the turn being watched it is usually missing. Scan the whole slice
        // instead, newest record wins.
        var modelInfo: (model: String, effort: String?)?
        for record in records {
            if let info = DshSessionTail.modelInfo(from: record) { modelInfo = info }
        }

        for record in current {
            let type = record["type"] as? String
            let data = payload(record)

            switch type {
            case "turn/start":
                busy = true
            case "turn/end":
                busy = false
                if let reason = data["reason"] as? [String: Any] {
                    endReason = reason["kind"] as? String
                }
            case "tool/call":
                let id = data["callId"] as? String ?? UUID().uuidString
                let name = data["name"] as? String ?? "tool"
                calls.append(
                    ToolCall(
                        id: id,
                        name: name,
                        target: toolTarget(name: name, arguments: data["arguments"] as? String),
                        completed: false,
                        failed: false
                    )
                )
            case "tool/result":
                let message = data["message"] as? [String: Any] ?? [:]
                let source = message["source"] as? [String: Any] ?? [:]
                let callId = source["callId"] as? String
                var isError = false
                for block in (message["content"] as? [[String: Any]]) ?? [] {
                    if block["type"] as? String == "tool-result", (block["isError"] as? Bool) == true {
                        isError = true
                    }
                }
                if let index = calls.lastIndex(where: { $0.id == callId || (callId == nil && !$0.completed) }) {
                    calls[index].completed = true
                    calls[index].failed = isError
                }
            case "model/selection":
                // Parsed above, across the whole slice.
                continue
            case "assistant/message":
                if let raw = data["usage"] as? [String: Any], let parsed = usage(from: raw) {
                    latestUsage = parsed
                }
            case "llm/retry":
                if let failure = data["failure"] as? [String: Any] {
                    failureMessage = (failure["message"] as? String) ?? (failure["code"] as? String)
                }
            case "todo/write":
                if let todos = data["todos"] as? [[String: Any]],
                   let active = todos.first(where: { ($0["status"] as? String) == "in_progress" }),
                   let text = (active["content"] ?? active["activeForm"]) as? String {
                    pendingTodos = text
                }
            default:
                continue
            }
        }

        let isBusy = busy ?? false

        // The running tool is the first call with no result yet — the same rule
        // the pi hook applies to its task list.
        var tasks: [PiTaskItem] = []
        var runningIndex: Int?
        for (index, call) in calls.enumerated() {
            let state: PiTaskItem.State
            if call.completed {
                state = .completed
            } else if runningIndex == nil {
                state = .running
                runningIndex = index
            } else {
                state = .upcoming
            }
            tasks.append(PiTaskItem(id: call.id, name: call.name, target: call.target, state: state))
        }

        var detail = PiLiveDetail()
        detail.tasks = tasks
        detail.toolFailed = calls.last?.failed ?? false
        detail.inputTokens = latestUsage?.inputTokens
        detail.outputTokens = latestUsage?.outputTokens
        detail.cacheReadTokens = latestUsage?.cacheReadTokens
        detail.totalTokens = latestUsage.map { $0.totalTokens }
        detail.cacheHitRate = latestUsage?.cacheHitRate

        let runningCall = runningIndex.map { calls[$0] }
        detail.toolName = runningCall?.name ?? calls.last?.name
        detail.toolTarget = runningCall?.target ?? calls.last?.target
        detail.toolIsPending = runningCall != nil && isBusy

        // DSH asks through a tool: while it is running, the agent is blocked on
        // the user, which is the confirmation case.
        if let running = runningCall, running.name == "ask_user_question" {
            detail.confirmation = running.target ?? "Waiting for your answer"
        } else if isBusy, runningCall == nil, let pendingTodos {
            // Between tools: the plan is the most useful thing to show.
            detail.toolTarget = pendingTodos
        }

        // A turn that did not finish cleanly is a failure (user aborts included);
        // a retry that recovered is not, because the turn ends `completed`.
        if let endReason, endReason != "completed" {
            detail.errorMessage = failureMessage ?? "Turn \(endReason)"
        }

        let hasDetail = !detail.isEmpty
        return Sample(
            busy: isBusy,
            model: modelInfo?.model,
            thinkingLevel: modelInfo?.effort,
            sawModelInfo: modelInfo != nil,
            detail: hasDetail ? detail : nil
        )
    }
}

/// The model and thinking level of the session file currently being watched.
///
/// Both records that carry them are rare, so most polls miss them; the value is
/// therefore remembered per file, and a file seen for the first time is deep
/// scanned once. The class is tiny and lockable on purpose: polling happens on a
/// utility queue, not on the main actor.
final class DshModelMemory {
    static let shared = DshModelMemory()

    struct Entry {
        var model: String?
        var thinkingLevel: String?
    }

    private let lock = NSLock()
    private var file: String?
    private var model: String?
    private var thinkingLevel: String?
    private var scanned: Set<String> = []

    /// Last known values, but only for the same file — a new session must not
    /// inherit the previous one's model.
    func cached(for file: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard self.file == file else { return nil }
        return Entry(model: model, thinkingLevel: thinkingLevel)
    }

    /// Remembers whatever the poll resolved. Nil values keep the previous answer
    /// for the same file, so a tail without a model record does not blank it.
    func store(file: String, model: String?, thinkingLevel: String?) {
        lock.lock()
        defer { lock.unlock() }
        if self.file != file {
            self.file = file
            self.model = nil
            self.thinkingLevel = nil
        }
        if let model, !model.isEmpty { self.model = model }
        if let thinkingLevel, !thinkingLevel.isEmpty { self.thinkingLevel = thinkingLevel }
    }

    /// True exactly once per session file: the deep scan is expensive, so a file
    /// is only ever walked back through once.
    func claimDeepScan(for file: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !scanned.contains(file) else { return false }
        if scanned.count > 64 { scanned.removeAll() }
        scanned.insert(file)
        return true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        model = nil
        thinkingLevel = nil
        scanned.removeAll()
    }
}

/// Watches the DSH CLI (`dst`) and drives the timer-style closed-notch activity,
/// mirroring `PiSessionMonitor` — the difference is the source: DSH has no hook,
/// so this tails the newest session file instead.
@MainActor
final class DshSessionMonitor: ObservableObject {
    static let shared = DshSessionMonitor()

    struct DshSessionSample {
        var busy: Bool
        var model: String?
        var thinkingLevel: String?
        var detail: PiLiveDetail?
        /// Where the model came from — `tail`, `memory`, `scan`, `settings`.
        var source: String?
    }

    @Published private(set) var phase: PiActivityPhase = .idle
    @Published private(set) var model: String?
    @Published private(set) var thinkingLevel: String?
    @Published private(set) var detail: PiLiveDetail?

    /// True while the activity should be on screen (running or showing the
    /// completion checkmark).
    var isActive: Bool { phase != .idle }

    private var pollingSource: DispatchSourceTimer?
    private var pendingIdleReturn: DispatchWorkItem?
    private let pollingQueue = DispatchQueue(label: "dynamicisland.dsh-session-monitor", qos: .utility)
    private var cancellables = Set<AnyCancellable>()

    func startMonitoring() {
        guard pollingSource == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: pollingQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            let result = Self.pollOnce()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(result)
            }
        }
        timer.resume()
        pollingSource = timer
    }

    func stopMonitoring() {
        pollingSource?.cancel()
        pollingSource = nil
        pendingIdleReturn?.cancel()
        pendingIdleReturn = nil
        withAnimation(.smooth) {
            phase = .idle
            model = nil
            thinkingLevel = nil
            detail = nil
        }
    }

    private func apply(_ sample: DshSessionSample) {
        let previousDetail = detail
        if sample.model != model || sample.thinkingLevel != thinkingLevel {
            CLIActivityDebugLog.record(
                "dsh model: \(sample.model ?? "-") level=\(sample.thinkingLevel ?? "-") via \(sample.source ?? "-")"
            )
        }
        model = sample.model
        thinkingLevel = sample.thinkingLevel
        detail = sample.detail

        // Waiting for the user's answer is an edge, not a state: chime once.
        if let confirmation = sample.detail?.confirmation,
           confirmation != previousDetail?.confirmation {
            CLIFinishSound.play(.confirmation, reason: confirmation)
        }

        if sample.detail != previousDetail {
            let line = sample.detail?.toolName.map {
                "\($0) \(sample.detail?.toolTarget ?? "-") \(sample.detail?.toolIsPending == true ? "running" : "idle")"
            } ?? "none"
            CLIActivityDebugLog.record("dsh activity: \(line)")
        }

        if sample.busy {
            pendingIdleReturn?.cancel()
            pendingIdleReturn = nil
            let previousStart: Date?
            if case .running(let existing) = phase { previousStart = existing } else { previousStart = nil }
            withAnimation(.smooth) {
                phase = .running(since: previousStart ?? Date())
            }
        } else if case .running(let startedAt) = phase {
            withAnimation(.smooth(duration: 0.3)) {
                phase = .completed(at: Date(), startedAt: startedAt)
            }
            if let detail = sample.detail {
                let succeeded = detail.errorMessage == nil && !detail.toolFailed
                CLIFinishSound.play(
                    succeeded ? .success : .failure,
                    reason: succeeded ? nil : (detail.errorMessage ?? "tool failed")
                )
                CLIActivityDebugLog.record(
                    "dsh finish: \(succeeded ? "success" : "failure") error=\(detail.errorMessage != nil ? 1 : 0) toolFailed=\(detail.toolFailed ? 1 : 0)"
                )
            }
            scheduleIdleReturn(after: sample.detail?.errorMessage == nil ? 2.6 : 12)
        }
    }

    private func scheduleIdleReturn(after delay: TimeInterval = 2.6) {
        pendingIdleReturn?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeInOut(duration: 1.0)) {
                self?.phase = .idle
            }
            self?.pendingIdleReturn = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        pendingIdleReturn = work
    }

    // MARK: - Polling

    /// DSH must be running, and a session file must be fresh enough to describe
    /// what it is doing right now.
    nonisolated static func pollOnce(
        now: Date = Date(),
        sessionsRoot: URL? = nil,
        memory: DshModelMemory = .shared
    ) -> DshSessionSample {
        let empty = DshSessionSample(busy: false, model: nil, thinkingLevel: nil, detail: nil, source: nil)
        guard isDshProcessRunning(),
              let session = newestSessionFile(now: now, root: sessionsRoot),
              let tail = tailText(of: session.url),
              let sample = DshSessionTail.sample(fromTail: tail) else {
            return empty
        }

        let key = session.url.path
        var model = sample.model
        var effort = sample.thinkingLevel
        var source = sample.sawModelInfo ? "tail" : nil
        if model == nil {
            if let cached = memory.cached(for: key) {
                model = cached.model
                effort = cached.thinkingLevel
                source = "memory"
            } else if memory.claimDeepScan(for: key) {
                if let deep = deepScanModelInfo(of: session.url) {
                    model = deep.model
                    effort = deep.effort
                    source = "scan"
                } else if let fallback = defaultModelInfo() {
                    // Nothing in the session names the model yet (it is written
                    // with the first request): the configured default is the
                    // honest answer.
                    model = fallback.model
                    effort = fallback.effort
                    source = "settings"
                }
            }
        }
        memory.store(file: key, model: model, thinkingLevel: effort)

        return DshSessionSample(
            busy: sample.busy,
            model: model,
            thinkingLevel: effort,
            detail: sample.detail,
            source: source
        )
    }

    /// DSH model ids are long and heavily suffixed
    /// (`deepseek-v4.1-flash-expires-on-0910`); the closed pill only has room for
    /// the recognisable part. The full id stays in the tooltip and in the
    /// expanded panel.
    nonisolated static func shortModelName(_ model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        var name = model
        for prefix in ["deepseek-", "deepseek/", "deepseek:"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        if let range = name.range(of: "-expires-on-") { name = String(name[..<range.lowerBound]) }
        for suffix in ["-preview", "-latest", "-experimental"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name.isEmpty ? model : name
    }

    /// `dst` is the launcher; the running app is `node …/bin/dsh --profile …`.
    nonisolated private static func isDshProcessRunning() -> Bool {
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
        return pgrepSucceeds(["-x", "dst"]) || pgrepSucceeds(["-f", "bin/dsh"])
    }

    /// Newest session file. DSH keeps one directory per session under
    /// `~/.dsh/sessions/<workspace>/<session-id>/`.
    nonisolated private static func newestSessionFile(now: Date, root: URL?) -> (url: URL, modified: Date)? {
        let sessionsRoot = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return nil }

        var best: (url: URL, modified: Date)?
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("session.jsonl") else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if best == nil || modified > best!.modified {
                best = (url, modified)
            }
        }
        // A file nobody has touched for minutes is not "running now".
        guard let best, now.timeIntervalSince(best.modified) < 600 else { return nil }
        return best
    }

    // MARK: - zstd tail

    /// Decompresses the end of a session file.
    ///
    /// The file is a concatenation of small independently-compressed frames (one
    /// per flush), and `zstd` refuses to start mid-frame, so this walks back to
    /// the last frame whose decompression produces JSON.
    nonisolated private static func tailText(of file: URL, maxBytes: Int = 262_144) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return nil }
        let sliceLength = min(maxBytes, size)
        guard (try? handle.seek(toOffset: UInt64(size - sliceLength))) != nil,
              let slice = try? handle.read(upToCount: sliceLength) else { return nil }

        // Uncompressed sessions (older DSH versions) can be read directly.
        if let text = String(data: slice, encoding: .utf8), text.contains("\"type\":") {
            return text
        }

        guard let zstd = zstdExecutable() else { return nil }

        // Start as early as possible so the decoded window covers the whole
        // slice — the last frame alone is only a few KB, which hides the turn
        // boundary and makes a running turn look idle. Fall back to later
        // candidates when the earliest one is a false positive.
        for offset in frameOffsets(in: slice).prefix(24) {
            let frame = slice.subdata(in: offset..<slice.count)
            guard !frame.isEmpty, frame.count < 16 * 1024 * 1024 else { continue }
            if let text = decompress(frame, with: zstd), text.contains("\"type\":") {
                return text
            }
        }
        return nil
    }

    // MARK: - Looking further back for the model

    /// `model/selection` is written on a switch and `request/header` once per
    /// request, so neither is guaranteed to be inside the tail: on a long turn
    /// the nearest one can sit hundreds of kilobytes — sometimes megabytes —
    /// behind the end of the file.
    ///
    /// This walks back in growing windows until a model record shows up. Windows
    /// are streamed through `zstd | grep | tail`, so even a 32 MB slice is never
    /// expanded into memory. Runs at most once per session file.
    nonisolated private static func deepScanModelInfo(of file: URL) -> (model: String, effort: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return nil }

        for window in [2 << 20, 8 << 20, 32 << 20] {
            let length = min(window, size)
            guard (try? handle.seek(toOffset: UInt64(size - length))) != nil,
                  let slice = try? handle.read(upToCount: length), !slice.isEmpty else { break }
            if let info = DshSessionTail.newestModelInfo(in: modelRecordLines(inWindow: slice)) {
                return info
            }
            if size <= window { break }
        }
        return nil
    }

    /// The model-naming lines of a raw slice of the session file. Frames are
    /// independent, so any run of them decodes; the first candidate that decodes
    /// to something wins.
    nonisolated private static func modelRecordLines(inWindow window: Data) -> String {
        guard let zstd = zstdExecutable() else { return "" }
        let offsets = frameOffsets(in: window)
        guard !offsets.isEmpty else { return "" }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-dsh-scan-\(ProcessInfo.processInfo.processIdentifier).zst")
        defer { try? FileManager.default.removeItem(at: temp) }

        for offset in offsets.prefix(24) {
            let frame = window.subdata(in: offset..<window.count)
            guard !frame.isEmpty, (try? frame.write(to: temp)) != nil else { continue }
            let command = "\(shellQuote(zstd.path)) -dc \(shellQuote(temp.path))"
                + " | /usr/bin/grep -E '\"type\": ?\"(model/selection|request/header)\"'"
                + " | /usr/bin/tail -n 8"
            if let text = runShell(command), text.contains("\"type\"") {
                return text
            }
        }
        return ""
    }

    /// DSH's configured default (`agent-default-model` in `~/.dsh/settings.yaml`),
    /// used only when the session itself has not named a model yet.
    nonisolated private static func defaultModelInfo() -> (model: String, effort: String?)? {
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/settings.yaml")
        guard let text = try? String(contentsOf: settings, encoding: .utf8) else { return nil }
        return defaultModelInfo(settings: text)
    }

    /// Reads the `agent-default-model` block of a DSH settings file:
    /// ```yaml
    /// agent-default-model:
    ///   provider: deepseek-official
    ///   model: deepseek-v4.1-flash-expires-on-0910
    ///   reasoningEffort: max
    /// ```
    nonisolated static func defaultModelInfo(settings: String) -> (model: String, effort: String?)? {
        var inside = false
        var model: String?
        var effort: String?
        for rawLine in settings.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let indented = rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t")
            if !indented {
                if inside { break }  // the block ended
                inside = line.hasPrefix("agent-default-model:")
                continue
            }
            guard inside, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "model": if !value.isEmpty { model = value }
            case "reasoningEffort", "reasoning-effort", "thinking": if !value.isEmpty { effort = value }
            default: continue
            }
        }
        guard let model else { return nil }
        return (model, effort)
    }

    // MARK: - Process helpers

    /// Offsets of every zstd frame magic inside a slice (false positives are
    /// filtered by whether the run actually decodes).
    nonisolated private static func frameOffsets(in slice: Data) -> [Int] {
        let magic = Data([0x28, 0xB5, 0x2F, 0xFD])
        var offsets: [Int] = []
        var searchStart = slice.startIndex
        while let range = slice.range(of: magic, in: searchStart..<slice.endIndex) {
            offsets.append(slice.distance(from: slice.startIndex, to: range.lowerBound))
            searchStart = range.upperBound
            if offsets.count > 4096 { break }
        }
        return offsets
    }

    nonisolated private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a shell pipeline and returns its stdout as text (empty on failure).
    nonisolated private static func runShell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func decompress(_ data: Data, with zstd: URL) -> String? {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-dsh-tail-\(ProcessInfo.processInfo.processIdentifier).zst")
        guard (try? data.write(to: temp)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: temp) }

        let process = Process()
        process.executableURL = zstd
        process.arguments = ["-dc", temp.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `zstd` ships with Homebrew on macOS (and the DSH profile's own toolchain
    /// on Linux); without it the DSH activity simply stays hidden.
    nonisolated private static func zstdExecutable() -> URL? {
        let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd", "/opt/local/bin/zstd"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
