import Carbon.HIToolbox
import Foundation

/// Guards auto-fix against corrupting text the user is *editing* rather than typing fresh.
///
/// The word buffer is a naive append-only accumulator with no document-position awareness, so when
/// the user moves the caret into existing text (arrow keys) or deletes back into it (backspace on an
/// empty buffer), the buffer no longer matches the on-screen word and a replacement would delete the
/// wrong characters. To stay safe we start a sticky "editing session" on those signals and suppress
/// auto-fix until the user reaches an unambiguous fresh start — a word boundary fired with an empty
/// buffer, or a newline. This is deliberately conservative: it may skip a few legitimate fixes, but
/// it never mangles text mid-edit. (Mouse clicks reset the whole typing session elsewhere, so the
/// buffer re-syncs to the click position and is handled separately.)
struct AutoFixEditingGuard {
    /// Legacy one-shot flag, consumed every boundary. Set alongside the sticky latch.
    private(set) var shouldSuppressCurrentToken = false
    /// Sticky latch: once the user is editing existing text, stays set until a clean fresh start.
    private(set) var inEditingSession = false

    mutating func reset() {
        shouldSuppressCurrentToken = false
        inEditingSession = false
    }

    /// Backspacing while the typing buffer is empty deletes into pre-existing text — the user is
    /// editing existing content, so start a sticky editing session.
    mutating func noteBackspace(bufferWasEmpty: Bool, enabled: Bool) {
        guard enabled, bufferWasEmpty else { return }
        noteEditingStarted()
    }

    /// Navigation keys (arrows, Home/End, Page Up/Down) move the caret into existing text. Start a
    /// sticky editing session.
    mutating func noteResetKey(_ keyCode: UInt16, enabled: Bool) {
        guard enabled, Self.isNavigationKey(keyCode) else { return }
        noteEditingStarted()
    }

    /// Marks that the user has started editing existing text. Sticky until a clean fresh start.
    mutating func noteEditingStarted() {
        shouldSuppressCurrentToken = true
        inEditingSession = true
    }

    /// A mouse click may land inside existing text, so suppress the very next word (the one the
    /// user starts typing from the clicked position). Unlike `noteEditingStarted`, this does NOT
    /// start a sticky editing session: once the first clean word boundary clears
    /// `shouldSuppressCurrentToken`, auto-fix resumes normally for all subsequent words.
    mutating func noteClickSuppression() {
        shouldSuppressCurrentToken = true
        // inEditingSession is intentionally not set: clicking a field and typing a whole word
        // from scratch is not the same as arrow-keying into the middle of an existing word.
    }

    /// Non-destructive check used at the word boundary: suppress when either the one-shot flag or
    /// the sticky editing latch is active. Does NOT clear the latch.
    func shouldSuppress(enabled: Bool) -> Bool {
        enabled && (shouldSuppressCurrentToken || inEditingSession)
    }

    /// Called after each word boundary is evaluated. Always consumes the one-shot flag; only clears
    /// the sticky editing latch on an unambiguous fresh start (a boundary that fired with an empty
    /// typing buffer, or a newline).
    mutating func noteBoundary(bufferWasEmpty: Bool, isNewline: Bool) {
        shouldSuppressCurrentToken = false
        if bufferWasEmpty || isNewline {
            inEditingSession = false
        }
    }

    static func isNavigationKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return true
        default:
            return false
        }
    }
}
