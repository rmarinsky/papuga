import XCTest
@testable import papuga

final class AutoFixProposalPolicyTests: XCTestCase {
    func test_spellingProposalIsOccurrenceOnlyAndDoesNotSwitchLayout() {
        let proposal = makeProposal(kind: .spelling)

        XCTAssertFalse(proposal.createsRuleOnAcceptance)
        XCTAssertFalse(proposal.changesInputLayout)
        XCTAssertEqual(proposal.candidateOrigin, .spelling)
    }

    func test_detectedLayoutProposalKeepsExistingLayoutBehavior() {
        let proposal = makeProposal(kind: .detected)

        XCTAssertTrue(proposal.createsRuleOnAcceptance)
        XCTAssertTrue(proposal.changesInputLayout)
        XCTAssertEqual(proposal.candidateOrigin, .keyboardLayout)
    }

    func test_onlyNeverReplacePersistsAnIgnoreDecision() {
        XCTAssertFalse(AutoFixProposalOutcome.dismissed.shouldAddToAllowlist)
        XCTAssertFalse(AutoFixProposalOutcome.timedOut.shouldAddToAllowlist)
        XCTAssertFalse(AutoFixProposalOutcome.accepted.shouldAddToAllowlist)
        XCTAssertTrue(AutoFixProposalOutcome.neverReplace.shouldAddToAllowlist)
    }

    func test_dismissAndTimeoutOfferRecovery() {
        XCTAssertTrue(AutoFixProposalOutcome.dismissed.shouldOfferRecovery)
        XCTAssertTrue(AutoFixProposalOutcome.timedOut.shouldOfferRecovery)
        XCTAssertFalse(AutoFixProposalOutcome.accepted.shouldOfferRecovery)
        XCTAssertFalse(AutoFixProposalOutcome.neverReplace.shouldOfferRecovery)
    }

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

    private func makeProposal(kind: AutoFixProposal.Kind) -> AutoFixProposal {
        AutoFixProposal(
            original: "важлво",
            candidate: "важливо",
            boundary: " ",
            fromLayoutID: "uk",
            targetLayoutID: kind == .spelling ? "uk" : "en",
            scoreOriginal: 0,
            scoreCandidate: 1,
            threshold: 0.35,
            algorithm: .appleNL,
            currentLang: "uk",
            targetLang: kind == .spelling ? "uk" : "en",
            bundleID: "com.apple.TextEdit",
            createdAt: 100,
            replacementAnchor: TextReplacementAnchor(
                targetPID: 10,
                bundleID: "com.apple.TextEdit",
                focusedElementIdentity: FocusedElementSignature.StableIdentity(
                    pid: 10,
                    role: "AXTextArea",
                    subrole: nil,
                    windowTitleHash: nil,
                    elementIdentifier: nil,
                    frameHash: nil
                ),
                sourceRange: AXTextRange(location: 0, length: 6),
                boundaryUTF16Length: 1,
                caretAfterBoundary: 7,
                expectedSource: "важлво"
            ),
            kind: kind
        )
    }
}
