import XCTest
@testable import papuga

@MainActor
final class PredictionEngineTests: XCTestCase {

    private func bench(_ s: String) { print("BENCH| \(s)") }

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("papuga-pred-\(UUID().uuidString).json")
    }

    // MARK: - Correctness (fast, deterministic, always runs)

    func test_engine_analyzes_and_ranks() async throws {
        let entries = MistakeBenchmarkData.synthetic(groupCount: 200)
        let cache = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cache) }

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
        defer { try? FileManager.default.removeItem(at: cache) }

        let first = PredictionEngine(
            analyzer: MistakeSuggestionAnalyzer(spellChecker: CountingSpellChecker()),
            cacheURL: cache
        )
        await first.analyzeToCompletionForTesting(observations: entries, force: false)
        let total = first.totalCount
        // Let the detached disk write land.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path), "cache file written")

        // A fresh engine pointed at the same cache should need zero work.
        let second = PredictionEngine(
            analyzer: MistakeSuggestionAnalyzer(spellChecker: CountingSpellChecker()),
            cacheURL: cache
        )
        await second.analyzeToCompletionForTesting(observations: entries, force: false)
        XCTAssertEqual(second.totalCount, total)
        XCTAssertEqual(second.analyzedCount, total) // all served from disk cache
        XCTAssertEqual(second.phase, .ready)
    }

    // MARK: - Benchmark on real data (gated)

    func test_bench_engine_realData() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPUGA_BENCH"] == "1",
                          "set PAPUGA_BENCH=1 to run perf benchmarks")
        guard let url = MistakeBenchmarkData.realDataURL() else { throw XCTSkip("no real data") }
        let entries = MistakeBenchmarkData.loadObservations(from: url)
        let cache = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cache) }

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
