import Foundation

/// Hybrid spell-check client: the authoritative system checker, plus SymSpell
/// candidate generation, plus a **learned-known overlay**.
///
/// Design invariant: `isMisspelled` can only ever become *more lenient* than the
/// system checker — it never flags a word the system accepts, and additionally
/// un-flags words the user clearly treats as correct (allowlist + own
/// vocabulary). So enabling it can only *remove* false positives, never add new
/// ones. `guesses` merges fast SymSpell corrections (incl. the user's own words)
/// ahead of the system's.
final class HybridSpellChecker: SpellCheckingClient {
    private let system: SpellCheckingClient
    private let indexes: [String: SymSpell]
    private let learnedKnown: [String: Set<String>]
    private let maxEditDistance: Int

    init(
        system: SpellCheckingClient = SystemSpellCheckingClient(),
        indexes: [String: SymSpell] = [:],
        learnedKnown: [String: Set<String>] = [:],
        maxEditDistance: Int = 2
    ) {
        self.system = system
        self.indexes = indexes
        self.learnedKnown = learnedKnown.mapValues { Set($0.map { $0.lowercased() }) }
        self.maxEditDistance = maxEditDistance
    }

    func isMisspelled(_ word: String, language: String) -> Bool {
        if learnedKnown[language]?.contains(word.lowercased()) == true { return false }
        return system.isMisspelled(word, language: language)
    }

    func guesses(for word: String, language: String) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()
        if let index = indexes[language] {
            for suggestion in index.lookup(word.lowercased(), maxEditDistance: maxEditDistance, max: 6)
            where seen.insert(suggestion.term).inserted {
                merged.append(suggestion.term)
            }
        }
        for guess in system.guesses(for: word, language: language)
        where seen.insert(guess.lowercased()).inserted {
            merged.append(guess)
        }
        return merged
    }
}
