import Foundation

/// On-disk configuration, matching the schema in CLAUDE.md exactly.
///
/// No sender ids are hardcoded anywhere in the source. A fresh install writes
/// `senders: []`, which means the app is armed but matches nothing until the
/// user adds one.
public struct Config: Codable, Equatable, Sendable {
    public var senders: [SenderRule]
    public var clearClipboardAfterSeconds: Int
    public var notify: Bool

    public static let `default` = Config(
        senders: [],
        clearClipboardAfterSeconds: 60,
        notify: true
    )

    public init(senders: [SenderRule], clearClipboardAfterSeconds: Int, notify: Bool) {
        self.senders = senders
        self.clearClipboardAfterSeconds = clearClipboardAfterSeconds
        self.notify = notify
    }

    /// Missing keys fall back to defaults so a hand-edited config with one key
    /// removed still loads instead of disarming the app.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        senders = try c.decodeIfPresent([SenderRule].self, forKey: .senders) ?? []
        clearClipboardAfterSeconds = try c.decodeIfPresent(Int.self, forKey: .clearClipboardAfterSeconds)
            ?? Config.default.clearClipboardAfterSeconds
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? Config.default.notify
    }

    /// The rule matching a given `handle.id`, or nil when the sender is not
    /// configured. Longest configured id wins, so a specific full number beats
    /// a short shortcode that happens to suffix-match.
    public func rule(forHandle handleID: String) -> SenderRule? {
        senders
            .filter { SenderMatcher.matches(handleID: handleID, ruleID: $0.id) }
            .max { $0.id.count < $1.id.count }
    }

    /// Clamped so a hand-edited config cannot leave a code on the clipboard
    /// forever or clear it before the user can paste. Zero means "never clear".
    public var clearInterval: TimeInterval? {
        if clearClipboardAfterSeconds <= 0 { return nil }
        return TimeInterval(min(max(clearClipboardAfterSeconds, 5), 3600))
    }
}
