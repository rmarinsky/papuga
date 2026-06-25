import Foundation
@testable import papuga

// MARK: - Spell-checker doubles

/// A `SpellCheckingClient` that counts every call. Deterministic, zero I/O —
/// used to measure the *amount of work* one screen render triggers (the primary,
/// machine-independent metric). Optionally wraps a real checker so we can also
/// see how often the cache (once added) would hit.
final class CountingSpellChecker: SpellCheckingClient {
    private(set) var guessCalls = 0
    private(set) var misspelledCalls = 0
    private(set) var distinctGuessWords = Set<String>()
    private(set) var distinctMisspelledWords = Set<String>()

    func reset() {
        guessCalls = 0
        misspelledCalls = 0
        distinctGuessWords.removeAll(keepingCapacity: true)
        distinctMisspelledWords.removeAll(keepingCapacity: true)
    }

    func isMisspelled(_ word: String, language: String) -> Bool {
        misspelledCalls += 1
        distinctMisspelledWords.insert("\(language):\(word.lowercased())")
        // Deterministic: half the words "look correct" so the layout path keeps
        // exploring candidates the way the real checker would.
        return word.count % 2 == 0
    }

    func guesses(for word: String, language: String) -> [String] {
        guessCalls += 1
        distinctGuessWords.insert("\(language):\(word.lowercased())")
        guard word.count > 1 else { return [] }
        // A few deterministic variants so the spelling-confidence Levenshtein
        // work (and de-dup) runs as it would in production.
        return [
            String(word.dropLast()) + "о",
            word + "и",
            word.capitalized,
        ]
    }
}

/// Caching decorator. Demonstrates the (word, language) cache that the
/// optimization phase will fold into the analyzer. Wrapping any other client
/// lets the benchmark measure the cache hit-rate on real data.
final class CachingSpellChecker: SpellCheckingClient {
    private let base: SpellCheckingClient
    private var misspelledCache: [String: Bool] = [:]
    private var guessCache: [String: [String]] = [:]
    private(set) var misspelledHits = 0
    private(set) var guessHits = 0

    init(base: SpellCheckingClient) { self.base = base }

    func isMisspelled(_ word: String, language: String) -> Bool {
        let key = "\(language)\u{1}\(word)"
        if let cached = misspelledCache[key] { misspelledHits += 1; return cached }
        let value = base.isMisspelled(word, language: language)
        misspelledCache[key] = value
        return value
    }

    func guesses(for word: String, language: String) -> [String] {
        let key = "\(language)\u{1}\(word)"
        if let cached = guessCache[key] { guessHits += 1; return cached }
        let value = base.guesses(for: word, language: language)
        guessCache[key] = value
        return value
    }
}

// MARK: - Real-data loader (privacy-safe: read at runtime, never committed)

enum MistakeBenchmarkData {
    /// Resolves the dataset path. Honors `PAPUGA_BENCH_DATA`, else the live
    /// app's Application Support file. Returns nil if neither exists.
    static func realDataURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["PAPUGA_BENCH_DATA"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport
            .appendingPathComponent("papuga", isDirectory: true)
            .appendingPathComponent("mistake-observations.jsonl")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func loadObservations(from url: URL) -> [MistakeObservation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [MistakeObservation] = []
        result.reserveCapacity(2048)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(MistakeObservation.self, from: lineData) else { continue }
            result.append(entry)
        }
        return result
    }

    /// Synthetic fallback (~`groupCount` distinct open words, heavy-tailed
    /// repetition) so the benchmark still runs on machines without real data.
    static func synthetic(groupCount: Int) -> [MistakeObservation] {
        let langs = ["uk", "uk", "uk", "uk", "en"] // ~80/20 like real usage
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var out: [MistakeObservation] = []
        out.reserveCapacity(groupCount + groupCount / 8)
        for i in 0..<groupCount {
            let lang = langs[i % langs.count]
            let word = "слово\(i)\(lang)"
            let target = i % 3 == 0 ? "ціль\(i)" : nil
            // Heavy tail: a few words repeat several times.
            let repeats = i < groupCount / 20 ? (3 + (i % 5)) : 1
            for r in 0..<repeats {
                out.append(MistakeObservation(
                    timestamp: base.addingTimeInterval(Double(i * 60 + r)),
                    issueType: .spelling,
                    source: word,
                    suggestedTarget: target,
                    language: lang,
                    bundleID: "com.example.app\(i % 7)",
                    confidence: 0.6
                ))
            }
        }
        return out
    }
}

// MARK: - Render-cost model (mirrors one MistakesView render exactly)

struct RenderMetrics {
    var groupCount = 0
    var openGroupCount = 0
    var candidateCalls = 0      // analyzer.candidates(...) invocations
    var guessCalls = 0
    var misspelledCalls = 0
    var wallClock: TimeInterval = 0
}

enum MistakesRenderHarness {
    /// Reproduces the work a single `MistakesView` body evaluation performs:
    /// derive groups, then compute candidates for **every** group (the non-lazy
    /// `VStack` builds all rows), plus the top-5 "Поради" cards which compute
    /// candidates + primaryTarget (a second candidates() call) per item.
    @discardableResult
    static func renderOnce(
        entries: [MistakeObservation],
        range: HistoryTimeRange,
        filter: MistakesFilter,
        query: String,
        analyzer: MistakeSuggestionAnalyzer,
        layoutManager: LayoutManager?,
        counter: CountingSpellChecker? = nil,
        now: Date
    ) -> RenderMetrics {
        var m = RenderMetrics()
        let startGuess = counter?.guessCalls ?? 0
        let startMis = counter?.misspelledCalls ?? 0
        let clock = DispatchTime.now()

        let ranged = MistakesScreenDerivation.rangedEntries(entries, range: range, now: now)
        let groups = MistakesScreenDerivation.groups(from: ranged, filter: filter, query: query)
        m.groupCount = groups.count
        m.openGroupCount = groups.filter { $0.status == .open }.count

        // content: every group row computes candidates once
        for g in groups {
            _ = MistakesScreenDerivation.candidates(for: g, analyzer: analyzer, layoutManager: layoutManager)
            m.candidateCalls += 1
        }
        // "Поради": top-5 -> candidates + primaryTarget (primaryTarget calls candidates again)
        for g in MistakesScreenDerivation.suggestionGroups(groups) {
            _ = MistakesScreenDerivation.candidates(for: g, analyzer: analyzer, layoutManager: layoutManager)
            _ = MistakesScreenDerivation.primaryTarget(for: g, analyzer: analyzer, layoutManager: layoutManager)
            m.candidateCalls += 2
        }
        // header counts (cheap, but mirror the work)
        _ = MistakesScreenDerivation.openCount(ranged)
        _ = MistakesScreenDerivation.repeatedCount(groups)
        _ = MistakesScreenDerivation.convertedCount(ranged)
        _ = MistakesScreenDerivation.ignoredCount(ranged)

        m.wallClock = Double(DispatchTime.now().uptimeNanoseconds - clock.uptimeNanoseconds) / 1_000_000_000
        m.guessCalls = (counter?.guessCalls ?? 0) - startGuess
        m.misspelledCalls = (counter?.misspelledCalls ?? 0) - startMis
        return m
    }
}
