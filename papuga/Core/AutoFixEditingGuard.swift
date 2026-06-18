import Carbon.HIToolbox
import Foundation

struct AutoFixEditingGuard {
    private(set) var shouldSuppressCurrentToken = false

    mutating func reset() {
        shouldSuppressCurrentToken = false
    }

    mutating func noteBackspace(bufferWasEmpty: Bool, enabled: Bool) {
        guard enabled, bufferWasEmpty else { return }
        shouldSuppressCurrentToken = true
    }

    mutating func noteResetKey(_ keyCode: UInt16, enabled: Bool) {
        guard enabled, Self.isNavigationKey(keyCode) else { return }
        shouldSuppressCurrentToken = true
    }

    mutating func consumeSuppression(enabled: Bool) -> Bool {
        let result = enabled && shouldSuppressCurrentToken
        shouldSuppressCurrentToken = false
        return result
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
