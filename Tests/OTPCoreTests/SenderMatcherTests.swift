import XCTest
@testable import OTPCore

final class SenderMatcherTests: XCTestCase {

    /// iOS message filtering appends this marker, so the same sender appears
    /// under two handle ids. Verified in a live chat.db: `987007100` had 682
    /// messages and `987007100(filtered)` another 442.
    func testFilteredSuffixIsStripped() {
        XCTAssertEqual(SenderMatcher.canonical("987007100(filtered)"), "987007100")
        XCTAssertEqual(SenderMatcher.canonical("SNAPPFOOD(filtered)"), "SNAPPFOOD")
        XCTAssertTrue(SenderMatcher.matches(handleID: "987007100(filtered)", ruleID: "987007100"))
        XCTAssertTrue(SenderMatcher.matches(handleID: "DIGIKALA(filtered)", ruleID: "digikala"))
    }

    func testAlphanumericSendersAreCaseAndSpaceInsensitive() {
        XCTAssertTrue(SenderMatcher.matches(handleID: "bank mellat", ruleID: "BankMellat"))
        XCTAssertTrue(SenderMatcher.matches(handleID: "HAMRAH AVAL", ruleID: "hamrahaval"))
        XCTAssertFalse(SenderMatcher.matches(handleID: "DIGIKALA", ruleID: "SNAPP"))
    }

    func testNumericSendersMatchAcrossCountryCodeForms() {
        XCTAssertTrue(SenderMatcher.matches(handleID: "+989999920000", ruleID: "9999920000"))
        XCTAssertTrue(SenderMatcher.matches(handleID: "+989999920000", ruleID: "989999920000"))
        XCTAssertTrue(SenderMatcher.matches(handleID: "98700 710 0", ruleID: "987007100"))
    }

    func testShortcodesMatchExactly() {
        XCTAssertTrue(SenderMatcher.matches(handleID: "20001", ruleID: "20001"))
        XCTAssertFalse(SenderMatcher.matches(handleID: "20001", ruleID: "20002"))
    }

    /// A three-digit rule must not suffix-match a long number, or configuring
    /// "300" would silently subscribe you to every sender ending in 300.
    func testTooShortToSuffixMatch() {
        XCTAssertFalse(SenderMatcher.matches(handleID: "+989999920300", ruleID: "300"))
        XCTAssertTrue(SenderMatcher.matches(handleID: "+989999920300", ruleID: "20300"))
    }

    func testAlphanumericNeverSuffixMatchesANumber() {
        XCTAssertFalse(SenderMatcher.matches(handleID: "SNAPP2000", ruleID: "2000"))
    }

    func testEmptyInputs() {
        XCTAssertFalse(SenderMatcher.matches(handleID: "", ruleID: "20001"))
        XCTAssertFalse(SenderMatcher.matches(handleID: "20001", ruleID: ""))
        XCTAssertFalse(SenderMatcher.matches(handleID: "(filtered)", ruleID: "20001"))
    }
}
