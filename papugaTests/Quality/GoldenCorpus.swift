import Foundation
import XCTest

/// One labelled case from the golden corpus.
struct GoldenCase: Equatable {
    enum Verdict: String { case fix, nofix }

    let input: String
    let language: String
    /// The correction, for `.fix` cases. `nil` for `.nofix`.
    let expected: String?
    let verdict: Verdict
    let bucket: String
    let line: Int

    var describedLocation: String { "\(bucket).tsv:\(line)" }
}

/// Loads the committed TSV corpus.
///
/// Resolved from `#filePath` rather than a bundle: these are plain source
/// fixtures, and relying on the synchronized-group resource copy would make
/// "the file silently was not bundled" look identical to "the bucket passed".
enum GoldenCorpus {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)          // .../papugaTests/Quality/GoldenCorpus.swift
            .deletingLastPathComponent()          // .../papugaTests/Quality
            .deletingLastPathComponent()          // .../papugaTests
            .appendingPathComponent("Fixtures/golden")
    }

    static let allBuckets = [
        "apostrophe",
        "common_uk",
        "common_en",
        "jargon",
        "russian_contamination",
        "spelling_en",
        "spelling_uk"
    ]

    static func load(_ bucket: String) throws -> [GoldenCase] {
        let url = directory.appendingPathComponent("\(bucket).tsv")
        let text = try String(contentsOf: url, encoding: .utf8)

        var cases: [GoldenCase] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let columns = line.components(separatedBy: "\t")
            guard columns.count == 4 else {
                throw GoldenCorpusError.malformed(
                    "\(bucket).tsv:\(index + 1) has \(columns.count) columns, expected 4 (tab-separated)"
                )
            }
            guard let verdict = GoldenCase.Verdict(rawValue: columns[3]) else {
                throw GoldenCorpusError.malformed(
                    "\(bucket).tsv:\(index + 1) unknown verdict '\(columns[3])'"
                )
            }
            let expected = columns[2] == "-" ? nil : columns[2]
            guard verdict == .nofix || expected != nil else {
                throw GoldenCorpusError.malformed(
                    "\(bucket).tsv:\(index + 1) is a `fix` case with no expected correction"
                )
            }
            cases.append(GoldenCase(
                input: columns[0],
                language: columns[1],
                expected: expected,
                verdict: verdict,
                bucket: bucket,
                line: index + 1
            ))
        }
        return cases
    }

    enum GoldenCorpusError: Error, CustomStringConvertible {
        case malformed(String)
        var description: String {
            switch self {
            case .malformed(let detail): return "Golden corpus: \(detail)"
            }
        }
    }
}

/// Per-bucket quality numbers.
///
/// `coverage` is deliberately separate from `top1`: the fail-closed gate used
/// to turn "wrong answer" into "no answer", and a single accuracy number hides
/// that difference entirely.
struct QualityReport: Equatable {
    var bucket: String
    var fixCases = 0
    var nofixCases = 0
    var covered = 0          // a `fix` case that produced the expected text anywhere
    var top1Hits = 0
    var top3Hits = 0
    var reciprocalRankSum = 0.0
    var falsePositives = 0   // a `nofix` case that got flagged

    var coverage: Double { fixCases == 0 ? 1 : Double(covered) / Double(fixCases) }
    var top1: Double { fixCases == 0 ? 1 : Double(top1Hits) / Double(fixCases) }
    var top3: Double { fixCases == 0 ? 1 : Double(top3Hits) / Double(fixCases) }
    var mrr: Double { fixCases == 0 ? 1 : reciprocalRankSum / Double(fixCases) }
    var fpRate: Double { nofixCases == 0 ? 0 : Double(falsePositives) / Double(nofixCases) }

    mutating func record(rankOfExpected rank: Int?) {
        fixCases += 1
        guard let rank else { return }
        covered += 1
        if rank == 1 { top1Hits += 1 }
        if rank <= 3 { top3Hits += 1 }
        reciprocalRankSum += 1.0 / Double(rank)
    }

    mutating func record(flagged: Bool) {
        nofixCases += 1
        if flagged { falsePositives += 1 }
    }

    /// A bucket with no `fix` cases has no ranking to report, and one with no
    /// `nofix` cases has no false-positive rate. Printing those as a perfect
    /// 1.00 / 0.00 reads as a pass; print them as "----" instead.
    var summaryLine: String {
        func column(_ label: String, _ value: Double, meaningful: Bool) -> String {
            meaningful ? String(format: "%@=%.2f", label, value) : "\(label)=----"
        }
        let ranking = fixCases > 0
        let flagging = nofixCases > 0
        return [
            bucket.padding(toLength: 22, withPad: " ", startingAt: 0),
            column("top1", top1, meaningful: ranking),
            column("top3", top3, meaningful: ranking),
            column("mrr", mrr, meaningful: ranking),
            column("coverage", coverage, meaningful: ranking),
            column("fpRate", fpRate, meaningful: flagging),
            "(\(fixCases) fix / \(nofixCases) nofix)"
        ].joined(separator: " ")
    }
}

/// Committed floors. The suite fails below them and prints a replacement block
/// when it beats them, so gains get locked in rather than quietly reclaimed.
struct QualityThresholds: Codable {
    struct Bucket: Codable {
        var minTop1: Double
        var minCoverage: Double
        var maxFPRate: Double
    }

    var buckets: [String: Bucket]

    static var url: URL {
        GoldenCorpus.directory.appendingPathComponent("thresholds.json")
    }

    static func load() throws -> QualityThresholds {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(QualityThresholds.self, from: data)
    }
}
