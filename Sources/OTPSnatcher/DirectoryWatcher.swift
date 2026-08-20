import Foundation
import OTPCore

/// Watches `~/Library/Messages` for changes and delivers debounced pulses.
///
/// The directory is watched, never the file. In WAL mode a new message usually
/// lands in `chat.db-wal` first and only later gets checkpointed into
/// `chat.db`, so a file-level watch on `chat.db` misses messages entirely.
/// Watching the directory catches all three of `chat.db`, `chat.db-wal` and
/// `chat.db-shm`.
///
/// Note that enumerating this directory is itself gated by Full Disk Access, so
/// a watcher that never fires is a plausible permission symptom rather than an
/// FSEvents bug.
final class DirectoryWatcher {

    private let directory: URL
    private let debounce: TimeInterval
    private let queue: DispatchQueue
    private let onPulse: () -> Void

    private var stream: FSEventStreamRef?
    private var pendingPulse: DispatchWorkItem?

    init(directory: URL,
         debounce: TimeInterval = 0.15,
         queue: DispatchQueue,
         onPulse: @escaping () -> Void) {
        self.directory = directory
        self.debounce = debounce
        self.queue = queue
        self.onPulse = onPulse
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info)
                .takeUnretainedValue()
                .schedulePulse()
        }

        // NoDefer so the first event in a burst arrives immediately rather than
        // after the latency window; the debounce below handles coalescing, and
        // doing it ourselves keeps the timing explicit.
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagIgnoreSelf
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else {
            Log.failure(.watcher, "fsevents-create-failed")
            return false
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            Log.failure(.watcher, "fsevents-start-failed")
            return false
        }

        self.stream = stream
        Log.event(.watcher, "fsevents-started")
        return true
    }

    func stop() {
        pendingPulse?.cancel()
        pendingPulse = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        Log.event(.watcher, "fsevents-stopped")
    }

    /// Collapses a burst of filesystem events into one pulse. A single message
    /// arriving touches the WAL, the shm and often the db, so without this the
    /// pipeline would run three or four times per SMS.
    private func schedulePulse() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingPulse?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.pendingPulse = nil
                self?.onPulse()
            }
            self.pendingPulse = work
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: work)
        }
    }
}

/// Fallback for the case where FSEvents coalesces or goes quiet.
///
/// Deliberately dumb: once a second, stat the database and its sidecars, and
/// pulse when any modification time moved. Only runs while explicitly enabled,
/// which the engine does either on the user's instruction or after it catches
/// FSEvents missing a write.
final class FallbackPoller {

    private let paths: [String]
    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let onPulse: () -> Void

    private var timer: DispatchSourceTimer?
    private var lastSignature: String?

    private(set) var isRunning = false

    init(databaseURL: URL,
         interval: TimeInterval = 1.0,
         queue: DispatchQueue,
         onPulse: @escaping () -> Void) {
        self.paths = ["", "-wal", "-shm"].map { databaseURL.path + $0 }
        self.interval = interval
        self.queue = queue
        self.onPulse = onPulse
    }

    deinit { stop() }

    func start() {
        guard timer == nil else { return }
        lastSignature = Self.signature(of: paths)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = Self.signature(of: self.paths)
            guard current != self.lastSignature else { return }
            self.lastSignature = current
            self.onPulse()
        }
        timer.resume()
        self.timer = timer
        isRunning = true
        Log.event(.watcher, "fallback-poller-started")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        guard isRunning else { return }
        isRunning = false
        Log.event(.watcher, "fallback-poller-stopped")
    }

    /// Modification times plus sizes, concatenated. Cheap, and a size change
    /// catches the case where two writes share a modification timestamp.
    static func signature(of paths: [String]) -> String {
        paths.map { path in
            var st = stat()
            guard stat(path, &st) == 0 else { return "-" }
            return "\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec).\(st.st_size)"
        }.joined(separator: "|")
    }

    static func latestModification(of paths: [String]) -> Date? {
        var newest: TimeInterval? = nil
        for path in paths {
            var st = stat()
            guard stat(path, &st) == 0 else { continue }
            let t = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
            newest = max(newest ?? t, t)
        }
        return newest.map { Date(timeIntervalSince1970: $0) }
    }

    var watchedPaths: [String] { paths }
}
