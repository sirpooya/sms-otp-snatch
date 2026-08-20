import XCTest
@testable import OTPCore

final class ConfigTests: XCTestCase {

    /// The exact document from CLAUDE.md must decode.
    func testSpecExampleDecodes() throws {
        let json = """
            {
              "senders": [
                { "id": "20001", "pattern": "\\\\b(\\\\d{5,6})\\\\b", "label": "Bank" }
              ],
              "clearClipboardAfterSeconds": 60,
              "notify": true
            }
            """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.senders.count, 1)
        XCTAssertEqual(config.senders[0].id, "20001")
        XCTAssertEqual(config.senders[0].label, "Bank")
        XCTAssertEqual(config.clearClipboardAfterSeconds, 60)
        XCTAssertTrue(config.notify)
    }

    func testMissingKeysFallBackToDefaults() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(config.senders, [])
        XCTAssertEqual(config.clearClipboardAfterSeconds, 60)
        XCTAssertTrue(config.notify)
    }

    func testRoundTrip() throws {
        let original = Config(
            senders: [SenderRule(id: "20001", pattern: nil, label: "Bank")],
            clearClipboardAfterSeconds: 30,
            notify: false
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data), original)
    }

    func testClearIntervalClamping() {
        func interval(_ seconds: Int) -> TimeInterval? {
            Config(senders: [], clearClipboardAfterSeconds: seconds, notify: true).clearInterval
        }
        XCTAssertNil(interval(0), "zero means never clear")
        XCTAssertNil(interval(-1))
        XCTAssertEqual(interval(1), 5, "too short to paste, clamped up")
        XCTAssertEqual(interval(60), 60)
        XCTAssertEqual(interval(999_999), 3600, "clamped down")
    }

    func testRuleLookupPrefersTheMoreSpecificSender() {
        let config = Config(
            senders: [
                SenderRule(id: "20000", label: "short"),
                SenderRule(id: "+989999920000", label: "full"),
            ],
            clearClipboardAfterSeconds: 60,
            notify: true
        )
        XCTAssertEqual(config.rule(forHandle: "+989999920000")?.label, "full")
    }

    func testRuleLookupIgnoresUnconfiguredSenders() {
        let config = Config(senders: [SenderRule(id: "20001")], clearClipboardAfterSeconds: 60, notify: true)
        XCTAssertNil(config.rule(forHandle: "DIGIKALA"))
    }
}
