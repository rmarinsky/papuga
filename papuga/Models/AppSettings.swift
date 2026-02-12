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
}

extension KeyboardShortcuts.Name {
    static let switchForward = Self("switchForward")
}
