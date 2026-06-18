import Defaults
import Foundation

enum AutoFixAppPolicy: String, Codable, CaseIterable, Defaults.Serializable {
    case autoMutate
    case suggestOnly
    case manualOnly
    case disabled

    var title: String {
        switch self {
        case .autoMutate:
            return "Автозамінювати"
        case .suggestOnly:
            return "Лише пропонувати"
        case .manualOnly:
            return "Лише вручну"
        case .disabled:
            return "Вимкнено"
        }
    }

    var allowsAutomaticMutation: Bool {
        self == .autoMutate
    }

    var allowsProposal: Bool {
        self == .autoMutate || self == .suggestOnly
    }
}

enum AutoFixAppPolicyResolver {
    static func policy(for bundleID: String?) -> AutoFixAppPolicy {
        guard let bundleID, !bundleID.isEmpty else { return .suggestOnly }

        if let override = Defaults[.autoFixAppPolicyOverrides][bundleID],
           let policy = AutoFixAppPolicy(rawValue: override) {
            return policy
        }

        return defaultPolicy(for: bundleID)
    }

    static func defaultPolicy(for bundleID: String) -> AutoFixAppPolicy {
        let lower = bundleID.lowercased()

        if disabledBundleIDs.contains(lower) || disabledPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return .disabled
        }

        if suggestOnlyBundleIDs.contains(lower) || suggestOnlyPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return .suggestOnly
        }

        return .autoMutate
    }

    private static let suggestOnlyBundleIDs: Set<String> = [
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92",
        "com.cursor.cursor",
        "com.apple.dt.xcode"
    ]

    private static let suggestOnlyPrefixes: [String] = [
        "com.jetbrains."
    ]

    private static let disabledBundleIDs: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "dev.warp.warp",
        "co.zeit.hyper"
    ]

    private static let disabledPrefixes: [String] = [
        "com.mitchellh.ghostty"
    ]
}

enum AutoFixMutationStrategy: String, Codable {
    case directUnicodeEvents
    case clipboardPaste
    case proposalOnly
    case disabled
}
