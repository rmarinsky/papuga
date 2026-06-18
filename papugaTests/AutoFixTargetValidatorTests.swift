import XCTest
@testable import papuga

final class AutoFixTargetValidatorTests: XCTestCase {
    func test_stable_identity_ignores_caret_location() {
        let first = FocusedElementSignature(
            pid: 100,
            role: "AXTextArea",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "editor",
            frameHash: 7,
            selectedRangeLocation: 10
        )

        let second = FocusedElementSignature(
            pid: 100,
            role: "AXTextArea",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "editor",
            frameHash: 7,
            selectedRangeLocation: 15
        )

        XCTAssertEqual(first.stableIdentity, second.stableIdentity)
    }

    func test_stable_identity_changes_when_frame_changes() {
        let first = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "search",
            frameHash: 7,
            selectedRangeLocation: 1
        )

        let second = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "search",
            frameHash: 8,
            selectedRangeLocation: 1
        )

        XCTAssertNotEqual(first.stableIdentity, second.stableIdentity)
    }
}
