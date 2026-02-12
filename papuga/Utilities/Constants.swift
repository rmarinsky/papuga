import Foundation

enum Constants {
    static let appName = "Papuga"
    static let bundleIdentifier = "ua.com.rmarinsky.papuga"
    static let doublePressDefaultInterval: TimeInterval = 0.4
    static let clipboardWaitDuration: TimeInterval = 0.1
    static let clipboardRestoreDelay: TimeInterval = 0.5
    static let clipboardRetryCount = 3
    static let clipboardRetryInterval: TimeInterval = 0.05
    static let permissionPollInterval: TimeInterval = 1.0
    static let maxKeyCode: UInt16 = 127
    static let estimatedManualReplacementSecondsPerWord: Double = 1.6
}

extension Notification.Name {
    static let textReplacementDidComplete = Notification.Name("ua.com.rmarinsky.papuga.textReplacementDidComplete")
}
