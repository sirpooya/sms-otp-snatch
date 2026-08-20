import XCTest
@testable import OTPCore

/// Table-driven against `Fixtures/persian-otp-samples.json`.
///
/// The fixture is the real specification for this component: every case is
/// modelled on a message shape that actually arrives in Iran, and roughly half
/// of them are messages that must yield *nothing*. Adding a case is the first
/// step for any reported miss.
final class CodeExtractorTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let sender: String
            let pattern: String?
            let body: String
            let expected: String?
            let strategy: String?
            let note: String?
        }
        let cases: [Case]
    }

    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/persian-otp-samples", withExtension: "json"),
            "fixture corpus missing from the test bundle"
        )
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    func testFixtureCorpus() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThan(fixture.cases.count, 20, "corpus should be broad enough to be meaningful")

        for testCase in fixture.cases {
            let rule = SenderRule(id: testCase.sender, pattern: testCase.pattern)
            let result = CodeExtractor.extract(from: testCase.body, rule: rule)

            if let expected = testCase.expected {
                XCTAssertEqual(result?.code, expected, "case \(testCase.name)")
                if let strategy = testCase.strategy {
                    XCTAssertEqual(result?.strategy.rawValue, strategy, "strategy for case \(testCase.name)")
                }
            } else {
                XCTAssertNil(result, "case \(testCase.name) should yield no code, got \(result?.code ?? "-")")
            }
        }
    }

    /// The single most important negative: a bank OTP arrives with the
    /// transaction amount in the same message, and the amount is longer and
    /// earlier than the code.
    func testAmountInSameMessageIsNotReturned() {
        let body = "بانک سامان\nخريد\nمبلغ 12,500,000 ريال\nرمز 483920\nزمان اعتبار رمز 00:04:59"
        let result = CodeExtractor.extract(from: body)
        XCTAssertEqual(result?.code, "483920")
        XCTAssertNotEqual(result?.code, "12500000")
        XCTAssertNotEqual(result?.code, "500")
    }

    func testValidityClockIsNotReturned() {
        let body = "رمز: 903117\nزمان اعتبار رمز 00:04:59"
        XCTAssertEqual(CodeExtractor.extract(from: body)?.code, "903117")
    }

    func testDomainBoundLineBeatsEverythingElse() {
        // Two plausible runs; the standardized line is unambiguous.
        let body = "کد تایید: 74129\nشماره پیگیری 998877\n@auth.digikala.com #74129"
        let result = CodeExtractor.extract(from: body)
        XCTAssertEqual(result?.strategy, .domainBound)
        XCTAssertEqual(result?.code, "74129")
    }

    func testDigitsInsideURLsAreIgnored() {
        let body = "لینک: https://zbl.io/MCI483920x و l.snpp.link/EAT4C2938"
        XCTAssertNil(CodeExtractor.extract(from: body))
    }

    func testAlphanumericCouponIsIgnored() {
        XCTAssertNil(CodeExtractor.extract(from: "کد تخفیف: A4RT219384"))
    }

    func testUSSDStringIsIgnored() {
        XCTAssertNil(CodeExtractor.extract(from: "شماره گیری کد دستوری *100*4#"))
    }

    func testInvalidSenderPatternFallsBackInsteadOfDisablingTheSender() {
        // An unbalanced group is a typo, not an instruction to stop matching.
        let rule = SenderRule(id: "X", pattern: "((\\d{6}")
        let result = CodeExtractor.extract(from: "کد تایید: 483920", rule: rule)
        XCTAssertEqual(result?.code, "483920")
        XCTAssertEqual(result?.strategy, .keywordAnchored)
    }

    func testSenderPatternWithoutCaptureGroupUsesWholeMatch() {
        let rule = SenderRule(id: "X", pattern: "\\d{5,6}")
        XCTAssertEqual(CodeExtractor.extract(from: "رمز 483920", rule: rule)?.code, "483920")
    }

    func testPerSenderKeywordExtendsTheCueTable() {
        // A sender with an unusual label for the code.
        let body = "شناسه یکتای شما 553311 است"
        XCTAssertNotEqual(CodeExtractor.extract(from: body)?.code, nil)

        let rule = SenderRule(id: "X", keywords: ["شناسه یکتای"])
        XCTAssertEqual(CodeExtractor.extract(from: body, rule: rule)?.code, "553311")
    }

    func testEmptyAndDigitlessBodies() {
        XCTAssertNil(CodeExtractor.extract(from: ""))
        XCTAssertNil(CodeExtractor.extract(from: "کد تایید ارسال شد"))
        XCTAssertNil(CodeExtractor.extract(from: "رمز 12"))
        XCTAssertNil(CodeExtractor.extract(from: "شماره 1234567890123"))
    }
}
