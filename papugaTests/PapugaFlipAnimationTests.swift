import XCTest
@testable import papuga

final class PapugaFlipAnimationTests: XCTestCase {
    func test_everyReplacementAdvancesAnotherFullTurn() {
        var animation = PapugaFlipAnimation()

        animation.trigger()
        XCTAssertEqual(animation.degrees, -360)

        animation.trigger()
        XCTAssertEqual(animation.degrees, -720)
    }
}
