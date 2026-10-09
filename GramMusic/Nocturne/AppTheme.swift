import SwiftUI

/// The resolved Nocturne token set, injected via `\.theme`. A change to theme mode or
/// accent recomputes one of these at the root → the whole tree repaints. Tokens map 1:1
/// to design-system §1.
struct AppTheme {
    var scheme: ColorScheme

    var bg: Color
    var bgGradTop: Color
    var bgGradBottom: Color
    var elev: Color
    var elev2: Color
    var glassTint: Color
    var hairline: Color
    var text: Color
    var text2: Color
    var text3: Color
    var accentText: Color
    var shadow: Color

    // Settings passthrough (so any view can read them off the theme).
    var accent: Accent
    var brand: BrandDirection
    var artwork: ArtworkStyle

    var accentColor: Color { accent.color }

    /// Primary fill for buttons / active chrome: flat accent (Nocturne) or Aurora gradient.
    var brandFill: AnyShapeStyle {
        brand == .aurora ? AnyShapeStyle(BrandDirection.auroraGradient) : AnyShapeStyle(accent.color)
    }

    /// Top-biased radial backdrop painted over `bg` (design-system §1 `bgGrad`).
    var backgroundGradient: RadialGradient {
        RadialGradient(colors: [bgGradTop, bgGradBottom],
                       center: UnitPoint(x: 0.5, y: -0.1),
                       startRadius: 0, endRadius: 620)
    }

    var shadowRadius: CGFloat { scheme == .dark ? 30 : 22 }
}

/// The 5 theme modes. Each resolves to an `AppTheme` given the system color scheme,
/// the chosen accent, and brand direction.
enum ThemeMode: String, CaseIterable, Identifiable {
    case tintedNight, night, dayClassic, day
    var id: String { rawValue }

    var label: String {
        switch self {
        case .tintedNight: "Default"
        case .night: "Night"
        case .dayClassic: "Day Classic"
        case .day: "Day"
        }
    }

    /// Resolve to concrete tokens.
    func resolve(systemScheme: ColorScheme, accent: Accent,
                 brand: BrandDirection, artwork: ArtworkStyle) -> AppTheme {
        switch self {
        case .tintedNight: return Self.tintedNightTheme(accent: accent, brand: brand, artwork: artwork)
        case .night: return Self.nightTheme(accent: accent, brand: brand, artwork: artwork)
        case .dayClassic: return Self.dayClassicTheme(accent: accent, brand: brand, artwork: artwork)
        case .day: return Self.dayTheme(accent: accent, brand: brand, artwork: artwork)
        }
    }

    // MARK: Palettes (design-system §1)

    private static func nightTheme(accent: Accent, brand: BrandDirection,
                                   artwork: ArtworkStyle) -> AppTheme {
        // Aurora brand deepens Night's backdrop to indigo-violet.
        let gradTop = brand == .aurora ? Color(hex: 0x20204E) : Color(hex: 0x15151D)
        let gradBottom = brand == .aurora ? Color(hex: 0x08080D) : Color(hex: 0x0A0A0E)
        return AppTheme(
            scheme: .dark,
            bg: brand == .aurora ? Color(hex: 0x100F24) : Color(hex: 0x0A0A0E),
            bgGradTop: gradTop, bgGradBottom: gradBottom,
            elev: Color(hex: 0x141419), elev2: Color(hex: 0x1C1C23),
            glassTint: Color(hex: 0x1C1C23).opacity(0.62),
            hairline: Color.white.opacity(0.08),
            text: Color(hex: 0xFBFBFD),
            text2: Color(red: 235/255, green: 235/255, blue: 245/255).opacity(0.62),
            text3: Color(red: 235/255, green: 235/255, blue: 245/255).opacity(0.32),
            accentText: .white, shadow: Color.black.opacity(0.55),
            accent: accent, brand: brand, artwork: artwork)
    }

    private static func tintedNightTheme(accent: Accent, brand: BrandDirection,
                                         artwork: ArtworkStyle) -> AppTheme {
        let a = accent.color
        let base = Color(hex: 0x0A0A0E)
        return AppTheme(
            scheme: .dark,
            bg: base.blended(with: a, amount: 0.09),
            bgGradTop: base.blended(with: a, amount: 0.22),
            bgGradBottom: base.blended(with: a, amount: 0.06),
            elev: Color(hex: 0x141419).blended(with: a, amount: 0.10),
            elev2: Color(hex: 0x1C1C23).blended(with: a, amount: 0.14),
            glassTint: Color(hex: 0x14141A).blended(with: a, amount: 0.14).opacity(0.66),
            hairline: Color.white.opacity(0.08).blended(with: a, amount: 0.22),
            text: Color(hex: 0xFBFBFD),
            text2: Color(red: 235/255, green: 235/255, blue: 245/255).opacity(0.62),
            text3: Color(red: 235/255, green: 235/255, blue: 245/255).opacity(0.32),
            accentText: .white, shadow: Color.black.opacity(0.55),
            accent: accent, brand: brand, artwork: artwork)
    }

    private static func dayTheme(accent: Accent, brand: BrandDirection,
                                 artwork: ArtworkStyle) -> AppTheme {
        AppTheme(
            scheme: .light,
            bg: Color(hex: 0xF4F4F7),
            bgGradTop: .white, bgGradBottom: Color(hex: 0xECECF1),
            elev: .white, elev2: .white,
            glassTint: Color.white.opacity(0.72),
            hairline: Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.12),
            text: Color(hex: 0x0B0B0F),
            text2: Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.60),
            text3: Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.30),
            accentText: .white, shadow: Color(red: 20/255, green: 20/255, blue: 40/255).opacity(0.12),
            accent: accent, brand: brand, artwork: artwork)
    }

    private static func dayClassicTheme(accent: Accent, brand: BrandDirection,
                                        artwork: ArtworkStyle) -> AppTheme {
        AppTheme(
            scheme: .light,
            bg: Color(hex: 0xF7F6F2),
            bgGradTop: .white, bgGradBottom: Color(hex: 0xF1EFE9),
            elev: .white, elev2: .white,
            glassTint: Color(red: 250/255, green: 249/255, blue: 245/255).opacity(0.75),
            hairline: Color(red: 70/255, green: 64/255, blue: 55/255).opacity(0.12),
            text: Color(hex: 0x0B0B0F),
            text2: Color(red: 70/255, green: 64/255, blue: 55/255).opacity(0.60),
            text3: Color(red: 70/255, green: 64/255, blue: 55/255).opacity(0.30),
            accentText: .white, shadow: Color(red: 20/255, green: 20/255, blue: 40/255).opacity(0.12),
            accent: accent, brand: brand, artwork: artwork)
    }
}
