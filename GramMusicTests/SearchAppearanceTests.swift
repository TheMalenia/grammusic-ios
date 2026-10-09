import XCTest
@testable import GramMusic

@MainActor
final class SearchAppearanceTests: XCTestCase {
    func test_keyboardRequestWaitsForCompletedAppearance() {
        let controller = NSearchAppearanceObserver.Controller()
        var requests = 0
        controller.onReady = { requests += 1 }
        controller.loadViewIfNeeded()

        controller.beginAppearanceTransition(true, animated: true)
        XCTAssertEqual(requests, 0, "Do not open the keyboard while navigation is animating")

        controller.endAppearanceTransition()
        XCTAssertEqual(requests, 1, "Request focus after the destination finishes appearing")

        controller.beginAppearanceTransition(false, animated: true)
        controller.endAppearanceTransition()
        XCTAssertEqual(requests, 1, "Leaving search must not request keyboard focus")
    }
}
