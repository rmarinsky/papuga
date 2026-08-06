import AppKit
import Foundation

/// Hybrid spell-check client: the authoritative system checker, plus SymSpell
/// candidate generation, plus a **learned-known overlay**.
///
/// The system checker and learned vocabulary protect original words from false
/// positives. The frequency index is strict only for mapped layout candidates.
/// `guesses` merges fast SymSpell corrections ahead of the system's.
final class HybridSpellChecker: SpellCheckingClient {
    static let production: HybridSpellChecker = {
        let known = LearnedVocabulary.knownGoodWords()
        let learnedKnown = Dictionary(grouping: known, by: { word in
            word.unicodeScalars.contains { (0x0400...0x04FF).contains(Int($0.value)) } ? "uk" : "en"
        }).mapValues(Set.init)
        let checker = HybridSpellChecker(learnedKnown: learnedKnown)
        DispatchQueue.global(qos: .utility).async {
            let base = [
                "uk": DictionaryBuilder.loadBundledBase(language: "uk"),
                "en": DictionaryBuilder.loadBundledBase(language: "en")
            ]
            let learned = DictionaryBuilder.learnedFrequencies(from: learnedKnown.flatMap { language, words in
                words.map { (token: $0, language: language) }
            })
            checker.installIndexes(DictionaryBuilder.build(base: base, learned: learned))
        }
        return checker
    }()

    private let system: SpellCheckingClient
    private var indexes: [String: SymSpell]
    private let learnedKnown: [String: Set<String>]
    private let maxEditDistance: Int
    private let lock = NSLock()

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

    func installIndexes(_ indexes: [String: SymSpell]) {
        lock.withLock { self.indexes = indexes }
    }

    func isMisspelled(_ word: String, language: String) -> Bool {
        if learnedKnown[language]?.contains(word.lowercased()) == true { return false }
        return system.isMisspelled(word, language: language)
    }

    /// The frequency index may only ever **promote** a word to `.correct`; it
    /// may never demote one to `.misspelled`.
    ///
    /// The index is 50k conversational surface forms per language. It is a good
    /// "this is definitely a word" signal and a hopeless "this is definitely
    /// not a word" signal: it contains no Ukrainian apostrophe forms at all
    /// (`п'ять`, `м'ясо`, `об'єкт`…) and only a fraction of an inflected
    /// language's forms. Treating absence as proof of misspelling is what made
    /// correct-but-uncommon Ukrainian unfixable.
    ///
    /// So the ordering is: learned overlay, then index overlay, then the
    /// system dictionary as the actual authority. That restores the invariant
    /// this file was written with — the index can only remove false positives,
    /// never add new ones — and makes the async `installIndexes` load
    /// behaviourally invisible rather than a silent first-run quality cliff.
    ///
    /// `.unavailable` now means "no authority can answer for this language",
    /// not "no SymSpell index" (which was always true for ru/pl/de). Asking
    /// NSSpellChecker about a language it does not support silently falls back
    /// to automatic detection and returns nonsense, so that case must stay
    /// distinguishable from a real verdict.
    func mappedSpellingStatus(_ word: String, language: String) -> MappedSpellingStatus {
        let key = word.lowercased()
        if learnedKnown[language]?.contains(key) == true { return .correct }
        if lock.withLock({ indexes[language] })?.words[key] != nil { return .correct }
        guard Self.systemSupports(language) else { return .unavailable }
        return system.isMisspelled(word, language: language) ? .misspelled : .correct
    }

    /// `NSSpellChecker.availableLanguages` is a stable, cheap-to-snapshot list,
    /// but it is an IPC round-trip, so take it once.
    private static let supportedSystemLanguages: Set<String> = {
        Set(NSSpellChecker.shared.availableLanguages.map { code in
            // Entries look like "uk", "en_GB", "pt_PT" — compare on the base.
            String(code.prefix(while: { $0 != "_" && $0 != "-" })).lowercased()
        })
    }()

    static func systemSupports(_ language: String) -> Bool {
        let base = String(language.prefix(while: { $0 != "_" && $0 != "-" })).lowercased()
        guard !base.isEmpty else { return false }
        return supportedSystemLanguages.contains(base)
    }

    func guesses(for word: String, language: String) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()
        if let index = lock.withLock({ indexes[language] }) {
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
