import XCTest
import SwiftUI
@testable import GramMusic

@MainActor
final class ScopedSearchTransitionTests: XCTestCase {
    func test_openAndCloseDisableNavigationAnimation() {
        var presented = false
        var transitions: [Transaction] = []
        let binding = Binding(get: { presented }, set: { value, transaction in
            presented = value
            transitions.append(transaction)
        })

        NScopedSearchTransition.setPresented(true, using: binding)
        XCTAssertTrue(presented)
        NScopedSearchTransition.setPresented(false, using: binding)
        XCTAssertFalse(presented)
        XCTAssertEqual(transitions.count, 2)
        XCTAssertTrue(transitions.allSatisfy(\.disablesAnimations))
        XCTAssertTrue(transitions.allSatisfy { $0.animation == nil })
    }
}
