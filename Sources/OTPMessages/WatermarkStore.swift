import Foundation
import OTPCore

/// Persists the last processed ROWID.
///
/// ROWID rather than a timestamp, per CLAUDE.md: monotonic, cheap to compare,
/// and immune to clock changes and to the two different date encodings in
/// `message.date`.
public final class WatermarkStore {
    private struct State: Codable {
        var lastSeenROWID: Int64
    }

    private let url: URL

    public init(url: URL = AppSupport.stateURL) {
        self.url = url
    }

    public func load() -> Int64? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
        return state.lastSeenROWID
    }

    /// Only ever called after a batch has been fully processed, so an interrupted
    /// run replays the tail rather than skipping it. Replaying is recoverable;
    /// skipping an OTP is not.
    public func save(_ rowID: Int64) throws {
        let data = try JSONEncoder().encode(State(lastSeenROWID: rowID))
        try AppSupport.writeAtomically(data, to: url)
    }
}
