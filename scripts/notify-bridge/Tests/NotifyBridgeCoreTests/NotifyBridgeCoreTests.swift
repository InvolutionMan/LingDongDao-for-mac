import Foundation
import SQLite3
import XCTest
@testable import NotifyBridgeCore

/// The bridge only has two jobs: read the system notification database and turn
/// one of its records into a sender the island can show. Both are tested here
/// against synthetic fixtures, so a real WeChat message is not needed to know
/// whether the parsing still works.
final class NotifyBridgeCoreTests: XCTestCase {

    // MARK: - Payload

    /// The shape macOS stores: strings under `req`.
    func testPayloadPrefersTheSubtitleAsSender() throws {
        let data = try plist([
            "app": "com.tencent.xinWeChat",
            "req": ["titl": "微信", "subt": "张三", "body": "在吗？"],
        ])
        let payload = try XCTUnwrap(NotificationPayload(data: data))
        XCTAssertEqual(payload.sender, "张三")
        XCTAssertEqual(payload.body, "在吗？")
    }

    /// Plenty of apps put the sender in the title and the app name in the
    /// subtitle; that must not turn into "from 微信".
    func testPayloadFallsBackToTheTitleWhenTheSubtitleIsTheAppName() throws {
        let data = try plist([
            "app": "com.apple.MobileSMS",
            "req": ["titl": "李四", "subt": "信息", "appn": "信息", "body": "hello"],
        ])
        let payload = try XCTUnwrap(NotificationPayload(data: data))
        XCTAssertEqual(payload.sender, "李四")
    }

    func testPayloadRejectsGarbage() {
        XCTAssertNil(NotificationPayload(data: Data("not a plist".utf8)))
        // A plist without any title is not a notification we can show.
        XCTAssertNil(NotificationPayload(data: (try? plist(["app": "x"])) ?? Data()))
    }

    // MARK: - Database

    func testRecordsAreFilteredByAppAndCursor() throws {
        let database = try FixtureDatabase(records: [
            (1, "com.apple.terminal", ["req": ["titl": "Command finished"]]),
            (2, "com.tencent.xinWeChat", ["req": ["titl": "微信", "subt": "张三", "body": "在吗？"]]),
            (3, "com.tencent.qq", ["req": ["titl": "QQ", "subt": "李四", "body": "晚上见"]]),
            (4, "com.apple.terminal", ["req": ["titl": "Command finished"]]),
        ])
        defer { database.cleanUp() }

        let all = try NotificationStore.records(
            after: 0,
            path: database.path,
            appIDs: ["com.tencent.xinWeChat", "com.tencent.qq"]
        )
        XCTAssertEqual(all.map(\.recordID), [2, 3], "only the watched apps, oldest first")
        XCTAssertEqual(all.first?.sender, "张三")
        XCTAssertEqual(all.first?.appName, "微信")

        let newer = try NotificationStore.records(
            after: 2,
            path: database.path,
            appIDs: ["com.tencent.xinWeChat", "com.tencent.qq"]
        )
        XCTAssertEqual(newer.map(\.recordID), [3], "the cursor skips what was already handled")

        XCTAssertEqual(try NotificationStore.latestRecordID(path: database.path), 4)
    }

    func testUnreadableDatabaseIsAnErrorNotACrash() {
        XCTAssertThrowsError(
            try NotificationStore.records(after: 0, path: "/tmp/atoll-no-such-db", appIDs: ["com.tencent.qq"])
        )
    }

    // MARK: - Options and cursor

    func testOptionsParseTheFlagsTheInstallerUses() {
        let options = Options(arguments: [
            "--body", "--interval", "5", "--once", "--dry-run",
            "--apps", "com.tencent.xinWeChat,com.tencent.qq",
            "--extension-id", "com.atoll.notify-bridge",
        ])
        XCTAssertTrue(options.showsBody)
        XCTAssertTrue(options.once)
        XCTAssertTrue(options.dryRun)
        XCTAssertEqual(options.interval, 5)
        XCTAssertEqual(options.bundleIdentifiers, ["com.tencent.xinWeChat", "com.tencent.qq"])
        XCTAssertEqual(options.extensionBundleIdentifier, "com.atoll.notify-bridge")
    }

    func testCursorRoundTripsAndFallsBackToTheDatabase() throws {
        let database = try FixtureDatabase(records: [(7, "com.tencent.qq", ["req": ["titl": "QQ"]])])
        defer { database.cleanUp() }
        let statePath = database.directory.appendingPathComponent("state.json").path
        let store = StateStore(path: statePath)

        // No state yet: start from "now", never from the beginning of history.
        XCTAssertEqual(
            try store.loadCursor(fallback: nil, databasePath: database.path), 7,
            "a fresh install must not replay weeks of notifications"
        )
        try store.saveCursor(9)
        XCTAssertEqual(try store.loadCursor(fallback: nil, databasePath: database.path), 9)
        XCTAssertEqual(try store.loadCursor(fallback: 0, databasePath: database.path), 9, "state wins over the flag")
    }

    // MARK: - Fixtures

    private func plist(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    /// A miniature of the system database: same table and column names for the
    /// parts the bridge reads.
    private struct FixtureDatabase {
        let directory: URL
        let path: String

        init(records: [(Int64, String, [String: Any])]) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("atoll-bridge-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent("db").path

            var handle: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
            let db = try XCTUnwrap(handle)
            defer { sqlite3_close(db) }

            try exec(db, """
                create table app (app_id integer primary key, identifier varchar, badge integer null);
                create table record (rec_id integer primary key, app_id integer, uuid blob,
                                     data blob, delivered_date real);
                """)

            var appIDs: [String: Int64] = [:]
            for (recordID, identifier, payload) in records {
                let appID: Int64
                if let existing = appIDs[identifier] {
                    appID = existing
                } else {
                    appID = Int64(appIDs.count + 1)
                    appIDs[identifier] = appID
                    try exec(db, "insert into app (app_id, identifier) values (\(appID), '\(identifier)');")
                }
                let blob = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
                var statement: OpaquePointer?
                XCTAssertEqual(
                    sqlite3_prepare_v2(db, "insert into record (rec_id, app_id, data, delivered_date) values (?, ?, ?, ?);", -1, &statement, nil),
                    SQLITE_OK
                )
                sqlite3_bind_int64(statement, 1, recordID)
                sqlite3_bind_int64(statement, 2, appID)
                _ = blob.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                sqlite3_bind_double(statement, 4, Date().timeIntervalSinceReferenceDate)
                XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
                sqlite3_finalize(statement)
            }
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }

        private func exec(_ db: OpaquePointer, _ sql: String) throws {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }
}
