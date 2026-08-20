import XCTest
@testable import OTPCore

final class ClipboardGuardTests: XCTestCase {

    func testClearsWhenNothingHasTouchedTheClipboard() {
        XCTAssertTrue(ClipboardGuard.shouldClear(
            currentChangeCount: 7, writtenChangeCount: 7,
            currentValue: "483920", writtenValue: "483920"
        ))
    }

    /// The user copied something else during the TTL. Their content wins.
    func testLeavesUserContentAlone() {
        XCTAssertFalse(ClipboardGuard.shouldClear(
            currentChangeCount: 9, writtenChangeCount: 7,
            currentValue: "a password they just copied", writtenValue: "483920"
        ))
    }

    /// Same string, but the clipboard was rewritten since. That rewrite might be
    /// the user copying the code by hand from the message, and clearing it would
    /// undo their action.
    func testSameValueButDifferentChangeCountIsNotOurs() {
        XCTAssertFalse(ClipboardGuard.shouldClear(
            currentChangeCount: 8, writtenChangeCount: 7,
            currentValue: "483920", writtenValue: "483920"
        ))
    }

    func testMatchingCountButDifferentValueIsNotOurs() {
        XCTAssertFalse(ClipboardGuard.shouldClear(
            currentChangeCount: 7, writtenChangeCount: 7,
            currentValue: "something else", writtenValue: "483920"
        ))
    }

    /// An empty clipboard has nothing of ours to clear.
    func testEmptyClipboardIsNotCleared() {
        XCTAssertFalse(ClipboardGuard.shouldClear(
            currentChangeCount: 7, writtenChangeCount: 7,
            currentValue: nil, writtenValue: "483920"
        ))
    }
}
