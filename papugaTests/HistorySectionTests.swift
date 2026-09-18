import XCTest
@testable import papuga

final class HistorySectionTests: XCTestCase {
    func test_navigationDoesNotExposeTypingMistakes() {
        XCTAssertFalse(HistorySection.allCases.map(\.title).contains("Помилки введення"))
    }
}
