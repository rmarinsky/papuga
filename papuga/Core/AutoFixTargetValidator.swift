import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct AXTextRange: Equatable {
    let location: Int
    let length: Int

    var cfRange: CFRange {
        CFRange(location: location, length: length)
    }
}

struct TextReplacementAnchor: Equatable {
    let targetPID: pid_t
    let bundleID: String
    let focusedElementIdentity: FocusedElementSignature.StableIdentity
    let sourceRange: AXTextRange
    let boundaryUTF16Length: Int
    let caretAfterBoundary: Int
    let expectedSource: String

    static func sourceRange(
        caretAfterBoundary: Int,
        source: String,
        boundary: String
    ) -> AXTextRange? {
        let sourceLength = source.utf16.count
        let boundaryLength = boundary.utf16.count
        let location = caretAfterBoundary - boundaryLength - sourceLength
        guard sourceLength > 0, boundaryLength > 0, location >= 0 else { return nil }
        return AXTextRange(location: location, length: sourceLength)
    }
}

struct TextReplacementResult: Equatable {
    /// Nil only when the editor committed the replacement but did not confirm the requested
    /// collapsed caret, so a later undo/retry cannot be anchored safely.
    let recoveryAnchor: TextReplacementAnchor?
}

struct FocusedElementSignature: Equatable {
    let pid: pid_t
    let role: String?
    let subrole: String?
    let windowTitleHash: Int?
    let elementIdentifier: String?
    let frameHash: Int?
    let selectedRangeLocation: Int?

    var stableIdentity: StableIdentity {
        StableIdentity(
            pid: pid,
            role: role,
            subrole: subrole,
            windowTitleHash: windowTitleHash,
            elementIdentifier: elementIdentifier,
            frameHash: frameHash
        )
    }

    struct StableIdentity: Equatable {
        let pid: pid_t
        let role: String?
        let subrole: String?
        let windowTitleHash: Int?
        let elementIdentifier: String?
        let frameHash: Int?
    }
}

struct AutoFixTargetSession: Equatable {
    let tokenID: UUID
    let startedAt: TimeInterval
    let targetPID: pid_t?
    let bundleID: String?
    let appName: String?
    let focusedElementSignature: FocusedElementSignature?
    let firstKeyCode: UInt16
    let firstCharacter: String
}

enum AutoFixTargetValidation: Equatable {
    case verified
    case changed(String)
    case unverifiable(String)

    var canMutate: Bool {
        self == .verified
    }

    var skipReason: AutoFixSkipReason {
        switch self {
        case .verified:
            return .targetUnverifiable
        case .changed:
            return .targetChanged
        case .unverifiable:
            return .targetUnverifiable
        }
    }
}

@MainActor
final class AutoFixTargetValidator {
    private(set) var session: AutoFixTargetSession?

    func reset() {
        session = nil
    }

    @discardableResult
    func startSession(event: CGEvent, keyCode: UInt16, typedString: String) -> AutoFixTargetSession {
        startSession(
            targetPID: Self.targetPID(from: event),
            keyCode: keyCode,
            typedString: typedString
        )
    }

    @discardableResult
    func startSession(targetPID: pid_t?, keyCode: UInt16, typedString: String) -> AutoFixTargetSession {
        let app = NSWorkspace.shared.frontmostApplication
        let session = AutoFixTargetSession(
            tokenID: UUID(),
            startedAt: ProcessInfo.processInfo.systemUptime,
            targetPID: targetPID,
            bundleID: app?.bundleIdentifier,
            appName: app?.localizedName,
            focusedElementSignature: Self.focusedElementSignature(),
            firstKeyCode: keyCode,
            firstCharacter: typedString
        )
        self.session = session
        return session
    }

    func validateCurrentTarget(expectedBundleID: String?) -> AutoFixTargetValidation {
        guard let session else {
            return .unverifiable("missing_session")
        }
        return validateCurrentTarget(for: session, expectedBundleID: expectedBundleID)
    }

    func validateCurrentTarget(
        for session: AutoFixTargetSession,
        expectedBundleID: String? = nil
    ) -> AutoFixTargetValidation {
        let activeBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let expected = expectedBundleID?.nilIfEmpty ?? session.bundleID?.nilIfEmpty

        if let expected, let activeBundleID, activeBundleID != expected {
            return .changed("bundle_changed")
        }

        guard let originalSignature = session.focusedElementSignature else {
            return .unverifiable("missing_initial_focused_element")
        }

        guard let currentSignature = Self.focusedElementSignature() else {
            return .unverifiable("missing_current_focused_element")
        }

        guard originalSignature.stableIdentity == currentSignature.stableIdentity else {
            return .changed("focused_element_changed")
        }

        return .verified
    }

    func validateKeyEventStillTargetsSession(_ event: CGEvent) -> AutoFixTargetValidation {
        validateKeyEventStillTargetsSession(targetPID: Self.targetPID(from: event))
    }

    func validateKeyEventStillTargetsSession(targetPID: pid_t?) -> AutoFixTargetValidation {
        guard let session else {
            return .unverifiable("missing_session")
        }

        if let originalPID = session.targetPID,
           let currentPID = targetPID,
           originalPID != currentPID {
            return .changed("event_target_pid_changed")
        }

        // Cheap per-keystroke check only: the event still targets the same process (or the target
        // PID is unavailable). Deliberately do NOT run the full focused-element AX signature here —
        // that is 7-9 synchronous AX IPC round-trips, and on this path it would fire on every
        // non-boundary keystroke. The expensive comparison is deferred to the word boundary
        // (validateCurrentTarget in evaluateAndMaybeFix) and to mutationIsStillSafe, which run
        // immediately before any mutation, so an undetected mid-word focus change can at worst skip
        // a fix — never apply a wrong one.
        return .verified
    }

    func captureReplacementAnchor(
        for session: AutoFixTargetSession,
        expectedBundleID: String,
        source: String,
        boundary: String
    ) -> TextReplacementAnchor? {
        guard validateCurrentTarget(for: session, expectedBundleID: expectedBundleID) == .verified,
              let focused = Self.focusedElement(),
              let signature = Self.focusedElementSignature(for: focused),
              signature.pid == session.focusedElementSignature?.pid,
              let selection = Self.selectedTextRange(for: focused),
              selection.length == 0,
              let sourceRange = TextReplacementAnchor.sourceRange(
                caretAfterBoundary: selection.location,
                source: source,
                boundary: boundary
              ),
              Self.string(for: sourceRange, in: focused) == source,
              Self.string(
                for: AXTextRange(
                    location: sourceRange.location + sourceRange.length,
                    length: boundary.utf16.count
                ),
                in: focused
              ) == boundary
        else {
            return nil
        }

        return TextReplacementAnchor(
            targetPID: signature.pid,
            bundleID: expectedBundleID,
            focusedElementIdentity: signature.stableIdentity,
            sourceRange: sourceRange,
            boundaryUTF16Length: boundary.utf16.count,
            caretAfterBoundary: selection.location,
            expectedSource: source
        )
    }

    /// Replaces exactly the anchored source range. The boundary after the source is never selected,
    /// deleted, or recreated, so rich editors keep their paragraph/list semantics intact.
    func replaceAnchoredText(_ anchor: TextReplacementAnchor, with replacement: String) -> TextReplacementResult? {
        guard let focused = validatedElement(for: anchor),
              Self.isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: focused),
              Self.isAttributeSettable(kAXSelectedTextAttribute as CFString, on: focused),
              Self.setSelectedTextRange(anchor.sourceRange, on: focused)
        else {
            return nil
        }

        let axWriteSucceeded = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            replacement as CFTypeRef
        ) == .success

        let replacementLength = replacement.utf16.count
        let replacementRange = AXTextRange(
            location: anchor.sourceRange.location,
            length: replacementLength
        )
        var replacementCommitted = axWriteSucceeded && Self.waitForCommittedReplacement(
            expected: replacement,
            at: replacementRange,
            attempts: 3,
            retryDelay: { Thread.sleep(forTimeInterval: 0.005) },
            readString: { Self.string(for: $0, in: focused) }
        )

        // Chromium-backed editors such as Cursor can report AXSelectedText success while ignoring
        // the write. The exact source range is already validated, so replace that selection with
        // tagged Unicode events and confirm the resulting text before reporting success.
        if !replacementCommitted,
           Self.string(for: anchor.sourceRange, in: focused) == anchor.expectedSource,
           Self.setSelectedTextRange(anchor.sourceRange, on: focused),
           Self.postUnicodeReplacement(replacement) {
            replacementCommitted = Self.waitForCommittedReplacement(
                expected: replacement,
                at: replacementRange,
                attempts: 10,
                retryDelay: { Thread.sleep(forTimeInterval: 0.005) },
                readString: { Self.string(for: $0, in: focused) }
            )
        }

        guard replacementCommitted else {
            _ = Self.setSelectedTextRange(
                AXTextRange(location: anchor.caretAfterBoundary, length: 0),
                on: focused
            )
            return nil
        }

        let resultingCaret = anchor.sourceRange.location + replacementLength + anchor.boundaryUTF16Length
        _ = Self.setSelectedTextRange(
            AXTextRange(location: resultingCaret, length: 0),
            on: focused
        )
        // Read back the actual selection instead of assuming how an editor behaves after setting
        // AXSelectedText. A non-collapsed/unknown selection cannot produce a safe recovery anchor.
        guard let resultingSelection = Self.selectedTextRange(for: focused),
              resultingSelection == AXTextRange(location: resultingCaret, length: 0)
        else {
            return TextReplacementResult(recoveryAnchor: nil)
        }

        return TextReplacementResult(
            recoveryAnchor: TextReplacementAnchor(
                targetPID: anchor.targetPID,
                bundleID: anchor.bundleID,
                focusedElementIdentity: anchor.focusedElementIdentity,
                sourceRange: AXTextRange(location: anchor.sourceRange.location, length: replacementLength),
                boundaryUTF16Length: anchor.boundaryUTF16Length,
                caretAfterBoundary: resultingSelection.location,
                expectedSource: replacement
            )
        )
    }

    nonisolated static func replacementWasCommitted(
        expected: String,
        at range: AXTextRange,
        readString: (AXTextRange) -> String?
    ) -> Bool {
        readString(range) == expected
    }

    nonisolated static func waitForCommittedReplacement(
        expected: String,
        at range: AXTextRange,
        attempts: Int,
        retryDelay: () -> Void,
        readString: (AXTextRange) -> String?
    ) -> Bool {
        guard attempts > 0 else { return false }
        for attempt in 0..<attempts {
            if replacementWasCommitted(expected: expected, at: range, readString: readString) {
                return true
            }
            if attempt < attempts - 1 {
                retryDelay()
            }
        }
        return false
    }

    private static func postUnicodeReplacement(_ replacement: String) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0,
            keyDown: false
        ) else {
            return false
        }

        let utf16 = Array(replacement.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
            keyUp.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        PapugaSyntheticEvent.tag(keyDown)
        PapugaSyntheticEvent.tag(keyUp)
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    func isReplacementAnchorValid(_ anchor: TextReplacementAnchor) -> Bool {
        validatedElement(for: anchor) != nil
    }

    private func validatedElement(for anchor: TextReplacementAnchor) -> AXUIElement? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == anchor.bundleID,
              let focused = Self.focusedElement(),
              let signature = Self.focusedElementSignature(for: focused),
              signature.pid == anchor.targetPID,
              signature.stableIdentity == anchor.focusedElementIdentity,
              Self.selectedTextRange(for: focused) == AXTextRange(
                location: anchor.caretAfterBoundary,
                length: 0
              ),
              Self.string(for: anchor.sourceRange, in: focused) == anchor.expectedSource
        else {
            return nil
        }
        return focused
    }

    nonisolated static func targetPID(from event: CGEvent) -> pid_t? {
        let raw = event.getIntegerValueField(.eventTargetUnixProcessID)
        guard raw > 0 else { return nil }
        return pid_t(raw)
    }

    static func focusedElementSignature() -> FocusedElementSignature? {
        guard let focused = focusedElement() else { return nil }
        return focusedElementSignature(for: focused)
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }

    private static func focusedElementSignature(for focused: AXUIElement) -> FocusedElementSignature? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success else {
            return nil
        }

        return FocusedElementSignature(
            pid: pid,
            role: stringAttribute(kAXRoleAttribute as CFString, from: focused),
            subrole: stringAttribute(kAXSubroleAttribute as CFString, from: focused),
            windowTitleHash: windowTitleHash(for: focused),
            elementIdentifier: stringAttribute("AXIdentifier" as CFString, from: focused),
            frameHash: frameHash(for: focused),
            selectedRangeLocation: selectedRangeLocation(for: focused)
        )
    }

    private static func selectedTextRange(for element: AXUIElement) -> AXTextRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = unsafeBitCast(rangeRef, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return AXTextRange(location: range.location, length: range.length)
    }

    private static func string(for range: AXTextRange, in element: AXUIElement) -> String? {
        var cfRange = range.cfRange
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        ) == .success else {
            return nil
        }
        return result as? String
    }

    private static func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
    }

    private static func setSelectedTextRange(_ range: AXTextRange, on element: AXUIElement) -> Bool {
        var cfRange = range.cfRange
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ) == .success
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func windowTitleHash(for element: AXUIElement) -> Int? {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowRef
        ) == .success,
              let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else {
            return stringAttribute(kAXTitleAttribute as CFString, from: element)?.stableHashValue
        }

        let window = unsafeBitCast(windowRef, to: AXUIElement.self)
        return stringAttribute(kAXTitleAttribute as CFString, from: window)?.stableHashValue
    }

    private static func frameHash(for element: AXUIElement) -> Int? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else {
            return nil
        }

        let positionValue = unsafeBitCast(positionRef, to: AXValue.self)
        let sizeValue = unsafeBitCast(sizeRef, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return nil
        }

        let rounded = [
            Int(position.x.rounded()),
            Int(position.y.rounded()),
            Int(size.width.rounded()),
            Int(size.height.rounded())
        ]
        return rounded.stableHashValue
    }

    private static func selectedRangeLocation(for element: AXUIElement) -> Int? {
        selectedTextRange(for: element)?.location
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var stableHashValue: Int {
        unicodeScalars.reduce(5381) { hash, scalar in
            ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
    }
}

private extension Array where Element == Int {
    var stableHashValue: Int {
        reduce(5381) { hash, value in
            ((hash << 5) &+ hash) &+ value
        }
    }
}
