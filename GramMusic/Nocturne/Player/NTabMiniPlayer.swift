import SwiftUI

/// The system supplies the glass and moves the accessory inline when navigation minimizes.
@available(iOS 26.1, *)
struct NTabMiniPlayer: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(PlayerEngine.self) private var player
    let onExpand: () -> Void
    let onTopChange: (CGFloat) -> Void
    @State private var measuredTop: CGFloat?

    var body: some View {
        NMiniPlayer(isCompact: placement == .inline, usesSystemBackground: true, onExpand: onExpand)
            .contextMenu {
                Button("Stop playback", systemImage: "stop.fill") { player.stop() }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY.rounded() } action: {
                measuredTop = $0
            }
            .task(id: measuredTop) {
                guard let measuredTop else { return }
                // Publish after the system transition settles, rather than invalidating
                // the entire tab hierarchy for every frame of its glass animation.
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                onTopChange(measuredTop)
            }
    }
}
