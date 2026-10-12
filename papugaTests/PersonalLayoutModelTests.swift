import XCTest
@testable import papuga

final class PersonalLayoutModelTests: XCTestCase {
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
