import XCTest
@testable import papuga

/// Locks the by-app derivation: a single merged suggestion is split into per-app rows by
/// the bundleID recorded on its observations, apps are ordered by volume, and the unknown
/// bucket sinks last.
final class AppMistakeGroupingTests: XCTestCase {

    private func obs(_ source: String, bundle: String?) -> MistakeObservation {
        MistakeObservation(issueType: .spelling, source: source, language: "en",
                           bundleID: bundle, confidence: 0.9)
    }

    func testSplitsByAppAndSortsByVolume() {
        let a1 = obs("teh", bundle: "com.apple.Safari")
        let a2 = obs("teh", bundle: "com.apple.Safari")
        let b1 = obs("teh", bundle: "com.apple.dt.Xcode")
        let group = PredictionGroup(
            id: "teh|en", source: "teh", language: "en", count: 3, lastSeen: Date(),
            candidates: [], primaryTarget: "the", observationIDs: [a1.id, a2.id, b1.id])

        let result = AppMistakeGrouping.appGroups(from: [group], observations: [a1, a2, b1])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.bundleID, "com.apple.Safari")
        XCTAssertEqual(result.first?.totalCount, 2)
        XCTAssertEqual(result.last?.bundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(result.last?.totalCount, 1)
        // Each app's row carries only that app's observation IDs.
        XCTAssertEqual(Set(result.first?.rows.first?.observationIDs ?? []), [a1.id, a2.id])
        XCTAssertEqual(result.last?.rows.first?.primaryTarget, "the")
    }

    func testNilBundleBucketSinksLast() {
        let a = obs("x", bundle: "com.app.a")
        let b = obs("x", bundle: nil)
        let g1 = PredictionGroup(id: "g1", source: "x", language: "en", count: 1, lastSeen: Date(),
                                 candidates: [], primaryTarget: "y", observationIDs: [a.id])
        let g2 = PredictionGroup(id: "g2", source: "x", language: "en", count: 1, lastSeen: Date(),
                                 candidates: [], primaryTarget: "y", observationIDs: [b.id])

        let result = AppMistakeGrouping.appGroups(from: [g1, g2], observations: [a, b])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.last?.bundleID, nil)
        XCTAssertEqual(result.first?.bundleID, "com.app.a")
    }

    func testEmptyInputYieldsEmpty() {
        XCTAssertTrue(AppMistakeGrouping.appGroups(from: [], observations: []).isEmpty)
    }
}
