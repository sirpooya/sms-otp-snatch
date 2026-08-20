import AppKit
import OTPCore
import OTPMessages

/// Entry point.
///
/// `@main` on a MainActor type rather than top-level code in `main.swift`, so
/// that constructing the AppKit delegate is properly main-actor isolated.
@main
@MainActor
struct OTPSnatcherApp {
    static func main() {
        if CommandLine.arguments.contains("--check") {
            runDiagnostic()
            return
        }

        let application = NSApplication.shared
        // LSUIElement in Info.plist is what makes this menu-bar-only in a real
        // bundle. Setting the policy here too keeps behaviour sane when the
        // binary is run straight out of .build during development.
        application.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    /// `OTPSnatcher --check` reports whether this build can read the message
    /// database, and exits. No UI, no watcher, no clipboard.
    ///
    /// It exists because the failure this app hits most often is a permission
    /// failure keyed to the code signature, and answering "can *this* binary
    /// read it" needs to be one command rather than a launch-and-observe cycle.
    ///
    /// It prints counts and states only: no sender, body or code, in line with
    /// the logging rules.
    private static func runDiagnostic() {
        let store = MessageStore()
        print("bundle:    \(Bundle.main.bundleIdentifier ?? "none (running unbundled)")")
        print("database:  \(MessageStore.defaultDatabaseURL.path)")

        do {
            try store.probe()
            let head = try store.maxRowID()
            print("access:    granted")
            print("maxROWID:  \(head)")
            let recent = try store.fetchNew(sinceRowID: max(0, head - 200), limit: 200)
            print("readable:  \(recent.count) of the last 200 rows decoded")
            print("snapshot:  \(store.lastReadUsedSnapshot ? "yes (WAL fallback in use)" : "no (direct read)")")
        } catch MessageStoreError.permissionDenied {
            print("access:    DENIED (no Full Disk Access for this signature)")
            print("fix:       grant Full Disk Access to this bundle, then relaunch")
        } catch MessageStoreError.databaseNotFound {
            print("access:    no database (Messages has not run on this Mac)")
        } catch {
            print("access:    failed (\(type(of: error)))")
        }

        let config = ConfigStore()
        switch config.load() {
        case .loaded(let c):
            print("config:    \(config.fileURL.path) (\(c.senders.count) sender(s))")
        case .createdDefault:
            print("config:    written fresh at \(config.fileURL.path)")
        case .invalid(_, let reason):
            print("config:    INVALID (\(reason)) at \(config.fileURL.path)")
        }
        print("watermark: \(WatermarkStore().load().map(String.init) ?? "not set")")
    }
}
