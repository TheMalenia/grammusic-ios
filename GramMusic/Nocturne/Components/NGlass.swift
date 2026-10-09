import SwiftUI

// The Liquid Glass seam. Everything "glassy" in Nocturne goes through `nGlass`, so iOS 26
// gets real `glassEffect` (accent-tinted, Telegram-style) while iOS 17–25 falls back to a
// tinted material. There is no longer a user translucency setting — glass on 26, material below.

extension View {
    /// Apply a neutral Liquid-Glass surface in `shape`. On iOS 26+ this is a real, untinted
    /// `glassEffect` (clear frosted chrome, no color cast); below it is a neutral
    /// `ultraThinMaterial` with a hairline. Set `interactive` for tappable surfaces (buttons,
    /// the mini-player) so the glass reacts to touch.
    ///
    /// Set `elevated` for floating surfaces (mini-player, banners) that need a drop shadow.
    /// On iOS 26+ the `glassEffect` already casts its own elevation depth, so `elevated` is a
    /// no-op there — manually stacking a `.shadow()` on glass double-shadows it. Below 26 the
    /// shadow is cast off the opaque backing shape so foreground text/symbols never pick it up.
    @ViewBuilder
    func nGlass<S: InsettableShape>(_ shape: S, theme: AppTheme,
                                    interactive: Bool = false,
                                    tint: Color? = nil,
                                    elevated: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            modifier(LiquidGlassSurface(shape: shape, interactive: interactive, tint: tint))
        } else {
            modifier(MaterialGlassSurface(shape: shape, theme: theme, tint: tint, elevated: elevated))
        }
    }

}

@available(iOS 26.0, *)
private struct LiquidGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        content.glassEffect(glass, in: shape)
    }

    /// Neutral by default; `tint` (e.g. a selected chip's accent) makes it a frosted accent glass.
    private var glass: Glass {
        let g = Glass.regular.tint(tint)
        return interactive ? g.interactive() : g
    }
}

/// iOS 17–25 fallback: the tinted-material surface Nocturne shipped before Liquid Glass. A
/// non-nil `tint` (selected chip) replaces the neutral glass tint so selection still reads.
private struct MaterialGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let theme: AppTheme
    let tint: Color?
    var elevated: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(tint ?? theme.glassTint)
                    .background(.ultraThinMaterial, in: shape)
                    .shadow(color: elevated ? theme.shadow : .clear, radius: 18, y: 8)
            }
            .overlay { shape.strokeBorder(theme.hairline, lineWidth: 0.5) }
            .clipShape(shape)
    }
}

extension View {
    /// Solid capsule surface for small filter/scope chips. Deliberately **not** Liquid Glass:
    /// glass on these tiny, frequently-animated controls flashes a rectangular drop shadow while
    /// the selection morphs. Selected = accent fill; unselected = `elev` with a hairline.
    func nChipSurface(selected: Bool, theme: AppTheme) -> some View {
        background(Capsule().fill(selected ? AnyShapeStyle(theme.accentColor) : AnyShapeStyle(theme.elev)))
            .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: selected ? 0 : 0.5))
    }
}

/// Full-bleed translucent backing for the tab bar / detail nav bar — a neutral frosted bar.
/// Uses `.bar` material (the system's translucent bar blur, which on iOS 26 is the Liquid Glass
/// bar look) so it renders reliably edge-to-edge under the home indicator. Callers add their own
/// hairline and `.ignoresSafeArea` so the surface reaches the screen edge.
struct NBarSurface: View {
    var body: some View {
        Rectangle().fill(.bar)
    }
}
