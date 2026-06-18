import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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

    nonisolated static func targetPID(from event: CGEvent) -> pid_t? {
        let raw = event.getIntegerValueField(.eventTargetUnixProcessID)
        guard raw > 0 else { return nil }
        return pid_t(raw)
    }

    static func focusedElementSignature() -> FocusedElementSignature? {
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

        let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)
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
        return range.location
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
