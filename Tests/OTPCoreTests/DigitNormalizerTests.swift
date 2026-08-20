import XCTest
@testable import OTPCore

final class DigitNormalizerTests: XCTestCase {

    func testPersianDigitsBecomeASCII() {
        XCTAssertEqual(DigitNormalizer.normalize("۰۱۲۳۴۵۶۷۸۹"), "0123456789")
    }

    func testArabicIndicDigitsBecomeASCII() {
        XCTAssertEqual(DigitNormalizer.normalize("٠١٢٣٤٥٦٧٨٩"), "0123456789")
    }

    func testMixedDigitFamiliesInOneNumber() {
        // Senders really do mix these inside a single code.
        XCTAssertEqual(DigitNormalizer.normalize("رمز ۴۸3٩20"), "رمز 483920")
    }

    func testZWNJInsideNumberIsRemoved() {
        XCTAssertEqual(DigitNormalizer.normalize("۱۲۳‌۴۵۶"), "123456")
    }

    func testBidiControlsAreRemoved() {
        let wrapped = "\u{200F}کد\u{202B}739104\u{202C}\u{2069}"
        XCTAssertEqual(DigitNormalizer.normalize(wrapped), "کد739104")
    }

    /// Iranian bank gateways emit Arabic yeh and kaf rather than the Persian
    /// letters, so `ريال` and `ریال` are the same word to a reader and two
    /// different strings to a matcher.
    func testArabicYehAndKafAreFoldedToPersian() {
        XCTAssertEqual(DigitNormalizer.normalize("ريال"), "ریال")
        XCTAssertEqual(DigitNormalizer.normalize("خريد"), "خرید")
        XCTAssertEqual(DigitNormalizer.normalize("كد"), "کد")
        XCTAssertEqual(DigitNormalizer.normalize("تأیید"), "تایید")
    }

    func testSeparatorsAreNormalized() {
        XCTAssertEqual(DigitNormalizer.normalize("۹۰،۰۰۰"), "90,000")
    }

    func testNonBreakingSpaceBecomesSpace() {
        XCTAssertEqual(DigitNormalizer.normalize("رمز\u{00A0}483920"), "رمز 483920")
    }

    func testPlainTextIsUnchanged() {
        XCTAssertEqual(DigitNormalizer.normalize("Code: 51294"), "Code: 51294")
    }

    func testIdempotent() {
        let input = "رمز ۴۸۳۹۲۰ ريال\u{200C}"
        let once = DigitNormalizer.normalize(input)
        XCTAssertEqual(DigitNormalizer.normalize(once), once)
    }
}
