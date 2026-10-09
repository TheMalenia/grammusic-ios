import SwiftUI

/// Reuses the same full player from the tab dock and the search dock.
struct NPlayerPresentation: ViewModifier {
    @Binding var isPresented: Bool
    var onOpenSource: ((NPlayerSourceRoute) -> Void)? = nil
    @Environment(PlayerEngine.self) private var player
    @Environment(TelegramService.self) private var telegram
    @Environment(AppSettings.self) private var settings
    @Environment(NActionFeedback.self) private var feedback
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @State private var presenter = PlayerPresenter()
    @State private var isInteractiveDismissing = false

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented) {
            InteractivePlayerHost(
                presenter: presenter,
                onClose: close,
                onDrivingChanged: { driving in
                    DispatchQueue.main.async { isInteractiveDismissing = driving }
                }
            ) {
                NNowPlayingView(onClose: { presenter.requestClose() }, onOpenSource: onOpenSource)
                    .environment(player)
                    .environment(telegram)
                    .environment(settings)
                    .environment(feedback)
                    .environment(\.theme, theme)
                    .environment(\.isInteractiveDismissing, isInteractiveDismissing)
                    .modelContext(context)
                    .tint(theme.accentColor)
                    .playbackErrorBanner()
                    .actionFeedback()
            }
            .ignoresSafeArea()
            .presentationBackground(.clear)
        }
    }

    private func close() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isPresented = false }
    }
}

extension View {
    func nowPlayingPresentation(isPresented: Binding<Bool>,
                                onOpenSource: ((NPlayerSourceRoute) -> Void)? = nil) -> some View {
        modifier(NPlayerPresentation(isPresented: isPresented, onOpenSource: onOpenSource))
    }
}
