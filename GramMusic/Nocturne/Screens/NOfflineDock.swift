import SwiftUI

/// Keep the offline notice in the chrome layer while scroll content can extend behind it.
struct NOfflineDock: ViewModifier {
    @Environment(TelegramService.self) private var telegram
    @Environment(\.nMiniDockTop) private var playerTop
    @State private var noticeTop: CGFloat?
    let onTopChange: (CGFloat) -> Void
    @State private var height: CGFloat?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if telegram.isOfflineStable {
                    OfflineBar().padding(.horizontal, 20).padding(.vertical, 4)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            height = $0.height
                            noticeTop = $0.minY
                            onTopChange($0.minY)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ScreenBackground())
            .environment(\.nMiniDockHeight, telegram.isOfflineStable ? height : nil)
            .environment(\.nMiniDockTop, telegram.isOfflineStable ? noticeTop : playerTop)
    }
}
