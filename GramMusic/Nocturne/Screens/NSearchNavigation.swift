import SwiftUI

/// Root search owns a stack; collection searches reuse their existing tab's navigation.
struct NSearchNavigation<Content: View>: View {
    let ownsStack: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        if ownsStack {
            NavigationStack { content() }
        } else {
            content()
        }
    }
}
