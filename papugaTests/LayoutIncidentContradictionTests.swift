import XCTest
@testable import papuga

/// One real word inside a long wrong-layout run used to annihilate the whole
/// incident: `contradictionCount == 0` was a hard gate, so up to 29 correctly
/// detected words were discarded because of a single contradicting token.
final class LayoutIncidentContradictionTests: XCTestCase {

    private func incident(strong: Int, contradictions: Int) -> LayoutIncidentTracker {
        var incident = LayoutIncidentTracker()
        for index in 0..<strong {
            incident.append(LayoutIncidentToken(
                original: "ghbdsn\(index)",
                candidate: "привіт\(index)",
                boundary: " ",
                targetLayoutID: "uk",
                evidence: .strong
            ))
        }
        for index in 0..<contradictions {
            incident.append(LayoutIncidentToken(
                original: "hello\(index)",
                candidate: "руддщ\(index)",
                boundary: " ",
                targetLayoutID: "uk",
                evidence: .contradiction
            ))
        }
        return incident
    }

    private func verdict(
        _ incident: LayoutIncidentTracker,
        tolerate: Bool
    ) -> LayoutIncidentDecision {
        incident.decision(
            scoreOriginal: 0.1,
            scoreCandidate: 0.95,
            threshold: 0.35,
            tolerateContradictions: tolerate
        )
    }

    func test_cleanIncidentStillReplaces() {
        let clean = incident(strong: 4, contradictions: 0)
        XCTAssertEqual(verdict(clean, tolerate: false), .replace)
        XCTAssertEqual(verdict(clean, tolerate: true), .replace)
    }

    func test_defaultBehaviourDiscardsOnAnyContradiction() {
        let mostlyGood = incident(strong: 9, contradictions: 1)
        XCTAssertEqual(verdict(mostlyGood, tolerate: false), .discard)
    }

    /// A single real word in a ten-word run becomes a proposal rather than
    /// nothing — but never a silent replacement.
    func test_toleratedContradictionDegradesToProposeNotReplace() {
        let mostlyGood = incident(strong: 9, contradictions: 1)
        XCTAssertEqual(verdict(mostlyGood, tolerate: true), .propose)
    }

    func test_tooManyContradictionsStillDiscard() {
        // 3 of 10 is above the 0.2 tolerance.
        let mixed = incident(strong: 7, contradictions: 3)
        XCTAssertEqual(verdict(mixed, tolerate: true), .discard)
    }

    /// Auto-replacement must never be reachable through the tolerant path,
    /// whatever the scores: silently rewriting a sentence containing a word the
    /// user meant is the worst failure mode this app has.
    func test_toleranceCanNeverProduceAReplacement() {
        for strong in 3...20 {
            for contradictions in 1...4 {
                let candidate = incident(strong: strong, contradictions: contradictions)
                XCTAssertNotEqual(
                    verdict(candidate, tolerate: true), .replace,
                    "strong=\(strong) contradictions=\(contradictions) reached .replace"
                )
            }
        }
    }

    func test_weakSupportIsStillDiscardedEvenWhenTolerant() {
        let weak = incident(strong: 2, contradictions: 1)
        XCTAssertEqual(verdict(weak, tolerate: true), .discard)
    }
}
