import AppKit
import OTPCore

/// The whole user interface.
@MainActor
final class MenuBarController {

    struct Actions {
        var toggleArmed: (Bool) -> Void
        var setClearInterval: (Int) -> Void
        var setNotify: (Bool) -> Void
        var toggleFallbackPolling: (Bool) -> Void
        var openConfigFile: () -> Void
        var grantFullDiskAccess: () -> Void
        var checkForUpdates: () -> Void
        var reloadConfig: () -> Void
        var quit: () -> Void
    }

    struct ViewState {
        var armed: Bool
        var permission: PermissionGate.State
        var senderCount: Int
        var configProblem: String?
        var clearAfterSeconds: Int
        var notify: Bool
        var fallbackPolling: Bool
        var lastMatch: (label: String, at: Date, strategy: String)?
    }

    private let statusItem: NSStatusItem
    private let actions: Actions
    private var state: ViewState
    private var menuTarget: AnyObject?

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    init(state: ViewState, actions: Actions) {
        self.state = state
        self.actions = actions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        rebuildMenu()
    }

    func update(_ transform: (inout ViewState) -> Void) {
        transform(&state)
        configureButton()
        rebuildMenu()
    }

    // MARK: - Status item

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let symbol: String
        let description: String
        switch state.permission {
        case .granted:
            symbol = state.armed ? "key.horizontal.fill" : "key.horizontal"
            description = state.armed ? "OTP Snatcher, armed" : "OTP Snatcher, paused"
        case .denied, .databaseMissing, .failed:
            symbol = "key.horizontal.slash"
            description = "OTP Snatcher, needs permission"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "key", accessibilityDescription: description)
        button.image?.isTemplate = true
        button.toolTip = description
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(header(statusLine))
        if let problem = state.configProblem {
            menu.addItem(header("config.json: \(problem)"))
        }

        if let match = state.lastMatch {
            menu.addItem(header("Last code: \(match.label) at \(timeFormatter.string(from: match.at)) (\(match.strategy))"))
        } else {
            menu.addItem(header("No code captured yet"))
        }

        menu.addItem(.separator())

        let arm = item(state.armed ? "Pause" : "Resume", #selector(Target.toggleArmed))
        menu.addItem(arm)

        if state.permission != .granted {
            menu.addItem(item("Grant Full Disk Access...", #selector(Target.grantAccess)))
        }

        menu.addItem(.separator())

        // Clipboard TTL. Presets rather than a text field: the value is a
        // trade-off between "long enough to paste" and "short enough not to
        // linger", and typing an arbitrary number adds nothing.
        let clearMenu = NSMenu()
        for seconds in [0, 15, 30, 60, 120, 300] {
            let title = seconds == 0 ? "Never" : "\(seconds) seconds"
            let entry = item(title, #selector(Target.setClearInterval))
            entry.tag = seconds
            entry.state = state.clearAfterSeconds == seconds ? .on : .off
            clearMenu.addItem(entry)
        }
        let clearItem = NSMenuItem(title: "Clear clipboard after", action: nil, keyEquivalent: "")
        clearItem.submenu = clearMenu
        menu.addItem(clearItem)

        let notifyItem = item("Notify on capture", #selector(Target.toggleNotify))
        notifyItem.state = state.notify ? .on : .off
        menu.addItem(notifyItem)

        let pollItem = item("Fallback polling", #selector(Target.togglePolling))
        pollItem.state = state.fallbackPolling ? .on : .off
        pollItem.toolTip = "Stat the database once a second instead of waiting for filesystem events. Only needed if events are being missed."
        menu.addItem(pollItem)

        menu.addItem(.separator())

        let sendersTitle = state.senderCount == 0
            ? "No senders configured"
            : "\(state.senderCount) sender\(state.senderCount == 1 ? "" : "s") configured"
        menu.addItem(header(sendersTitle))
        menu.addItem(item("Edit Senders in config.json...", #selector(Target.openConfig)))
        menu.addItem(item("Reload Config", #selector(Target.reloadConfig)))

        menu.addItem(.separator())
        menu.addItem(item("Check for Updates...", #selector(Target.checkUpdates)))
        menu.addItem(item("Quit OTP Snatcher", #selector(Target.quit), key: "q"))

        // NSMenuItem holds its target weakly, so the controller owns it.
        let target = Target(actions: actions, state: state)
        menuTarget = target
        for entry in menu.items {
            if entry.action != nil { entry.target = target }
            entry.submenu?.items.forEach { $0.target = target }
        }

        statusItem.menu = menu
    }

    private var statusLine: String {
        switch state.permission {
        case .granted:
            if state.senderCount == 0 { return "Idle: add a sender to start" }
            return state.armed ? "Watching for codes" : "Paused"
        case .denied: return "Blocked: Full Disk Access not granted"
        case .databaseMissing: return "No message database on this Mac"
        case .failed: return "Cannot read the message database"
        }
    }

    private func header(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func item(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.isEnabled = true
        return entry
    }

    /// Menu items need an ObjC target. Keeping it a private class here avoids
    /// making the controller itself an NSObject subclass.
    @MainActor
    private final class Target: NSObject {
        private let actions: Actions
        private let state: ViewState

        init(actions: Actions, state: ViewState) {
            self.actions = actions
            self.state = state
        }

        @objc func toggleArmed() { actions.toggleArmed(!state.armed) }
        @objc func setClearInterval(_ sender: NSMenuItem) { actions.setClearInterval(sender.tag) }
        @objc func toggleNotify() { actions.setNotify(!state.notify) }
        @objc func togglePolling() { actions.toggleFallbackPolling(!state.fallbackPolling) }
        @objc func openConfig() { actions.openConfigFile() }
        @objc func reloadConfig() { actions.reloadConfig() }
        @objc func grantAccess() { actions.grantFullDiskAccess() }
        @objc func checkUpdates() { actions.checkForUpdates() }
        @objc func quit() { actions.quit() }
    }
}
