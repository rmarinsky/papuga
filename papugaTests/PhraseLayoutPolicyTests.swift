import XCTest
@testable import papuga

final class PhraseLayoutPolicyTests: XCTestCase {
    func test_acceptsOnlyUnanimousLayoutDirection() {
        let assessments: [PhraseTokenAssessment] = [
            .layoutCandidate(targetLayoutID: "uk"),
            .layoutCandidate(targetLayoutID: "uk"),
            .layoutCandidate(targetLayoutID: "uk")
        ]

        XCTAssertEqual(PhraseLayoutPolicy.unanimousTarget(in: assessments), "uk")
    }

    func test_validOrSpellingTokenVetoesWholePhraseConversion() {
        let yoyMargeTo: [PhraseTokenAssessment] = [
            .keep,
            .spellingCandidate("merge"),
            .keep
        ]
        XCTAssertNil(PhraseLayoutPolicy.unanimousTarget(in: yoyMargeTo))
    }

    func test_ambiguousOrMixedDirectionVetoesWholePhraseConversion() {
        XCTAssertNil(PhraseLayoutPolicy.unanimousTarget(in: [
            .layoutCandidate(targetLayoutID: "uk"),
            .ambiguous,
            .layoutCandidate(targetLayoutID: "uk")
        ]))
        XCTAssertNil(PhraseLayoutPolicy.unanimousTarget(in: [
            .layoutCandidate(targetLayoutID: "uk"),
            .layoutCandidate(targetLayoutID: "en"),
            .layoutCandidate(targetLayoutID: "uk")
        ]))
    }

    func test_assessmentMarksValidShortWordAsKeep() {
        let assessment = PhraseLayoutPolicy.assess(
            originalCore: "to",
            correctedCore: "ещ",
            sourceLanguage: "en",
            targetLanguage: "uk",
            targetLayoutID: "uk",
            isAmbiguous: false,
            isKnownCorrect: { word, language in word == "to" && language == "en" }
        )

        XCTAssertEqual(assessment, .keep)
    }

    func test_assessmentAcceptsShortWrongLayoutTokenOnlyWhenTargetIsValid() {
        let assessment = PhraseLayoutPolicy.assess(
            originalCore: "ed",
            correctedCore: "був",
            sourceLanguage: "en",
            targetLanguage: "uk",
            targetLayoutID: "uk",
            isAmbiguous: false,
            isKnownCorrect: { word, language in word == "був" && language == "uk" }
        )

        XCTAssertEqual(assessment, .layoutCandidate(targetLayoutID: "uk"))
    }

    func test_assessmentClassifiesSameScriptCorrectionAsSpellingCandidate() {
        let assessment = PhraseLayoutPolicy.assess(
            originalCore: "marge",
            correctedCore: "merge",
            sourceLanguage: "en",
            targetLanguage: "en",
            targetLayoutID: "en",
            isAmbiguous: false,
            isKnownCorrect: { word, _ in word == "merge" }
        )

        XCTAssertEqual(assessment, .spellingCandidate("merge"))
    }
}
