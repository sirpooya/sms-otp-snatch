import Foundation

/// The decision of whether an expired code may be taken off the clipboard.
///
/// Split out from the AppKit code so it can be tested directly: this predicate
/// is the difference between "the OTP disappears after a minute" and "the app
/// silently eats whatever the user copied in the meantime".
public enum ClipboardGuard {

    /// Clear only when the clipboard still holds exactly what we put there.
    ///
    /// Both conditions are load-bearing:
    ///
    /// - The change count catches a rewrite even when the new content happens to
    ///   be an identical string, which is what makes "the user copied the same
    ///   code again by hand" safe.
    /// - The value comparison catches the case where the change count matches by
    ///   coincidence, for instance after a pasteboard rewrite that restored an
    ///   equal count.
    ///
    /// When in doubt this returns false. Leaving an expired code on the
    /// clipboard is a small risk; wiping the user's clipboard out from under
    /// them is a bug they will notice and never forgive.
    public static func shouldClear(
        currentChangeCount: Int,
        writtenChangeCount: Int,
        currentValue: String?,
        writtenValue: String
    ) -> Bool {
        guard currentChangeCount == writtenChangeCount else { return false }
        guard let currentValue, currentValue == writtenValue else { return false }
        return true
    }
}
