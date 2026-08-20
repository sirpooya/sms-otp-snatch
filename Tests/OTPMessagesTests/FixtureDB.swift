import Foundation
import SQLite3

/// Builds a throwaway SQLite file with the subset of the chat.db schema this
/// app reads.
///
/// No test in this target touches `~/Library/Messages`, so `swift test` runs
/// with no permissions and no Messages installation, on a CI runner included.
/// The one exception is `MessageStoreIntegrationTests`, which skips itself when
/// Full Disk Access is absent.
struct FixtureDB {

    /// A real `attributedBody` blob, archived by NSArchiver on macOS 26.5 and
    /// checked in as base64 rather than generated at test time.
    ///
    /// Generating it would make the test depend on `NSArchiver` still being able
    /// to *write* typedstreams, which is a different and less certain guarantee
    /// than being able to read them. Decoding to the exact expected string is
    /// the whole point of the test, so the input has to be fixed.
    ///
    /// Decodes to:
    ///   "بانک سامان\nخريد\nمبلغ 12,500,000 ريال\nرمز 483920"
    static let typedStreamBlobBase64 = """
        BAtzdHJlYW10eXBlZIHoA4QBQISEhBJOU0F0dHJpYnV0ZWRTdHJpbmcAhIQITlNPYmplY3QAhZKE\
        hIQITlNTdHJpbmcBlIQBK0fYqNin2YbaqSDYs9in2YXYp9mGCtiu2LHZitivCtmF2KjZhNi6IDEy\
        LDUwMCwwMDAg2LHZitin2YQK2LHZhdiyIDQ4MzkyMIaEAmlJAS+ShISEDE5TRGljdGlvbmFyeQCU\
        hAFpAIaG
        """

    static var typedStreamBlob: Data {
        Data(base64Encoded: typedStreamBlobBase64.replacingOccurrences(of: "\n", with: ""))!
    }

    static let typedStreamExpectedBody = "بانک سامان\nخريد\nمبلغ 12,500,000 ريال\nرمز 483920"

    struct Row {
        var text: String?
        var blob: Data?
        var handle: String?
        var service: String = "SMS"
        /// Apple epoch nanoseconds. Defaults to a plausible recent value.
        var date: Int64 = 780_000_000_000_000_000
        var isFromMe: Bool = false
    }

    let directory: URL
    let url: URL

    init(name: String = "chat.db", walMode: Bool = false, rows: [Row]) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("otpsnatcher-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(name)
        try Self.build(at: url, walMode: walMode, rows: rows)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Writing

    private static func build(at url: URL, walMode: Bool, rows: [Row]) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else {
            throw FixtureError.cannotCreate
        }
        defer { sqlite3_close(db) }

        if walMode {
            try exec(db, "PRAGMA journal_mode=WAL;")
            try exec(db, "PRAGMA wal_autocheckpoint=0;")
        }

        // Only the columns this app reads. The real table has well over a
        // hundred, none of which we touch.
        try exec(db, """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, service TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT,
                attributedBody BLOB,
                handle_id INTEGER,
                service TEXT,
                date INTEGER,
                is_from_me INTEGER DEFAULT 0
            );
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            """)

        var handleIDs: [String: Int64] = [:]
        for row in rows {
            var handleRowID: Int64 = 0
            if let handle = row.handle {
                if let existing = handleIDs[handle] {
                    handleRowID = existing
                } else {
                    try insertHandle(db, handle)
                    handleRowID = sqlite3_last_insert_rowid(db)
                    handleIDs[handle] = handleRowID
                }
            }
            try insertMessage(db, row, handleRowID: handleRowID)
        }
    }

    private static func insertHandle(_ db: OpaquePointer, _ id: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO handle (id, service) VALUES (?1, 'SMS');", -1, &stmt, nil) == SQLITE_OK else {
            throw FixtureError.cannotCreate
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw FixtureError.cannotCreate }
    }

    private static func insertMessage(_ db: OpaquePointer, _ row: Row, handleRowID: Int64) throws {
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO message (text, attributedBody, handle_id, service, date, is_from_me)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw FixtureError.cannotCreate }
        defer { sqlite3_finalize(stmt) }

        if let text = row.text {
            sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        if let blob = row.blob {
            _ = blob.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_int64(stmt, 3, handleRowID)
        sqlite3_bind_text(stmt, 4, row.service, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, row.date)
        sqlite3_bind_int(stmt, 6, row.isFromMe ? 1 : 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw FixtureError.cannotCreate }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.cannotCreate }
    }

    enum FixtureError: Error { case cannotCreate }
}

// SQLITE_TRANSIENT is a macro that does not survive into Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
