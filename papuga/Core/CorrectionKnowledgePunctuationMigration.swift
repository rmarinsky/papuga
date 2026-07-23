import Defaults
import Foundation

struct CorrectionKnowledgePunctuationMigrationResult: Equatable {
    let allowlist: [String]
    let activeRules: [CustomAutoReplaceRule]
    let quarantinedRules: [CustomAutoReplaceRule]
}

enum CorrectionKnowledgePunctuationMigration {
    static let currentVersion = 1

    static func prepare(
        allowlist: [String],
        rules: [CustomAutoReplaceRule],
        alreadyQuarantined: [CustomAutoReplaceRule]
    ) -> CorrectionKnowledgePunctuationMigrationResult {
        var normalizedAllowlist: [String] = []
        var seenWords = Set<String>()
        for rawWord in allowlist {
            let word = IgnoreWordService.normalizedWord(rawWord)
            let key = word.lowercased()
            guard !word.isEmpty, seenWords.insert(key).inserted else { continue }
            normalizedAllowlist.append(word)
        }

        var activeRules: [CustomAutoReplaceRule] = []
        var quarantinedRules = alreadyQuarantined
        var quarantinedIDs = Set(alreadyQuarantined.map(\.id))
        for rule in rules {
            let source = BufferedToken(rawText: rule.source, keyCodes: [])
            let target = BufferedToken(rawText: rule.target, keyCodes: [])
            let ambiguousLayoutSource = (!source.leadingEdge.isEmpty || !source.trailingEdge.isEmpty)
                && AutoFixDecision.isCrossScriptConversion(
                    original: source.core,
                    candidate: target.core
                )
            if source.core.isEmpty
                || !target.leadingEdge.isEmpty
                || !target.trailingEdge.isEmpty
                || ambiguousLayoutSource {
                if quarantinedIDs.insert(rule.id).inserted {
                    quarantinedRules.append(rule)
                }
            } else {
                var normalizedRule = rule
                normalizedRule.source = source.core
                normalizedRule.target = target.core
                activeRules.append(normalizedRule)
            }
        }

        return CorrectionKnowledgePunctuationMigrationResult(
            allowlist: normalizedAllowlist,
            activeRules: activeRules,
            quarantinedRules: quarantinedRules
        )
    }

    @MainActor
    static func runIfNeeded() {
        guard Defaults[.autoFixPunctuationKnowledgeMigrationVersion] < currentVersion else { return }
        let result = prepare(
            allowlist: Defaults[.autoFixAllowlist],
            rules: Defaults[.customAutoReplaceRules],
            alreadyQuarantined: Defaults[.quarantinedAutoReplaceRules]
        )
        Defaults[.autoFixAllowlist] = result.allowlist
        Defaults[.customAutoReplaceRules] = result.activeRules
        Defaults[.quarantinedAutoReplaceRules] = result.quarantinedRules
        Defaults[.autoFixPunctuationKnowledgeMigrationVersion] = currentVersion

        if !result.quarantinedRules.isEmpty {
            AppLogger.warn(
                AppLogger.autoFix,
                "Quarantined \(result.quarantinedRules.count) auto-replace rule(s) with edge punctuation"
            )
        }
    }
}
