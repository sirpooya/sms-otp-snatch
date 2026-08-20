import AppKit

/// Entry point.
///
/// `@main` on a MainActor type rather than top-level code in `main.swift`, so
/// that constructing the AppKit delegate is properly main-actor isolated.
@main
@MainActor
struct OTPSnatcherApp {
    static func main() {
        let application = NSApplication.shared
        // LSUIElement in Info.plist is what makes this menu-bar-only in a real
        // bundle. Setting the policy here too keeps behaviour sane when the
        // binary is run straight out of .build during development.
        application.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
