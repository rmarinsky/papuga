import Defaults
import Foundation

/// Words Papuga should treat as already handled / known-good, so they never
/// resurface as suggestions even if old open observations linger in the store:
/// the user's allowlist ("не чіпати"), and both sides of their custom rules
/// (a rule source is already handled; a rule target is a correct word).
enum LearnedVocabulary {
    static func handledSources(
        allowlist: [String] = Defaults[.autoFixAllowlist],
        rules: [CustomAutoReplaceRule] = Defaults[.customAutoReplaceRules]
    ) -> Set<String> {
        var set = Set<String>()
        for word in allowlist { set.insert(MistakeObservation.normalizedToken(word)) }
        for rule in rules {
            set.insert(MistakeObservation.normalizedToken(rule.source))
            set.insert(MistakeObservation.normalizedToken(rule.target))
        }
        set.remove("")
        return set
    }
}
