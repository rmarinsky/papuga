import Carbon.HIToolbox
import XCTest
@testable import papuga

final class AutoFixEditingGuardTests: XCTestCase {
    func test_backspaceWithEmptyBufferSuppressesNextToken() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteBackspace(bufferWasEmpty: true, enabled: true)

        XCTAssertTrue(guardrail.consumeSuppression(enabled: true))
        XCTAssertFalse(guardrail.consumeSuppression(enabled: true))
    }

    func test_backspaceInsideCurrentBufferDoesNotSuppress() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteBackspace(bufferWasEmpty: false, enabled: true)

        XCTAssertFalse(guardrail.consumeSuppression(enabled: true))
    }

    func test_navigationKeySuppressesNextToken() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteResetKey(UInt16(kVK_LeftArrow), enabled: true)

        XCTAssertTrue(guardrail.consumeSuppression(enabled: true))
    }

    func test_escapeDoesNotSuppressNextToken() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteResetKey(UInt16(kVK_Escape), enabled: true)

        XCTAssertFalse(guardrail.consumeSuppression(enabled: true))
    }

    func test_disabledGuardNeverSuppresses() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteBackspace(bufferWasEmpty: true, enabled: false)
        guardrail.noteResetKey(UInt16(kVK_LeftArrow), enabled: false)

        XCTAssertFalse(guardrail.consumeSuppression(enabled: true))
    }
}
