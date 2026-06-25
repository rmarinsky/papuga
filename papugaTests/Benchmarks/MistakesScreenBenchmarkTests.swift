import XCTest
@testable import papuga

/// Performance benchmark for the "Помилки введення" (mistakes) screen.
///
/// Heavy tests are gated behind `PAPUGA_BENCH=1` so the normal test suite stays
/// fast and deterministic. Run the full benchmark with:
///
///   PAPUGA_BENCH=1 xcodebuild test -project papuga.xcodeproj -scheme papuga \
///     -destination 'platform=macOS' \
///     -only-testing:papugaTests/MistakesScreenBenchmarkTests
///
/// Data: by default it loads the live app's real observations from
/// `~/Library/Application Support/papuga/mistake-observations.jsonl`
/// (override with `PAPUGA_BENCH_DATA=/path`). Falls back to synthetic data.
final class MistakesScreenBenchmarkTests: XCTestCase {

    private func loadDataset() -> (entries: [MistakeObservation], source: String) {
        if let url = MistakeBenchmarkData.realDataURL() {
            let entries = MistakeBenchmarkData.loadObservations(from: url)
            if !entries.isEmpty { return (entries, "REAL(\(url.lastPathComponent))") }
        }
        return (MistakeBenchmarkData.synthetic(groupCount: 820), "SYNTHETIC(820)")
    }

    private func bench(_ line: String) { print("BENCH| \(line)") }

    // MARK: - Correctness: the extraction reproduces the real-data ground truth

    /// Validates `MistakesScreenDerivation` matches the screen's grouping on real
    /// data (independently computed offline: 819 open groups, 57 repeated).
    func test_extraction_reproducesGrouping() throws {
        guard let url = MistakeBenchmarkData.realDataURL() else {
            throw XCTSkip("no real data on this machine")
        }
        let entries = MistakeBenchmarkData.loadObservations(from: url)
        let now = Date()
        let ranged = MistakesScreenDerivation.rangedEntries(entries, range: .all, now: now)
        let groups = MistakesScreenDerivation.groups(from: ranged, filter: .all, query: "")
        let openGroups = groups.filter { $0.status == .open }
        let repeated = MistakesScreenDerivation.repeatedCount(groups)

        bench("dataset rows=\(entries.count) ranged(all)=\(ranged.count)")
        bench("groups(filter=all)=\(groups.count) openGroups=\(openGroups.count) repeated=\(repeated)")

        // Every group from the .all filter must be open (mirrors the screen).
        XCTAssertEqual(groups.count, openGroups.count)
        // Sanity vs the ~890 figure in the UI — keep this loose so it survives
        // the user typing more.
        XCTAssertGreaterThan(openGroups.count, 300)
    }

    // MARK: - Metric 1: work per render (deterministic, machine-independent)

    func test_bench_callCounts_perRender() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPUGA_BENCH"] == "1",
                          "set PAPUGA_BENCH=1 to run perf benchmarks")
        let (entries, source) = loadDataset()
        let now = Date()
        let lm = LayoutManager()
        let layouts = lm.orderedLayouts().count
        bench("=== CALL COUNTS (one full 'Усі / Увесь час' render) ===")
        bench("data=\(source) layouts=\(layouts)")

        // First render (cold analyzer cache) — as on opening the tab.
        let counter = CountingSpellChecker()
        let analyzer = MistakeSuggestionAnalyzer(spellChecker: counter)
        let m = MistakesRenderHarness.renderOnce(
            entries: entries, range: .all, filter: .all, query: "",
            analyzer: analyzer, layoutManager: lm, counter: counter, now: now
        )
        bench("RENDER #1 (cold) groups=\(m.groupCount) candidateCalls=\(m.candidateCalls) " +
              "guessCalls=\(m.guessCalls) misspelledCalls=\(m.misspelledCalls) " +
              "spellTotal=\(m.guessCalls + m.misspelledCalls)")

        // Re-render with the SAME analyzer (sheet present / scroll / save). With
        // the QW3 candidate cache these should be ~0 NSSpellChecker calls.
        let m2 = MistakesRenderHarness.renderOnce(
            entries: entries, range: .all, filter: .all, query: "",
            analyzer: analyzer, layoutManager: lm, counter: counter, now: now
        )
        bench("RENDER #2 (warm cache) candidateCalls=\(m2.candidateCalls) " +
              "guessCalls=\(m2.guessCalls) misspelledCalls=\(m2.misspelledCalls) " +
              "spellTotal=\(m2.guessCalls + m2.misspelledCalls)  ← QW3 effect")

        // With a (word,language) cache wrapping the same counter — shows how much
        // of that work is redundant and would vanish with memoization.
        let baseCounter = CountingSpellChecker()
        let caching = CachingSpellChecker(base: baseCounter)
        let analyzer2 = MistakeSuggestionAnalyzer(spellChecker: caching)
        _ = MistakesRenderHarness.renderOnce(
            entries: entries, range: .all, filter: .all, query: "",
            analyzer: analyzer2, layoutManager: lm, counter: baseCounter, now: now
        )
        let totalGuess = baseCounter.guessCalls + caching.guessHits
        let totalMis = baseCounter.misspelledCalls + caching.misspelledHits
        bench("CACHED  realGuessCalls=\(baseCounter.guessCalls)/\(totalGuess) " +
              "realMisspelledCalls=\(baseCounter.misspelledCalls)/\(totalMis) " +
              "(remainder are cache hits → 0 NSSpellChecker cost)")
        bench("CACHE HIT RATE guesses=\(percent(caching.guessHits, totalGuess)) " +
              "misspelled=\(percent(caching.misspelledHits, totalMis))")
    }

    // MARK: - Metric 2: wall-clock with the real NSSpellChecker (what the user feels)

    func test_bench_wallClock_realSpellChecker() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPUGA_BENCH"] == "1",
                          "set PAPUGA_BENCH=1 to run perf benchmarks")
        let (entries, source) = loadDataset()
        let now = Date()
        let lm = LayoutManager()
        bench("=== WALL CLOCK (real NSSpellChecker, data=\(source), layouts=\(lm.orderedLayouts().count)) ===")

        // COLD: fresh analyzer + fresh NSSpellChecker document tag (first time the
        // user opens the tab).
        let coldAnalyzer = MistakeSuggestionAnalyzer(spellChecker: SystemSpellCheckingClient())
        let cold = MistakesRenderHarness.renderOnce(
            entries: entries, range: .all, filter: .all, query: "",
            analyzer: coldAnalyzer, layoutManager: lm, counter: nil, now: now
        )
        bench(String(format: "COLD render = %.0f ms (groups=%d)", cold.wallClock * 1000, cold.groupCount))

        // WARM: reuse the analyzer (as the screen's @State does) across re-renders.
        let warmAnalyzer = MistakeSuggestionAnalyzer(spellChecker: SystemSpellCheckingClient())
        _ = MistakesRenderHarness.renderOnce(entries: entries, range: .all, filter: .all, query: "",
                                             analyzer: warmAnalyzer, layoutManager: lm, counter: nil, now: now)
        var warmTimes: [Double] = []
        for _ in 0..<5 {
            let r = MistakesRenderHarness.renderOnce(entries: entries, range: .all, filter: .all, query: "",
                                                     analyzer: warmAnalyzer, layoutManager: lm, counter: nil, now: now)
            warmTimes.append(r.wallClock * 1000)
        }
        let avg = warmTimes.reduce(0, +) / Double(warmTimes.count)
        bench(String(format: "WARM render avg = %.0f ms  (min %.0f, max %.0f over %d)",
                     avg, warmTimes.min() ?? 0, warmTimes.max() ?? 0, warmTimes.count))
        bench("NOTE: the live screen pays this on EVERY body pass (sheet present, " +
              "scroll, search keystroke, each store mutation) — not just once.")
    }

    // MARK: - Metric 3: the "create rule" save path (per-observation rewrites)

    func test_bench_savePath_markGroup() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPUGA_BENCH"] == "1",
                          "set PAPUGA_BENCH=1 to run perf benchmarks")
        let (entries, source) = loadDataset()
        let now = Date()
        let groups = MistakesScreenDerivation.groups(
            from: MistakesScreenDerivation.rangedEntries(entries, range: .all, now: now),
            filter: .all, query: ""
        )
        // The realistic action: "Створити правило" marks every observation in the
        // largest repeated group.
        guard let biggest = groups.max(by: { $0.count < $1.count }) else {
            throw XCTSkip("no groups")
        }
        let ids = biggest.observationIDs
        bench("=== SAVE PATH (mark group of \(ids.count), data=\(source), total entries=\(entries.count)) ===")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("papuga-bench-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // BEFORE: one updateStatus(for:) per id (N rewrites + N view invalidations)
        let storeA = MistakeObservationStore(testFileURL: tmp)
        storeA.replaceEntriesForTesting(entries)
        let clockA = DispatchTime.now()
        for id in ids {
            storeA.updateStatus(for: id, to: .convertedToRule)
        }
        storeA.waitForPendingWritesForTesting()
        let msA = Double(DispatchTime.now().uptimeNanoseconds - clockA.uptimeNanoseconds) / 1_000_000
        bench(String(format: "BEFORE (loop updateStatus(for:)): %.1f ms — %d full-file rewrites, %d view invalidations",
                     msA, ids.count, ids.count))

        // AFTER (QW4): one batch updateStatus(forIDs:) → 1 rewrite + 1 invalidation
        let tmpB = FileManager.default.temporaryDirectory
            .appendingPathComponent("papuga-bench-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmpB) }
        let storeB = MistakeObservationStore(testFileURL: tmpB)
        storeB.replaceEntriesForTesting(entries)
        let clockB = DispatchTime.now()
        storeB.updateStatus(forIDs: ids, to: .convertedToRule)
        storeB.waitForPendingWritesForTesting()
        let msB = Double(DispatchTime.now().uptimeNanoseconds - clockB.uptimeNanoseconds) / 1_000_000
        bench(String(format: "AFTER  (batch updateStatus(forIDs:)): %.1f ms — 1 rewrite, 1 invalidation  → %.1fx fewer disk rewrites, %.1fx fewer re-renders",
                     msB, Double(ids.count), Double(ids.count)))
        bench("NOTE: the dominant live cost is the view invalidations — each used to " +
              "re-run the full ~4.7s render; \(ids.count) → 1.")
    }

    private func percent(_ a: Int, _ b: Int) -> String {
        guard b > 0 else { return "n/a" }
        return String(format: "%.0f%%", Double(a) / Double(b) * 100)
    }
}
