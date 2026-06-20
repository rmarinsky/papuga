import XCTest
@testable import papuga

/// Flags everything misspelled; returns guesses only for the words you map.
private final class FixedGuessChecker: SpellCheckingClient {
    let guessMap: [String: [String]]
    init(_ guessMap: [String: [String]]) { self.guessMap = guessMap }
    func isMisspelled(_ word: String, language: String) -> Bool { true }
    func guesses(for word: String, language: String) -> [String] { guessMap[word.lowercased()] ?? [] }
}

final class SuggestionQualityTests: XCTestCase {

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("papuga-pred-\(UUID().uuidString).json")
    }

    func test_wordPlausibility_rejectsGibberishKeepsRealWords() {
        // Real / word-like → kept.
        for w in ["roman", "привіт", "hello", "borscht", "віджет", "плейрайт"] {
            XCTAssertTrue(WordPlausibility.isWordLike(w), "\(w) should be word-like")
        }
        // The actual garbage from the screenshots → rejected.
        for w in ["gktqhfqn", "dsl;tn", "htgjpbnjhs]", "від.ет", "kj", "x"] {
            XCTAssertFalse(WordPlausibility.isWordLike(w), "\(w) should be rejected")
        }
    }

    @MainActor
    func test_analyzer_neverSurfacesGibberish() throws {
        let lm = LayoutManager()
        try XCTSkipUnless(lm.orderedLayouts().count >= 2, "needs ≥2 layouts")
        let analyzer = MistakeSuggestionAnalyzer() // real NSSpellChecker
        // These real Ukrainian/domain words used to produce gibberish layout flips.
        for word in ["плейрайт", "репозиторії", "віджет", "налаштування"] {
            let candidates = analyzer.candidates(
                for: word, language: "uk", recordedTargets: [],
                layoutManager: lm, limit: 6
            )
            for candidate in candidates where candidate.kind != .recorded {
                XCTAssertTrue(
                    WordPlausibility.isWordLike(candidate.text),
                    "gibberish candidate '\(candidate.text)' (\(candidate.kind.rawValue)) for '\(word)'"
                )
            }
        }
    }

    @MainActor
    func test_engine_mergesDuplicateCardsAcrossApps() async throws {
        func obs(_ app: String) -> MistakeObservation {
            MistakeObservation(
                issueType: .manualCorrection, source: "кщьфт", suggestedTarget: "roman",
                language: "uk", bundleID: app, confidence: 0.8
            )
        }
        let entries = (0..<3).map { _ in obs("app.a") } + (0..<3).map { _ in obs("app.b") }
        let cache = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cache) }
        let engine = PredictionEngine(
            analyzer: MistakeSuggestionAnalyzer(spellChecker: CountingSpellChecker()),
            chunkSize: 10, cacheURL: cache
        )
        engine.handledSourcesProvider = { [] } // independent of the machine's allowlist
        await engine.analyzeToCompletionForTesting(observations: entries, force: false)

        let cards = engine.ranked.filter { $0.source.caseInsensitiveCompare("кщьфт") == .orderedSame }
        XCTAssertEqual(cards.count, 1, "the same correction in two apps must be ONE card")
        XCTAssertEqual(cards.first?.count, 6, "merged count = 3 + 3")
        XCTAssertEqual(cards.first?.observationIDs.count, 6, "rule should cover all instances")
    }

    func test_learnedVocabulary_handledSources() {
        let handled = LearnedVocabulary.handledSources(
            allowlist: ["Плейрайт", "репозиторії"],
            rules: [CustomAutoReplaceRule(source: "кщьфт", target: "roman")]
        )
        XCTAssertTrue(handled.contains("плейрайт"))   // normalized + lowercased
        XCTAssertTrue(handled.contains("репозиторії"))
        XCTAssertTrue(handled.contains("кщьфт"))       // rule source
        XCTAssertTrue(handled.contains("roman"))       // rule target
    }

    @MainActor
    func test_engine_skipsHandledWords() async throws {
        func obs(_ source: String) -> MistakeObservation {
            MistakeObservation(issueType: .spelling, source: source, suggestedTarget: nil,
                               language: "uk", bundleID: "app", confidence: 0.6)
        }
        let entries = [obs("плейрайт"), obs("плейрайт"), obs("кіт"), obs("кіт")]
        let cache = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cache) }
        let engine = PredictionEngine(
            analyzer: MistakeSuggestionAnalyzer(spellChecker: CountingSpellChecker()),
            chunkSize: 10, cacheURL: cache
        )
        engine.handledSourcesProvider = { ["плейрайт"] } // user allowlisted it
        await engine.analyzeToCompletionForTesting(observations: entries, force: false)

        XCTAssertFalse(engine.ranked.contains { $0.source == "плейрайт" }, "handled word must not resurface")
        XCTAssertTrue(engine.ranked.contains { $0.source == "кіт" }, "unhandled word still shown")
    }

    @MainActor
    func test_engine_learnsDomainWordButKeepsRealTypos() async throws {
        func obs(_ source: String, _ target: String?) -> MistakeObservation {
            MistakeObservation(issueType: .spelling, source: source, suggestedTarget: target,
                               language: "uk", bundleID: "app", confidence: 0.6)
        }
        // "плейрайт" recurs with NO close correction → a real domain word.
        // "помилак" recurs WITH a close correction "помилка" → a genuine typo.
        let entries =
            (0..<3).map { _ in obs("плейрайт", nil) } +
            (0..<3).map { _ in obs("помилак", nil) }
        let cache = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cache) }
        let engine = PredictionEngine(
            analyzer: MistakeSuggestionAnalyzer(spellChecker: FixedGuessChecker(["помилак": ["помилка"]])),
            chunkSize: 10, cacheURL: cache
        )
        engine.handledSourcesProvider = { [] }
        await engine.analyzeToCompletionForTesting(observations: entries, force: false)

        XCTAssertTrue(engine.domainVocabulary.contains("плейрайт"), "domain word should be learned")
        XCTAssertFalse(engine.domainVocabulary.contains("помилак"), "a typo with a close fix must NOT be learned")
        XCTAssertFalse(engine.ranked.contains { $0.source == "плейрайт" }, "learned word leaves the list")
        XCTAssertTrue(engine.ranked.contains { $0.source == "помилак" }, "real typo still shown")
    }
}
