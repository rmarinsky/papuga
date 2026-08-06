import XCTest
@testable import papuga

/// Measures suggestion quality against the committed golden corpus.
///
/// This exists because nothing did. Before it, no test asserted "for input X
/// the top candidate is Y", nothing measured the false-positive rate, and
/// `HybridSpellChecker.production` — the shipping path — was exercised by no
/// test at all, since every candidate test injected a fake. That is how the
/// spelling authority could be inverted without a single failure.
///
/// Deliberately runs against the **real** bundled lists and the **real** system
/// dictionary. Language buckets skip loudly when macOS lacks that dictionary;
/// a silently-empty suite is worse than no suite.
final class PredictionQualityTests: XCTestCase {

    private var checker: HybridSpellChecker!
    private var analyzer: MistakeSuggestionAnalyzer!

    override func setUp() {
        super.setUp()
        checker = HybridSpellChecker.production
        waitForFrequencyIndexes()
        analyzer = MistakeSuggestionAnalyzer(spellChecker: checker)
    }

    /// `production` builds its indexes on a utility queue. Measuring before
    /// they land would sample a different system than the one that ships and
    /// make the numbers depend on machine speed.
    private func waitForFrequencyIndexes() {
        let deadline = Date().addingTimeInterval(20)
        while checker.indexedLanguages.count < 2, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            checker.indexedLanguages.isSuperset(of: ["uk", "en"]),
            "frequency indexes never loaded — quality numbers would be meaningless"
        )
    }

    // MARK: - Corpus hygiene (never skipped)

    func test_corpusParsesAndIsNotEmpty() throws {
        var total = 0
        for bucket in GoldenCorpus.allBuckets {
            let cases = try GoldenCorpus.load(bucket)
            XCTAssertFalse(cases.isEmpty, "\(bucket).tsv is empty")
            total += cases.count
        }
        XCTAssertGreaterThan(total, 60, "corpus is too small to mean anything")
    }

    func test_everyBucketHasAThreshold() throws {
        let thresholds = try QualityThresholds.load()
        for bucket in GoldenCorpus.allBuckets {
            XCTAssertNotNil(
                thresholds.buckets[bucket],
                "\(bucket) has no floor in thresholds.json — it would never fail"
            )
        }
    }

    // MARK: - The measurement

    func test_qualityMeetsCommittedFloors() throws {
        let thresholds = try QualityThresholds.load()
        var reports: [QualityReport] = []
        var skipped: [String] = []

        for bucket in GoldenCorpus.allBuckets {
            let cases = try GoldenCorpus.load(bucket)
            guard let language = cases.first?.language else { continue }
            guard HybridSpellChecker.systemSupports(language) else {
                skipped.append("\(bucket) (no '\(language)' dictionary on this machine)")
                continue
            }
            reports.append(evaluate(cases, bucket: bucket))
        }

        printReport(reports, skipped: skipped, thresholds: thresholds)

        for report in reports {
            guard let floor = thresholds.buckets[report.bucket] else { continue }
            XCTAssertGreaterThanOrEqual(
                report.top1, floor.minTop1 - Self.tolerance,
                "\(report.bucket): top1 regressed to \(fmt(report.top1)), floor \(fmt(floor.minTop1))"
            )
            XCTAssertGreaterThanOrEqual(
                report.coverage, floor.minCoverage - Self.tolerance,
                "\(report.bucket): coverage regressed to \(fmt(report.coverage)), floor \(fmt(floor.minCoverage))"
            )
            XCTAssertLessThanOrEqual(
                report.fpRate, floor.maxFPRate + Self.tolerance,
                "\(report.bucket): false positives rose to \(fmt(report.fpRate)), ceiling \(fmt(floor.maxFPRate))"
            )
        }

        if !skipped.isEmpty {
            print("⚠️  SKIPPED BUCKETS — these numbers cover only part of the corpus:")
            skipped.forEach { print("     - \($0)") }
        }
    }

    // MARK: - Evaluation

    private static let tolerance = 0.0001

    private func evaluate(_ cases: [GoldenCase], bucket: String) -> QualityReport {
        var report = QualityReport(bucket: bucket)
        for testCase in cases {
            switch testCase.verdict {
            case .nofix:
                report.record(flagged: isFlaggedAsMistake(testCase))
            case .fix:
                report.record(rankOfExpected: rankOfExpectedCandidate(testCase))
            }
        }
        return report
    }

    /// Would this word be treated as a mistake at all? This is the gate that
    /// decides whether a correctly-typed word turns into an observation, and
    /// therefore the honest definition of a false positive.
    private func isFlaggedAsMistake(_ testCase: GoldenCase) -> Bool {
        checker.isMisspelled(testCase.input, language: testCase.language)
    }

    /// 1-based rank of the expected correction among the surfaced candidates,
    /// or nil when it was never offered.
    private func rankOfExpectedCandidate(_ testCase: GoldenCase) -> Int? {
        guard let expected = testCase.expected else { return nil }
        let candidates = analyzer.candidates(
            forRawSources: [testCase.input],
            language: testCase.language,
            limit: 6
        )
        let normalizedExpected = MistakeObservation.normalizedToken(expected)
        let index = candidates.firstIndex {
            MistakeObservation.normalizedToken($0.text) == normalizedExpected
        }
        return index.map { $0 + 1 }
    }

    // MARK: - Reporting

    private func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

    /// Prints the table plus, when everything clears its floor, a
    /// copy-pasteable replacement block so gains get ratcheted in.
    private func printReport(
        _ reports: [QualityReport],
        skipped: [String],
        thresholds: QualityThresholds
    ) {
        print("\n=== Prediction quality ===")
        reports.forEach { print("  " + $0.summaryLine) }

        let improved = reports.filter { report in
            guard let floor = thresholds.buckets[report.bucket] else { return false }
            return report.top1 > floor.minTop1 + Self.tolerance
                || report.coverage > floor.minCoverage + Self.tolerance
                || report.fpRate < floor.maxFPRate - Self.tolerance
        }
        guard !improved.isEmpty else { return }

        print("\n📈 Beat the floors. Replace the \"buckets\" object in thresholds.json:")
        var merged = thresholds.buckets
        for report in reports {
            guard let floor = merged[report.bucket] else { continue }
            merged[report.bucket] = QualityThresholds.Bucket(
                // A bucket with no cases of a kind has no meaningful number
                // there, so never ratchet a vacuous 1.00 / 0.00 into a floor.
                minTop1: report.fixCases > 0 ? max(floor.minTop1, report.top1) : floor.minTop1,
                minCoverage: report.fixCases > 0
                    ? max(floor.minCoverage, report.coverage) : floor.minCoverage,
                maxFPRate: report.nofixCases > 0
                    ? min(floor.maxFPRate, report.fpRate) : floor.maxFPRate
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Encode only the buckets — the file's explanatory `_comment` is not
        // part of the model and must survive the paste.
        if let data = try? encoder.encode(merged),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }
}
