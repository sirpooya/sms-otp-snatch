import XCTest
@testable import OTPMessages

final class WALFallbackTests: XCTestCase {

    /// The read must succeed even when the live database cannot be opened
    /// read-only, and it must see rows that exist only in the `-wal`.
    func testSnapshotFallbackReadsWALOnlyRows() throws {
        let (directory, database) = try FixtureDB.makeWALOnlyDatabase(
            body: "بانک سامان\nرمز 483920", handle: "+989999920000"
        )
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = MessageStore(databaseURL: database)
        let rows = try store.fetchNew(sinceRowID: 0)

        XCTAssertEqual(rows.count, 1, "the row lives in the -wal; reading it proves the WAL was consulted")
        XCTAssertEqual(rows.first?.body, "بانک سامان\nرمز 483920")
        XCTAssertTrue(store.lastReadUsedSnapshot, "this case is only readable via the private snapshot")
    }

    /// The snapshot is a full copy of the user's message database, so it must
    /// not outlive the read.
    func testSnapshotIsRemovedAfterTheRead() throws {
        let (directory, database) = try FixtureDB.makeWALOnlyDatabase(
            body: "رمز 483920", handle: "20001"
        )
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = MessageStore(databaseURL: database)
        _ = try store.fetchNew(sinceRowID: 0)
        XCTAssertTrue(store.lastReadUsedSnapshot)

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("OTPSnatcher-snapshot-") }
        XCTAssertTrue(leftovers.isEmpty, "snapshot directories left behind: \(leftovers)")
    }

    /// A healthy database must not pay the snapshot cost.
    func testHealthyDatabaseIsReadDirectly() throws {
        let fixture = try FixtureDB(rows: [.init(text: "رمز 483920", handle: "20001")])
        defer { fixture.cleanUp() }

        let store = MessageStore(databaseURL: fixture.url)
        _ = try store.fetchNew(sinceRowID: 0)
        XCTAssertFalse(store.lastReadUsedSnapshot)
    }
}
