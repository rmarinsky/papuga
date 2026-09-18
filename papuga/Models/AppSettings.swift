import Foundation
import Defaults
import KeyboardShortcuts

enum DoublePressShortcutPreset: String, CaseIterable {
    case optionShift
    case commandShift
    case controlShift

    var title: String {
        switch self {
        case .optionShift:
            return "Opt+Shift"
        case .commandShift:
            return "Cmd+Shift"
        case .controlShift:
            return "Ctrl+Shift"
        }
    }
}

enum SwitchResultMode: String, CaseIterable {
    case copyOnly
    case copyAndPaste

    var title: String {
        switch self {
        case .copyOnly:
            return "Копіювати"
        case .copyAndPaste:
            return "Копіювати і вставити"
        }
    }

    var description: String {
        switch self {
        case .copyOnly:
            return "Після перемикання текст лише потрапляє у буфер обміну."
        case .copyAndPaste:
            return "Після перемикання текст потрапляє у буфер і одразу вставляється."
        }
    }
}

enum ClipboardHistoryRetentionPreset: String, CaseIterable {
    case oneHour
    case oneDay
    case twoDays
    case oneWeek
    case oneMonth
    case threeMonths
    case forever

    var title: String {
        switch self {
        case .oneHour:
            return "1 година"
        case .oneDay:
            return "1 день"
        case .twoDays:
            return "2 дні"
        case .oneWeek:
            return "1 тиждень"
        case .oneMonth:
            return "1 місяць"
        case .threeMonths:
            return "3 місяці"
        case .forever:
            return "Завжди"
        }
    }

    var timeInterval: TimeInterval? {
        switch self {
        case .oneHour:
            return 60 * 60
        case .oneDay:
            return 24 * 60 * 60
        case .twoDays:
            return 2 * 24 * 60 * 60
        case .oneWeek:
            return 7 * 24 * 60 * 60
        case .oneMonth:
            return 30 * 24 * 60 * 60
        case .threeMonths:
            return 90 * 24 * 60 * 60
        case .forever:
            return nil
        }
    }
}

enum ClipboardHistoryMenuItemLimitPreset: Int, CaseIterable {
    case all = 0
    case ten = 10
    case twenty = 20
    case thirty = 30
    case fifty = 50
    case hundred = 100

    var title: String {
        rawValue == 0 ? "Всі" : "\(rawValue)"
    }
}

extension Defaults.Keys {
    static let isServiceRunning = Key<Bool>("isServiceRunning", default: true)
    static let useDoublePress = Key<Bool>("useDoublePress", default: true)
    static let doublePressInterval = Key<Double>("doublePressInterval", default: 0.4)
    static let doublePressShortcut = Key<String>("doublePressShortcut", default: DoublePressShortcutPreset.optionShift.rawValue)
    static let layoutOrder = Key<[String]>("layoutOrder", default: [])
    static let disabledLayouts = Key<[String]>("disabledLayouts", default: [])
    static let showMenuBarIcon = Key<Bool>("showMenuBarIcon", default: true)
    static let switchResultMode = Key<String>("switchResultMode", default: SwitchResultMode.copyAndPaste.rawValue)
    static let textReplacementCount = Key<Int>("textReplacementCount", default: 0)
    static let totalReplacedWords = Key<Int>("totalReplacedWords", default: 0)
    static let analyticsDayStamp = Key<String>("analyticsDayStamp", default: "")
    static let savedSecondsToday = Key<Int>("savedSecondsToday", default: 0)
    static let dailyStatsHistory = Key<[PapugaDailyStats]>("dailyStatsHistory", default: [])
    static let dailyStatsHistoryMigrated = Key<Bool>("dailyStatsHistoryMigrated", default: false)
    /// User's measured typing speed (net WPM) from the typing-speed test. `0`
    /// means "not measured yet" — the time-saved estimate falls back to
    /// `Constants.defaultTypingWordsPerMinute`.
    static let measuredTypingWPM = Key<Double>("measuredTypingWPM", default: 0)
    static let clipboardHistoryRetention = Key<String>(
        "clipboardHistoryRetention",
        default: ClipboardHistoryRetentionPreset.oneDay.rawValue
    )
    static let clipboardMenuTimeRange = Key<String>(
        "clipboardMenuTimeRange",
        default: ClipboardHistoryRetentionPreset.oneDay.rawValue
    )
    static let clipboardMenuItemLimit = Key<Int>(
        "clipboardMenuItemLimit",
        default: ClipboardHistoryMenuItemLimitPreset.all.rawValue
    )

    static let autoFixEnabled = Key<Bool>("autoFixEnabled", default: true)
    static let autoFixAlgorithm = Key<String>("autoFixAlgorithm", default: LanguageScorerAlgorithm.appleNL.rawValue)
    /// Must stay in sync with `AutoFixSensitivityPreset.balanced`. The Settings
    /// picker labels the current state by finding the nearest preset, so a
    /// default that matches none of them made a fresh install display
    /// "Збалансовано" while actually running a lower (more eager) threshold
    /// than every preset on offer, `Обмежено` included.
    static let autoFixThreshold = Key<Double>("autoFixThreshold", default: 0.35)
    /// Minimum gap between the top two candidate layouts' scores before we trust the winner. When
    /// two layouts (e.g. Ukrainian vs Russian) score within this margin the direction is ambiguous,
    /// so we surface a proposal instead of silently auto-applying a guess. 0 = always pick the top.
    static let autoFixCandidateSeparation = Key<Double>("autoFixCandidateSeparation", default: 0.15)
    static let autoFixMinWordLength = Key<Int>("autoFixMinWordLength", default: 2)
    static let autoFixTwoCharacterMinimumMigrated = Key<Bool>(
        "autoFixTwoCharacterMinimumMigrated",
        default: false
    )
    // `autoFixUndoWindow` was removed: nothing read it. Backspace deliberately
    // does not undo a fix (AutoFixController.handleBackspace just clears
    // `lastFix`), so the Settings slider it backed promised a behaviour that
    // does not exist. Undo is the toast / the global shortcut, both of which
    // are bounded by anchor re-validation rather than by a timer.
    static let autoFixBlocklist = Key<[String]>("autoFixBlocklist", default: [])
    static let autoFixAllowlist = Key<[String]>("autoFixAllowlist", default: [])
    static let autoFixToastEnabled = Key<Bool>("autoFixToastEnabled", default: true)
    static let autoFixConservativeEditingGuard = Key<Bool>("autoFixConservativeEditingGuard", default: true)
    static let autoFixSpellingTypoGuardEnabled = Key<Bool>("autoFixSpellingTypoGuardEnabled", default: true)
    static let autoFixSpellingTypoGuardMinWordLength = Key<Int>("autoFixSpellingTypoGuardMinWordLength", default: 4)
    static let autoFixSpellingTypoGuardMaxEditDistance = Key<Int>("autoFixSpellingTypoGuardMaxEditDistance", default: 1)
    static let autoFixProposalEnabled = Key<Bool>("autoFixProposalEnabled", default: true)
    /// Must stay in sync with `AutoFixSensitivityPreset.balanced` — see
    /// `autoFixThreshold`. The old 0.12 also contradicted
    /// docs/autofix-analysis-and-guardrails.md, which documents 0.22.
    static let autoFixProposalWindow = Key<Double>("autoFixProposalWindow", default: 0.22)
    /// Experimental, default off. When a captured wrong-layout sentence
    /// contains a contradicting token (a word that is already correct), the
    /// whole incident is discarded — up to 29 correctly-detected words thrown
    /// away because of one real word in the middle. With this on, a small
    /// share of contradictions degrades the verdict to a *proposal* instead;
    /// auto-replacement still requires a clean incident.
    ///
    /// Off by default because the tolerance ratio has not been tuned against
    /// real decision history yet — see the replay harness note in the plan.
    static let autoFixTolerateIncidentContradictions = Key<Bool>(
        "autoFixTolerateIncidentContradictions",
        default: false
    )
    static let autoFixAppPolicyOverrides = Key<[String: String]>("autoFixAppPolicyOverrides", default: [:])
    static let autoFixLayoutSwitchPolicy = Key<String>(
        "autoFixLayoutSwitchPolicy",
        default: AutoFixLayoutSwitchPolicy.alwaysSwitchToReplacementLayout.rawValue
    )

    // Keep the persisted keys for migration compatibility. This setting now controls the
    // user-facing decision journal as well as the replacement-derived internal analytics.
    static let replacementHistoryEnabled = Key<Bool>("replacementHistoryEnabled", default: true)
    static let replacementHistoryRetention = Key<String>(
        "replacementHistoryRetention",
        default: ReplacementHistoryRetention.oneMonth.rawValue
    )
    static let openHistoryOnAppLaunch = Key<Bool>("openHistoryOnAppLaunch", default: true)
    static let customAutoReplaceRules = Key<[CustomAutoReplaceRule]>("customAutoReplaceRules", default: [])
    static let quarantinedAutoReplaceRules = Key<[CustomAutoReplaceRule]>("quarantinedAutoReplaceRules", default: [])
    static let autoFixPunctuationKnowledgeMigrationVersion = Key<Int>(
        "autoFixPunctuationKnowledgeMigrationVersion",
        default: 0
    )
    static let dismissedRecommendations = Key<[String]>("dismissedRecommendations", default: [])

}

enum AutoFixSettingsMigration {
    static func migrateTwoCharacterMinimumIfNeeded() {
        guard !Defaults[.autoFixTwoCharacterMinimumMigrated] else { return }
        if Defaults[.autoFixMinWordLength] == 3 {
            Defaults[.autoFixMinWordLength] = 2
        }
        Defaults[.autoFixTwoCharacterMinimumMigrated] = true
    }
}

extension KeyboardShortcuts.Name {
    static let switchForward = Self("switchForward")
    static let toggleAutoFix = Self("toggleAutoFix")
    static let openPapuga = Self("openPapuga")
    static let undoLastFix = Self("undoLastFix")
}
