import XCTest
@testable import papuga

/// System double that flags everything as misspelled and returns a fixed guess.
private final class AllWrongSpellChecker: SpellCheckingClient {
    func isMisspelled(_ word: String, language: String) -> Bool { true }
    func guesses(for word: String, language: String) -> [String] { ["systemguess"] }
}

private final class AllCorrectSpellChecker: SpellCheckingClient {
    func isMisspelled(_ word: String, language: String) -> Bool { false }
    func guesses(for word: String, language: String) -> [String] { [] }
}

final class HybridDictionaryTests: XCTestCase {

    func test_bundledFrequencyDictionariesLoad() {
        XCTAssertGreaterThan(DictionaryBuilder.loadBundledBase(language: "uk").count, 49_000)
        XCTAssertGreaterThan(DictionaryBuilder.loadBundledBase(language: "en").count, 49_000)
    }

    func test_builder_parse() {
        let parsed = DictionaryBuilder.parse("hello 100\nworld 50\nlone\n")
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].0, "hello"); XCTAssertEqual(parsed[0].1, 100)
        XCTAssertEqual(parsed[2].0, "lone"); XCTAssertEqual(parsed[2].1, 1) // no count → 1
    }

    func test_builder_learnedFrequencies_normalizesAndCountsPerLanguage() {
        let learned = DictionaryBuilder.learnedFrequencies(from: [
            ("Дев", "uk"), ("дев.", "uk"), ("дев", "uk"), ("hello", "en"),
        ])
        let uk = Dictionary(uniqueKeysWithValues: learned["uk"] ?? [])
        XCTAssertEqual(uk["дев"], 3)            // Дев / дев. / дев all normalize together
        XCTAssertEqual(learned["en"]?.first?.0, "hello")
    }

    func test_builder_build_combinesBaseAndLearnedWithWeight() {
        let indexes = DictionaryBuilder.build(
            base: ["uk": [("привіт", 1)]],
            learned: ["uk": [("дев", 1)]],
            learnedWeight: 1000
        )
        let uk = indexes["uk"]
        XCTAssertNotNil(uk)
        XCTAssertEqual(uk?.words["привіт"], 1)
        XCTAssertEqual(uk?.words["дев"], 1000)  // learned weighted up
    }

    func test_hybrid_learnedKnown_onlyRemovesFalsePositives() {
        let hybrid = HybridSpellChecker(
            system: AllWrongSpellChecker(),
            learnedKnown: ["uk": ["дев"]]
        )
        // The user's own word is now "known" → not flagged.
        XCTAssertFalse(hybrid.isMisspelled("дев", language: "uk"))
        XCTAssertFalse(hybrid.isMisspelled("ДЕВ", language: "uk")) // case-insensitive
        // Anything else still defers to the (authoritative) system checker.
        XCTAssertTrue(hybrid.isMisspelled("кнокп", language: "uk"))
    }

    func test_hybrid_guesses_putSymSpellCorrectionsFirst() {
        let indexes = DictionaryBuilder.build(
            base: ["uk": [("привіт", 100)]],
            learned: [:]
        )
        let hybrid = HybridSpellChecker(system: AllWrongSpellChecker(), indexes: indexes)
        let guesses = hybrid.guesses(for: "привт", language: "uk")
        XCTAssertEqual(guesses.first, "привіт")          // SymSpell correction first
        XCTAssertTrue(guesses.contains("systemguess"))   // system guess still merged in
    }

    /// The core invariant: the frequency index may only ever **promote** a word
    /// to `.correct`. It is 50k conversational surface forms — a good "this is
    /// a word" signal and a hopeless "this is not a word" signal (it contains
    /// no Ukrainian apostrophe forms at all). When it was treated as
    /// authoritative, every correct-but-uncommon word became `.misspelled` and
    /// layout auto-fix failed closed on it.
    func test_hybrid_indexPromotesButNeverDemotes() {
        let indexes = DictionaryBuilder.build(
            base: ["uk": [("привіт", 100)]],
            learned: [:]
        )
        let hybrid = HybridSpellChecker(system: AllCorrectSpellChecker(), indexes: indexes)

        // In the index → correct, regardless of the system checker.
        XCTAssertEqual(hybrid.mappedSpellingStatus("привіт", language: "uk"), .correct)
        // Absent from the index but the system accepts it → still correct.
        XCTAssertEqual(hybrid.mappedSpellingStatus("привчт", language: "uk"), .correct)
    }

    func test_hybrid_systemRejectionStillFailsClosed() {
        let indexes = DictionaryBuilder.build(base: ["uk": [("привіт", 100)]], learned: [:])
        let hybrid = HybridSpellChecker(system: AllWrongSpellChecker(), indexes: indexes)

        // Index promotes it even though the system rejects everything.
        XCTAssertEqual(hybrid.mappedSpellingStatus("привіт", language: "uk"), .correct)
        // Nothing vouches for this one and the system rejects it → suppress.
        XCTAssertEqual(hybrid.mappedSpellingStatus("кнокп", language: "uk"), .misspelled)
    }

    /// A learned word is correct even when neither the index nor the system
    /// knows it — that is the whole point of the overlay.
    func test_hybrid_learnedOverlayPromotesWithoutAnIndex() {
        let hybrid = HybridSpellChecker(
            system: AllWrongSpellChecker(),
            learnedKnown: ["uk": ["пофіксити"]]
        )
        XCTAssertEqual(hybrid.mappedSpellingStatus("пофіксити", language: "uk"), .correct)
        XCTAssertEqual(hybrid.mappedSpellingStatus("ПОФІКСИТИ", language: "uk"), .correct)
    }

    /// Without an index the system checker is the authority — which is what
    /// this test always claimed to assert. It previously reported
    /// `.unavailable` instead, so every layout replacement into a language with
    /// no bundled index (ru, pl, de, fr…) was suppressed outright.
    func test_hybrid_withoutIndexFallsBackToSystem() throws {
        try XCTSkipUnless(
            HybridSpellChecker.systemSupports("fr"),
            "macOS on this machine has no French dictionary"
        )
        let hybrid = HybridSpellChecker(system: AllWrongSpellChecker())
        XCTAssertTrue(hybrid.isMisspelled("anything", language: "fr"))
        XCTAssertEqual(hybrid.guesses(for: "anything", language: "fr"), ["systemguess"])
        XCTAssertEqual(hybrid.mappedSpellingStatus("anything", language: "fr"), .misspelled)
    }

    /// `.unavailable` now means "no authority can answer", not "no SymSpell
    /// index". Asking NSSpellChecker about a language it does not support
    /// silently falls back to automatic detection and returns nonsense, so that
    /// case has to stay distinguishable from a real verdict.
    func test_hybrid_unsupportedLanguageIsUnavailableRatherThanMisspelled() {
        let hybrid = HybridSpellChecker(system: AllWrongSpellChecker())
        XCTAssertFalse(HybridSpellChecker.systemSupports("zz"))
        XCTAssertEqual(hybrid.mappedSpellingStatus("anything", language: "zz"), .unavailable)
    }

    func test_systemSupports_matchesOnTheBaseLanguageCode() {
        // macOS reports regional variants like "en_GB"; a bare "en" must match.
        XCTAssertTrue(HybridSpellChecker.systemSupports("en"))
        XCTAssertTrue(HybridSpellChecker.systemSupports("en_US"))
        XCTAssertFalse(HybridSpellChecker.systemSupports(""))
    }

    /// End-to-end against the real bundled lists + the real system dictionary.
    ///
    /// The bundled `frequency_uk.txt` contains **zero** apostrophe forms, so
    /// while the index was authoritative every one of these was `.misspelled`:
    /// layout auto-fix failed closed on them and the compound path offered a
    /// different, more frequent word instead. macOS does know them.
    func test_realDictionary_acceptsUkrainianApostropheForms() throws {
        try XCTSkipUnless(
            HybridSpellChecker.systemSupports("uk"),
            "macOS on this machine has no Ukrainian dictionary"
        )
        let hybrid = HybridSpellChecker()
        for word in ["п'ять", "м'ясо", "об'єкт", "сім'я", "здоров'я", "ім'я"] {
            XCTAssertEqual(
                hybrid.mappedSpellingStatus(word, language: "uk"), .correct,
                "\(word) must not be treated as a layout-fix blocker"
            )
        }
    }

    /// Documents the data problem that step 5 fixes: these are absent from the
    /// list, which is precisely why the list must not be the authority.
    func test_bundledUkrainianListHasNoApostropheForms() {
        let base = DictionaryBuilder.loadBundledBase(language: "uk")
        let withApostrophes = base.filter { entry in
            entry.0.contains(where: { $0 == "'" || $0 == "\u{2019}" || $0 == "\u{02BC}" })
        }
        XCTAssertTrue(
            withApostrophes.isEmpty,
            "the list gained apostrophe forms — revisit the comment on mappedSpellingStatus"
        )
    }
}
