import XCTest
@testable import papuga

final class CandidateRankingTests: XCTestCase {

    private func candidate(
        _ text: String,
        _ tier: CandidateTier,
        distance: Int = 0,
        logFrequency: Double = 0,
        kind: MistakeSuggestionKind = .spelling
    ) -> MistakeSuggestionCandidate {
        MistakeSuggestionCandidate(
            kind: kind,
            text: text,
            tier: tier,
            editDistance: distance,
            logFrequency: logFrequency
        )
    }

    /// The invariant that makes the old inversion impossible. If the widest
    /// in-tier swing ever exceeds the narrowest gap between tiers, a
    /// low-tier candidate can outscore a high-tier one again and the whole
    /// point of tiers is lost.
    func test_confidenceNeverCrossesTiers() {
        // Widest in-tier spread: best case (distance 0, max frequency bonus)
        // against worst case (max distance penalty, no bonus).
        func best(_ tier: CandidateTier) -> Double {
            CandidateTier.confidence(tier: tier, editDistance: 0, logFrequency: 100)
        }
        func worst(_ tier: CandidateTier) -> Double {
            CandidateTier.confidence(tier: tier, editDistance: 99, logFrequency: 0)
        }

        let ordered = CandidateTier.allCases.sorted()
        for (higher, lower) in zip(ordered, ordered.dropFirst()) {
            XCTAssertGreaterThan(
                worst(higher), best(lower),
                "the worst \(higher) outranks the best \(lower) on score — tiers no longer separate"
            )
        }
    }

    /// The concrete regression: a validated layout flip must beat a distance-1
    /// dictionary guess no matter how long the word. At 11+ characters the old
    /// scalar model put the guess (0.822) above the layout flip (0.82).
    func test_validatedLayoutBeatsDictionaryGuessAtEveryWordLength() {
        for length in 3...25 {
            let word = String(repeating: "а", count: length)
            let layout = candidate(word, .validatedLayout, kind: .keyboardLayout)
            let guess = candidate(word + "и", .dictionaryGuess, distance: 1, logFrequency: 6)
            XCTAssertTrue(
                layout.ranksBefore(guess),
                "length \(length): dictionary guess overtook the validated layout flip"
            )
            XCTAssertFalse(guess.ranksBefore(layout))
        }
    }

    func test_tierOrderingDominatesEveryOtherSignal() {
        // A recorded correction with the worst possible sub-signals still wins.
        let recorded = candidate("x", .recorded, distance: 9, logFrequency: 0, kind: .recorded)
        let layout = candidate("y", .validatedLayout, distance: 0, logFrequency: 99)
        XCTAssertTrue(recorded.ranksBefore(layout))
    }

    /// Frequency finally decides between equally-distant guesses. `helo` used
    /// to offer `halo` before `help` purely because the tie-break was
    /// alphabetical and every same-distance guess scored identically.
    func test_frequencyBreaksTiesAmongEquallyDistantGuesses() {
        let help = candidate("help", .dictionaryGuess, distance: 1, logFrequency: 5.0)
        let halo = candidate("halo", .dictionaryGuess, distance: 1, logFrequency: 2.0)
        XCTAssertTrue(help.ranksBefore(halo))
        XCTAssertFalse(halo.ranksBefore(help))

        let sorted = [halo, help].sorted { $0.ranksBefore($1) }
        XCTAssertEqual(sorted.map(\.text), ["help", "halo"])
    }

    func test_smallerEditDistanceWinsBeforeFrequency() {
        let near = candidate("near", .dictionaryGuess, distance: 1, logFrequency: 0)
        let common = candidate("common", .dictionaryGuess, distance: 2, logFrequency: 99)
        XCTAssertTrue(near.ranksBefore(common))
    }

    /// No alphabetical tie-break: ordering must not depend on the alphabet.
    func test_tieBreakIsDeterministicAndNotAlphabetical() {
        let zebra = candidate("zebra", .dictionaryGuess, distance: 1, logFrequency: 3)
        let alphabet = candidate("alphabet", .dictionaryGuess, distance: 1, logFrequency: 3)
        // Shorter wins, so the alphabetically-later word comes first.
        XCTAssertTrue(zebra.ranksBefore(alphabet))
    }

    func test_unvalidatedLayoutRanksBelowADictionaryGuess() {
        let guess = candidate("привіт", .dictionaryGuess, distance: 2)
        let unvalidated = candidate("привет", .unvalidatedLayout, kind: .keyboardLayout)
        XCTAssertTrue(guess.ranksBefore(unvalidated))
    }

    func test_derivedConfidenceStaysWithinBounds() {
        for tier in CandidateTier.allCases {
            for distance in 0...5 {
                let value = CandidateTier.confidence(
                    tier: tier, editDistance: distance, logFrequency: 7
                )
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
        }
    }

    /// Payloads written before tiers (AI batches, older history) carry only
    /// `kind`, so decoding must still place them sensibly.
    func test_legacyPayloadWithoutTierDecodesToAMatchingTier() throws {
        let json = """
        {"kind":"keyboardLayout","text":"також","confidence":0.82}
        """
        let decoded = try JSONDecoder().decode(
            MistakeSuggestionCandidate.self, from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.tier, .validatedLayout)
        XCTAssertEqual(decoded.text, "також")
    }

    func test_roundTripPreservesRankingMetadata() throws {
        let original = candidate("привіт", .dictionaryGuess, distance: 2, logFrequency: 4.5)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MistakeSuggestionCandidate.self, from: data)
        XCTAssertEqual(decoded.tier, original.tier)
        XCTAssertEqual(decoded.editDistance, original.editDistance)
        XCTAssertEqual(decoded.logFrequency, original.logFrequency, accuracy: 0.0001)
        XCTAssertEqual(decoded.confidence, original.confidence, accuracy: 0.0001)
    }
}
