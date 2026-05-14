import XCTest
@testable import papuga

final class AutoFixDecisionTests: XCTestCase {
    func test_shouldSkip_short_word() {
        // Single-char tokens are always skipped (no possible fix signal). Two-char
        // tokens are now eligible — they're handled via the dictionary path in the
        // controller rather than statistical scoring.
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("a"), .tooShort)
        XCTAssertNil(AutoFixDecision.shouldSkipWord("ab"))
        XCTAssertNil(AutoFixDecision.shouldSkipWord("abc"))
    }

    func test_shortTokenMaxLength_covers_two_and_three_char_tokens() {
        XCTAssertEqual(AutoFixDecision.shortTokenMaxLength, 3)
    }

    func test_shouldSkip_word_with_digits() {
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("test123"), .containsDigits)
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("2fast"), .containsDigits)
    }

    func test_shouldSkip_word_with_forbidden_chars() {
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("user@host"), .containsForbiddenChars)
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("https://x"), .containsForbiddenChars)
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("hostname.com"), .containsForbiddenChars)
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("#hashtag"), .containsForbiddenChars)
        XCTAssertEqual(AutoFixDecision.shouldSkipWord("$variable"), .containsForbiddenChars)
    }

    func test_shouldSkip_allows_leading_dot_for_layout_mapped_words() {
        // `.hsq` in EN layout → `.` is `ю` on Ukrainian-PC; the token maps to
        // `юрій`. Must NOT be blanket-rejected by the skip filter.
        XCTAssertNil(AutoFixDecision.shouldSkipWord(".hsq"))
        XCTAssertNil(AutoFixDecision.shouldSkipWord("path/to"))
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

    func test_isCorrectlySpelled_recognises_real_words_in_each_language() {
        // Real English words in EN — must be recognised.
        XCTAssertTrue(AutoFixDecision.isCorrectlySpelled("faster", language: "en"))
        XCTAssertTrue(AutoFixDecision.isCorrectlySpelled("hello", language: "en"))
        // Wrong-layout gibberish typed in EN layout (intent: Ukrainian word) —
        // must be flagged as misspelled in EN.
        XCTAssertFalse(AutoFixDecision.isCorrectlySpelled("ghbdsn", language: "en"))
        XCTAssertFalse(AutoFixDecision.isCorrectlySpelled("nmrybr", language: "en"))
    }

    func test_languageHint_recognises_known_layouts() {
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.Ukrainian-PC"), "uk")
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.Russian"), "ru")
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.US"), "en")
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.German"), "de")
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.UnknownLang"), "en")
    }

    // MARK: - Typo correction

    func test_levenshtein_basic_distances() {
        XCTAssertEqual(AutoFixDecision.levenshtein("", "", limit: 5), 0)
        XCTAssertEqual(AutoFixDecision.levenshtein("hello", "hello", limit: 5), 0)
        XCTAssertEqual(AutoFixDecision.levenshtein("hellp", "hello", limit: 5), 1) // substitution
        XCTAssertEqual(AutoFixDecision.levenshtein("helo", "hello", limit: 5), 1)  // insertion
        XCTAssertEqual(AutoFixDecision.levenshtein("helllo", "hello", limit: 5), 1) // deletion
        XCTAssertEqual(AutoFixDecision.levenshtein("kitten", "sitting", limit: 5), 3)
    }

    func test_levenshtein_short_circuits_when_over_limit() {
        // When the cap is exceeded, levenshtein returns limit+1 (any sentinel
        // > limit is fine — callers compare against `<= limit`).
        let result = AutoFixDecision.levenshtein("abcdef", "ghijkl", limit: 1)
        XCTAssertGreaterThan(result, 1)
    }

    func test_acceptableCorrection_rejects_big_length_changes() {
        // Suggestion that adds/removes >1 char from the candidate is rejected
        // wholesale — too easy to invent a different word.
        XCTAssertFalse(AutoFixDecision.acceptableCorrection(of: "hellp", to: "helping"))
        XCTAssertFalse(AutoFixDecision.acceptableCorrection(of: "hellp", to: "he"))
    }

    func test_acceptableCorrection_distance_caps_by_length() {
        // ≤5 chars: max 1 edit.
        XCTAssertTrue(AutoFixDecision.acceptableCorrection(of: "hellp", to: "hello"))
        XCTAssertFalse(AutoFixDecision.acceptableCorrection(of: "abcd", to: "wxyz"))
        // ≥6 chars: max 2 edits.
        XCTAssertTrue(AutoFixDecision.acceptableCorrection(of: "helllo!", to: "hello!!"))
        XCTAssertFalse(AutoFixDecision.acceptableCorrection(of: "abcdefg", to: "wxyzefg"))
    }

    func test_correctTypo_fixes_known_misspelling_in_english() {
        let result = AutoFixDecision.correctTypo(in: "hellp", language: "en")
        XCTAssertNotNil(result, "NSSpellChecker should suggest a correction for 'hellp'")
        if let result {
            XCTAssertTrue(
                AutoFixDecision.acceptableCorrection(of: "hellp", to: result),
                "Top suggestion should be near-miss to 'hellp', got '\(result)'"
            )
        }
    }

    func test_correctTypo_returns_nil_for_already_correct_word() {
        // NSSpellChecker.guesses on a correctly spelled word may return the
        // word itself or no useful alternatives — in either case the helper
        // must NOT propose a "correction" that's the same word.
        let result = AutoFixDecision.correctTypo(in: "hello", language: "en")
        if let result {
            XCTAssertNotEqual(result.lowercased(), "hello",
                              "Helper must skip suggestions equal to the input")
        }
    }

    func test_correctTypo_returns_nil_or_unacceptable_for_pure_gibberish() {
        // Random consonant cluster — either no guesses or no near-miss
        // acceptable correction. Either path is fine; what we don't want is
        // an acceptable correction popping out of nowhere.
        let result = AutoFixDecision.correctTypo(in: "qzxqzx", language: "en")
        if let result {
            XCTAssertFalse(
                AutoFixDecision.acceptableCorrection(of: "qzxqzx", to: result),
                "Gibberish should not yield an acceptable near-miss correction"
            )
        }
    }
}
