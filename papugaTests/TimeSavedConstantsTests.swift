import Defaults
import XCTest
@testable import papuga

final class TimeSavedConstantsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Defaults[.measuredTypingWPM] = 0
    }

    override func tearDown() {
        Defaults[.measuredTypingWPM] = 0
        super.tearDown()
    }

    func testSanitizesTypingSpeedForEstimate() {
        XCTAssertEqual(Constants.sanitizedTypingWordsPerMinute(.infinity), 40)
        XCTAssertEqual(Constants.sanitizedTypingWordsPerMinute(4), 10)
        XCTAssertEqual(Constants.sanitizedTypingWordsPerMinute(200), 160)
        XCTAssertEqual(Constants.sanitizedTypingWordsPerMinute(42.4), 42)
    }

    func testSecondsSavedUsesMeasuredTypingSpeed() {
        Defaults[.measuredTypingWPM] = 60

        XCTAssertEqual(Constants.secondsSaved(words: 3), 5)
        XCTAssertEqual(Constants.secondsSaved(words: 0), 3)
    }

    func testAggregateEstimateMatchesOverheadPlusTypingTime() {
        Defaults[.measuredTypingWPM] = 30

        XCTAssertEqual(Constants.estimatedSecondsSaved(replacementCount: 2, totalWords: 5), 14)
        XCTAssertEqual(Constants.estimatedSecondsSaved(replacementCount: 0, totalWords: 5), 0)
    }
}
