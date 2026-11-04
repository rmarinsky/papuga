import AppKit
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

    @MainActor
    func test_addPersistsAllowlistEntryExactlyOnce() {
        let first = IgnoreWordService.add("ghbdtn", teachAppleSpelling: false)
        let second = IgnoreWordService.add("GHBDTN", teachAppleSpelling: false)

        XCTAssertEqual(first?.addedToAllowlist, true)
        XCTAssertEqual(second?.addedToAllowlist, false)
        XCTAssertEqual(Defaults[.autoFixAllowlist], ["ghbdtn"])
    }

    /// Removing a word must never unlearn a spelling the user taught macOS
    /// themselves — only what Papuga taught is Papuga's to take back.
    @MainActor
    func test_removeLeavesUserLearnedSystemSpellingAlone() {
        let word = "papugatestqzxv"
        let checker = NSSpellChecker.shared
        let savedTaught = Defaults[.papugaTaughtSpellings]
        defer {
            checker.unlearnWord(word)
            Defaults[.papugaTaughtSpellings] = savedTaught
        }
        Defaults[.papugaTaughtSpellings] = []
        checker.learnWord(word)
        Defaults[.autoFixAllowlist] = [word]

        XCTAssertTrue(IgnoreWordService.remove(word))

        XCTAssertTrue(checker.hasLearnedWord(word))
        XCTAssertEqual(Defaults[.autoFixAllowlist], [])
    }

    @MainActor
    func test_removeUnlearnsOnlyWhatPapugaTaught() {
        let word = "papugatestqzxw"
        let checker = NSSpellChecker.shared
        let savedTaught = Defaults[.papugaTaughtSpellings]
        defer {
            checker.unlearnWord(word)
            Defaults[.papugaTaughtSpellings] = savedTaught
        }
        Defaults[.papugaTaughtSpellings] = []

        XCTAssertEqual(IgnoreWordService.add(word)?.taughtAppleSpelling, true)
        XCTAssertEqual(Defaults[.papugaTaughtSpellings], [word])

        XCTAssertTrue(IgnoreWordService.remove(word))

        XCTAssertFalse(checker.hasLearnedWord(word))
        XCTAssertEqual(Defaults[.papugaTaughtSpellings], [])
    }
}
