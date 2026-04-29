import Foundation
import Defaults

enum AnalyticsCounters {
    /// Bumps the user-facing counters shown in the Settings → Аналітика tab and the
    /// menu bar summary. Called from both manual-switch (`TextSwitchEngine`) and
    /// auto-fix-as-you-type (`AutoFixController`) so the dashboard reflects all
    /// replacements regardless of which path produced them.
    static func recordReplacement(text: String) {
        let wordsInText = max(1, text.split(separator: " ").count)
        let savedSeconds = Int((Double(wordsInText) * Constants.estimatedManualReplacementSecondsPerWord).rounded())

        let currentDay = Constants.currentDayStamp()
        if Defaults[.analyticsDayStamp] != currentDay {
            Defaults[.analyticsDayStamp] = currentDay
            Defaults[.savedSecondsToday] = 0
        }

        Defaults[.textReplacementCount] += 1
        Defaults[.totalReplacedWords] += wordsInText
        Defaults[.savedSecondsToday] += savedSeconds
    }

    /// Reverses a previous `recordReplacement` call when the user undoes an auto-fix
    /// within the grace window.
    static func reverseReplacement(text: String) {
        let wordsInText = max(1, text.split(separator: " ").count)
        let savedSeconds = Int((Double(wordsInText) * Constants.estimatedManualReplacementSecondsPerWord).rounded())
        Defaults[.textReplacementCount] = max(0, Defaults[.textReplacementCount] - 1)
        Defaults[.totalReplacedWords] = max(0, Defaults[.totalReplacedWords] - wordsInText)
        Defaults[.savedSecondsToday] = max(0, Defaults[.savedSecondsToday] - savedSeconds)
    }
}
