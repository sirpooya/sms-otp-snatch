import XCTest
import OTPTypedStream
@testable import OTPMessages

final class AttributedBodyDecoderTests: XCTestCase {

    private let decoder = AttributedBodyDecoder()

    /// Documents the finding that shaped this whole component: on macOS 26.5,
    /// `attributedBody` is a legacy `streamtyped` archive, `NSKeyedUnarchiver`
    /// cannot read it, and `NSUnarchiver` still can.
    func testRealBlobIsATypedStream() {
        let blob = FixtureDB.typedStreamBlob
        XCTAssertTrue(TypedStreamScanner.looksLikeTypedStream(blob))
        XCTAssertNil(try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: blob),
                     "if this ever starts succeeding, the format changed")
    }

    func testPrimaryPathDecodesTheBody() throws {
        try XCTSkipUnless(OTPTypedStreamDecoderAvailable(),
                          "NSUnarchiver has been removed; the scanner fallback is now the primary path")
        XCTAssertEqual(OTPDecodeTypedStreamString(FixtureDB.typedStreamBlob),
                       FixtureDB.typedStreamExpectedBody)
    }

    /// The pure-Swift fallback must produce the same answer as the shim, because
    /// the day it takes over there will be no way to compare.
    func testFallbackScannerAgreesWithTheShim() {
        XCTAssertEqual(TypedStreamScanner.string(from: FixtureDB.typedStreamBlob),
                       FixtureDB.typedStreamExpectedBody)
    }

    func testDecoderPicksSomePathAndGetsItRight() {
        XCTAssertEqual(decoder.string(from: FixtureDB.typedStreamBlob),
                       FixtureDB.typedStreamExpectedBody)
    }

    func testKeyedArchiveIsAlsoUnderstood() throws {
        // Not what macOS writes today, but if Apple migrates the column this is
        // the format it would migrate to.
        let original = NSAttributedString(string: "کد تایید: 483920")
        let data = try NSKeyedArchiver.archivedData(withRootObject: original,
                                                    requiringSecureCoding: false)
        XCTAssertTrue(data.starts(with: Array("bplist00".utf8)))
        XCTAssertEqual(decoder.string(from: data), "کد تایید: 483920")
    }

    // MARK: - Garbage in

    func testGarbageInputsReturnNilRatherThanCrashing() {
        XCTAssertNil(decoder.string(from: Data()))
        XCTAssertNil(decoder.string(from: Data([0x00])))
        XCTAssertNil(decoder.string(from: Data(repeating: 0xFF, count: 512)))
        XCTAssertNil(decoder.string(from: Data("streamtyped but not really".utf8)))
    }

    /// A truncated typedstream is the realistic corruption case, and the length
    /// prefix would run past the end of the buffer.
    func testTruncatedTypedStreamIsRejected() {
        let full = FixtureDB.typedStreamBlob
        for cut in [8, 24, 48, 64, full.count - 4] {
            let truncated = full.prefix(cut)
            XCTAssertNil(TypedStreamScanner.string(from: Data(truncated)),
                         "truncation at \(cut) should not produce a string")
        }
    }

    func testScannerRejectsNonTypedStream() {
        XCTAssertFalse(TypedStreamScanner.looksLikeTypedStream(Data("bplist00...".utf8)))
        XCTAssertNil(TypedStreamScanner.string(from: Data("bplist00...".utf8)))
    }
}
