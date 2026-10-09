import SwiftUI

/// A search page has a title and its own persistent field, independent of tab activation.
struct NSearchTabChrome: ViewModifier {
    let enabled: Bool
    let isEmbedded: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(isEmbedded ? .inline : .large)
        } else {
            content
        }
    }
}
