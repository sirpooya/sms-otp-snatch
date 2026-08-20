import Foundation
import OTPCore

/// Loads and saves `config.json`, and reports whether the file on disk is
/// broken so the UI can say so instead of silently disarming.
public final class ConfigStore {
    public enum LoadOutcome {
        case loaded(Config)
        case createdDefault(Config)
        /// The file exists but does not parse. The previous good config, or the
        /// default, is used meanwhile.
        case invalid(Config, reason: String)
    }

    private let url: URL

    public init(url: URL = AppSupport.configURL) {
        self.url = url
    }

    public var fileURL: URL { url }

    public func load() -> LoadOutcome {
        guard let data = try? Data(contentsOf: url) else {
            let fresh = Config.default
            try? save(fresh)
            return .createdDefault(fresh)
        }
        do {
            return .loaded(try JSONDecoder().decode(Config.self, from: data))
        } catch {
            // Report the decoding position, never the file contents: a malformed
            // config can contain anything the user pasted in.
            return .invalid(Config.default, reason: Self.describe(error))
        }
    }

    public func save(_ config: Config) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AppSupport.writeAtomically(encoder.encode(config), to: url)
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "not valid JSON" }
        switch decoding {
        case .keyNotFound(let key, _): return "missing key \"\(key.stringValue)\""
        case .typeMismatch(_, let ctx):
            return "wrong type for \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case .valueNotFound(_, let ctx):
            return "null value for \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted: return "not valid JSON"
        @unknown default: return "not valid JSON"
        }
    }
}
