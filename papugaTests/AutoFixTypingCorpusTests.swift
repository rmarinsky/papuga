import Carbon.HIToolbox
import XCTest
@testable import papuga

/// Uses the evaluator called by AutoFixController, real OS layouts, real AppleNL,
/// real system spelling, and shipped dictionaries. No predicted outcomes are mocked.
final class AutoFixTypingCorpusTests: XCTestCase {
    private struct Case: Decodable {
        let id: String
        let category: String
        let keys: String
        let expectedText: String
        let expectedLayout: String
    }
    private func source(_ id: String) throws -> InputSourceInfo {
        let list = TISCreateInputSourceList([kTISPropertyInputSourceID!: id] as CFDictionary, true).takeRetainedValue() as! [TISInputSource]
        return InputSourceInfo(id: id, name: id, source: try XCTUnwrap(list.first, "Required test layout missing: \(id)"))
    }
    private static let checker = HybridSpellChecker(indexes: DictionaryBuilder.build(base: [
            "uk": DictionaryBuilder.loadBundledBase(language: "uk"),
            "en": DictionaryBuilder.loadBundledBase(language: "en")
        ], learned: [:]))

    private func check(_ category: String) throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/typing/corpus.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: path)).filter { $0.category == category }
        XCTAssertFalse(cases.isEmpty, "A missing corpus category must not turn green")
        let from = try source("com.apple.keylayout.US")
        let to = try source("com.apple.keylayout.Ukrainian-PC")
        let evaluator = AutoFixWordEvaluator(mapper: CharacterMapper(), spellChecker: Self.checker, scorer: AppleNLScorer())
        for tc in cases {
            XCTContext.runActivity(named: "\(tc.id): \(tc.keys) → \(tc.expectedText)") { _ in
                let actual = evaluator.evaluate(String(tc.keys.dropLast()), source: from, targets: [to], configuration: .init())
                if tc.expectedLayout == from.id {
                    XCTAssertNil(actual.replacement, "\(tc.id): must preserve intentional input; got \(actual.disposition)")
                } else {
                    XCTAssertEqual(actual.replacement?.candidate, String(tc.expectedText.dropLast()),
                        "\(tc.id): \(actual.disposition); scores \(actual.scoreOriginal)/\(actual.effectiveScore)")
                    XCTAssertEqual(actual.replacement?.targetID, tc.expectedLayout, tc.id)
                    if let replacement = actual.replacement {
                        XCTAssertTrue(AutoFixDecision.shouldBypassLayoutIncidentGrace(
                            scoreCandidate: replacement.scoreCandidate, hasVerifiedLayoutWord: true),
                            "\(tc.id): an approved dictionary-backed correction must not wait for more words")
                    }
                }
            }
        }
    }
    func test_unverifiedThirdLayoutDoesNotHideVerifiedUkrainianWord() throws {
        let from = try source("com.apple.keylayout.US")
        let ukrainian = try source("com.apple.keylayout.Ukrainian-PC")
        let russian = try source("com.apple.keylayout.Russian")
        let evaluator = AutoFixWordEvaluator(mapper: CharacterMapper(), spellChecker: Self.checker, scorer: AppleNLScorer())
        let result = evaluator.evaluate("ghbdsn", source: from, targets: [russian, ukrainian], configuration: .init())
        XCTAssertEqual(result.replacement?.candidate, "привіт", "\(result.disposition)")
        XCTAssertEqual(result.replacement?.targetID, ukrainian.id)
    }

    func test_learnedAbbreviationIsNotReplacedByFrequentUkrainianWord() throws {
        let from = try source("com.apple.keylayout.US")
        let to = try source("com.apple.keylayout.Ukrainian-PC")
        let checker = HybridSpellChecker(indexes: DictionaryBuilder.build(base: [
            "uk": DictionaryBuilder.loadBundledBase(language: "uk"),
            "en": DictionaryBuilder.loadBundledBase(language: "en")
        ], learned: [:]), learnedKnown: ["en": ["yt", "vtys", "wt"]])
        let evaluator = AutoFixWordEvaluator(mapper: CharacterMapper(), spellChecker: checker, scorer: AppleNLScorer())
        for word in ["yt", "vtys", "wt"] {
            let result = evaluator.evaluate(word, source: from, targets: [to], configuration: .init())
            XCTAssertEqual(result.disposition, .sourceWord, word)
            XCTAssertNil(result.replacement, word)
        }
    }

    func test_punctuationIsPreserved() throws { try check("punctuation") }
    func test_englishTyposDoNotBecomeUkrainian() throws { try check("typo") }
    func test_commonWords() throws { try check("common") }
    func test_shortWords() throws { try check("short") }
    func test_longWords() throws { try check("long") }
    func test_hyphenatedWords() throws { try check("hyphen") }
    func test_apostropheWords() throws { try check("apostrophe") }
    func test_capitalizedWords() throws { try check("capitalized") }
    func test_intentionalEnglishIsNotReplaced() throws { try check("negative") }
    func test_codeAddressesNumbersAndAmbiguousWordsAreNotReplaced() throws { try check("protected") }
}
