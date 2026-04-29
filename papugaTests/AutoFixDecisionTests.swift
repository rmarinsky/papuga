import XCTest
@testable import papuga

final class AutoFixDecisionTests: XCTestCase {
    func test_shouldSkip_short_word() {
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("a"), .tooShort)
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("ab"), .tooShort)
        XCTAssertNil(AutoFixDecision.shouldSkipWord("abc"))
    }

    func test_shouldSkip_word_with_digits() {
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("test123"), .containsDigits)
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("2fast"), .containsDigits)
    }

    func test_shouldSkip_word_with_forbidden_chars() {
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("user@host"), .containsForbiddenChars)
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("path/to/file"), .containsForbiddenChars)
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("hostname.com"), .containsForbiddenChars)
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("#hashtag"), .containsForbiddenChars)
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("$variable"), .containsForbiddenChars)
    }

    func test_shouldSkip_passes_normal_words() {
        XCTAssertNil(AutoFixDecision.shouldSkipWord("hello"))
        XCTAssertNil(AutoFixDecision.shouldSkipWord("привіт"))
        XCTAssertNil(AutoFixDecision.shouldSkipWord("юрій"))
    }

    func test_shouldReplace_only_when_margin_met() {
        XCTAssertTrue(AutoFixDecision.shouldReplace(scoreOriginal: 0.1, scoreCandidate: 0.6, threshold: 0.4))
        XCTAssertTrue(AutoFixDecision.shouldReplace(scoreOriginal: 0.0, scoreCandidate: 0.4, threshold: 0.4))
        XCTAssertFalse(AutoFixDecision.shouldReplace(scoreOriginal: 0.5, scoreCandidate: 0.6, threshold: 0.4))
        XCTAssertFalse(AutoFixDecision.shouldReplace(scoreOriginal: 0.6, scoreCandidate: 0.5, threshold: 0.0))
    }

    func test_isWordBoundary_for_whitespace_keycodes() {
        XCTAssertTrue(AutoFixDecision.isWordBoundary(keyCode: 0x31, typedString: " "))   // space
        XCTAssertTrue(AutoFixDecision.isWordBoundary(keyCode: 0x24, typedString: "\n"))  // return
        XCTAssertTrue(AutoFixDecision.isWordBoundary(keyCode: 0x30, typedString: "\t"))  // tab
    }

    func test_isWordBoundary_false_for_punctuation() {
        // Punctuation is NOT a boundary because it's layout-dependent: ';' on US is
        // 'ж' on Ukrainian-PC, ',' on US is 'б' on Russian, etc. Treating it as
        // boundary prematurely flushes the buffer mid-word.
        XCTAssertFalse(AutoFixDecision.isWordBoundary(keyCode: 0x2F, typedString: "."))
        XCTAssertFalse(AutoFixDecision.isWordBoundary(keyCode: 0x2B, typedString: ","))
        XCTAssertFalse(AutoFixDecision.isWordBoundary(keyCode: 0x29, typedString: ";"))
        XCTAssertFalse(AutoFixDecision.isWordBoundary(keyCode: 0x21, typedString: ":"))
        XCTAssertFalse(AutoFixDecision.isWordBoundary(keyCode: 0x2C, typedString: "?"))
    }

    func test_isWordBoundary_false_for_letters() {
        XCTAssertFalse(AutoFixDecision.isWordBoundary(keyCode: 0x00, typedString: "a"))
        XCTAssertFalse(AutoFixDecision.isWordBoundary(keyCode: 0x0E, typedString: "ы"))
    }

    func test_isInAllowlist_case_insensitive() {
        let allowlist = ["Foo", "лето", "MyVar"]
        XCTAssertTrue(AutoFixDecision.isInAllowlist("foo", allowlist: allowlist))
        XCTAssertTrue(AutoFixDecision.isInAllowlist("FOO", allowlist: allowlist))
        XCTAssertTrue(AutoFixDecision.isInAllowlist("Лето", allowlist: allowlist))
        XCTAssertTrue(AutoFixDecision.isInAllowlist("myvar", allowlist: allowlist))
        XCTAssertFalse(AutoFixDecision.isInAllowlist("bar", allowlist: allowlist))
        XCTAssertFalse(AutoFixDecision.isInAllowlist("foo ", allowlist: allowlist))
    }

    func test_isInAllowlist_empty_list() {
        XCTAssertFalse(AutoFixDecision.isInAllowlist("anything", allowlist: []))
    }

    func test_languageHint_recognises_known_layouts() {
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.Ukrainian-PC"), "uk")
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.Russian"), "ru")
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.US"), "en")
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.German"), "de")
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.UnknownLang"), "en")
    }
}
