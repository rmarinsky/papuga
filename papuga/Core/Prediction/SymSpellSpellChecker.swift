import Foundation

/// Drop-in `SpellCheckingClient` backed by per-language `SymSpell` indexes, with
/// a fallback (e.g. `SystemSpellCheckingClient`) for languages that have no
/// loaded dictionary yet.
///
/// This is the integration seam for Phase D: once uk/en frequency dictionaries
/// (bundled and/or learned from the user's own correctly-typed history) are
/// loaded, the analyzer's spell-check work runs ~150× faster than NSSpellChecker
/// and fully off the main thread — making even tens of thousands of mistakes
/// analyze near-instantly. Until a language is loaded, it transparently defers
/// to the fallback, so wiring it in is safe and incremental.
final class SymSpellSpellChecker: SpellCheckingClient {
    private var indexes: [String: SymSpell]
    private let fallback: SpellCheckingClient?
    private let maxEditDistance: Int

    init(
        indexes: [String: SymSpell] = [:],
        fallback: SpellCheckingClient? = SystemSpellCheckingClient(),
        maxEditDistance: Int = 2
    ) {
        self.indexes = indexes
        self.fallback = fallback
        self.maxEditDistance = maxEditDistance
    }

    func setIndex(_ index: SymSpell, for language: String) {
        indexes[language] = index
    }

    func hasIndex(for language: String) -> Bool { indexes[language] != nil }

    func isMisspelled(_ word: String, language: String) -> Bool {
        if let index = indexes[language] {
            return index.words[word.lowercased()] == nil
        }
        return fallback?.isMisspelled(word, language: language) ?? false
    }

    func guesses(for word: String, language: String) -> [String] {
        if let index = indexes[language] {
            return index.lookup(word.lowercased(), maxEditDistance: maxEditDistance, max: 8).map(\.term)
        }
        return fallback?.guesses(for: word, language: language) ?? []
    }
}
