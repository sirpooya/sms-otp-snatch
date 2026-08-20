import XCTest
import SQLite3
@testable import OTPMessages
@testable import OTPCore

final class MessageStoreTests: XCTestCase {

    private var fixture: FixtureDB!

    override func tearDown() {
        fixture?.cleanUp()
        fixture = nil
        super.tearDown()
    }

    // MARK: - Reading

    func testFetchNewSkipsOutboundMessages() throws {
        fixture = try FixtureDB(rows: [
            .init(text: "کد تایید: 111111", handle: "20001"),
            .init(text: "کد تایید: 222222", handle: "20001", isFromMe: true),
            .init(text: "کد تایید: 333333", handle: "20001"),
        ])
        let rows = try MessageStore(databaseURL: fixture.url).fetchNew(sinceRowID: 0)
        XCTAssertEqual(rows.map(\.body), ["کد تایید: 111111", "کد تایید: 333333"])
    }

    func testWatermarkAdvancesAndDoesNotReplay() throws {
        fixture = try FixtureDB(rows: [
            .init(text: "one 111111", handle: "20001"),
            .init(text: "two 222222", handle: "20001"),
        ])
        let store = MessageStore(databaseURL: fixture.url)

        let first = try store.fetchNew(sinceRowID: 0)
        XCTAssertEqual(first.count, 2)
        let watermark = try XCTUnwrap(first.last?.rowID)

        XCTAssertTrue(try store.fetchNew(sinceRowID: watermark).isEmpty)
        XCTAssertEqual(try store.fetchNew(sinceRowID: watermark - 1).count, 1)
    }

    func testRowsAreOrderedByRowIDAscending() throws {
        fixture = try FixtureDB(rows: (1...5).map {
            .init(text: "code \($0)00000", handle: "20001")
        })
        let rows = try MessageStore(databaseURL: fixture.url).fetchNew(sinceRowID: 0)
        XCTAssertEqual(rows.map(\.rowID), rows.map(\.rowID).sorted())
    }

    func testLimitCapsTheBatch() throws {
        fixture = try FixtureDB(rows: (1...10).map { _ in .init(text: "x 123456", handle: "20001") })
        let rows = try MessageStore(databaseURL: fixture.url).fetchNew(sinceRowID: 0, limit: 3)
        XCTAssertEqual(rows.count, 3)
    }

    // MARK: - Body resolution

    /// The important one: on modern macOS `text` is NULL for the overwhelming
    /// majority of rows (26,411 of 27,915 inbound SMS in a live database), so
    /// this path is the normal case, not an edge case.
    func testNullTextDecodesFromAttributedBody() throws {
        fixture = try FixtureDB(rows: [
            .init(text: nil, blob: FixtureDB.typedStreamBlob, handle: "+989999920000"),
        ])
        let rows = try MessageStore(databaseURL: fixture.url).fetchNew(sinceRowID: 0)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.body, FixtureDB.typedStreamExpectedBody)

        // And end to end: the decoded body must yield the right code.
        let result = CodeExtractor.extract(from: try XCTUnwrap(rows.first?.body))
        XCTAssertEqual(result?.code, "483920")
    }

    func testTextWinsOverAttributedBodyWhenBothPresent() throws {
        fixture = try FixtureDB(rows: [
            .init(text: "plain 999999", blob: FixtureDB.typedStreamBlob, handle: "20001"),
        ])
        let rows = try MessageStore(databaseURL: fixture.url).fetchNew(sinceRowID: 0)
        XCTAssertEqual(rows.first?.body, "plain 999999")
    }

    func testEmptyTextFallsThroughToAttributedBody() throws {
        fixture = try FixtureDB(rows: [
            .init(text: "", blob: FixtureDB.typedStreamBlob, handle: "20001"),
        ])
        XCTAssertEqual(try MessageStore(databaseURL: fixture.url).fetchNew(sinceRowID: 0).first?.body,
                       FixtureDB.typedStreamExpectedBody)
    }

    /// An undecodable blob must cost us that one row, not the batch. chat.db is
    /// not a trusted input.
    func testUndecodableBlobIsSkippedWithoutLosingTheBatch() throws {
        fixture = try FixtureDB(rows: [
            .init(text: nil, blob: Data([0x00, 0x01, 0x02, 0xFF, 0xFE]), handle: "20001"),
            .init(text: nil, blob: FixtureDB.typedStreamBlob, handle: "20001"),
            .init(text: nil, blob: Data(), handle: "20001"),
            .init(text: "after 123456", handle: "20001"),
        ])
        let rows = try MessageStore(databaseURL: fixture.url).fetchNew(sinceRowID: 0)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.body, "after 123456")
    }

    // MARK: - Senders

    func testFilteredSenderIsCanonicalizedButRawIsPreserved() throws {
        fixture = try FixtureDB(rows: [
            .init(text: "کد تایید: 123456", handle: "987007100(filtered)"),
        ])
        let row = try XCTUnwrap(try MessageStore(databaseURL: fixture.url).fetchNew(sinceRowID: 0).first)
        XCTAssertEqual(row.sender, "987007100")
        XCTAssertEqual(row.rawSender, "987007100(filtered)")
    }

    func testAlphanumericAndShortcodeSenders() throws {
        fixture = try FixtureDB(rows: [
            .init(text: "a 123456", handle: "DIGIKALA"),
            .init(text: "b 123456", handle: "20001"),
            .init(text: "c 123456", handle: "bank mellat"),
        ])
        let rows = try MessageStore(databaseURL: fixture.url).fetchNew(sinceRowID: 0)
        XCTAssertEqual(rows.map(\.sender), ["DIGIKALA", "20001", "bank mellat"])
    }

    /// LEFT JOIN, not JOIN: a message whose handle is missing must still arrive,
    /// with an empty sender, rather than disappearing from the result set.
    func testMessageWithNoHandleIsStillReturned() throws {
        fixture = try FixtureDB(rows: [.init(text: "orphan 123456", handle: nil)])
        let rows = try MessageStore(databaseURL: fixture.url).fetchNew(sinceRowID: 0)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.sender, "")
    }

    func testServiceIsReported() throws {
        fixture = try FixtureDB(rows: [
            .init(text: "sms 123456", handle: "20001", service: "SMS"),
            .init(text: "imessage 123456", handle: "20001", service: "iMessage"),
        ])
        let rows = try MessageStore(databaseURL: fixture.url).fetchNew(sinceRowID: 0)
        XCTAssertEqual(rows.map(\.service), ["SMS", "iMessage"])
    }

    // MARK: - Dates

    func testAppleEpochNanoseconds() {
        // 780,000,000,000,000,000 ns after 2001-01-01 is mid-2025.
        let date = MessageStore.date(fromAppleTimestamp: 780_000_000_000_000_000)
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: try! XCTUnwrap(date)
        )
        XCTAssertEqual(components.year, 2025)
    }

    /// Rows written by much older versions store seconds, not nanoseconds. The
    /// two are three orders of magnitude apart, so magnitude discriminates.
    func testAppleEpochSecondsForLegacyRows() {
        let date = try! XCTUnwrap(MessageStore.date(fromAppleTimestamp: 500_000_000))
        let year = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year
        XCTAssertEqual(year, 2016)
    }

    func testZeroDateIsNil() {
        XCTAssertNil(MessageStore.date(fromAppleTimestamp: 0))
    }

    func testDateSurvivesTheRoundTripThroughTheStore() throws {
        fixture = try FixtureDB(rows: [
            .init(text: "x 123456", handle: "20001", date: 780_000_000_000_000_000),
        ])
        let row = try XCTUnwrap(try MessageStore(databaseURL: fixture.url).fetchNew(sinceRowID: 0).first)
        XCTAssertNotNil(row.date)
    }

    // MARK: - maxRowID and probe

    func testMaxRowIDAndProbe() throws {
        fixture = try FixtureDB(rows: [
            .init(text: "a 123456", handle: "20001"),
            .init(text: "b 123456", handle: "20001"),
        ])
        let store = MessageStore(databaseURL: fixture.url)
        XCTAssertNoThrow(try store.probe())
        XCTAssertEqual(try store.maxRowID(), 2)
    }

    func testMaxRowIDOnEmptyTable() throws {
        fixture = try FixtureDB(rows: [])
        XCTAssertEqual(try MessageStore(databaseURL: fixture.url).maxRowID(), 0)
    }

    // MARK: - Errors

    func testMissingDatabaseIsReportedAsNotFoundNotAsPermission() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString).db")
        XCTAssertThrowsError(try MessageStore(databaseURL: url).probe()) { error in
            guard case MessageStoreError.databaseNotFound = error else {
                return XCTFail("expected databaseNotFound, got \(error)")
            }
        }
    }

    func testUnreadableFileIsReportedAsPermissionDenied() throws {
        fixture = try FixtureDB(rows: [.init(text: "x 123456", handle: "20001")])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.url.path) }

        XCTAssertThrowsError(try MessageStore(databaseURL: fixture.url).probe()) { error in
            guard case MessageStoreError.permissionDenied = error else {
                return XCTFail("expected permissionDenied, got \(error)")
            }
        }
    }

    func testNonDatabaseFileIsReportedAsMalformed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-db-\(UUID().uuidString).db")
        try Data("this is not a database".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try MessageStore(databaseURL: url).probe())
    }
}
