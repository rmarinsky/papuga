import Defaults
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

    // MARK: - Time-saved value model
    //
    // A manual layout fix isn't linear in words: there's a fixed cost to notice
    // the mistake and select the text, plus a per-word cost to retype it in the
    // correct layout. So savings = overhead + words × perWord, where perWord is
    // personalized from the user's measured typing speed (`measuredTypingWPM`)
    // when they've taken the typing test, and `defaultTypingWordsPerMinute`
    // otherwise. This replaces the old flat 1.6 s/word, which under-credited the
    // (majority) short fixes by ignoring the fixed reaction/selection overhead.

    /// Fixed cost of a manual fix independent of length: notice the mistake +
    /// select the text + trigger the correction.
    static let manualFixOverheadSeconds: Double = 2.0
    /// Fallback typing speed when the user hasn't run the typing-speed test.
    static let defaultTypingWordsPerMinute: Double = 40
    static let typingWordsPerMinuteRange: ClosedRange<Double> = 10...160

    static func sanitizedTypingWordsPerMinute(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTypingWordsPerMinute }
        return min(max(value, typingWordsPerMinuteRange.lowerBound), typingWordsPerMinuteRange.upperBound).rounded()
    }

    /// The typing speed feeding the estimate: the user's measured value if the
    /// test has been taken, else the default.
    static func effectiveTypingWordsPerMinute() -> Double {
        let measured = Defaults[.measuredTypingWPM]
        return measured > 0 ? sanitizedTypingWordsPerMinute(measured) : defaultTypingWordsPerMinute
    }

    private static func secondsPerWord() -> Double {
        60.0 / max(effectiveTypingWordsPerMinute(), 1)
    }

    /// Estimated seconds saved by one replacement of `words` words.
    static func secondsSaved(words: Int) -> Int {
        let count = Double(max(1, words))
        return Int((manualFixOverheadSeconds + count * secondsPerWord()).rounded())
    }

    static func currentDayStamp() -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Aggregate estimate across many replacements: per-replacement overhead
    /// plus per-word retype cost. Matches `secondsSaved(words:)` summed over
    /// `replacementCount` replacements totalling `totalWords` words.
    static func estimatedSecondsSaved(replacementCount: Int, totalWords: Int) -> Int {
        guard replacementCount > 0 else { return 0 }
        let estimated = Double(replacementCount) * manualFixOverheadSeconds
            + Double(totalWords) * secondsPerWord()
        return Int(estimated.rounded())
    }
}

extension Notification.Name {
    static let textReplacementDidComplete = Notification.Name("ua.com.rmarinsky.papuga.textReplacementDidComplete")
}
