import XCTest
@testable import papuga

final class PersonalLayoutModelTests: XCTestCase {
    func test_failedInsertionsNeverTeachLayoutPairs() {
        let model = PersonalLayoutModel()
        model.replaceHistory((0..<4).map { day in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(day * 86400)),
                kind: .manualSwitch, original: "lfdfq dct ", converted: "давай все ",
                sourceLayoutID: from, targetLayoutID: to, verificationSucceeded: false)
        })
        XCTAssertEqual(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
    }

    func test_undoingPhraseRemovesEarlierWordAndContextEvidence() {
        let model = PersonalLayoutModel()
        var history = (0..<3).map { day in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(day * 86400)),
                kind: .manualSwitch, original: "lfdfq dct ", converted: "давай все ",
                sourceLayoutID: from, targetLayoutID: to)
        }
        history.append(ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: 300000),
            kind: .autoFixUndone, original: "lfdfq dct", converted: "давай все", sourceLayoutID: from))
        model.replaceHistory(history)
        XCTAssertEqual(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
        XCTAssertEqual(model.boost(original: "dct", candidate: "все", sourceID: from, targetID: to, previousWord: "lfdfq"), 0)
    }

    func test_retriesIncompleteTokensAndClearedHistoryDoNotTeach() {
        let model = PersonalLayoutModel()
        let retries = (0..<3).map { second in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(second)),
                kind: .manualSwitch, original: "lfdfq dct", converted: "давай все",
                sourceLayoutID: from, targetLayoutID: to, bundleID: "test.editor")
        }
        model.replaceHistory(retries)
        XCTAssertEqual(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
        XCTAssertEqual(model.boost(original: "dct", candidate: "все", sourceID: from, targetID: to), 0)
        model.replaceHistory((0..<3).map { day in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(day * 86400)),
                kind: .manualSwitch, original: "lfdfq ", converted: "давай ", sourceLayoutID: from, targetLayoutID: to)
        })
        XCTAssertGreaterThan(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
        model.replaceHistory([])
        XCTAssertEqual(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
    }

    private let from = "com.apple.keylayout.US"
    private let to = "com.apple.keylayout.Ukrainian-PC"

    func test_repeatedManualPhrasesTeachCompletedWordPairs() {
        let model = PersonalLayoutModel()
        let history = (0..<3).map { day in
            ReplacementHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(day * 86400)),
                kind: .manualSwitch, original: "lfdfq dct ", converted: "давай все ",
                sourceLayoutID: from, targetLayoutID: to, bundleID: "test.editor")
        }
        model.replaceHistory(history)
        XCTAssertGreaterThan(model.boost(original: "lfdfq", candidate: "давай", sourceID: from, targetID: to), 0)
        XCTAssertGreaterThan(model.boost(original: "dct", candidate: "все", sourceID: from, targetID: to, previousWord: "lfdfq"), 0)
        XCTAssertEqual(model.boost(original: "dct", candidate: "всі", sourceID: from, targetID: to), 0)
    }
}
