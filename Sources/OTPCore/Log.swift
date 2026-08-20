import Foundation
import os

/// The only logging facility in the app.
///
/// Security rule from CLAUDE.md, enforced by the shape of this API: there is no
/// function here that takes free-form text. Callers can log a ROWID, a match
/// verdict, a strategy name, or a count. There is deliberately no way to pass a
/// message body or an extracted code, in any build configuration.
public enum Log {
    private static let subsystem = "com.pooya.otpsnatcher"

    private static let watcher = Logger(subsystem: subsystem, category: "watcher")
    private static let store = Logger(subsystem: subsystem, category: "store")
    private static let match = Logger(subsystem: subsystem, category: "match")
    private static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    private static let permission = Logger(subsystem: subsystem, category: "permission")

    public enum Area: String, Sendable {
        case watcher, store, match, clipboard, permission
    }

    private static func logger(for area: Area) -> Logger {
        switch area {
        case .watcher: return watcher
        case .store: return store
        case .match: return match
        case .clipboard: return clipboard
        case .permission: return permission
        }
    }

    /// A named event with no payload.
    public static func event(_ area: Area, _ name: StaticString) {
        logger(for: area).log("\(name, privacy: .public)")
    }

    /// A named event carrying a row identifier. ROWIDs are safe: they are
    /// monotonic counters, not content.
    public static func row(_ area: Area, _ name: StaticString, rowID: Int64) {
        logger(for: area).log("\(name, privacy: .public) rowID=\(rowID, privacy: .public)")
    }

    /// A named event carrying a count.
    public static func count(_ area: Area, _ name: StaticString, _ value: Int) {
        logger(for: area).log("\(name, privacy: .public) n=\(value, privacy: .public)")
    }

    /// A match verdict. `strategy` is an enum case name, never message content.
    public static func verdict(rowID: Int64, matched: Bool, strategy: StaticString) {
        match.log("verdict rowID=\(rowID, privacy: .public) matched=\(matched, privacy: .public) via=\(strategy, privacy: .public)")
    }

    /// A permission state, by case name. Not free-form: the caller passes an
    /// enum case name, which is why this takes a StaticString.
    public static func state(_ area: Area, _ name: StaticString, _ value: StaticString) {
        logger(for: area).log("\(name, privacy: .public)=\(value, privacy: .public)")
    }

    /// An error, reported by its type only. Error descriptions can embed file
    /// paths but never message content; still, only the case name is logged.
    public static func failure(_ area: Area, _ name: StaticString, code: Int32 = 0) {
        logger(for: area).error("\(name, privacy: .public) code=\(code, privacy: .public)")
    }
}
