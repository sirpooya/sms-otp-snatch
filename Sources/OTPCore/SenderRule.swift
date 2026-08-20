import Foundation

/// One configured sender, from `config.json`.
public struct SenderRule: Codable, Equatable, Sendable {
    /// The sender as it appears in `handle.id`: a shortcode (`20001`), a long
    /// number (`+989999920000`), or an alphanumeric id (`DIGIKALA`).
    public var id: String

    /// Optional per-sender regex override. If set, it is *authoritative*: when
    /// it fails to match, extraction returns nil rather than falling back to
    /// the generic strategies. A user writes a pattern precisely to stop the
    /// app grabbing the wrong number, so silently ignoring it would defeat the
    /// point.
    public var pattern: String?

    /// Human label for the menu. Never used for matching.
    public var label: String?

    /// Optional extra positive anchors for this sender, merged with the
    /// built-in keyword table.
    public var keywords: [String]?

    public init(id: String, pattern: String? = nil, label: String? = nil, keywords: [String]? = nil) {
        self.id = id
        self.pattern = pattern
        self.label = label
        self.keywords = keywords
    }
}

/// Matches a `handle.id` from chat.db against a configured sender id.
///
/// Two real-world wrinkles, both observed in a live chat.db:
///
/// 1. iOS message filtering appends `(filtered)` to the handle id, so the same
///    shortcode appears as both `987007100` and `987007100(filtered)`. Without
///    stripping that suffix, a configured sender silently misses a large slice
///    of its own messages.
/// 2. Numeric senders show up in several forms for the same line
///    (`+989999920000`, `989999920000`, `09999920000`), so numeric comparison
///    is done on the digit tail rather than the literal string.
public enum SenderMatcher {

    public static func canonical(_ handleID: String) -> String {
        var s = handleID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip one or more trailing "(filtered)" / "(Filtered)" markers.
        while true {
            let lower = s.lowercased()
            guard lower.hasSuffix("(filtered)") else { break }
            s = String(s.dropLast("(filtered)".count)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    public static func matches(handleID: String, ruleID: String) -> Bool {
        let handle = canonical(handleID)
        let rule = canonical(ruleID)
        if handle.isEmpty || rule.isEmpty { return false }

        // Alphanumeric senders: case-insensitive, whitespace-insensitive
        // ("bank mellat" vs "BANKMELLAT").
        let hFold = fold(handle)
        let rFold = fold(rule)
        if hFold == rFold { return true }

        // Numeric senders: compare digit tails so country-code and trunk-zero
        // variants of the same line match. Both sides must be *purely* numeric
        // for this, otherwise "DIGIKALA" and a shortcode could suffix-match on
        // stray digits.
        guard isNumeric(handle), isNumeric(rule) else { return false }
        let hDigits = digitsOnly(handle)
        let rDigits = digitsOnly(rule)
        if hDigits == rDigits { return !hDigits.isEmpty }

        let (shorter, longer) = hDigits.count <= rDigits.count ? (hDigits, rDigits) : (rDigits, hDigits)
        // 4 digits is the shortest shortcode worth suffix-matching; below that
        // the false-positive risk outweighs the convenience.
        guard shorter.count >= 4 else { return false }
        return longer.hasSuffix(shorter)
    }

    /// True when the sender is a phone number or shortcode rather than an
    /// alphanumeric sender id. Punctuation that carriers sprinkle into numbers
    /// (`+`, spaces, dashes, parens) is tolerated.
    private static func isNumeric(_ s: String) -> Bool {
        let normalized = DigitNormalizer.normalize(s)
        var sawDigit = false
        for ch in normalized {
            if ch.isASCII && ch.isNumber { sawDigit = true; continue }
            if "+-() ".contains(ch) { continue }
            return false
        }
        return sawDigit
    private static func fold(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace }
    }

    private static func digitsOnly(_ s: String) -> String {
        DigitNormalizer.normalize(s).filter { $0.isASCII && $0.isNumber }
    }
}
