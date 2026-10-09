import SwiftUI

// Chrome primitives: the screen backdrop and the glass-surface modifier. (Components §"Glass surface".)

/// Full-screen Nocturne backdrop: base `bg` plus the top-biased radial `bgGrad`.
struct ScreenBackground: View {
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack {
            theme.bg
            theme.backgroundGradient
        }
        .ignoresSafeArea()
    }
}

/// A shadow overlay for the top of the screen to make the status bar readable.
struct TopStatusBarShadow: View {
    @Environment(\.theme) private var theme
    var body: some View {
        LinearGradient(
            colors: [
                theme.bg.opacity(0.8),
                theme.bg.opacity(0.3),
                .clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 120)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

extension View {
    /// Glass chrome surface for nav/tab bars, the mini-player, sheets and floating buttons.
    /// Real Liquid Glass on iOS 26, tinted material below — see `nGlass` in NGlass.swift.
    func nocturneGlass<S: InsettableShape>(_ shape: S, theme: AppTheme,
                                           interactive: Bool = false,
                                           elevated: Bool = false) -> some View {
        nGlass(shape, theme: theme, interactive: interactive, elevated: elevated)
    }
}

/// The brand logo tile: PlaneMark on the accent fill gradient inside a continuous square,
/// with an inner top highlight + accent glow. (Design-system §10, Components §PlaneMark.)
struct LogoTile: View {
    @Environment(\.theme) private var theme
    var size: CGFloat = 72

    var body: some View {
        if let icon = UIImage(named: "Logo") {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .shadow(color: theme.accentColor.opacity(0.45), radius: size * 0.28, y: size * 0.12)
        } else {
            // Fallback just in case
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(theme.brand == .aurora ? AnyShapeStyle(BrandDirection.auroraGradient)
                                             : AnyShapeStyle(theme.accent.fillGradient))
                .overlay {
                    PlaneMark().fill(.white)
                        .frame(width: size * 0.44, height: size * 0.44)
                }
                .frame(width: size, height: size)
        }
    }
}

/// Brand lockup: logo tile + "GramMusic" wordmark (splash/login/onboarding).
struct NWordmark: View {
    @Environment(\.theme) private var theme
    var tileSize: CGFloat = 72
    var showTagline = false

    var body: some View {
        VStack(spacing: 16) {
            LogoTile(size: tileSize)
            Text("GramMusic")
                .font(.system(size: tileSize * 0.53, weight: .bold, design: .rounded))
                .tracking(-1)
                .foregroundStyle(theme.text)
            if showTagline {
                Text("The player your music deserves")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.text2)
            }
        }
    }
}
