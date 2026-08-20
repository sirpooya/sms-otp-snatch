import Foundation
import OTPCore
import OTPMessages

/// The runtime pipeline: filesystem pulse to clipboard.
///
/// Everything except the callbacks runs on one serial queue, which is what makes
/// the watermark safe. Combined with the watcher's debounce, a burst of
/// filesystem events for a single message produces one database read, and a row
/// can never be processed twice, so a code can never be written to the clipboard
/// twice.
final class SnatcherEngine {

    struct Match: Sendable {
        let code: String
        let senderLabel: String
        let strategy: ExtractionResult.Strategy
        let at: Date
    }

    enum Failure: Sendable {
        case permissionDenied
        case databaseMissing
        case other
    }

    private let queue = DispatchQueue(label: "com.pooya.otpsnatcher.engine", qos: .userInitiated)
    private let store: MessageStore
    private let watermarks: WatermarkStore

    private let onMatch: @Sendable (Match) -> Void
    private let onFailure: @Sendable (Failure) -> Void

    /// Guarded by `queue`.
    private var config: Config
    private var armed = true
    private var lastPulse = Date.distantPast
    private var isProcessing = false

    init(store: MessageStore,
         watermarks: WatermarkStore,
         config: Config,
         onMatch: @escaping @Sendable (Match) -> Void,
         onFailure: @escaping @Sendable (Failure) -> Void) {
        self.store = store
        self.watermarks = watermarks
        self.config = config
        self.onMatch = onMatch
        self.onFailure = onFailure
    }

    // MARK: - Control

    func update(config: Config) {
        queue.async { self.config = config }
    }

    func setArmed(_ value: Bool) {
        queue.async {
            self.armed = value
            Log.event(.watcher, value ? "armed" : "disarmed")
        }
    }

    /// Sets the watermark to the current head of the table if there is no
    /// watermark yet, so a fresh install does not replay years of history and
    /// fire a notification for a message from 2019.
    func primeWatermarkIfNeeded() {
        queue.async {
            guard self.watermarks.load() == nil else { return }
            do {
                let head = try self.store.maxRowID()
                try self.watermarks.save(head)
                Log.row(.store, "watermark-primed", rowID: head)
            } catch {
                self.report(error)
            }
        }
    }

    /// Called by the watcher (already debounced) and by the fallback poller.
    func pulse() {
        queue.async { self.process() }
    }

    var lastPulseTime: Date {
        queue.sync { lastPulse }
    }

    // MARK: - Pipeline

    private func process() {
        guard armed else { return }
        // Belt and braces: the serial queue already prevents overlap, but this
        // makes the invariant explicit for anyone who later makes the fetch
        // asynchronous.
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        lastPulse = Date()

        let since = watermarks.load() ?? 0
        let rows: [MessageRow]
        do {
            rows = try store.fetchNew(sinceRowID: since)
        } catch {
            report(error)
            return
        }
        guard !rows.isEmpty else { return }

        var newest: Match? = nil
        for row in rows {
            guard let rule = config.rule(forHandle: row.sender) else { continue }
            guard let result = CodeExtractor.extract(from: row.body, rule: rule) else {
                Log.verdict(rowID: row.rowID, matched: false, strategy: "none")
                continue
            }
            Log.verdict(rowID: row.rowID, matched: true, strategy: "match")
            newest = Match(
                code: result.code,
                senderLabel: rule.label ?? rule.id,
                strategy: result.strategy,
                at: row.date ?? Date()
            )
        }

        // The watermark advances only after the whole batch has been walked. An
        // interrupted run therefore replays the tail rather than skipping it:
        // replaying costs a duplicate clipboard write, skipping costs the user
        // the code they were waiting for.
        if let last = rows.last {
            do { try watermarks.save(last.rowID) } catch { Log.failure(.store, "watermark-save-failed") }
        }

        // Only the newest match reaches the clipboard. If two codes arrived in
        // one batch, the later one is the one the user is waiting for, and one
        // notification beats two.
        if let newest {
            onMatch(newest)
        }
    }

    private func report(_ error: Error) {
        switch error {
        case MessageStoreError.permissionDenied:
            Log.failure(.permission, "full-disk-access-denied")
            onFailure(.permissionDenied)
        case MessageStoreError.databaseNotFound:
            Log.failure(.store, "database-not-found")
            onFailure(.databaseMissing)
        case MessageStoreError.cannotOpen(let code):
            Log.failure(.store, "cannot-open", code: code)
            onFailure(.other)
        case MessageStoreError.sqlite(let code):
            Log.failure(.store, "sqlite-error", code: code)
            onFailure(.other)
        default:
            Log.failure(.store, "read-failed")
            onFailure(.other)
        }
    }
}
