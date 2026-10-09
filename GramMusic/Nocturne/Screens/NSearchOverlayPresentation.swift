import SwiftUI

/// A tab uses the shell's player and feedback; scoped search overlays own their presentation.
struct NSearchOverlayPresentation: ViewModifier {
    let isTab: Bool
    @Binding var showNowPlaying: Bool
    let onExpand: () -> Void
    @Environment(PlayerEngine.self) private var player

    @ViewBuilder
    func body(content: Content) -> some View {
        if isTab {
            content
        } else {
            content
                .nMiniDock(onExpand: onExpand)
                .environment(\.nUsesNativePlayerAccessory, false)
                .nowPlayingPresentation(isPresented: $showNowPlaying)
                .actionFeedback(bottomClearance: player.current == nil ? 16 : 80)
                .playbackErrorBanner()
        }
    }
}
