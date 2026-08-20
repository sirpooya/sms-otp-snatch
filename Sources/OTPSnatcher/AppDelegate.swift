import AppKit
import OTPCore
import OTPMessages

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The public download page. There is no in-app updater on purpose: this
    /// process holds Full Disk Access over the entire message history, and the
    /// security rules in CLAUDE.md rule out network code. "Check for Updates"
    /// therefore hands off to the browser rather than fetching anything itself.
    private static let releasesURL = URL(string: "https://github.com/sirpooya/OTPSnatcher/releases")!

    private let configStore = ConfigStore()
    private let watermarks = WatermarkStore()
    private let store = MessageStore()
    private let clipboard = ClipboardSink()
    private let notifier = Notifier()

    private var gate: PermissionGate!
    private var engine: SnatcherEngine!
    private var watcher: DirectoryWatcher!
    private var poller: FallbackPoller!
    private var configWatcher: DirectoryWatcher!
    private var menu: MenuBarController!

    private var config = Config.default
    private var armed = true
    private var watchdog: DispatchSourceTimer?

    private let watchQueue = DispatchQueue(label: "com.pooya.otpsnatcher.watch", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One unconditional launch marker, so `log show --predicate
        // 'subsystem == "com.pooya.otpsnatcher"'` always shows whether the app
        // started and which permission state it saw. Without it, the denied
        // path is completely silent, which makes support impossible.
        Log.event(.watcher, "launched")
        loadConfig(announce: false)

        gate = PermissionGate(store: store)

        engine = SnatcherEngine(
            store: store,
            watermarks: watermarks,
            config: config,
            onMatch: { [weak self] match in
                Task { @MainActor in self?.handle(match) }
            },
            onFailure: { [weak self] failure in
                Task { @MainActor in self?.handle(failure) }
            }
        )

        watcher = DirectoryWatcher(
            directory: MessageStore.defaultDatabaseURL.deletingLastPathComponent(),
            queue: watchQueue,
            onPulse: { [weak self] in self?.engine.pulse() }
        )

        poller = FallbackPoller(
            databaseURL: MessageStore.defaultDatabaseURL,
            queue: watchQueue,
            onPulse: { [weak self] in self?.engine.pulse() }
        )

        // Reuse of the same watcher for the config directory: an edit to
        // config.json takes effect without a relaunch, which is what makes
        // "edit the JSON" an acceptable way to manage senders.
        configWatcher = DirectoryWatcher(
            directory: (try? AppSupport.ensureDirectory()) ?? AppSupport.directory,
            debounce: 0.4,
            queue: watchQueue,
            onPulse: { [weak self] in
                Task { @MainActor in self?.loadConfig(announce: true) }
            }
        )

        let permission = gate.check()
        Log.state(.permission, "launch-check", permission.logName)
        menu = MenuBarController(
            state: viewState(permission: permission),
            actions: menuActions()
        )

        if permission == .granted {
            engine.primeWatermarkIfNeeded()
            watcher.start()
            startWatchdog()
            // One pulse at launch, in case a code arrived while the app was not
            // running.
            engine.pulse()
        } else {
            gate.presentDialogIfNeeded(for: permission)
        }
        configWatcher.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recheckPermission() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchdog?.cancel()
        watcher?.stop()
        poller?.stop()
        configWatcher?.stop()
        // Leave the clipboard as it is: the user may be mid-paste, and a code
        // they asked for is not ours to take away on the way out.
        clipboard.cancelPendingClear()
    }

    // MARK: - Wiring

    private func menuActions() -> MenuBarController.Actions {
        MenuBarController.Actions(
            toggleArmed: { [weak self] value in
                guard let self else { return }
                armed = value
                engine.setArmed(value)
                if value { engine.pulse() }
                refreshMenu()
            },
            setClearInterval: { [weak self] seconds in
                guard let self else { return }
                config.clearClipboardAfterSeconds = seconds
                persistConfig()
            },
            setNotify: { [weak self] value in
                guard let self else { return }
                config.notify = value
                persistConfig()
            },
            toggleFallbackPolling: { [weak self] value in
                guard let self else { return }
                if value { poller.start() } else { poller.stop() }
                refreshMenu()
            },
            openConfigFile: { [weak self] in
                guard let self else { return }
                _ = try? AppSupport.ensureDirectory()
                if !FileManager.default.fileExists(atPath: configStore.fileURL.path) {
                    try? configStore.save(config)
                }
                NSWorkspace.shared.open(configStore.fileURL)
            },
            grantFullDiskAccess: { [weak self] in
                self?.gate.presentDeniedDialog()
            },
            checkForUpdates: {
                NSWorkspace.shared.open(Self.releasesURL)
            },
            reloadConfig: { [weak self] in
                self?.loadConfig(announce: true)
            },
            quit: {
                NSApplication.shared.terminate(nil)
            }
        )
    }

    private func handle(_ match: SnatcherEngine.Match) {
        clipboard.write(match.code, clearAfter: config.clearInterval)
        if config.notify {
            notifier.notifyCaptured(senderLabel: match.senderLabel)
        }
        menu.update { state in
            state.lastMatch = (label: match.senderLabel, at: Date(), strategy: match.strategy.rawValue)
        }
    }

    private func handle(_ failure: SnatcherEngine.Failure) {
        let permission: PermissionGate.State
        switch failure {
        case .permissionDenied: permission = .denied
        case .databaseMissing: permission = .databaseMissing
        case .other: permission = .failed
        }
        menu.update { $0.permission = permission }
        gate.presentDialogIfNeeded(for: permission)
    }

    private func recheckPermission() {
        let permission = gate.check()
        Log.state(.permission, "recheck", permission.logName)
        menu.update { $0.permission = permission }
        guard permission == .granted else { return }
        // The grant may have arrived while we were in the background, so start
        // the parts that were skipped at launch.
        gate.resetDialogState()
        engine.primeWatermarkIfNeeded()
        watcher.start()
        startWatchdog()
        engine.pulse()
    }

    // MARK: - Config

    private func loadConfig(announce: Bool) {
        var problem: String? = nil
        switch configStore.load() {
        case .loaded(let loaded): config = loaded
        case .createdDefault(let fresh): config = fresh
        case .invalid(let fallback, let reason):
            config = fallback
            problem = reason
        }
        engine?.update(config: config)
        guard announce, menu != nil else { return }
        menu.update { state in
            state.senderCount = self.config.senders.count
            state.configProblem = problem
            state.clearAfterSeconds = self.config.clearClipboardAfterSeconds
            state.notify = self.config.notify
        }
    }

    private func persistConfig() {
        do {
            try configStore.save(config)
        } catch {
            Log.failure(.store, "config-save-failed")
        }
        engine.update(config: config)
        refreshMenu()
    }

    private func refreshMenu() {
        menu.update { state in
            state.armed = self.armed
            state.senderCount = self.config.senders.count
            state.clearAfterSeconds = self.config.clearClipboardAfterSeconds
            state.notify = self.config.notify
            state.fallbackPolling = self.poller.isRunning
        }
    }

    private func viewState(permission: PermissionGate.State) -> MenuBarController.ViewState {
        MenuBarController.ViewState(
            armed: armed,
            permission: permission,
            senderCount: config.senders.count,
            configProblem: nil,
            clearAfterSeconds: config.clearClipboardAfterSeconds,
            notify: config.notify,
            fallbackPolling: false,
            lastMatch: nil
        )
    }

    // MARK: - FSEvents watchdog

    /// Some users report FSEvents coalescing events away under load. Rather than
    /// polling by default, watch for the symptom: the database was modified more
    /// recently than our last pulse, and stayed that way. When that happens,
    /// turn the poller on and leave it on.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: watchQueue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let paths = self.poller.watchedPaths
            guard let modified = FallbackPoller.latestModification(of: paths) else { return }
            let lastPulse = self.engine.lastPulseTime
            guard modified.timeIntervalSince(lastPulse) > 10 else { return }
            Task { @MainActor in
                guard !self.poller.isRunning else { return }
                Log.event(.watcher, "fsevents-missed-write-enabling-poller")
                self.poller.start()
                self.refreshMenu()
            }
        }
        timer.resume()
        watchdog = timer
    }
}
