import Foundation
import OTPCore
import OTPTypedStream

public protocol AttributedBodyDecoding: Sendable {
    func string(from data: Data) -> String?
}

/// Resolves a message body from `attributedBody`.
///
/// Three paths, tried in order, because the format is not guaranteed across OS
/// versions:
///
/// 1. A keyed archive (`bplist00`). Not what macOS 26.5 writes, but this is the
///    format Apple would plausibly migrate to, and handling it costs four lines.
/// 2. The legacy `NSUnarchiver` via the ObjC shim. This is the live path today.
/// 3. `TypedStreamScanner`, the pure-Swift fallback, for the day the shim stops
///    working.
///
/// Never regex the raw blob bytes. That approach appears to work right up until
/// a message contains a digit sequence inside an attribute name.
public struct AttributedBodyDecoder: AttributedBodyDecoding {
    public init() {}

    public func string(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if data.starts(with: Array("bplist00".utf8)) {
            if let decoded = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self, from: data
            ), !decoded.string.isEmpty {
                return decoded.string
            }
        }

        if let decoded = OTPDecodeTypedStreamString(data), !decoded.isEmpty {
            return decoded
        }

        if let scanned = TypedStreamScanner.string(from: data), !scanned.isEmpty {
            return scanned
        }

        return nil
    }
}
