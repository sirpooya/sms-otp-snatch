import Foundation

/// Pure-Swift, best-effort reader for the one thing we need out of a
/// `streamtyped` archive: the body text.
///
/// This is the documented fallback for the day Apple removes `NSUnarchiver`
/// (see `OTPTypedStream`). It is not a general typedstream parser and does not
/// try to be one. It finds the archived `NSString` payload and reads it.
///
/// Layout, from a real chat.db blob:
///
/// ```
/// 04 0B "streamtyped" 81 E8 03      header, version 1000
/// ... "NSAttributedString" ... "NSString" 01 94 84 01
/// 2B                                '+' = C-string type marker
/// 23                                length (0x23 = 35 bytes)
/// <35 bytes of UTF-8>               the body
/// ```
///
/// Lengths are variable width: a byte below 0x80 is the length itself, 0x81
/// introduces a little-endian UInt16, 0x82 a little-endian UInt32.
public enum TypedStreamScanner {

    private static let magic: [UInt8] = Array("streamtyped".utf8)
    private static let cStringMarker: UInt8 = 0x2B // '+'

    public static func looksLikeTypedStream(_ data: Data) -> Bool {
        guard data.count > 13 else { return false }
        let bytes = [UInt8](data.prefix(13))
        return bytes[0] == 0x04 && bytes[1] == 0x0B && Array(bytes[2..<13]) == magic
    }

    public static func string(from data: Data) -> String? {
        guard looksLikeTypedStream(data) else { return nil }
        let bytes = [UInt8](data)

        // Anchor on the NSString class name so we skip the archive preamble and
        // the NSAttributedString/NSObject class descriptors.
        guard var cursor = index(of: Array("NSString".utf8), in: bytes, from: 0) else { return nil }
        cursor += "NSString".utf8.count

        // The first '+' after the class name introduces the payload.
        while cursor < bytes.count, bytes[cursor] != cStringMarker { cursor += 1 }
        guard cursor < bytes.count else { return nil }
        cursor += 1

        guard let (length, next) = readLength(bytes, at: cursor), length > 0 else { return nil }
        guard next + length <= bytes.count else { return nil }

        let payload = Data(bytes[next..<(next + length)])
        guard let text = String(data: payload, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    private static func readLength(_ bytes: [UInt8], at index: Int) -> (length: Int, next: Int)? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        switch first {
        case 0x81:
            guard index + 2 < bytes.count else { return nil }
            let value = Int(bytes[index + 1]) | (Int(bytes[index + 2]) << 8)
            return (value, index + 3)
        case 0x82:
            guard index + 4 < bytes.count else { return nil }
            let value = Int(bytes[index + 1])
                | (Int(bytes[index + 2]) << 8)
                | (Int(bytes[index + 3]) << 16)
                | (Int(bytes[index + 4]) << 24)
            return (value, index + 5)
        case 0x00..<0x80:
            return (Int(first), index + 1)
        default:
            // 0x83 and above are not lengths we expect here.
            return nil
        }
    }

    private static func index(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        var i = start
        while i <= last {
            if haystack[i] == needle[0] {
                var matched = true
                for k in 1..<needle.count where haystack[i + k] != needle[k] {
                    matched = false
                    break
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }
}
