import SwiftUI

/// Reusable hero detail chrome for Chat / Playlist / Artist pages (Components §DetailScroll).
///
/// Lays a `ScreenBackground` + an artwork-tinted radial behind a vertically scrolling stack
/// of `hero` then `content`. A floating glass back button sits top-left. The nav `title`
/// fades in (and a glass bar hairline appears) once the user scrolls past ~220pt — driven by
/// a scroll-offset `PreferenceKey` so it's pure SwiftUI with no UIKit.
struct NDetailScroll<Hero: View, Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PlayerEngine.self) private var player
    @Environment(TelegramService.self) private var telegram

    /// Seed for the artwork-tinted backdrop radial (`ArtworkSeed(seed).accent`).
    var seed: String
    /// Nav title that crossfades in past the threshold.
    var title: String
    /// Height of the seeded radial wash at the top.
    var backdropHeight: CGFloat = 360
    /// Scroll distance after which the nav title/bar appears.
    var revealAt: CGFloat = 220
    @ViewBuilder var hero: () -> Hero
    @ViewBuilder var content: () -> Content

    @State private var scrollY: CGFloat = 0

    private var revealed: Bool { scrollY > revealAt }

    var body: some View {
        ZStack(alignment: .top) {
            ScreenBackground()

            // Artwork-tinted wash: a radial of the seed accent at the top fading to bg.
            LinearGradient(
                colors: [ArtworkSeed(seed).accent.opacity(0.55),
                         ArtworkSeed(seed).accent.opacity(0.18),
                         theme.bg.opacity(0)],
                startPoint: .top, endPoint: .bottom)
                .frame(height: backdropHeight)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            ScrollView {
                VStack(spacing: 0) {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ScrollOffsetKey.self,
                                               value: -proxy.frame(in: .named("ndetail")).minY)
                    }
                    .frame(height: 0)

                    hero()
                        .padding(.top, 70)          // clear the floating back button
                        .padding(.horizontal, 16)

                    content()
                        .nMiniPlayerClearance(player.current != nil, offline: telegram.isOfflineStable, base: 24)
                }
            }
            .coordinateSpace(name: "ndetail")
            .modifier(NScrollDockViewport())
            .scrollDismissesKeyboard(.immediately)
            .onPreferenceChange(ScrollOffsetKey.self) { scrollY = $0 }

            navBar
        }
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipe()      // restore edge-swipe-back (hidden bar disables it)
    }

    // MARK: Floating nav bar (back button always; title/material on reveal)

    private var navBar: some View {
        ZStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .frame(width: 38, height: 38)
                        .nocturneGlass(Circle(), theme: theme)
                        .frame(width: 44, height: 44)        // ≥44pt tap target around the 38pt glass
                        .contentShape(Circle())
                }
                .buttonStyle(NPressable(scale: 0.9))
                .accessibilityLabel("Back")

                Spacer()
            }
            .padding(.horizontal, 14)

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .padding(.horizontal, 56)
                .opacity(revealed ? 1 : 0)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background {
            // Glass bar + bottom hairline that fades in with the title (covers the safe area).
            NBarSurface()
                .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 0.5) }
                .ignoresSafeArea(edges: .top)
                .opacity(revealed ? 1 : 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: revealed)
    }
}

/// Tracks the vertical scroll offset inside `NDetailScroll`.
private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
