import XCTest
@testable import papuga

/// System double that flags everything as misspelled and returns a fixed guess.
private final class AllWrongSpellChecker: SpellCheckingClient {
    func isMisspelled(_ word: String, language: String) -> Bool { true }
    func guesses(for word: String, language: String) -> [String] { ["systemguess"] }
}

final class HybridDictionaryTests: XCTestCase {

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
}
