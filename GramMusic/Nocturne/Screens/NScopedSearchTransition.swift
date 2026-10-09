import SwiftUI

/// Find in a collection opens directly. Keep navigation animation out of both the
/// presentation and X dismissal while the search field manages keyboard focus.
@MainActor
enum NScopedSearchTransition {
    static func setPresented(_ presented: Bool, using binding: Binding<Bool>) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        binding.transaction(transaction).wrappedValue = presented
    }
}
