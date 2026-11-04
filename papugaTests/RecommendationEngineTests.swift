import XCTest
import Defaults
@testable import papuga

final class RecommendationEngineTests: XCTestCase {
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

    func test_undoingALayoutFixNeverOffersToAllowlistTheMistake() {
        // "nfr" → "так": undoing three times used to surface "Папуга більше не
        // чіпатиме це слово", and one click made "так" permanently unfixable.
        let history = (0..<3).map { _ in
            ReplacementHistoryEntry(kind: .autoFixUndone, original: "nfr", converted: "так")
        }

        let recommendations = RecommendationEngine.compute(
            from: history,
            allowlist: [],
            blocklist: [],
            customRules: [],
            dismissed: [],
            convertedIsRealWord: { $0 == "так" }
        )

        XCTAssertFalse(recommendations.contains {
            if case .addWordToAllowlist = $0 { return true }
            return false
        })
    }

    func test_undoingAConversionIntoGibberishStillOffersTheAllowlist() {
        // "npx" → "тзч" is not a word: the user really does type "npx", so the
        // escape hatch stays.
        let history = (0..<3).map { _ in
            ReplacementHistoryEntry(kind: .autoFixUndone, original: "npx", converted: "тзч")
        }

        let recommendations = RecommendationEngine.compute(
            from: history,
            allowlist: [],
            blocklist: [],
            customRules: [],
            dismissed: [],
            convertedIsRealWord: { _ in false }
        )

        XCTAssertTrue(recommendations.contains {
            if case .addWordToAllowlist(let word, _, _) = $0 { return word == "npx" }
            return false
        })
    }

    @MainActor
    func test_applyingCustomRuleRecommendationRemovesConflictingAllowlistEntry() {
        Defaults[.autoFixAllowlist] = ["pomylkka"]

        RecommendationEngine.apply(.createCustomRule(
            source: "pomylkka",
            target: "pomylka",
            count: 3,
            tier: 1,
            canCreateCoreRule: true
        ))

        XCTAssertFalse(Defaults[.autoFixAllowlist].contains("pomylkka"))
        XCTAssertEqual(Defaults[.customAutoReplaceRules].map(\.source), ["pomylkka"])
        XCTAssertEqual(Defaults[.customAutoReplaceRules].map(\.target), ["pomylka"])
    }

    @MainActor
    func test_applyingRecommendationStoresCoreSourceAndTargetOnly() {
        Defaults[.autoFixAllowlist] = ["можі?", "other"]

        RecommendationEngine.apply(.createCustomRule(
            source: "“можі?”",
            target: "може,",
            count: 3,
            tier: 1,
            canCreateCoreRule: true
        ))

        XCTAssertEqual(Defaults[.autoFixAllowlist], ["other"])
        XCTAssertEqual(Defaults[.customAutoReplaceRules].map(\.source), ["можі"])
        XCTAssertEqual(Defaults[.customAutoReplaceRules].map(\.target), ["може"])
    }

    func test_doesNotRecommendCoreRuleForEdgeBearingManualLayoutSwitch() {
        let history = (0..<3).map { _ in
            ReplacementHistoryEntry(
                kind: .manualSwitch,
                original: "nfrj;",
                converted: "також",
                sourceLayoutID: "com.apple.keylayout.US",
                targetLayoutID: "com.apple.keylayout.Ukrainian-PC"
            )
        }

        let recommendations = RecommendationEngine.compute(
            from: history,
            allowlist: [],
            blocklist: [],
            customRules: [],
            dismissed: []
        )

        XCTAssertFalse(recommendations.contains {
            if case .createCustomRule = $0 { return true }
            return false
        })
    }

    @MainActor
    func test_applyRejectsRecommendationMarkedUnsafeForCoreRule() {
        RecommendationEngine.apply(.createCustomRule(
            source: "nfrj",
            target: "також",
            count: 3,
            tier: 1,
            canCreateCoreRule: false
        ))

        XCTAssertTrue(Defaults[.customAutoReplaceRules].isEmpty)
    }
}
