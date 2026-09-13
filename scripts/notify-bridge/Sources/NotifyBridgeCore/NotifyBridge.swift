import AtollExtensionKit
import Foundation

/// Bridges WeChat / QQ notifications into Atoll's Dynamic Island.
///
/// Runs forever by default (launchd keeps it alive), polling the system
/// notification database for records newer than the cursor it remembers, and
/// presenting each as an Atoll live activity — the sender, optionally the
/// message body, with the app's own icon.
public struct NotifyBridge {
    public static func run() async {
        let options = Options(arguments: Array(CommandLine.arguments.dropFirst()))

        if options.showHelp {
            print(Options.help)
            return
        }

        if options.test {
            do {
                let sample = BridgeNotification(
                    recordID: -1,
                    bundleIdentifier: options.bundleIdentifiers[0],
                    sender: "测试联系人",
                    body: "这是一条来自 atoll-notify-bridge 的测试消息",
                    appName: NotificationStore.friendlyName(for: options.bundleIdentifiers[0]),
                    deliveredAt: Date()
                )
                printLine(sample, options: options)
                try await NotifyBridge.present(sample, options: options)
                print("presented — check the island (an authorisation prompt may appear)")
            } catch {
                FileHandle.standardError.write(Data(("test failed: \(error.localizedDescription)\n").utf8))
                exit(1)
            }
            return
        }

        let store = StateStore(path: options.statePath)
        var cursor: Int64?

        while true {
            do {
                if cursor == nil {
                    cursor = try store.loadCursor(
                        fallback: options.replayHistory ? 0 : nil,
                        databasePath: options.databasePath
                    )
                    note("watching \(options.bundleIdentifiers.joined(separator: ", ")) from record \(cursor ?? 0)")
                }
                cursor = try await pass(cursor: cursor ?? 0, options: options, store: store)
            } catch {
                // Reported once every pass — a bridge that cannot read the
                // database (usually Full Disk Access) should say so in its log
                // rather than fail silently, and must keep running so it picks
                // up the moment the permission is granted.
                note("cannot read notifications: \(error.localizedDescription)")
                cursor = nil
                if options.once { exit(1) }
            }
            if options.once { return }
            try? await Task.sleep(nanoseconds: UInt64(options.interval * 1_000_000_000))
        }
    }

    /// Always written: the launch agent's log is the only place a user can see
    /// why nothing shows up.
    public static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// One poll: read what is new, present it, advance the cursor.
    @discardableResult
    public static func pass(cursor: Int64, options: Options, store: StateStore) async throws -> Int64 {
        let records = try NotificationStore.records(
            after: cursor,
            path: options.databasePath,
            appIDs: options.bundleIdentifiers
        )
        guard !records.isEmpty else { return cursor }

        var newest = cursor
        for record in records {
            newest = max(newest, record.recordID)
            printLine(record, options: options)
            guard !options.dryRun else { continue }
            do {
                try await present(record, options: options)
            } catch {
                log("could not present \(record.sender): \(error.localizedDescription)", options: options)
            }
        }
        try store.saveCursor(newest)
        return newest
    }

    /// Atoll answers over XPC; if it is not running — or refuses this helper
    /// because the helper is not a proper app bundle — the call would otherwise
    /// hang forever, which under launchd means a wedged agent.
    public static func withTimeout<T: Sendable>(
        seconds: TimeInterval = 6,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // A task group cannot be used here: the kit's XPC callback is capable of
        // leaking its continuation (seen in practice — "leaked its continuation
        // without resuming it"), and a group waits for every child before it
        // returns, so the timeout would hang exactly like the call it guards.
        // Racing a timer and abandoning the loser keeps the agent alive.
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var finished = false
            func finish(_ result: Result<T, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }
            Task {
                do { finish(.success(try await work())) } catch { finish(.failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                finish(.failure(BridgeError.payload(
                    "Atoll did not answer within \(Int(seconds))s — is it running, and is this helper authorised?"
                )))
            }
        }
    }

    public static func present(_ record: BridgeNotification, options: Options) async throws {
        let descriptor = AtollLiveActivityDescriptor(
            id: "\(record.bundleIdentifier)-\(record.sender)",
            bundleIdentifier: options.extensionBundleIdentifier,
            priority: .normal,
            title: record.sender,
            subtitle: options.showsBody ? record.body : record.appName,
            leadingIcon: .appIcon(
                bundleIdentifier: record.bundleIdentifier,
                size: CGSize(width: 20, height: 20),
                cornerRadius: 4
            ),
            estimatedDuration: options.dismissAfter
        )
        // Presenting again with the same id replaces the activity, which is what
        // keeps one sender to one row; the kit's `updateLiveActivity` is avoided
        // on purpose (it leaks its XPC continuation, hanging the caller).
        try await withTimeout { try await AtollClient.shared.presentLiveActivity(descriptor) }
    }

    private static func printLine(_ record: BridgeNotification, options: Options) {
        let body = options.showsBody ? " — \(record.body ?? "")" : ""
        print("[\(record.appName)] \(record.sender)\(body)")
    }

    private static func log(_ message: String, options: Options) {
        guard options.debug else { return }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

// MARK: - Options

public struct Options {
    public var bundleIdentifiers: [String] = ["com.tencent.xinWeChat", "com.tencent.qq"]
    public var databasePath: String = NotificationStore.defaultPath
    public var statePath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".atoll/notify-bridge-state.json").path
    public var extensionBundleIdentifier: String = "com.atoll.notify-bridge"
    public var showsBody: Bool = false
    public var usesUpdate: Bool = false
    public var dismissAfter: TimeInterval? = 8
    public var interval: TimeInterval = 2
    public var once: Bool = false
    public var dryRun: Bool = false
    public var replayHistory: Bool = false
    public var debug: Bool = false
    public var showHelp: Bool = false
    public var test: Bool = false

    public init(arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() -> String? {
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }
            switch argument {
            case "--apps": if let list = value() { bundleIdentifiers = list.split(separator: ",").map(String.init) }
            case "--database": if let path = value() { databasePath = path }
            case "--state": if let path = value() { statePath = path }
            case "--extension-id": if let id = value() { extensionBundleIdentifier = id }
            case "--body": showsBody = true
            case "--no-update": usesUpdate = false
            case "--persistent": dismissAfter = nil
            case "--dismiss-after": if let seconds = value().flatMap(Double.init) { dismissAfter = seconds }
            case "--interval": if let seconds = value().flatMap(Double.init) { interval = seconds }
            case "--once": once = true
            case "--dry-run": dryRun = true
            case "--replay-history": replayHistory = true
            case "--debug": debug = true
            case "--test": test = true
            case "--help", "-h": showHelp = true
            default: break
            }
            index += 1
        }
    }

    public static let help = """
    atoll-notify-bridge — show WeChat / QQ messages in Atoll's Dynamic Island

      --test                 present one made-up message and exit
      --once                 scan once and exit (handy for testing)
      --dry-run              print what would be shown, without touching Atoll
      --body                 include the message body (default: sender only)
      --apps a,b             bundle identifiers to watch
                             (default: com.tencent.xinWeChat,com.tencent.qq)
      --interval seconds     poll interval (default 2)
      --dismiss-after secs   auto-dismiss the activity after a while (8)
      --persistent           never auto-dismiss
      --no-update            present a new activity instead of updating
      --replay-history       start from the beginning of the database
      --state path           cursor file (default ~/.atoll/notify-bridge-state.json)
      --database path        notification database
      --extension-id id      bundle id Atoll authorises for this bridge
      --debug                log to stderr
    """
}

// MARK: - Cursor

/// Remembers the last notification handled, so a restart does not replay the
/// whole database — and a fresh install starts from "now" unless asked
/// otherwise.
public struct StateStore {
    public let path: String

    public func loadCursor(fallback: Int64?, databasePath: String) throws -> Int64 {
        if let data = FileManager.default.contents(atPath: path),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cursor = object["lastRecordID"] as? Int64 {
            return cursor
        }
        if let fallback { return fallback }
        return try NotificationStore.latestRecordID(path: databasePath)
    }

    public func saveCursor(_ cursor: Int64) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: ["lastRecordID": cursor])
        try data.write(to: url, options: .atomic)
    }
}


/// The pieces the executable and the tests share.
public enum Bridge {
    public static let defaultBundleIdentifiers = ["com.tencent.xinWeChat", "com.tencent.qq"]
}
