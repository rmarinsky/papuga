import XCTest
@testable import papuga

final class CorrectionKnowledgeMigrationTests: XCTestCase {
    func test_normalizesAllowlistAndQuarantinesPunctuationTargets() {
        let safeRule = CustomAutoReplaceRule(source: "можі,", target: "може")
        let unsafeRule = CustomAutoReplaceRule(source: "pvth;fd", target: "змержав,")
        let ambiguousLayoutRule = CustomAutoReplaceRule(source: "nfrj;", target: "також")

        let result = CorrectionKnowledgePunctuationMigration.prepare(
            allowlist: ["yoy,", "YOY", "saas?", " saas "],
            rules: [safeRule, unsafeRule, ambiguousLayoutRule],
            alreadyQuarantined: []
        )

        XCTAssertEqual(result.allowlist, ["yoy", "saas"])
        XCTAssertEqual(result.activeRules.map(\.source), ["можі"])
        XCTAssertEqual(result.activeRules.map(\.target), ["може"])
        XCTAssertEqual(result.quarantinedRules, [unsafeRule, ambiguousLayoutRule])
    }
}
