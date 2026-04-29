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
        }
    }

    var timeInterval: TimeInterval {
        switch self {
        case .oneHour:
            return 60 * 60
        case .oneDay:
            return 24 * 60 * 60
        case .twoDays:
            return 2 * 24 * 60 * 60
        case .oneWeek:
            return 7 * 24 * 60 * 60
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
    static let showMenuBarIcon = Key<Bool>("showMenuBarIcon", default: true)
    static let switchResultMode = Key<String>("switchResultMode", default: SwitchResultMode.copyAndPaste.rawValue)
    static let textReplacementCount = Key<Int>("textReplacementCount", default: 0)
    static let totalReplacedWords = Key<Int>("totalReplacedWords", default: 0)
    static let analyticsDayStamp = Key<String>("analyticsDayStamp", default: "")
    static let savedSecondsToday = Key<Int>("savedSecondsToday", default: 0)
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

    static let autoFixEnabled = Key<Bool>("autoFixEnabled", default: false)
    static let autoFixAlgorithm = Key<String>("autoFixAlgorithm", default: LanguageScorerAlgorithm.appleNL.rawValue)
    static let autoFixThreshold = Key<Double>("autoFixThreshold", default: 0.3)
    static let autoFixUndoWindow = Key<Double>("autoFixUndoWindow", default: 1.5)
    static let autoFixBlocklist = Key<[String]>("autoFixBlocklist", default: [])
    static let autoFixAllowlist = Key<[String]>("autoFixAllowlist", default: [])
    static let autoFixToastEnabled = Key<Bool>("autoFixToastEnabled", default: true)
}

extension KeyboardShortcuts.Name {
    static let switchForward = Self("switchForward")
}
