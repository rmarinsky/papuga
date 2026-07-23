import XCTest
@testable import papuga

final class LayoutIncidentTrackerTests: XCTestCase {
    func test_threeStrongTokensProduceOneAutomaticSentenceReplacement() {
        var tracker = LayoutIncidentTracker()
        tracker.append(strongToken("vj;yf", "можна"))
        tracker.append(strongToken("dbrjhbcnfnb", "використати"))
        tracker.append(strongToken("lkz", "для", boundary: "\n"))

        let decision = tracker.decision(
            scoreOriginal: 0.05,
            scoreCandidate: 0.82,
            threshold: 0.35
        )

        XCTAssertEqual(decision, .replace)
        XCTAssertEqual(tracker.originalBody, "vj;yf dbrjhbcnfnb lkz")
        XCTAssertEqual(tracker.candidateBody, "можна використати для")
        XCTAssertEqual(tracker.trailingBoundary, "\n")
    }

    func test_twoStrongTokensProduceProposalEvenWithLowLanguageScore() {
        var tracker = LayoutIncidentTracker()
        tracker.append(strongToken("vj;yf", "можна"))
        tracker.append(strongToken("dbrjhbcnfnb", "використати"))

        XCTAssertEqual(
            tracker.decision(scoreOriginal: 1, scoreCandidate: 0, threshold: 0.35),
            .propose
        )
    }

    func test_validSourceContradictionPreventsIncidentAction() {
        var tracker = LayoutIncidentTracker()
        tracker.append(strongToken("vj;yf", "можна"))
        tracker.append(LayoutIncidentToken(
            original: "text",
            candidate: "еуые",
            boundary: " ",
            targetLayoutID: "uk",
            evidence: .contradiction
        ))
        tracker.append(strongToken("lkz", "для"))

        XCTAssertEqual(
            tracker.decision(scoreOriginal: 0, scoreCandidate: 1, threshold: 0.35),
            .discard
        )
    }

    func test_neutralEmojiAdjacencyIsPreservedAndCountsAgainstSupport() {
        var tracker = LayoutIncidentTracker()
        tracker.append(strongToken("vj;yf", "можна"))
        tracker.append(LayoutIncidentToken(
            original: "🙂",
            candidate: "🙂",
            boundary: " ",
            targetLayoutID: "uk",
            evidence: .neutral
        ))
        tracker.append(strongToken("dbrjhbcnfnb", "використати"))

        XCTAssertEqual(tracker.originalBody, "vj;yf 🙂 dbrjhbcnfnb")
        XCTAssertEqual(tracker.candidateBody, "можна 🙂 використати")
        XCTAssertEqual(tracker.strongTokenCount, 2)
        XCTAssertEqual(tracker.supportRatio, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(
            tracker.decision(scoreOriginal: 1, scoreCandidate: 0, threshold: 0.35),
            .propose
        )
    }

    func test_sentenceBoundaryRecognisesSourceOrConvertedPunctuation() {
        var sourceTerminated = LayoutIncidentTracker()
        sourceTerminated.append(strongToken("wrong.", "словою"))

        var candidateTerminated = LayoutIncidentTracker()
        candidateTerminated.append(strongToken("цкщтпю", "wrong."))

        XCTAssertTrue(sourceTerminated.endsSentence)
        XCTAssertTrue(candidateTerminated.endsSentence)
    }

    func test_targetChangeBreaksIncidentInsteadOfMixingConversions() {
        var tracker = LayoutIncidentTracker()
        XCTAssertEqual(tracker.append(strongToken("one", "раз", target: "uk")), .accepted)
        XCTAssertEqual(tracker.append(strongToken("two", "два", target: "ru")), .targetChanged)
        XCTAssertEqual(tracker.wordCount, 1)
    }

    func test_safetyCapUsesWordsOrUTF16WithoutSplittingStoredText() {
        var tracker = LayoutIncidentTracker(maxWords: 30, maxUTF16Length: 300)
        for index in 0..<30 {
            let result = tracker.append(strongToken("w\(index)", "с\(index)"))
            XCTAssertEqual(result, index == 29 ? .reachedCap : .accepted)
        }

        XCTAssertEqual(tracker.wordCount, 30)
        XCTAssertTrue(tracker.isAtSafetyCap)

        var utf16Tracker = LayoutIncidentTracker(maxWords: 30, maxUTF16Length: 8)
        XCTAssertEqual(
            utf16Tracker.append(strongToken("👨‍👩‍👧‍👦", "родина")),
            .wouldExceedCap
        )
        XCTAssertTrue(utf16Tracker.isEmpty)
    }

    func test_overflowTokenIsNotAddedToAnExistingIncident() {
        var tracker = LayoutIncidentTracker(maxWords: 30, maxUTF16Length: 12)
        XCTAssertEqual(tracker.append(strongToken("abcd", "абвг")), .accepted)

        XCTAssertEqual(
            tracker.append(strongToken("0123456789", "0123456789")),
            .wouldExceedCap
        )
        XCTAssertEqual(tracker.originalBody, "abcd")
        XCTAssertEqual(tracker.candidateBody, "абвг")
    }

    func test_timerPromotesFastContinuationAndExpiresAtDefinedDeadlines() {
        var timer = LayoutIncidentTimerState()
        timer.armSingleWord(at: 10)

        XCTAssertTrue(timer.consumeFastContinuation(at: 10.5))
        XCTAssertNil(timer.takeDueAction(at: 11))

        timer.armSingleWord(at: 20)
        XCTAssertEqual(timer.takeDueAction(at: 20.75), .applySingleWord)

        timer.armIncidentIdle(at: 30)
        XCTAssertNil(timer.takeDueAction(at: 31.19))
        XCTAssertEqual(timer.takeDueAction(at: 31.2), .finalizeIncident)
    }

    func test_returnAndTabAreHardIncidentBoundaries() {
        XCTAssertTrue(LayoutIncidentTracker.isHardBoundary("\r"))
        XCTAssertTrue(LayoutIncidentTracker.isHardBoundary("\n"))
        XCTAssertTrue(LayoutIncidentTracker.isHardBoundary("\t"))
        XCTAssertFalse(LayoutIncidentTracker.isHardBoundary(" "))
    }

    private func strongToken(
        _ original: String,
        _ candidate: String,
        boundary: String = " ",
        target: String = "uk"
    ) -> LayoutIncidentToken {
        LayoutIncidentToken(
            original: original,
            candidate: candidate,
            boundary: boundary,
            targetLayoutID: target,
            evidence: .strong
        )
    }
}
