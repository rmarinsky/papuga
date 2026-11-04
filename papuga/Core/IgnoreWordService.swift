import AppKit
import Defaults
import Foundation
import OSLog

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
            AppLogger.autoFix.notice(
                "Ignore word added: allowlist=\(addedToAllowlist, privacy: .public) removed_rules=\(removedReplacementRuleCount, privacy: .public) apple_spelling=\(taughtAppleSpelling, privacy: .public)"
            )
        }

        return IgnoreWordResult(
            word: word,
            addedToAllowlist: addedToAllowlist,
            removedReplacementRuleCount: removedReplacementRuleCount,
            taughtAppleSpelling: taughtAppleSpelling
        )
    }

    /// Undoes `add`. Dropping the word from the allowlist alone is not enough:
    /// `add` also taught it to the *system* spelling dictionary, and a learned
    /// word makes `isMisspelled` false forever — which trips AutoFix's
    /// "the original is a real word, the user meant it" guard. Removing the
    /// allowlist entry without this left the word just as unfixable as before,
    /// with nothing in Papuga's own settings left to explain why.
    @MainActor
    @discardableResult
    static func remove(_ rawWord: String) -> Bool {
        let word = normalizedWord(rawWord)
        guard !word.isEmpty else { return false }

        var allowlist = Defaults[.autoFixAllowlist]
        let before = allowlist.count
        allowlist.removeAll { normalizedWord($0).caseInsensitiveCompare(word) == .orderedSame }
        let removedFromAllowlist = allowlist.count != before
        if removedFromAllowlist {
            Defaults[.autoFixAllowlist] = allowlist
        }

        let checker = NSSpellChecker.shared
        var taught = Defaults[.papugaTaughtSpellings]
        var unlearnedAny = false
        for variant in appleSpellingVariants(for: word) where taught.contains(variant) {
            if checker.hasLearnedWord(variant) {
                checker.unlearnWord(variant)
                unlearnedAny = true
            }
            taught.removeAll { $0 == variant }
        }
        Defaults[.papugaTaughtSpellings] = taught

        if removedFromAllowlist || unlearnedAny {
            AppLogger.autoFix.notice(
                "Ignore word removed: allowlist=\(removedFromAllowlist, privacy: .public) apple_spelling=\(unlearnedAny, privacy: .public)"
            )
        }
        return removedFromAllowlist || unlearnedAny
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
                Defaults[.papugaTaughtSpellings].append(variant)
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
