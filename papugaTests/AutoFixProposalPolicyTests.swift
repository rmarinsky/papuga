import XCTest
@testable import papuga

final class AutoFixProposalPolicyTests: XCTestCase {
    func test_suggestsWhenCandidateIsBelowThresholdButInsideWindow() {
        XCTAssertTrue(AutoFixProposalPolicy.shouldSuggest(
            scoreOriginal: 0.30,
            scoreCandidate: 0.56,
            threshold: 0.30,
            window: 0.05
        ))
    }

    func test_doesNotSuggestWhenCandidateAlreadyMeetsAutoFixThreshold() {
        XCTAssertFalse(AutoFixProposalPolicy.shouldSuggest(
            scoreOriginal: 0.20,
            scoreCandidate: 0.55,
            threshold: 0.30,
            window: 0.12
        ))
    }

    func test_doesNotSuggestWhenCandidateIsTooFarFromThreshold() {
        XCTAssertFalse(AutoFixProposalPolicy.shouldSuggest(
            scoreOriginal: 0.30,
            scoreCandidate: 0.40,
            threshold: 0.30,
            window: 0.08
        ))
    }

    func test_doesNotSuggestWhenCandidateIsNotBetterThanOriginal() {
        XCTAssertFalse(AutoFixProposalPolicy.shouldSuggest(
            scoreOriginal: 0.50,
            scoreCandidate: 0.49,
            threshold: 0.30,
            window: 0.12
        ))
    }
}
