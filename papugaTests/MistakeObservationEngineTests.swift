import Defaults
import XCTest
@testable import papuga

final class MistakeObservationEngineTests: XCTestCase {
    private final class FakeSpellChecker: SpellCheckingClient {
        var misspelled: Set<String> = []
        var guessesByWord: [String: [String]] = [:]

        func isMisspelled(_ word: String, language: String) -> Bool {
            misspelled.contains(word.lowercased())
        }

        func guesses(for word: String, language: String) -> [String] {
            guessesByWord[word.lowercased()] ?? []
        }
    }

    private final class RecordingStore: MistakeObservationRecording {
        var entries: [MistakeObservation] = []

        func record(_ entry: MistakeObservation) {
            entries.append(entry)
        }
    }

    override func setUp() {
        super.setUp()
        Defaults[.mistakeObservationEnabled] = true
        Defaults[.autoFixAllowlist] = []
        Defaults[.autoFixBlocklist] = []
        Defaults[.autoFixMinWordLength] = 3
        Defaults[.disabledLayouts] = []
    }

    override func tearDown() {
        Defaults[.mistakeObservationEnabled] = true
        Defaults[.autoFixAllowlist] = []
        Defaults[.autoFixBlocklist] = []
        Defaults[.autoFixMinWordLength] = 3
        Defaults[.disabledLayouts] = []
        super.tearDown()
    }

    func test_observeCompletedWord_recordsMisspelledWordWithSuggestion() {
        let spellChecker = FakeSpellChecker()
        spellChecker.misspelled = ["pomylkka"]
        spellChecker.guessesByWord = ["pomylkka": ["pomylka"]]
        let store = RecordingStore()
        let engine = MistakeObservationEngine(spellChecker: spellChecker, store: store)

        let result = engine.observeCompletedWord(CompletedWordObservation(
            word: "pomylkka",
            language: "uk",
            bundleID: "com.example.editor",
            timestamp: Date(timeIntervalSince1970: 10),
            allowlist: [],
            blocklist: [],
            minWordLength: 3
        ))

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(result?.issueType, .spelling)
        XCTAssertEqual(result?.source, "pomylkka")
        XCTAssertEqual(result?.suggestedTarget, "pomylka")
        XCTAssertEqual(result?.bundleID, "com.example.editor")
    }

    func test_observeCompletedWord_spellchecksCoreAndKeepsPunctuationForRendering() {
        let spellChecker = FakeSpellChecker()
        spellChecker.misspelled = ["можі"]
        spellChecker.guessesByWord = ["можі": ["може"]]
        let store = RecordingStore()
        let engine = MistakeObservationEngine(spellChecker: spellChecker, store: store)

        let result = engine.observeCompletedWord(CompletedWordObservation(
            word: "“можі?”",
            language: "uk",
            bundleID: "com.example.editor",
            timestamp: Date(timeIntervalSince1970: 10),
            allowlist: [],
            blocklist: [],
            minWordLength: 3
        ))

        XCTAssertEqual(result?.source, "“можі?”")
        XCTAssertEqual(result?.sourceCore, "можі")
        XCTAssertEqual(result?.leadingPunctuation, "“")
        XCTAssertEqual(result?.trailingPunctuation, "?”")
        XCTAssertEqual(result?.suggestedTarget, "може")
        XCTAssertEqual(result?.renderedSuggestedTarget, "“може?”")
    }

    func test_observeCompletedWord_skipsSensitiveAndIgnoredTokens() {
        let spellChecker = FakeSpellChecker()
        spellChecker.misspelled = ["test123", "ignored", "blocked"]
        let store = RecordingStore()
        let engine = MistakeObservationEngine(spellChecker: spellChecker, store: store)

        _ = engine.observeCompletedWord(CompletedWordObservation(
            word: "test123",
            language: "en",
            bundleID: nil,
            timestamp: Date(),
            allowlist: [],
            blocklist: [],
            minWordLength: 3
        ))
        _ = engine.observeCompletedWord(CompletedWordObservation(
            word: "ignored",
            language: "en",
            bundleID: nil,
            timestamp: Date(),
            allowlist: ["ignored"],
            blocklist: [],
            minWordLength: 3
        ))
        _ = engine.observeCompletedWord(CompletedWordObservation(
            word: "blocked",
            language: "en",
            bundleID: "com.example.blocked",
            timestamp: Date(),
            allowlist: [],
            blocklist: ["com.example.blocked"],
            minWordLength: 3
        ))

        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_observeCompletedWord_ignoresLegacyDisabledObservationFlag() {
        Defaults[.mistakeObservationEnabled] = false
        let spellChecker = FakeSpellChecker()
        spellChecker.misspelled = ["pomylkka"]
        spellChecker.guessesByWord = ["pomylkka": ["pomylka"]]
        let store = RecordingStore()
        let engine = MistakeObservationEngine(spellChecker: spellChecker, store: store)

        let result = engine.observeCompletedWord(CompletedWordObservation(
            word: "pomylkka",
            language: "uk",
            bundleID: nil,
            timestamp: Date(),
            allowlist: [],
            blocklist: [],
            minWordLength: 3
        ))

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(result?.source, "pomylkka")
        XCTAssertEqual(result?.suggestedTarget, "pomylka")
    }

    func test_suggestionAnalyzer_returnsMultipleSpellingCandidates() {
        let spellChecker = FakeSpellChecker()
        spellChecker.guessesByWord = [
            "wrold": ["world", "would", "wold", "w rld", "world"]
        ]
        let analyzer = MistakeSuggestionAnalyzer(spellChecker: spellChecker)

        let candidates = analyzer.candidates(for: "wrold", language: "en", limit: 4)

        XCTAssertEqual(candidates.map(\.text), ["wold", "world", "would"])
        XCTAssertTrue(candidates.allSatisfy { $0.kind == .spelling })
    }

    func test_suggestionAnalyzerUsesCoreForPunctuationBearingSource() {
        let spellChecker = FakeSpellChecker()
        spellChecker.guessesByWord = ["unfortunatly": ["Unfortunately"]]
        let analyzer = MistakeSuggestionAnalyzer(spellChecker: spellChecker)

        let candidates = analyzer.candidates(for: "Unfortunatly,", language: "en", limit: 4)

        XCTAssertTrue(candidates.contains {
            $0.kind == .spelling && $0.text == "Unfortunately"
        })
        XCTAssertEqual(
            candidates.first(where: { $0.text == "Unfortunately" })?.replacementPlan?.renderedReplacement,
            "Unfortunately,"
        )

        let periodCandidates = analyzer.candidates(for: "Unfortunatly.", language: "en", limit: 4)
        XCTAssertEqual(
            periodCandidates.first(where: { $0.text == "Unfortunately" })?.replacementPlan?.renderedReplacement,
            "Unfortunately."
        )
    }

    func test_suggestionAnalyzer_keepsRecordedTargetFirstAndDeduplicates() {
        let spellChecker = FakeSpellChecker()
        spellChecker.guessesByWord = [
            "pomylkka": ["pomylka", "pomilka"]
        ]
        let analyzer = MistakeSuggestionAnalyzer(spellChecker: spellChecker)

        let candidates = analyzer.candidates(
            for: "pomylkka",
            language: "uk",
            recordedTargets: ["pomylka"],
            limit: 4
        )

        XCTAssertEqual(candidates.first?.text, "pomylka")
        XCTAssertEqual(candidates.first?.kind, .recorded)
        XCTAssertEqual(candidates.filter { $0.text == "pomylka" }.count, 1)
        XCTAssertTrue(candidates.contains { $0.text == "pomilka" && $0.kind == .spelling })
    }

    func test_recordedTargetFallbackFailsClosedForEdgeBearingCrossScriptPair() {
        let analyzer = MistakeSuggestionAnalyzer(spellChecker: FakeSpellChecker())

        let unsafe = analyzer.candidates(
            for: "nfrj;",
            language: "en",
            recordedTargets: ["також"],
            layoutManager: nil,
            limit: 4
        ).first
        let safeSpelling = analyzer.candidates(
            for: "можі,",
            language: "uk",
            recordedTargets: ["може"],
            layoutManager: nil,
            limit: 4
        ).first

        XCTAssertEqual(unsafe?.kind, .recorded)
        XCTAssertEqual(unsafe?.canCreateCoreRule, false)
        XCTAssertEqual(safeSpelling?.canCreateCoreRule, true)
    }

    func test_groupedCandidatesRequireRuleSafetyAcrossEveryRawSource() throws {
        let unsafeGroupEntries = [
            MistakeObservation(
                issueType: .manualCorrection,
                source: "nfrj",
                suggestedTarget: "також",
                language: "en",
                confidence: 0.9
            ),
            MistakeObservation(
                issueType: .manualCorrection,
                source: "nfrj;",
                suggestedTarget: "також",
                language: "en",
                confidence: 0.9
            )
        ]
        let safeGroupEntries = [
            MistakeObservation(
                issueType: .spelling,
                source: "можі",
                suggestedTarget: "може",
                language: "uk",
                confidence: 0.9
            ),
            MistakeObservation(
                issueType: .spelling,
                source: "можі,",
                suggestedTarget: "може",
                language: "uk",
                confidence: 0.9
            )
        ]
        let analyzer = MistakeSuggestionAnalyzer(spellChecker: FakeSpellChecker())
        let unsafeGroup = try XCTUnwrap(
            MistakesScreenDerivation.groups(from: unsafeGroupEntries, filter: .all, query: "").first
        )
        let safeGroup = try XCTUnwrap(
            MistakesScreenDerivation.groups(from: safeGroupEntries, filter: .all, query: "").first
        )

        let unsafeCandidate = MistakesScreenDerivation.candidates(
            for: unsafeGroup,
            analyzer: analyzer,
            layoutManager: nil
        ).first
        let safeCandidate = MistakesScreenDerivation.candidates(
            for: safeGroup,
            analyzer: analyzer,
            layoutManager: nil
        ).first

        XCTAssertEqual(Set(unsafeGroup.rawSources), ["nfrj", "nfrj;"])
        XCTAssertEqual(unsafeCandidate?.canCreateCoreRule, false)
        XCTAssertEqual(safeCandidate?.canCreateCoreRule, true)
    }

    func test_suggestionAnalyzer_includesKeyboardLayoutCandidateWhenLayoutsExist() throws {
        let oldOrder = Defaults[.layoutOrder]
        let oldDisabled = Defaults[.disabledLayouts]
        defer {
            Defaults[.layoutOrder] = oldOrder
            Defaults[.disabledLayouts] = oldDisabled
        }

        let layoutManager = LayoutManager()
        let ids = layoutManager.availableLayouts.map(\.id)
        let us = "com.apple.keylayout.US"
        let ukrainian = "com.apple.keylayout.Ukrainian-PC"
        guard ids.contains(us), ids.contains(ukrainian) else {
            throw XCTSkip("US and Ukrainian-PC input sources are required for this layout suggestion test.")
        }

        Defaults[.layoutOrder] = [us, ukrainian] + ids.filter { $0 != us && $0 != ukrainian }
        Defaults[.disabledLayouts] = []

        let analyzer = MistakeSuggestionAnalyzer(spellChecker: FakeSpellChecker())
        let candidates = analyzer.candidates(
            for: ".hsq",
            language: "en",
            layoutManager: layoutManager,
            limit: 6
        )

        let yuriy = candidates.first { candidate in
            candidate.kind == .keyboardLayout && candidate.text.lowercased() == "юрій"
        }
        XCTAssertNotNil(yuriy)
        XCTAssertEqual(yuriy?.replacementPlan?.interpretationReason, .layoutFullToken)
        XCTAssertEqual(yuriy?.replacementPlan?.renderedReplacement.lowercased(), "юрій")

        let terminalSemicolon = analyzer.candidates(
            for: "nfrj;",
            language: "en",
            layoutManager: layoutManager,
            limit: 8
        ).first { $0.text.lowercased() == "також" }
        XCTAssertEqual(terminalSemicolon?.replacementPlan?.interpretationReason, .layoutFullToken)
        XCTAssertEqual(terminalSemicolon?.replacementPlan?.renderedReplacement.lowercased(), "також")
        XCTAssertEqual(terminalSemicolon?.canCreateCoreRule, false)

        let recordedFullToken = analyzer.candidates(
            for: "nfrj;",
            language: "en",
            recordedTargets: ["також"],
            layoutManager: layoutManager,
            limit: 8
        ).first
        XCTAssertEqual(recordedFullToken?.kind, .recorded)
        XCTAssertEqual(recordedFullToken?.replacementPlan?.interpretationReason, .layoutFullToken)
        XCTAssertEqual(recordedFullToken?.replacementPlan?.renderedReplacement.lowercased(), "також")
        XCTAssertEqual(recordedFullToken?.canCreateCoreRule, false)

        let recordedCoreWithComma = analyzer.candidates(
            for: "ghbdsn,",
            language: "en",
            recordedTargets: ["привіт"],
            layoutManager: layoutManager,
            limit: 8
        ).first
        XCTAssertEqual(recordedCoreWithComma?.kind, .recorded)
        XCTAssertEqual(
            recordedCoreWithComma?.replacementPlan?.interpretationReason,
            .layoutCorePreservingEdges
        )
        XCTAssertEqual(recordedCoreWithComma?.replacementPlan?.renderedReplacement.lowercased(), "привіт,")
        XCTAssertEqual(recordedCoreWithComma?.canCreateCoreRule, true)
    }

    func test_recordManualCorrection_recordsSourceAndTarget() {
        let store = RecordingStore()
        let engine = MistakeObservationEngine(spellChecker: FakeSpellChecker(), store: store)

        let result = engine.recordManualCorrection(ManualCorrectionCandidate(
            source: "pomylkka",
            target: "pomylka",
            language: "uk",
            bundleID: "com.example.editor",
            confidence: 0.8
        ))

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(result?.issueType, .manualCorrection)
        XCTAssertEqual(result?.source, "pomylkka")
        XCTAssertEqual(result?.suggestedTarget, "pomylka")
    }
}
