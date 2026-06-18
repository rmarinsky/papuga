import Foundation

enum Constants {
    static let appName = "Papuga"
    static let bundleIdentifier = "ua.com.rmarinsky.papuga"
    static let doublePressDefaultInterval: TimeInterval = 0.4
    static let clipboardWaitDuration: TimeInterval = 0.1
    // Delay before restoring the user's original clipboard, leaving the target app time to consume
    // the simulated Cmd+V. Trimmed from 0.5s — the old value dominated perceived switch latency.
    static let clipboardRestoreDelay: TimeInterval = 0.2
    // Polling budget for the post-copy clipboard read. Raised from 3 so dropping the fixed leading
    // wait keeps the same worst-case budget (4 × 0.05s = 0.2s) while reading fast apps immediately.
    static let clipboardRetryCount = 5
    static let clipboardRetryInterval: TimeInterval = 0.05
    // Small settle gap before switching the system layout (was the full 0.1s copy wait).
    static let switchLayoutSettleDelay: TimeInterval = 0.03
    static let permissionPollInterval: TimeInterval = 1.0
    static let maxKeyCode: UInt16 = 127
    static let estimatedManualReplacementSecondsPerWord: Double = 1.6

    static func currentDayStamp() -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func estimatedSecondsSaved(replacementCount: Int, totalWords: Int) -> Int {
        guard replacementCount > 0 else { return 0 }
        let averageWords = Double(totalWords) / Double(replacementCount)
        let estimated = Double(replacementCount) * averageWords * estimatedManualReplacementSecondsPerWord
        return Int(estimated.rounded())
    }
}

extension Notification.Name {
    static let textReplacementDidComplete = Notification.Name("ua.com.rmarinsky.papuga.textReplacementDidComplete")
}
