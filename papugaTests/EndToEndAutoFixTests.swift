import XCTest
import Carbon.HIToolbox
@testable import papuga

/// End-to-end test that mimics what `AutoFixController` does on a word boundary:
/// take the typed word in the wrong layout, remap it via `CharacterMapper`, score
/// both candidates with the chosen algorithm, and verify the decision agrees
/// with what we expect a user would want.
final class EndToEndAutoFixTests: XCTestCase {
    private struct AutoFixCase {
        let typedInWrongLayout: String
        let expectedCorrected: String
        let fromLayoutID: String
        let toLayoutID: String
        let expectedFix: Bool
    }

    private var mapper = CharacterMapper()

    override func setUp() {
        super.setUp()
        mapper = CharacterMapper()
    }

    private func source(forID id: String) throws -> TISInputSource {
        let conditions = [kTISPropertyInputSourceID!: id as CFString] as CFDictionary
        guard let list = TISCreateInputSourceList(conditions, true)?.takeRetainedValue() as? [TISInputSource],
              let s = list.first else {
            throw XCTSkip("Input source \(id) not present on this Mac.")
        }
        return s
    }

    private func runEndToEnd(_ tc: AutoFixCase, algorithm: LanguageScorerAlgorithm) throws {
        let fromSrc = try source(forID: tc.fromLayoutID)
        let toSrc = try source(forID: tc.toLayoutID)
        mapper.buildMap(for: fromSrc, sourceID: tc.fromLayoutID)
        mapper.buildMap(for: toSrc, sourceID: tc.toLayoutID)

        let candidate = mapper.convert(text: tc.typedInWrongLayout, fromSourceID: tc.fromLayoutID, toSourceID: tc.toLayoutID)
        XCTAssertEqual(candidate.lowercased(), tc.expectedCorrected.lowercased(),
                       "Char mapping wrong for '\(tc.typedInWrongLayout)'")

        let scorer = LanguageScorerFactory.make(algorithm)
        let fromLang = AutoFixDecision.languageHintForLayoutID(tc.fromLayoutID)
        let toLang = AutoFixDecision.languageHintForLayoutID(tc.toLayoutID)
        let scoreOriginal = scorer.score(tc.typedInWrongLayout, expecting: fromLang)
        let scoreCandidate = scorer.score(candidate, expecting: toLang)

        let shouldFix = AutoFixDecision.shouldReplace(
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: 0.4
        )

        XCTAssertEqual(
            shouldFix,
            tc.expectedFix,
            "[\(algorithm.rawValue)] decision wrong for '\(tc.typedInWrongLayout)' → '\(candidate)' (scores: \(scoreOriginal) vs \(scoreCandidate))"
        )
    }

    private func rawSingleTokenDecision(
        original: String,
        candidate: String,
        fromLayoutID: String,
        toLayoutID: String,
        algorithm: LanguageScorerAlgorithm,
        threshold: Double = 0.3
    ) -> Bool {
        let scorer = LanguageScorerFactory.make(algorithm)
        let fromLang = AutoFixDecision.languageHintForLayoutID(fromLayoutID)
        let toLang = AutoFixDecision.languageHintForLayoutID(toLayoutID)
        let scoreOriginal = scorer.score(original, expecting: fromLang)
        let scoreCandidate = scorer.score(candidate, expecting: toLang)
        return AutoFixDecision.shouldReplace(
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: threshold
        )
    }

    private func guardedSingleTokenDecision(
        original: String,
        candidate: String,
        fromLayoutID: String,
        toLayoutID: String,
        algorithm: LanguageScorerAlgorithm,
        threshold: Double = 0.3
    ) -> Bool {
        let fromLang = AutoFixDecision.languageHintForLayoutID(fromLayoutID)
        if AutoFixDecision.isCorrectlySpelled(original, language: fromLang) {
            return false
        }

        let typoAssessment = AutoFixDecision.spellingTypoGuardAssessment(
            original: original,
            candidate: candidate,
            language: fromLang,
            minWordLength: 4,
            maxEditDistance: 1
        )
        if typoAssessment.shouldSuppressAutoReplace {
            return false
        }

        return rawSingleTokenDecision(
            original: original,
            candidate: candidate,
            fromLayoutID: fromLayoutID,
            toLayoutID: toLayoutID,
            algorithm: algorithm,
            threshold: threshold
        )
    }

    private static let positiveUkrainianCases: [AutoFixCase] = [
        AutoFixCase(typedInWrongLayout: ".hsq", expectedCorrected: "юрій",
                    fromLayoutID: "com.apple.keylayout.US",
                    toLayoutID: "com.apple.keylayout.Ukrainian-PC",
                    expectedFix: true),
        AutoFixCase(typedInWrongLayout: ",ed nb nen", expectedCorrected: "був ти тут",
                    fromLayoutID: "com.apple.keylayout.US",
                    toLayoutID: "com.apple.keylayout.Ukrainian-PC",
                    expectedFix: true),
        AutoFixCase(typedInWrongLayout: "ghbdsn", expectedCorrected: "привіт",
                    fromLayoutID: "com.apple.keylayout.US",
                    toLayoutID: "com.apple.keylayout.Ukrainian-PC",
                    expectedFix: true)
    ]

    private static let negativeCases: [AutoFixCase] = [
        // Multi-word English phrase — Apple NL has high confidence in EN, no fix.
        AutoFixCase(typedInWrongLayout: "hello world", expectedCorrected: "руддщ цщкдв",
                    fromLayoutID: "com.apple.keylayout.US",
                    toLayoutID: "com.apple.keylayout.Ukrainian-PC",
                    expectedFix: false)
    ]

    func test_ukrainian_positive_cases_fix_with_appleNL() throws {
        for tc in Self.positiveUkrainianCases {
            try runEndToEnd(tc, algorithm: .appleNL)
        }
    }

    func test_ukrainian_positive_cases_fix_with_ngram() throws {
        for tc in Self.positiveUkrainianCases {
            try runEndToEnd(tc, algorithm: .ngram)
        }
    }

    func test_ukrainian_positive_cases_fix_with_cld3() throws {
        for tc in Self.positiveUkrainianCases {
            try runEndToEnd(tc, algorithm: .cld3)
        }
    }

    func test_negative_cases_dont_fix_with_appleNL() throws {
        for tc in Self.negativeCases {
            try runEndToEnd(tc, algorithm: .appleNL)
        }
    }

    func test_negative_cases_dont_fix_with_ngram() throws {
        for tc in Self.negativeCases {
            try runEndToEnd(tc, algorithm: .ngram)
        }
    }

    func test_negative_cases_dont_fix_with_cld3() throws {
        for tc in Self.negativeCases {
            try runEndToEnd(tc, algorithm: .cld3)
        }
    }

    /// Documents a known limitation of the AppleNL backend: short single English words like
    /// 'world' get remapped to 'цщкдв' which AppleNL classifies as Ukrainian with very high
    /// confidence. Without a dictionary check the auto-fix WILL trigger here. This test
    /// captures that failure mode so we notice when it changes.
    func test_known_false_positive_world_remap() throws {
        let fromID = "com.apple.keylayout.US"
        let toID = "com.apple.keylayout.Ukrainian-PC"
        let fromSrc = try source(forID: fromID)
        let toSrc = try source(forID: toID)
        mapper.buildMap(for: fromSrc, sourceID: fromID)
        mapper.buildMap(for: toSrc, sourceID: toID)

        let candidate = mapper.convert(text: "world", fromSourceID: fromID, toSourceID: toID)
        XCTAssertEqual(candidate, "цщкдв")

        let scorer = AppleNLScorer()
        let scoreEN = scorer.score("world", expecting: "en")
        let scoreUK = scorer.score("цщкдв", expecting: "uk")

        XCTAssertGreaterThan(scoreUK, scoreEN, "AppleNL surprisingly favours UK for 'цщкдв' — false positive")
        XCTAssertTrue(
            AutoFixDecision.shouldReplace(scoreOriginal: scoreEN, scoreCandidate: scoreUK, threshold: 0.4),
            "Auto-fix would (incorrectly) trigger here without a dictionary check"
        )
    }

    func test_single_letter_english_typos_do_not_auto_fix_to_cyrillic() throws {
        let fromID = "com.apple.keylayout.US"
        let toID = "com.apple.keylayout.Ukrainian-PC"
        let fromSrc = try source(forID: fromID)
        let toSrc = try source(forID: toID)
        mapper.buildMap(for: fromSrc, sourceID: fromID)
        mapper.buildMap(for: toSrc, sourceID: toID)

        for original in ["fster", "wrold", "hellp"] {
            let candidate = mapper.convert(text: original, fromSourceID: fromID, toSourceID: toID)
            if original == "fster" {
                XCTAssertTrue(
                    rawSingleTokenDecision(
                        original: original,
                        candidate: candidate,
                        fromLayoutID: fromID,
                        toLayoutID: toID,
                        algorithm: .appleNL
                    ),
                    "Raw scorer should demonstrate the false-positive risk for \(original) -> \(candidate)"
                )
            }
            XCTAssertFalse(
                guardedSingleTokenDecision(
                    original: original,
                    candidate: candidate,
                    fromLayoutID: fromID,
                    toLayoutID: toID,
                    algorithm: .appleNL
                ),
                "Typo guard should block auto-fix for \(original) -> \(candidate)"
            )
        }
    }

    func test_typoGuard_does_not_block_true_wrong_layout_word() throws {
        let fromID = "com.apple.keylayout.US"
        let toID = "com.apple.keylayout.Ukrainian-PC"
        let fromSrc = try source(forID: fromID)
        let toSrc = try source(forID: toID)
        mapper.buildMap(for: fromSrc, sourceID: fromID)
        mapper.buildMap(for: toSrc, sourceID: toID)

        let original = "ghbdsn"
        let candidate = mapper.convert(text: original, fromSourceID: fromID, toSourceID: toID)
        XCTAssertEqual(candidate, "привіт")
        XCTAssertTrue(
            guardedSingleTokenDecision(
                original: original,
                candidate: candidate,
                fromLayoutID: fromID,
                toLayoutID: toID,
                algorithm: .appleNL
            )
        )
    }
}
