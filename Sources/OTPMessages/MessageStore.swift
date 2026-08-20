import Foundation
import SQLite3
import OTPCore

public struct MessageRow: Equatable, Sendable {
    public let rowID: Int64
    /// `handle.id` with the iOS `(filtered)` marker stripped.
    public let sender: String
    /// `handle.id` exactly as stored, kept so the UI can show what to configure.
    public let rawSender: String
    public let body: String
    public let date: Date?
    /// `SMS` or `iMessage`. OTPs arrive as `SMS`.
    public let service: String?
}

public enum MessageStoreError: Error, Equatable {
    /// The database is not where it should be. Messages.app has probably never
    /// run on this Mac.
    case databaseNotFound(path: String)
    /// TCC denied the read. This is the one the onboarding flow reacts to.
    case permissionDenied(path: String)
    /// SQLite refused to open even from a private snapshot.
    case cannotOpen(code: Int32)
    /// The file opened but is not the schema we expect.
    case malformed
    case sqlite(code: Int32)
}

/// Read-only access to `~/Library/Messages/chat.db`.
///
/// Two things make this less trivial than it looks.
///
/// **WAL.** The database is in WAL mode and we open it read-only, which SQLite
/// permits only when it can read the `-shm` file and no recovery is pending.
/// When a write is in flight, or the `-shm` is unreadable, SQLite returns
/// SQLITE_READONLY_RECOVERY or SQLITE_BUSY. The fix is a private snapshot: copy
/// `chat.db`, `-wal` and `-shm` into a 0700 temp directory, read the copy, then
/// delete it. `immutable=1` is deliberately never used, because it would make
/// SQLite ignore the `-wal` and silently miss the newest messages, which are
/// exactly the ones we care about.
///
/// **Permission versus corruption.** The onboarding flow needs to tell "the user
/// has not granted Full Disk Access" apart from every other failure, so the
/// readability check happens before SQLite is involved, where errno still says
/// EPERM.
public final class MessageStore {

    public static var defaultDatabaseURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Messages/chat.db")
    }

    private let databaseURL: URL
    private let decoder: AttributedBodyDecoding

    public init(databaseURL: URL = MessageStore.defaultDatabaseURL,
                decoder: AttributedBodyDecoding = AttributedBodyDecoder()) {
        self.databaseURL = databaseURL
        self.decoder = decoder
    }

    // MARK: - Public API

    /// Cheap liveness check for the permission gate: opens the database and
    /// counts nothing. Throws exactly the errors `fetchNew` would throw.
    public func probe() throws {
        _ = try withConnection { db in
            try scalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'message';")
        }
    }

    /// Highest ROWID currently in `message`. Used to set the initial watermark
    /// so a fresh install does not replay history.
    public func maxRowID() throws -> Int64 {
        try withConnection { db in
            try scalar(db, "SELECT IFNULL(MAX(ROWID), 0) FROM message;")
        }
    }

    /// Inbound messages newer than `sinceRowID`, oldest first.
    ///
    /// `limit` bounds the batch so a first run after a long sleep, or a very
    /// stale watermark, cannot occupy the caller for an unbounded time. The
    /// caller advances its watermark to the last row it processed and comes
    /// back for more.
    public func fetchNew(sinceRowID: Int64, limit: Int = 200) throws -> [MessageRow] {
        try withConnection { db in
            // LEFT JOIN, not JOIN: a message with a NULL handle_id should not
            // vanish from the result set, it should arrive with an empty sender
            // and get filtered by the caller.
            let sql = """
                SELECT m.ROWID, m.text, m.attributedBody, m.date, m.service, h.id
                FROM message m
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE m.ROWID > ?1 AND m.is_from_me = 0
                ORDER BY m.ROWID ASC
                LIMIT ?2;
                """

            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK else {
                // A busy or read-only-recovery failure here is not corruption,
                // it is the WAL case, so it has to surface as .sqlite for the
                // snapshot fallback to kick in.
                throw Self.needsSnapshot(rc) ? MessageStoreError.sqlite(code: rc) : .malformed
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, sinceRowID)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var rows: [MessageRow] = []
            var undecodable = 0

            while true {
                let step = sqlite3_step(stmt)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw MessageStoreError.sqlite(code: step) }

                let rowID = sqlite3_column_int64(stmt, 0)

                var body: String? = nil
                if let raw = sqlite3_column_text(stmt, 1) {
                    let text = String(cString: raw)
                    if !text.isEmpty { body = text }
                }
                if body == nil, let blob = sqlite3_column_blob(stmt, 2) {
                    let length = Int(sqlite3_column_bytes(stmt, 2))
                    if length > 0 {
                        body = decoder.string(from: Data(bytes: blob, count: length))
                    }
                }
                guard let body, !body.isEmpty else {
                    undecodable += 1
                    Log.row(.store, "body-undecodable", rowID: rowID)
                    continue
                }

                let rawSender = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                let service = sqlite3_column_text(stmt, 4).map { String(cString: $0) }

                rows.append(MessageRow(
                    rowID: rowID,
                    sender: SenderMatcher.canonical(rawSender),
                    rawSender: rawSender,
                    body: body,
                    date: Self.date(fromAppleTimestamp: sqlite3_column_int64(stmt, 3)),
                    service: service
                ))
            }

            if undecodable > 0 { Log.count(.store, "undecodable-batch", undecodable) }
            return rows
        }
    }

    // MARK: - Apple epoch

    /// `message.date` is nanoseconds since 2001-01-01 UTC on modern macOS, and
    /// seconds on rows written by much older versions. The two are three orders
    /// of magnitude apart, so magnitude is a safe discriminator: a seconds value
    /// would have to represent the year 33,000 to reach the threshold.
    public static func date(fromAppleTimestamp raw: Int64) -> Date? {
        guard raw != 0 else { return nil }
        let seconds = abs(raw) > 1_000_000_000_000
            ? Double(raw) / 1_000_000_000
            : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    // MARK: - Connection handling

    private func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try assertReadable(databaseURL)

        if let db = try? open(databaseURL) {
            defer { sqlite3_close(db) }
            do {
                return try body(db)
            } catch MessageStoreError.sqlite(let code) where Self.needsSnapshot(code) {
                Log.failure(.store, "wal-read-failed-falling-back", code: code)
            }
        } else {
            Log.event(.store, "direct-open-failed-falling-back")
        }

        return try withSnapshot { url in
            let db = try open(url)
            defer { sqlite3_close(db) }
            return try body(db)
        }
    }

    private func open(_ url: URL) throws -> OpaquePointer {
        // mode=ro, and deliberately NOT immutable=1: immutable would skip the
        // -wal file, which is where the newest messages live.
        let uri = "file:\(url.path)?mode=ro"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let rc = sqlite3_open_v2(uri, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw MessageStoreError.cannotOpen(code: rc)
        }
        // Short timeout: a watcher-triggered read that cannot get in should
        // fail fast and let the snapshot path handle it.
        sqlite3_busy_timeout(db, 1_500)
        return db
    }

    private static func needsSnapshot(_ code: Int32) -> Bool {
        // SQLITE_READONLY_RECOVERY (776) and SQLITE_READONLY_CANTINIT (1288)
        // both mean "this WAL database needs a write to be readable".
        code == SQLITE_BUSY || code == SQLITE_READONLY || code == 776 || code == 1288
            || code == SQLITE_IOERR || code == SQLITE_CANTOPEN
    }

    /// Copies the database and its WAL sidecars somewhere private, runs `body`
    /// against the copy, then removes the copy on every exit path.
    ///
    /// This materializes the user's entire message database on disk, so: unique
    /// directory, 0700, inside the system temp directory (never anywhere synced
    /// or user-visible), and removed in a `defer`.
    private func withSnapshot<T>(_ body: (URL) throws -> T) throws -> T {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("OTPSnatcher-snapshot-\(UUID().uuidString)", isDirectory: true)

        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }

        let base = databaseURL.lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            let source = databaseURL.deletingLastPathComponent()
                .appendingPathComponent(base + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = dir.appendingPathComponent(base + suffix)
            try fm.copyItem(at: source, to: destination)
        }

        Log.event(.store, "snapshot-taken")
        return try body(dir.appendingPathComponent(base))
    }

    /// Distinguishes "no Full Disk Access" from every other failure, while errno
    /// is still meaningful. SQLite collapses both into SQLITE_CANTOPEN.
    private func assertReadable(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            // A missing file could also be a permission failure on the parent
            // directory, which is itself TCC-protected. Check the parent to tell
            // the two apart.
            let parent = url.deletingLastPathComponent()
            if !fm.isReadableFile(atPath: parent.path) {
                throw MessageStoreError.permissionDenied(path: url.path)
            }
            throw MessageStoreError.databaseNotFound(path: url.path)
        }

        let fd = Darwin.open(url.path, O_RDONLY)
        if fd >= 0 {
            Darwin.close(fd)
            return
        }
        if errno == EPERM || errno == EACCES {
            throw MessageStoreError.permissionDenied(path: url.path)
        }
        throw MessageStoreError.cannotOpen(code: errno)
    }

    private func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else {
            throw Self.needsSnapshot(rc) ? MessageStoreError.sqlite(code: rc) : .malformed
        }
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else { throw MessageStoreError.sqlite(code: step) }
        return sqlite3_column_int64(stmt, 0)
    }
}
