import AppKit
import OTPCore

/// Puts the code on the clipboard, keeps it out of clipboard-manager history,
/// and takes it back off after the configured TTL.
@MainActor
final class ClipboardSink {

    /// The nspasteboard.org convention for secrets. Alfred, Raycast, Maccy and
    /// friends check for this type and skip the item, so the code never lands in
    /// a third-party history database. This matters more than the auto-clear:
    /// a clipboard manager would otherwise keep the OTP forever.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private struct Written {
        let value: String
        let changeCount: Int
    }

    private var lastWritten: Written?
    private var clearWork: DispatchWorkItem?

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func write(_ code: String, clearAfter: TimeInterval?) {
        clearWork?.cancel()
        clearWork = nil

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(code, forType: .string)
        item.setString(code, forType: Self.concealedType)
        pasteboard.writeObjects([item])

        lastWritten = Written(value: code, changeCount: pasteboard.changeCount)
        Log.event(.clipboard, "code-written")

        guard let clearAfter else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.clearIfStillOurs() }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter, execute: work)
    }

    /// Clears only if the clipboard still holds exactly what we put there.
    ///
    /// Both checks are needed. The change count catches the case where the user
    /// copied something else and it happens to be the same string; the value
    /// comparison catches the case where another app rewrote the pasteboard with
    /// identical-looking content. If either says "not ours any more", we leave
    /// it alone: stomping on the user's clipboard is worse than leaving an
    /// expired code on it.
    func clearIfStillOurs() {
        defer { clearWork = nil }
        guard let written = lastWritten else { return }
        guard pasteboard.changeCount == written.changeCount else {
            Log.event(.clipboard, "clear-skipped-changed")
            lastWritten = nil
            return
        }
        guard pasteboard.string(forType: .string) == written.value else {
            Log.event(.clipboard, "clear-skipped-value-differs")
            lastWritten = nil
            return
        }
        pasteboard.clearContents()
        lastWritten = nil
        Log.event(.clipboard, "cleared")
    }

    /// Exposed for the "should I clear" unit tests and for teardown.
    var hasPendingClear: Bool { clearWork != nil }

    func cancelPendingClear() {
        clearWork?.cancel()
        clearWork = nil
    }
}
