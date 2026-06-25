import Carbon.HIToolbox
import XCTest
@testable import papuga

final class AutoFixEditingGuardTests: XCTestCase {
    func test_backspaceWithEmptyBufferStartsStickyEditingSession() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteBackspace(bufferWasEmpty: true, enabled: true)

        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))
        // A non-clean boundary (word still being typed) keeps the latch set.
        guardrail.noteBoundary(bufferWasEmpty: false, isNewline: false)
        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))
    }

    func test_backspaceInsideCurrentBufferDoesNotSuppress() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteBackspace(bufferWasEmpty: false, enabled: true)

        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_navigationKeyStartsStickyEditingSession() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteResetKey(UInt16(kVK_LeftArrow), enabled: true)

        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))
    }

    func test_escapeDoesNotSuppress() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteResetKey(UInt16(kVK_Escape), enabled: true)

        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_emptyBufferBoundaryClearsStickyLatch() {
        var guardrail = AutoFixEditingGuard()
        guardrail.noteResetKey(UInt16(kVK_LeftArrow), enabled: true)
        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))

        // User reaches a clean fresh start: a boundary fired with nothing typed.
        guardrail.noteBoundary(bufferWasEmpty: true, isNewline: false)

        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_newlineBoundaryClearsStickyLatch() {
        var guardrail = AutoFixEditingGuard()
        guardrail.noteBackspace(bufferWasEmpty: true, enabled: true)
        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))

        guardrail.noteBoundary(bufferWasEmpty: false, isNewline: true)

        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_resetClearsStickyLatch() {
        var guardrail = AutoFixEditingGuard()
        guardrail.noteEditingStarted()
        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))

        guardrail.reset()

        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_disabledGuardNeverSuppresses() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteBackspace(bufferWasEmpty: true, enabled: false)
        guardrail.noteResetKey(UInt16(kVK_LeftArrow), enabled: false)

        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_shouldSuppressHonorsEnabledFlag() {
        var guardrail = AutoFixEditingGuard()
        guardrail.noteEditingStarted()

        XCTAssertFalse(guardrail.shouldSuppress(enabled: false))
        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))
    }

    func test_clickSuppressionSuppressesCurrentTokenOnly() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteClickSuppression()
        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))

        // After the first word boundary (even non-clean / non-empty buffer), latch must clear.
        guardrail.noteBoundary(bufferWasEmpty: false, isNewline: false)
        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_clickSuppressionDoesNotStartStickySession() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteClickSuppression()
        // Simulate: user typed a word after clicking, hit space (bufferWasEmpty: false, not a newline).
        guardrail.noteBoundary(bufferWasEmpty: false, isNewline: false)

        // All subsequent words must NOT be suppressed — only the first word after click was held.
        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))

        // Another word goes through cleanly.
        guardrail.noteBoundary(bufferWasEmpty: false, isNewline: false)
        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_editingStartedKeepsStickySessionAfterNonCleanBoundary() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteEditingStarted()
        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))

        // Non-clean boundary does NOT clear the sticky session.
        guardrail.noteBoundary(bufferWasEmpty: false, isNewline: false)
        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))
    }
}
