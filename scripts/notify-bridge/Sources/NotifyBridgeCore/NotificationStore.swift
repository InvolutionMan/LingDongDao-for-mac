import Foundation
import SQLite3

/// sqlite3 tells us how long a bound string must live; the macro is not exposed
/// to Swift, so it is spelled out (`SQLITE_TRANSIENT` = -1).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One notification the system recorded, already filtered to the apps we care
/// about.
public struct BridgeNotification: Equatable {
    public let recordID: Int64
    public let bundleIdentifier: String
    /// Who wrote it: WeChat/QQ put the sender in the subtitle, other apps in the
    /// title.
    public let sender: String
    public let body: String?
    public let appName: String
    public let deliveredAt: Date?

    public init(
        recordID: Int64,
        bundleIdentifier: String,
        sender: String,
        body: String?,
        appName: String,
        deliveredAt: Date?
    ) {
        self.recordID = recordID
        self.bundleIdentifier = bundleIdentifier
        self.sender = sender
        self.body = body
        self.appName = appName
        self.deliveredAt = deliveredAt
    }
}

/// Reads the system's notification database.
///
/// macOS keeps every delivered notification in
/// `~/Library/Group Containers/group.com.apple.usernoted/db2/db`; the payload is
/// a binary plist in `record.data`. Reading it needs Full Disk Access, which is
/// why this runs as its own helper instead of inside Atoll.
public enum NotificationStore {
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
            .path
    }

    /// Highest `rec_id` currently in the database — the starting cursor, so a
    /// fresh install does not replay weeks of history.
    public static func latestRecordID(path: String) throws -> Int64 {
        let db = try open(path, readOnly: true)
        defer { sqlite3_close(db) }
        return try scalarInt(db, "select coalesce(max(rec_id), 0) from record;")
    }

    /// Everything newer than `afterID`, oldest first.
    public static func records(after afterID: Int64, path: String, appIDs: [String]) throws -> [BridgeNotification] {
        let db = try open(path, readOnly: true)
        defer { sqlite3_close(db) }

        let placeholders = appIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
            select r.rec_id, a.identifier, r.data, r.delivered_date
            from record r join app a on a.app_id = r.app_id
            where r.rec_id > ? and a.identifier in (\(placeholders))
            order by r.rec_id asc
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BridgeError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, afterID)
        for (index, appID) in appIDs.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 2), appID, -1, SQLITE_TRANSIENT)
        }

        var found: [BridgeNotification] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let identifier = string(statement, 1), let blob = data(statement, 2) else { continue }
            guard let payload = NotificationPayload(data: blob) else { continue }
            found.append(
                BridgeNotification(
                    recordID: sqlite3_column_int64(statement, 0),
                    bundleIdentifier: identifier,
                    sender: payload.sender,
                    body: payload.body,
                    appName: payload.appName ?? Self.friendlyName(for: identifier),
                    deliveredAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3))
                )
            )
        }
        return found
    }

    public static func friendlyName(for bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case "com.tencent.xinWeChat": return "微信"
        case "com.tencent.qq": return "QQ"
        default: return bundleIdentifier
        }
    }

    // MARK: - sqlite plumbing

    private static func open(_ path: String, readOnly: Bool) throws -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: path) else {
            throw BridgeError.notFound(path)
        }
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            throw BridgeError.sqlite("cannot open \(path) — Full Disk Access missing?")
        }
        return db
    }

    private static func scalarInt(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BridgeError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private static func string(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    private static func data(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }
}

enum BridgeError: LocalizedError {
    case notFound(String)
    case sqlite(String)
    case payload(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "notification database not found at \(path)"
        case .sqlite(let message):
            return "sqlite: \(message)"
        case .payload(let message):
            return "notification payload: \(message)"
        }
    }
}
