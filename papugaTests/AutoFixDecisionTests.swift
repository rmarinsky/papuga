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

    func test_shouldSuggestPhraseLayoutMistake_for_cyrillic_to_english_phrase() {
        XCTAssertTrue(AutoFixDecision.shouldSuggestPhraseLayoutMistake(
            original: "вщ цу рфму ф екфтіскшиешщт",
            candidate: "do we have a transcription",
            targetLanguage: "en",
            scoreCandidate: 0.97
        ))
    }

    func test_shouldSuggestPhraseLayoutMistake_does_not_fire_for_single_word() {
        XCTAssertFalse(AutoFixDecision.shouldSuggestPhraseLayoutMistake(
            original: "црут",
            candidate: "when",
            targetLanguage: "en",
            scoreCandidate: 0.97
        ))
    }

    func test_shouldSuggestSingleTokenLayoutMistake_for_latin_to_ukrainian_word() {
        XCTAssertTrue(AutoFixDecision.shouldSuggestSingleTokenLayoutMistake(
            original: "yjhbfkbpe.",
            candidate: "нормалізуй",
            targetLanguage: "uk",
            scoreCandidate: 0.91
        ))
    }

    func test_shouldSuggestSingleTokenLayoutMistake_for_cyrillic_to_english_word() {
        XCTAssertTrue(AutoFixDecision.shouldSuggestSingleTokenLayoutMistake(
            original: "тщкьфдшяу",
            candidate: "normalize",
            targetLanguage: "en",
            scoreCandidate: 0.91
        ))
    }

    func test_shouldSuggestSingleTokenLayoutMistake_rejects_same_script_typos() {
        XCTAssertFalse(AutoFixDecision.shouldSuggestSingleTokenLayoutMistake(
            original: "normlaize",
            candidate: "normalize",
            targetLanguage: "en",
            scoreCandidate: 0.91
        ))
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

    func test_spellingTypoGuard_suppresses_single_letter_english_typo() {
        let assessment = AutoFixDecision.spellingTypoGuardAssessment(
            original: "fster",
            candidate: "аіеук",
            language: "en",
            minWordLength: 4,
            maxEditDistance: 1,
            isKnownCorrect: { _, _ in false },
            suggestions: { _, _ in ["faster"] }
        )

        XCTAssertTrue(assessment.shouldSuppressAutoReplace)
        XCTAssertEqual(assessment.suggestion, "faster")
        XCTAssertEqual(assessment.editDistance, 1)
    }

    func test_spellingTypoGuard_suppresses_adjacent_letter_swap() {
        let assessment = AutoFixDecision.spellingTypoGuardAssessment(
            original: "wrold",
            candidate: "цкщдв",
            language: "en",
            minWordLength: 4,
            maxEditDistance: 1,
            isKnownCorrect: { _, _ in false },
            suggestions: { _, _ in ["world"] }
        )

        XCTAssertTrue(assessment.shouldSuppressAutoReplace)
        XCTAssertEqual(assessment.suggestion, "world")
        XCTAssertEqual(assessment.editDistance, 1)
    }

    func test_spellingTypoGuard_suppresses_ukrainian_typo() {
        let assessment = AutoFixDecision.spellingTypoGuardAssessment(
            original: "важлво",
            candidate: "df;kdj",
            language: "uk",
            minWordLength: 4,
            maxEditDistance: 1,
            isKnownCorrect: { _, _ in false },
            suggestions: { _, _ in ["важливо"] }
        )

        XCTAssertTrue(assessment.shouldSuppressAutoReplace)
        XCTAssertEqual(assessment.suggestion, "важливо")
        XCTAssertEqual(assessment.editDistance, 1)
    }

    func test_spellingTypoGuard_doesNotSuppress_classicWrongLayoutGibberish() {
        let assessment = AutoFixDecision.spellingTypoGuardAssessment(
            original: "ghbdsn",
            candidate: "привіт",
            language: "en",
            minWordLength: 4,
            maxEditDistance: 1,
            isKnownCorrect: { _, _ in false },
            suggestions: { _, _ in [] }
        )

        XCTAssertFalse(assessment.shouldSuppressAutoReplace)
        XCTAssertNil(assessment.suggestion)
        XCTAssertNil(assessment.editDistance)
    }

    func test_spellingTypoGuard_respects_minWordLength() {
        let defaultLengthAssessment = AutoFixDecision.spellingTypoGuardAssessment(
            original: "teh",
            candidate: "еур",
            language: "en",
            minWordLength: 4,
            maxEditDistance: 1,
            isKnownCorrect: { _, _ in false },
            suggestions: { _, _ in ["the"] }
        )
        let shorterLengthAssessment = AutoFixDecision.spellingTypoGuardAssessment(
            original: "teh",
            candidate: "еур",
            language: "en",
            minWordLength: 3,
            maxEditDistance: 1,
            isKnownCorrect: { _, _ in false },
            suggestions: { _, _ in ["the"] }
        )

        XCTAssertFalse(defaultLengthAssessment.shouldSuppressAutoReplace)
        XCTAssertTrue(shorterLengthAssessment.shouldSuppressAutoReplace)
    }

    func test_spellingTypoGuard_requires_crossScriptCandidate() {
        let assessment = AutoFixDecision.spellingTypoGuardAssessment(
            original: "fster",
            candidate: "faster",
            language: "en",
            minWordLength: 4,
            maxEditDistance: 1,
            isKnownCorrect: { _, _ in false },
            suggestions: { _, _ in ["faster"] }
        )

        XCTAssertFalse(assessment.shouldSuppressAutoReplace)
    }

    func test_languageHint_recognises_known_layouts() {
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.Ukrainian-PC"), "uk")
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.Russian"), "ru")
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.US"), "en")
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.German"), "de")
        XCTAssertEqual(AutoFixDecision.languageHintForLayoutID("com.apple.keylayout.UnknownLang"), "en")
    }
}
