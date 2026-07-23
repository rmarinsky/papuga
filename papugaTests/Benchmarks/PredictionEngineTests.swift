import XCTest
@testable import papuga

@MainActor
final class PredictionEngineTests: XCTestCase {

    private func bench(_ s: String) { print("BENCH| \(s)") }

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("papuga-pred-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("prediction-cache.json")
    }

    private func removeTempCache(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func test_potentialReplacementLog_keeps_each_actionable_occurrence_and_excludes_handled_entries() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recorded = MistakeObservation(
            timestamp: now.addingTimeInterval(-60),
            issueType: .manualCorrection,
            source: "teh",
            suggestedTarget: "the",
            language: "en",
            confidence: 0.9
        )
        let predicted = MistakeObservation(
            timestamp: now,
            issueType: .spelling,
            source: "helo",
            language: "en",
            confidence: 0.8
        )
        let repeated = MistakeObservation(
            timestamp: now.addingTimeInterval(-120),
            issueType: .manualCorrection,
            source: "teh",
            suggestedTarget: "the",
            language: "en",
            confidence: 0.9
        )
        let missingTarget = MistakeObservation(
            issueType: .spelling,
            source: "mystery",
            language: "en",
            confidence: 0.5
        )
        let sameTarget = MistakeObservation(
            issueType: .spelling,
            source: "same",
            suggestedTarget: " SAME ",
            language: "en",
            confidence: 0.9
        )
        let handled = MistakeObservation(
            issueType: .spelling,
            source: "Papuga",
            suggestedTarget: "papuga-app",
            language: "en",
            confidence: 0.9
        )
        let resolved = MistakeObservation(
            issueType: .manualCorrection,
            status: .convertedToRule,
            source: "wierd",
            suggestedTarget: "weird",
            language: "en",
            confidence: 0.9
        )
        let dismissed = MistakeObservation(
            issueType: .manualCorrection,
            status: .dismissed,
            source: "colour",
            suggestedTarget: "color",
            language: "en",
            confidence: 0.9
        )
        let dictionaryEntry = MistakeObservation(
            issueType: .spelling,
            status: .addedToDictionary,
            source: "Codex",
            suggestedTarget: "codec",
            language: "en",
            confidence: 0.9
        )
        let truncatedSource = MistakeObservation(
            issueType: .manualCorrection,
            source: String(repeating: "x", count: MistakeObservation.maxStoredCharCount + 1),
            suggestedTarget: "safe-looking-target",
            language: "en",
            confidence: 0.9
        )

        let entries = PotentialReplacementLogEntry.derive(
            observations: [
                recorded, predicted, repeated, missingTarget, sameTarget, handled,
                resolved, dismissed, dictionaryEntry, truncatedSource,
            ],
            predictedTargetsByObservationID: [predicted.id: "hello"],
            handledSources: [MistakeObservation.normalizedToken(handled.source)]
        )

        XCTAssertEqual(entries.map(\.id), [predicted.id, recorded.id, repeated.id])
        XCTAssertEqual(entries.map(\.target), ["hello", "the", "the"])
        XCTAssertEqual(entries.map(\.origin), [.prediction, .recorded, .recorded])

        let afterHandledVocabularyRemoval = PotentialReplacementLogEntry.derive(
            observations: [recorded, predicted, repeated, handled],
            predictedTargetsByObservationID: [predicted.id: "hello"],
            handledSources: []
        )
        XCTAssertEqual(afterHandledVocabularyRemoval.count, 4)
        XCTAssertTrue(afterHandledVocabularyRemoval.contains { $0.id == handled.id })
    }

    func test_engine_publishes_concrete_target_for_each_actionable_observation() async {
        let recorded = MistakeObservation(
            issueType: .manualCorrection,
            source: "teh",
            suggestedTarget: "the",
            language: "en",
            confidence: 0.9
        )
        let predicted = MistakeObservation(
            issueType: .spelling,
            source: "helo",
            language: "en",
            confidence: 0.8
        )
        let unresolved = MistakeObservation(
            issueType: .spelling,
            source: "x",
            language: "en",
            confidence: 0.4
        )
        let truncatedSource = MistakeObservation(
            issueType: .manualCorrection,
            source: String(repeating: "x", count: MistakeObservation.maxStoredCharCount + 1),
            suggestedTarget: "target",
            language: "en",
            confidence: 0.9
        )
        let cache = tempCacheURL()
        defer { removeTempCache(at: cache) }
        let engine = PredictionEngine(
            analyzer: MistakeSuggestionAnalyzer(spellChecker: PotentialChangeSpellChecker()),
            cacheURL: cache
        )
        engine.domainLearningEnabled = false

        await engine.analyzeToCompletionForTesting(
            observations: [recorded, predicted, unresolved, truncatedSource],
            force: true
        )

        XCTAssertEqual(engine.phase, .ready)
        XCTAssertEqual(
            engine.actionableTargetsByObservationID,
            [recorded.id: "the", predicted.id: "hello"]
        )
    }

    func test_engine_refreshes_when_handledVocabularyChanges() async {
        let observation = MistakeObservation(
            issueType: .manualCorrection,
            source: "teh",
            suggestedTarget: "the",
            language: "en",
            confidence: 0.9
        )
        let cache = tempCacheURL()
        defer { removeTempCache(at: cache) }
        let store = MistakeObservationStore(
            testFileURL: cache.deletingLastPathComponent().appendingPathComponent("observations.jsonl")
        )
        store.replaceEntriesForTesting([observation])
        var handledSources = Set<String>()
        let engine = PredictionEngine(store: store, cacheURL: cache)
        engine.domainLearningEnabled = false
        engine.handledSourcesProvider = { handledSources }

        await engine.bootstrapToCompletionForTesting()
        XCTAssertEqual(engine.actionableTargetsByObservationID, [observation.id: "the"])

        handledSources = [observation.normalizedSource]
        await engine.bootstrapToCompletionForTesting()
        XCTAssertTrue(engine.actionableTargetsByObservationID.isEmpty)

        handledSources = []
        await engine.bootstrapToCompletionForTesting()
        XCTAssertEqual(engine.actionableTargetsByObservationID, [observation.id: "the"])
    }

    // MARK: - Correctness (fast, deterministic, always runs)

    func test_engine_analyzes_and_ranks() async throws {
        let entries = MistakeBenchmarkData.synthetic(groupCount: 200)
        let cache = tempCacheURL()
        defer { removeTempCache(at: cache) }

        let engine = PredictionEngine(
            analyzer: MistakeSuggestionAnalyzer(spellChecker: CountingSpellChecker()),
            chunkSize: 25,
            cacheURL: cache
        )
        await engine.analyzeToCompletionForTesting(observations: entries, force: false)

        XCTAssertEqual(engine.phase, .ready)
        XCTAssertEqual(engine.analyzedCount, engine.totalCount)
        XCTAssertGreaterThan(engine.totalCount, 0)
        XCTAssertEqual(engine.cacheCountForTesting, engine.totalCount)

        // Ranked is sorted by score (desc) and bounded.
        let scores = engine.ranked.map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >))
        XCTAssertLessThanOrEqual(engine.ranked.count, 80)
        // The most frequent synthetic words bubble to the top.
        XCTAssertGreaterThan(engine.ranked.first?.count ?? 0, 1)
    }

    func test_engine_diskCache_roundTrip() async throws {
        let entries = MistakeBenchmarkData.synthetic(groupCount: 120)
        let cache = tempCacheURL()
        defer { removeTempCache(at: cache) }
        let store = MistakeObservationStore(
            testFileURL: cache.deletingLastPathComponent().appendingPathComponent("observations.jsonl")
        )
        store.replaceEntriesForTesting(entries)

        let first = PredictionEngine(
            analyzer: MistakeSuggestionAnalyzer(spellChecker: CountingSpellChecker()),
            store: store,
            cacheURL: cache
        )
        await first.analyzeToCompletionForTesting(observations: entries, force: false)
        let total = first.totalCount
        // Let the detached disk write land.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path), "cache file written")

        // A fresh engine pointed at the same cache should need zero work.
        let warmSpellChecker = CountingSpellChecker()
        let second = PredictionEngine(
            analyzer: MistakeSuggestionAnalyzer(spellChecker: warmSpellChecker),
            store: store,
            cacheURL: cache
        )
        second.domainLearningEnabled = false
        await second.bootstrapToCompletionForTesting()
        XCTAssertEqual(second.totalCount, total)
        XCTAssertEqual(second.analyzedCount, total) // all served from disk cache
        XCTAssertEqual(second.phase, .ready)
        XCTAssertEqual(
            second.actionableTargetsByObservationID,
            first.actionableTargetsByObservationID
        )
        XCTAssertEqual(warmSpellChecker.guessCalls, 0)
        XCTAssertEqual(warmSpellChecker.misspelledCalls, 0)

        await second.bootstrapToCompletionForTesting()
        XCTAssertEqual(warmSpellChecker.guessCalls, 0, "repeated bootstrap stays idempotent")
        XCTAssertEqual(warmSpellChecker.misspelledCalls, 0, "repeated bootstrap stays idempotent")
    }

    func test_engineAndMergesRuleSafetyAcrossApps() async throws {
        let entries = [
            MistakeObservation(
                issueType: .manualCorrection,
                source: "nfrj",
                suggestedTarget: "також",
                language: "en",
                bundleID: "com.example.app-a",
                confidence: 0.9
            ),
            MistakeObservation(
                issueType: .manualCorrection,
                source: "nfrj;",
                suggestedTarget: "також",
                language: "en",
                bundleID: "com.example.app-b",
                confidence: 0.9
            )
        ]
        let cache = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cache) }
        let engine = PredictionEngine(
            analyzer: MistakeSuggestionAnalyzer(spellChecker: CountingSpellChecker()),
            cacheURL: cache
        )
        engine.handledSourcesProvider = { [] }
        engine.domainLearningEnabled = false

        await engine.analyzeToCompletionForTesting(observations: entries, force: false)

        let merged = try XCTUnwrap(engine.ranked.first)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.candidates.first?.text, "також")
        XCTAssertEqual(merged.candidates.first?.canCreateCoreRule, false)
        let clusterMember = try XCTUnwrap(engine.errorClusters.first?.members.first)
        XCTAssertEqual(clusterMember.target, "також")
        XCTAssertEqual(clusterMember.isCoreRuleCreationAllowed, false)
    }

    func test_primaryTarget_prefersValidExactLayoutOverInvalidRecordedEdit() {
        let observation = MistakeObservation(
            issueType: .manualCorrection,
            source: "nfrj;",
            suggestedTarget: "nfr",
            language: "en",
            confidence: 0.9
        )
        let group = MistakeGroupData(entries: [observation])
        let candidates = [
            MistakeSuggestionCandidate(kind: .recorded, text: "nfr", confidence: 0.9),
            MistakeSuggestionCandidate(
                kind: .keyboardLayout,
                text: "також",
                confidence: 0.82,
                replacementPlan: ReplacementPlan(
                    rawSource: "nfrj;",
                    correctedCore: "також",
                    preservedLeadingPunctuation: "",
                    preservedTrailingPunctuation: "",
                    renderedReplacement: "також",
                    boundary: "",
                    interpretationReason: .layoutFullToken
                )
            )
        ]
        let engine = PredictionEngine(
            analyzer: MistakeSuggestionAnalyzer(spellChecker: CountingSpellChecker()),
            cacheURL: tempCacheURL()
        )

        XCTAssertEqual(engine.primaryTarget(for: group, candidates: candidates), "також")
    }

    // MARK: - Benchmark on real data (gated)

    func test_bench_engine_realData() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPUGA_BENCH"] == "1",
                          "set PAPUGA_BENCH=1 to run perf benchmarks")
        guard let url = MistakeBenchmarkData.realDataURL() else { throw XCTSkip("no real data") }
        let entries = MistakeBenchmarkData.loadObservations(from: url)
        let cache = tempCacheURL()
        defer { removeTempCache(at: cache) }

        let engine = PredictionEngine(
            analyzer: MistakeSuggestionAnalyzer(spellChecker: SystemSpellCheckingClient()),
            chunkSize: 40,
            cacheURL: cache
        )
        let lm = LayoutManager()
        engine.configure(layoutManager: lm)

        bench("=== PREDICTION ENGINE (real data, \(entries.count) obs) ===")
        let t0 = DispatchTime.now()
        await engine.analyzeToCompletionForTesting(observations: entries, force: false)
        let cold = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        bench(String(format: "COLD background pass: %.0f ms, groups=%d, analyzed=%d (chunked off the render path)",
                     cold, engine.totalCount, engine.analyzedCount))

        // Warm: same engine, cache populated → instant, no re-computation.
        let t1 = DispatchTime.now()
        await engine.analyzeToCompletionForTesting(observations: entries, force: false)
        let warm = Double(DispatchTime.now().uptimeNanoseconds - t1.uptimeNanoseconds) / 1_000_000
        bench(String(format: "WARM (cache hit): %.1f ms", warm))

        bench("TOP RANKED (most frequent × confident):")
        for g in engine.ranked.prefix(6) {
            bench(String(format: "  %2d×  %@ → %@  (score %.1f)",
                         g.count, g.source, g.primaryTarget ?? "—", g.score))
        }
        bench("DOMAIN LEARNING: flaggedCount=\(engine.flaggedCount), learned \(engine.domainVocabulary.count) domain words")
        bench("  sample: \(engine.domainVocabulary.sorted().prefix(18).joined(separator: ", "))")
        XCTAssertEqual(engine.phase, .ready)
        XCTAssertEqual(engine.analyzedCount, engine.totalCount)
    }
}

private struct PotentialChangeSpellChecker: SpellCheckingClient {
    func isMisspelled(_ word: String, language: String) -> Bool {
        word != "hello"
    }

    func guesses(for word: String, language: String) -> [String] {
        word == "helo" ? ["hello"] : []
    }
}
