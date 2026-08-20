import AppKit
import OTPCore
import OTPMessages

/// Detects the Full Disk Access failure and walks the user to the fix.
///
/// FDA cannot be requested programmatically, so the only options are to detect
/// the failure precisely and then deep-link into the right settings pane. That
/// is why `MessageStore` bothers to distinguish permission errors from every
/// other read failure.
@MainActor
final class PermissionGate {

    enum State: Equatable {
        case granted
        case denied
        case databaseMissing
        case failed
    }

    /// The exact pane. Without the anchor, the user lands on the Privacy root
    /// and has to hunt for the right row.
    static let privacyPaneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    private let store: MessageStore
    private var hasShownDialog = false

    init(store: MessageStore) {
        self.store = store
    }

    func check() -> State {
        do {
            try store.probe()
            return .granted
        } catch MessageStoreError.permissionDenied {
            return .denied
        } catch MessageStoreError.databaseNotFound {
            return .databaseMissing
        } catch {
            return .failed
        }
    }

    static func openPrivacyPane() {
        NSWorkspace.shared.open(privacyPaneURL)
    }

    /// Shown at most once per launch. The menu item stays available for as long
    /// as the state is `.denied`, so nagging is unnecessary.
    func presentDialogIfNeeded(for state: State) {
        guard !hasShownDialog else { return }
        switch state {
        case .granted: return
        case .denied: hasShownDialog = true; presentDeniedDialog()
        case .databaseMissing: hasShownDialog = true; presentMissingDialog()
        case .failed: hasShownDialog = true; presentFailedDialog()
        }
    }

    func presentDeniedDialog() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "OTP Snatcher needs Full Disk Access"
        alert.informativeText = """
            Forwarded text messages are stored by Messages in a database that \
            macOS protects. Reading it requires Full Disk Access, which only you \
            can grant.

            Nothing leaves this Mac. The app has no network code at all: it reads \
            the message database, copies the code, and clears the clipboard again.

            In System Settings, switch on OTP Snatcher under Full Disk Access, \
            then quit and reopen the app.
            """
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Self.openPrivacyPane()
        }
    }

    private func presentMissingDialog() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No message database found"
        alert.informativeText = """
            Messages has not created a database on this Mac yet. Open Messages \
            and sign in, then turn on Text Message Forwarding on your iPhone \
            (Settings, Apps, Messages, Text Message Forwarding) so forwarded SMS \
            arrive here.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentFailedDialog() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not read the message database"
        alert.informativeText = """
            The database exists and is readable, but the read failed. If this \
            persists, quit Messages and reopen OTP Snatcher.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Re-probe on activation: granting Full Disk Access usually means the user
    /// tabs away to System Settings and comes back, and the grant only takes
    /// effect for a fresh check.
    func resetDialogState() {
        hasShownDialog = false
    }
}
