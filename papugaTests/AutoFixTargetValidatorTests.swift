import CoreGraphics
import XCTest
@testable import papuga

final class AutoFixTargetValidatorTests: XCTestCase {
    func test_papugaSyntheticEventTag_isRecognizedByEventTapFilter() throws {
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ))

        XCTAssertFalse(PapugaSyntheticEvent.isTagged(event))
        PapugaSyntheticEvent.tag(event)
        XCTAssertTrue(PapugaSyntheticEvent.isTagged(event))
    }

    func test_replacementAnchor_excludesSpaceBoundary() throws {
        let range = try XCTUnwrap(TextReplacementAnchor.sourceRange(
            caretAfterBoundary: 8,
            source: "привіт",
            boundary: " "
        ))

        XCTAssertEqual(range, AXTextRange(location: 1, length: 6))
    }

    func test_replacementAnchor_excludesReturnAndTabBoundaries() throws {
        XCTAssertEqual(
            TextReplacementAnchor.sourceRange(caretAfterBoundary: 7, source: "привіт", boundary: "\r"),
            AXTextRange(location: 0, length: 6)
        )
        XCTAssertEqual(
            TextReplacementAnchor.sourceRange(caretAfterBoundary: 7, source: "привіт", boundary: "\t"),
            AXTextRange(location: 0, length: 6)
        )
    }

    func test_replacementAnchor_usesUTF16ForComposedText() throws {
        let source = "e\u{301}🙂"
        let range = try XCTUnwrap(TextReplacementAnchor.sourceRange(
            caretAfterBoundary: 9,
            source: source,
            boundary: " "
        ))

        XCTAssertEqual(source.count, 2)
        XCTAssertEqual(source.utf16.count, 4)
        XCTAssertEqual(range, AXTextRange(location: 4, length: 4))
    }

    func test_sentenceReplacementAnchor_excludesTrailingListBoundary() throws {
        let source = "vj;yf 👨‍👩‍👧‍👦 dbrjhbcnfnb"
        let prefixUTF16Length = 11
        let boundary = "\r"
        let caret = prefixUTF16Length + source.utf16.count + boundary.utf16.count

        let range = try XCTUnwrap(TextReplacementAnchor.sourceRange(
            caretAfterBoundary: caret,
            source: source,
            boundary: boundary
        ))

        XCTAssertEqual(range.location, prefixUTF16Length)
        XCTAssertEqual(range.length, source.utf16.count)
        XCTAssertEqual(range.location + range.length, caret - boundary.utf16.count)
    }

    func test_replacementAnchor_canLeaveAWholeOverflowSuffixUntouched() throws {
        let source = "first incident"
        let untouchedSuffix = " overflow word "
        let caret = source.utf16.count + untouchedSuffix.utf16.count

        XCTAssertEqual(
            TextReplacementAnchor.sourceRange(
                caretAfterBoundary: caret,
                source: source,
                boundary: untouchedSuffix
            ),
            AXTextRange(location: 0, length: source.utf16.count)
        )
    }

    func test_replacementAnchor_rejectsCaretBeforeSourceAndBoundary() {
        XCTAssertNil(TextReplacementAnchor.sourceRange(
            caretAfterBoundary: 3,
            source: "привіт",
            boundary: " "
        ))
    }

    func test_replacementCommit_rejectsAXSuccessWhenEditorTextDidNotChange() {
        let replacementRange = AXTextRange(location: 12, length: 5)

        XCTAssertFalse(AutoFixTargetValidator.replacementWasCommitted(
            expected: "роблю",
            at: replacementRange,
            readString: { requestedRange in
                XCTAssertEqual(requestedRange, replacementRange)
                return "hj,k"
            }
        ))
    }

    func test_replacementCommit_acceptsExactEditorReadback() {
        let replacementRange = AXTextRange(location: 12, length: 5)

        XCTAssertTrue(AutoFixTargetValidator.replacementWasCommitted(
            expected: "роблю",
            at: replacementRange,
            readString: { requestedRange in
                XCTAssertEqual(requestedRange, replacementRange)
                return "роблю"
            }
        ))
    }

    func test_replacementCommit_pollingAcceptsDelayedExactReadback() {
        let replacementRange = AXTextRange(location: 12, length: 5)
        var reads = 0
        var delays = 0

        XCTAssertTrue(AutoFixTargetValidator.waitForCommittedReplacement(
            expected: "роблю",
            at: replacementRange,
            attempts: 3,
            retryDelay: { delays += 1 },
            readString: { _ in
                reads += 1
                return reads == 3 ? "роблю" : "hj,k"
            }
        ))
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(delays, 2)
    }

    func test_replacementCommit_pollingRejectsPersistentMismatch() {
        var delays = 0

        XCTAssertFalse(AutoFixTargetValidator.waitForCommittedReplacement(
            expected: "роблю",
            at: AXTextRange(location: 12, length: 5),
            attempts: 3,
            retryDelay: { delays += 1 },
            readString: { _ in "hj,k" }
        ))
        XCTAssertEqual(delays, 2)
    }

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
