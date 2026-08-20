import Foundation

/// Everything this app writes lives under one directory, and nothing else does.
public enum AppSupport {
    public static let directoryName = "OTPSnatcher"

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static var configURL: URL { directory.appendingPathComponent("config.json") }
    public static var stateURL: URL { directory.appendingPathComponent("state.json") }

    @discardableResult
    public static func ensureDirectory() throws -> URL {
        let dir = directory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return dir
    }

    /// Write-to-temp-then-replace, so a crash mid-write cannot leave a
    /// half-written config or a truncated watermark behind.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        try ensureDirectory()
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }
}
