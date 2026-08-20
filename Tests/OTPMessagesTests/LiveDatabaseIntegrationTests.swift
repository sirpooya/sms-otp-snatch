import XCTest
@testable import OTPMessages
@testable import OTPCore

/// The only tests that touch `~/Library/Messages/chat.db`.
///
/// Every one of them skips cleanly when Full Disk Access is absent, so
/// `swift test` stays green on a machine (or a CI runner) that has never seen
/// Messages. They assert on counts and ratios only: no message body, sender or
/// extracted code is ever printed, asserted against, or written anywhere.
final class LiveDatabaseIntegrationTests: XCTestCase {

    private func liveStore() throws -> MessageStore {
        let store = MessageStore()
        do {
            try store.probe()
        } catch MessageStoreError.permissionDenied {
            throw XCTSkip("no Full Disk Access for the test runner")
        } catch MessageStoreError.databaseNotFound {
            throw XCTSkip("no Messages database on this machine")
        }
        return store
    }

    func testCanReadTheRealDatabase() throws {
        let store = try liveStore()
        let head = try store.maxRowID()
        XCTAssertGreaterThan(head, 0, "a live database should have messages")
    }

    /// A healthy live database should be readable directly. If this starts
    /// failing, the snapshot fallback is carrying the app and something about
    /// the WAL state deserves a look.
    func testLiveReadDoesNotNeedTheSnapshotFallback() throws {
        let store = try liveStore()
        _ = try store.fetchNew(sinceRowID: max(0, try store.maxRowID() - 50))
        XCTAssertFalse(store.lastReadUsedSnapshot,
                       "live read fell back to a snapshot copy, which should be rare")
    }

    /// The decode path is the risky one, and its real-world success rate is the
    /// number that matters: on modern macOS the great majority of rows carry a
    /// NULL `text` and a typedstream blob instead.
    func testBodyDecodeSucceedsOnTheOverwhelmingMajorityOfRealRows() throws {
        let store = try liveStore()
        let head = try store.maxRowID()
        let window: Int64 = 2000
        let rows = try store.fetchNew(sinceRowID: max(0, head - window), limit: 2000)

        try XCTSkipIf(rows.count < 50, "not enough recent messages to be meaningful")

        // `fetchNew` drops rows it cannot decode, so the ratio of returned rows
        // to the ROWID span is a proxy for decode success. Some of the gap is
        // legitimately outbound messages, so the bar is deliberately modest.
        let span = Double(min(window, head))
        let ratio = Double(rows.count) / span
        XCTAssertGreaterThan(ratio, 0.25,
                             "decoded \(rows.count) of about \(Int(span)) rows; the decoder may be failing")

        // Every returned row must have a non-empty body: an empty one means the
        // decode "succeeded" without producing text.
        XCTAssertTrue(rows.allSatisfy { !$0.body.isEmpty })
    }

    /// The point of the whole app, measured against live traffic: for messages
    /// that clearly are OTPs, do we find a code? Counts only.
    func testExtractorFindsCodesInRealOTPMessages() throws {
        let store = try liveStore()
        let head = try store.maxRowID()
        let rows = try store.fetchNew(sinceRowID: max(0, head - 4000), limit: 4000)
        try XCTSkipIf(rows.count < 50, "not enough recent messages to be meaningful")

        // A message containing one of these words, from a numeric or
        // alphanumeric shortcode, is almost certainly a code delivery.
        let strongCues = ["رمز یکبار مصرف", "رمز پویا", "کد تایید", "کد ورود", "verification code"]

        var likelyOTPs = 0
        var extracted = 0
        for row in rows {
            let normalized = DigitNormalizer.normalize(row.body)
            guard strongCues.contains(where: { normalized.contains($0) }) else { continue }
            likelyOTPs += 1
            if CodeExtractor.extract(from: row.body) != nil { extracted += 1 }
        }

        try XCTSkipIf(likelyOTPs < 5, "only \(likelyOTPs) obvious OTP messages in range")
        let hitRate = Double(extracted) / Double(likelyOTPs)
        // Measured 156 of 157 on a live database on 2026-08-21. The one holdout
        // is "سرویس رمز یکبار مصرف شما فعال گردید" ("your one-time password
        // service is now active"), which matches the cue but contains no digits
        // at all, so there is nothing to extract. The bar is set just below that
        // to leave room for one such message per sample without going green on a
        // real regression.
        XCTAssertGreaterThan(hitRate, 0.95,
                             "extracted \(extracted) of \(likelyOTPs) obvious OTP messages")
    }

    /// The inverse, and the more dangerous direction: marketing messages must
    /// not yield a code, because a false positive silently overwrites the
    /// clipboard with a discount code.
    func testExtractorStaysQuietOnObviousMarketingMessages() throws {
        let store = try liveStore()
        let head = try store.maxRowID()
        let rows = try store.fetchNew(sinceRowID: max(0, head - 4000), limit: 4000)
        try XCTSkipIf(rows.count < 50, "not enough recent messages to be meaningful")

        let marketingCues = ["کد تخفیف", "کد دستوری", "گیگابایت", "بسته اینترنت"]
        let otpCues = ["رمز", "کد تایید", "کد ورود", "verification"]

        var marketing = 0
        var falsePositives = 0
        for row in rows {
            let normalized = DigitNormalizer.normalize(row.body)
            guard marketingCues.contains(where: { normalized.contains($0) }) else { continue }
            // Skip anything that also looks like a genuine code delivery.
            guard !otpCues.contains(where: { normalized.contains($0) }) else { continue }
            marketing += 1
            if CodeExtractor.extract(from: row.body) != nil { falsePositives += 1 }
        }

        try XCTSkipIf(marketing < 5, "only \(marketing) obvious marketing messages in range")
        let rate = Double(falsePositives) / Double(marketing)
        XCTAssertLessThan(rate, 0.1,
                          "\(falsePositives) of \(marketing) marketing messages produced a code")
    }
}
