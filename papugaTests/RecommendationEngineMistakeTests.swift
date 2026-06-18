import XCTest
import Defaults
@testable import papuga

final class RecommendationEngineMistakeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Defaults[.autoFixAllowlist] = []
        Defaults[.customAutoReplaceRules] = []
        Defaults[.dismissedRecommendations] = []
    }

    override func tearDown() {
        Defaults[.autoFixAllowlist] = []
        Defaults[.customAutoReplaceRules] = []
        Defaults[.dismissedRecommendations] = []
        super.tearDown()
    }

    func test_recommendsCustomRuleFromRepeatedManualCorrections() {
        let mistakes = (0..<3).map { _ in
            MistakeObservation(
                issueType: .manualCorrection,
                source: "pomylkka",
                suggestedTarget: "pomylka",
                language: "uk",
                bundleID: "com.example.editor",
                confidence: 0.8
            )
        }

        let recommendations = RecommendationEngine.compute(
            from: [],
            mistakes: mistakes,
            allowlist: [],
            blocklist: [],
            customRules: [],
            dismissed: []
        )

        XCTAssertTrue(recommendations.contains {
            if case .createCustomRule(let source, let target, let count, _) = $0 {
                return source == "pomylkka" && target == "pomylka" && count == 3
            }
            return false
        })
    }

    func test_ignoresResolvedMistakesForRecommendations() {
        let mistakes = (0..<3).map { _ in
            MistakeObservation(
                issueType: .manualCorrection,
                status: .convertedToRule,
                source: "pomylkka",
                suggestedTarget: "pomylka",
                language: "uk",
                bundleID: nil,
                confidence: 0.8
            )
        }

        let recommendations = RecommendationEngine.compute(
            from: [],
            mistakes: mistakes,
            allowlist: [],
            blocklist: [],
            customRules: [],
            dismissed: []
        )

        XCTAssertTrue(recommendations.isEmpty)
    }

    func test_ignoresDictionaryMistakesForRecommendations() {
        let mistakes = (0..<3).map { _ in
            MistakeObservation(
                issueType: .manualCorrection,
                status: .addedToDictionary,
                source: "SwiftUI",
                suggestedTarget: "Swift",
                language: "en",
                bundleID: nil,
                confidence: 0.8
            )
        }

        let recommendations = RecommendationEngine.compute(
            from: [],
            mistakes: mistakes,
            allowlist: [],
            blocklist: [],
            customRules: [],
            dismissed: []
        )

        XCTAssertTrue(recommendations.isEmpty)
    }

    @MainActor
    func test_applyingCustomRuleRecommendationRemovesConflictingAllowlistEntry() {
        Defaults[.autoFixAllowlist] = ["pomylkka"]

        RecommendationEngine.apply(.createCustomRule(source: "pomylkka", target: "pomylka", count: 3, tier: 1))

        XCTAssertFalse(Defaults[.autoFixAllowlist].contains("pomylkka"))
        XCTAssertEqual(Defaults[.customAutoReplaceRules].map(\.source), ["pomylkka"])
        XCTAssertEqual(Defaults[.customAutoReplaceRules].map(\.target), ["pomylka"])
    }
}
