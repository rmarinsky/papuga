import XCTest
@testable import papuga

/// Rules are one-word-only, so phrase history rows used to offer a permanently
/// disabled "Створити правило". A phrase converts token-by-token, which makes a
/// 1:1 word alignment trustworthy enough to offer each pair separately.
final class PhraseRulePairTests: XCTestCase {
    func test_phraseSplitsIntoAlignedWordPairs() {
        let pairs = HistoryWordActionPolicy.phraseRulePairs(
            source: "nj ljhtxs",
            target: "то доречі"
        )
        XCTAssertEqual(pairs.map(\.source), ["nj", "ljhtxs"])
        XCTAssertEqual(pairs.map(\.target), ["то", "доречі"])
    }

    func test_unalignedTokenCountsOfferNothing() {
        XCTAssertTrue(
            HistoryWordActionPolicy.phraseRulePairs(source: "lj dtcskkz", target: "весілля").isEmpty,
            "2 words → 1 word cannot be aligned without guessing"
        )
    }

    func test_singleWordEntriesAreNotPhrasePairs() {
        XCTAssertTrue(
            HistoryWordActionPolicy.phraseRulePairs(source: "ghbdsn", target: "привіт").isEmpty,
            "single words keep the existing direct button"
        )
    }

    func test_truncatedEntriesOfferNothing() {
        XCTAssertTrue(
            HistoryWordActionPolicy.phraseRulePairs(source: "nj ljhtxs…", target: "то доречі").isEmpty
        )
        XCTAssertTrue(
            HistoryWordActionPolicy.phraseRulePairs(source: "nj ljhtxs", target: "то доречі…").isEmpty
        )
        XCTAssertTrue(HistoryWordActionPolicy.phraseRulePairs(source: "nj ljhtxs", target: nil).isEmpty)
    }

    func test_pairsFailingWordPolicyAreDroppedIndividually() {
        // "d" is below the two-character minimum; the other pair survives.
        let pairs = HistoryWordActionPolicy.phraseRulePairs(
            source: "d ljhtxs",
            target: "в доречі"
        )
        XCTAssertEqual(pairs.map(\.source), ["ljhtxs"])
    }

    func test_identicalPairsAreDropped() {
        // A word that needed no conversion is not a rule.
        let pairs = HistoryWordActionPolicy.phraseRulePairs(
            source: "hello ljhtxs",
            target: "hello доречі"
        )
        XCTAssertEqual(pairs.map(\.source), ["ljhtxs"])
    }
}
