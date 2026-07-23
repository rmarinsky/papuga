import AppKit
import Defaults
import Foundation

struct IgnoreWordResult: Equatable {
    let word: String
    let addedToAllowlist: Bool
    let removedReplacementRuleCount: Int
    let taughtAppleSpelling: Bool
}

enum IgnoreWordService {
    @MainActor
    @discardableResult
    static func add(
        _ rawWord: String,
        teachAppleSpelling: Bool = true,
        removeReplacementRules: Bool = true
    ) -> IgnoreWordResult? {
        let word = normalizedWord(rawWord)
        guard !word.isEmpty else { return nil }

        var allowlist = Defaults[.autoFixAllowlist]
        let addedToAllowlist: Bool
        if allowlist.contains(where: {
            normalizedWord($0).caseInsensitiveCompare(word) == .orderedSame
        }) {
            addedToAllowlist = false
        } else {
            allowlist.append(word)
            Defaults[.autoFixAllowlist] = allowlist
            addedToAllowlist = true
        }

        let removedReplacementRuleCount: Int
        if removeReplacementRules {
            var rules = Defaults[.customAutoReplaceRules]
            let originalCount = rules.count
            rules.removeAll {
                normalizedWord($0.source).caseInsensitiveCompare(word) == .orderedSame
            }
            removedReplacementRuleCount = originalCount - rules.count
            if removedReplacementRuleCount > 0 {
                Defaults[.customAutoReplaceRules] = rules
            }
        } else {
            removedReplacementRuleCount = 0
        }

        let taughtAppleSpelling = teachAppleSpelling && teachAppleSpellingDictionaryIfAppropriate(word)

        if addedToAllowlist || removedReplacementRuleCount > 0 || taughtAppleSpelling {
            AppLogger.action(
                AppLogger.autoFix,
                "Added ignore word '\(word)' allowlist=\(addedToAllowlist) removed_rules=\(removedReplacementRuleCount) apple_spelling=\(taughtAppleSpelling)"
            )
        }

        return IgnoreWordResult(
            word: word,
            addedToAllowlist: addedToAllowlist,
            removedReplacementRuleCount: removedReplacementRuleCount,
            taughtAppleSpelling: taughtAppleSpelling
        )
    }

    static func normalizedWord(_ rawWord: String) -> String {
        BufferedToken.normalizedCore(from: rawWord)
    }

    static func shouldTeachAppleSpelling(_ rawWord: String) -> Bool {
        let word = normalizedWord(rawWord)
        guard word.count >= 2 else { return false }
        guard !word.contains(where: \.isWhitespace) else { return false }
        guard !ProtectedLexiconMatcher.isEmailLike(word),
              !ProtectedLexiconMatcher.isURLLike(word),
              !ProtectedLexiconMatcher.isDomainLike(word) else {
            return false
        }
        guard !word.contains("/"), !word.contains("\\") else { return false }

        let scalars = word.unicodeScalars
        guard scalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return false
        }
        return scalars.allSatisfy {
            CharacterSet.letters.contains($0)
                || CharacterSet.decimalDigits.contains($0)
                || allowedWordScalars.contains($0)
        }
    }

    private static func teachAppleSpellingDictionaryIfAppropriate(_ word: String) -> Bool {
        guard shouldTeachAppleSpelling(word) else { return false }

        let checker = NSSpellChecker.shared
        var learnedAny = false

        for variant in appleSpellingVariants(for: word) where shouldTeachAppleSpelling(variant) {
            if !checker.hasLearnedWord(variant) {
                checker.learnWord(variant)
                learnedAny = true
            }
        }

        return learnedAny
    }

    private static func appleSpellingVariants(for word: String) -> [String] {
        var variants = [word]
        if let canonical = ProtectedLexiconStore.shared.match(word)?.entry.canonical,
           canonical != word {
            variants.append(canonical)
        }
        return Array(Set(variants))
    }

    private static let allowedWordScalars = CharacterSet(charactersIn: "-_+&")
}
