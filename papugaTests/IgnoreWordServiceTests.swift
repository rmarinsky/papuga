import XCTest
import Defaults
@testable import papuga

final class IgnoreWordServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Defaults[.autoFixAllowlist] = []
        Defaults[.customAutoReplaceRules] = []
    }

    override func tearDown() {
        Defaults[.autoFixAllowlist] = []
        Defaults[.customAutoReplaceRules] = []
        super.tearDown()
    }

    func test_shouldTeachAppleSpelling_acceptsWordLikeTerms() {
        XCTAssertTrue(IgnoreWordService.shouldTeachAppleSpelling("Payoneer"))
        XCTAssertTrue(IgnoreWordService.shouldTeachAppleSpelling("GitHub"))
        XCTAssertTrue(IgnoreWordService.shouldTeachAppleSpelling("API"))
        XCTAssertTrue(IgnoreWordService.shouldTeachAppleSpelling("SwiftUI"))
    }

    func test_shouldTeachAppleSpelling_rejectsDomainsEmailsAndPaths() {
        XCTAssertFalse(IgnoreWordService.shouldTeachAppleSpelling("payoneer.com"))
        XCTAssertFalse(IgnoreWordService.shouldTeachAppleSpelling("roman@payoneer.com"))
        XCTAssertFalse(IgnoreWordService.shouldTeachAppleSpelling("https://github.com"))
        XCTAssertFalse(IgnoreWordService.shouldTeachAppleSpelling("~/src/App.swift"))
    }

    func test_normalizedWord_trimsEdgePunctuation() {
        XCTAssertEqual(IgnoreWordService.normalizedWord(" “Payoneer,” "), "Payoneer")
    }

    @MainActor
    func test_addRemovesConflictingReplacementRule() {
        Defaults[.customAutoReplaceRules] = [
            CustomAutoReplaceRule(source: "ghbdtn", target: "привіт"),
            CustomAutoReplaceRule(source: "zfrbq", target: "який")
        ]

        let result = IgnoreWordService.add("ghbdtn", teachAppleSpelling: false)

        XCTAssertEqual(result?.word, "ghbdtn")
        XCTAssertEqual(result?.removedReplacementRuleCount, 1)
        XCTAssertEqual(Defaults[.autoFixAllowlist], ["ghbdtn"])
        XCTAssertEqual(Defaults[.customAutoReplaceRules].map(\.source), ["zfrbq"])
    }
}
