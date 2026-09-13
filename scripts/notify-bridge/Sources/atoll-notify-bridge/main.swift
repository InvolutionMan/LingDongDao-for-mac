import AtollExtensionKit
import Foundation

/// Bridges WeChat / QQ notifications into Atoll's Dynamic Island.
///
/// Runs forever by default (launchd keeps it alive), polling the system
/// notification database for records newer than the cursor it remembers, and
/// presenting each as an Atoll live activity — the sender, optionally the
/// message body, with the app's own icon.
@main
struct NotifyBridge {
    static func main() async {
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
    static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// One poll: read what is new, present it, advance the cursor.
    @discardableResult
    static func pass(cursor: Int64, options: Options, store: StateStore) async throws -> Int64 {
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
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval = 6,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BridgeError.payload("Atoll did not answer within \(Int(seconds))s — is it running, and is this helper authorised?")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func present(_ record: BridgeNotification, options: Options) async throws {
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
        if options.usesUpdate {
            do {
                try await withTimeout { try await AtollClient.shared.updateLiveActivity(descriptor) }
            } catch {
                try await withTimeout { try await AtollClient.shared.presentLiveActivity(descriptor) }
            }
        } else {
            try await withTimeout { try await AtollClient.shared.presentLiveActivity(descriptor) }
        }
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

struct Options {
    var bundleIdentifiers: [String] = ["com.tencent.xinWeChat", "com.tencent.qq"]
    var databasePath: String = NotificationStore.defaultPath
    var statePath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".atoll/notify-bridge-state.json").path
    var extensionBundleIdentifier: String = "com.atoll.notify-bridge"
    var showsBody: Bool = false
    var usesUpdate: Bool = true
    var dismissAfter: TimeInterval? = 8
    var interval: TimeInterval = 2
    var once: Bool = false
    var dryRun: Bool = false
    var replayHistory: Bool = false
    var debug: Bool = false
    var showHelp: Bool = false
    var test: Bool = false

    init(arguments: [String]) {
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

    static let help = """
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
struct StateStore {
    let path: String

    func loadCursor(fallback: Int64?, databasePath: String) throws -> Int64 {
        if let data = FileManager.default.contents(atPath: path),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cursor = object["lastRecordID"] as? Int64 {
            return cursor
        }
        if let fallback { return fallback }
        return try NotificationStore.latestRecordID(path: databasePath)
    }

    func saveCursor(_ cursor: Int64) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: ["lastRecordID": cursor])
        try data.write(to: url, options: .atomic)
    }
}
