import Foundation
import UserNotifications
import OTPCore

/// Banner when a code is captured.
///
/// The code itself is deliberately **not** in the notification. Notification
/// Center persists banners, so putting the code there would undo the concealed
/// pasteboard type and the auto-clear: the secret would sit in notification
/// history long after the clipboard was wiped. The banner says which sender it
/// came from; the code is already in the paste buffer, which is the point.
@MainActor
final class Notifier {

    private var authorizationRequested = false
    private var authorized = false

    /// UNUserNotificationCenter requires a bundled app with a bundle
    /// identifier. Running the raw binary out of `.build` has neither, and
    /// touching the center there traps, so every entry point checks this first.
    private var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func notifyCaptured(senderLabel: String) {
        guard isBundled else { return }
        requestAuthorizationIfNeeded { [weak self] granted in
            guard granted else { return }
            self?.post(title: "Code copied", body: "From \(senderLabel). Paste with Command-V.")
        }
    }

    private func requestAuthorizationIfNeeded(_ completion: @escaping (Bool) -> Void) {
        if authorizationRequested {
            completion(authorized)
            return
        }
        authorizationRequested = true
        // Requested lazily, on the first code we would announce, rather than at
        // launch: a menu-bar utility asking for notification permission before
        // it has done anything reads as spam.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.authorized = granted
                completion(granted)
            }
        }
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if error != nil { Log.failure(.clipboard, "notification-failed") }
        }
    }
}
