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
///   model/selection                    → model + reasoning effort
///   assistant/message{usage}           → tokens and cache hit rate
///   llm/retry{failure}                 → provider failures worth surfacing
///   todo/write                         → the plan, when there is one
enum DshSessionTail {
    /// Everything the notch needs from a tail slice.
    struct Sample {
        var busy: Bool
        var model: String?
        var thinkingLevel: String?
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
        var model: String?
        var effort: String?
        var latestUsage: CLIUsage?
        var calls: [ToolCall] = []
        var pendingTodos: String?

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
                model = data["model"] as? String
                effort = data["reasoningEffort"] as? String
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
            model: model,
            thinkingLevel: effort,
            detail: hasDetail ? detail : nil
        )
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
    nonisolated static func pollOnce(now: Date = Date(), sessionsRoot: URL? = nil) -> DshSessionSample {
        guard isDshProcessRunning(),
              let session = newestSessionFile(now: now, root: sessionsRoot),
              let tail = tailText(of: session.url),
              let sample = DshSessionTail.sample(fromTail: tail) else {
            return DshSessionSample(busy: false, model: nil, thinkingLevel: nil, detail: nil)
        }
        return DshSessionSample(
            busy: sample.busy,
            model: sample.model,
            thinkingLevel: sample.thinkingLevel,
            detail: sample.detail
        )
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
        let magic = Data([0x28, 0xB5, 0x2F, 0xFD])
        var offsets: [Int] = []
        var searchStart = slice.startIndex
        while let range = slice.range(of: magic, in: searchStart..<slice.endIndex) {
            offsets.append(slice.distance(from: slice.startIndex, to: range.lowerBound))
            searchStart = range.upperBound
            if offsets.count > 4096 { break }
        }

        // Start as early as possible so the decoded window covers the whole
        // slice — the last frame alone is only a few KB, which hides the turn
        // boundary and makes a running turn look idle. Fall back to later
        // candidates when the earliest one is a false positive.
        let candidates = offsets.prefix(24)
        for offset in candidates {
            let frame = slice.subdata(in: offset..<slice.count)
            guard !frame.isEmpty, frame.count < 16 * 1024 * 1024 else { continue }
            if let text = decompress(frame, with: zstd), text.contains("\"type\":") {
                return text
            }
        }
        return nil
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
