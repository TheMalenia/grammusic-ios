import SwiftUI
import Observation

/// User-selectable design choices, persisted in `UserDefaults`. Observed by the root so a
/// change recomputes the injected `AppTheme` and repaints everything. (Design-system §1/§2/§6.)
@MainActor
@Observable
final class AppSettings {
    var themeMode: ThemeMode { didSet { d.set(themeMode.rawValue, forKey: "n_themeMode") } }
    var accentId: String { didSet { d.set(accentId, forKey: "n_accent") } }
    var brand: BrandDirection { didSet { d.set(brand.rawValue, forKey: "n_brand") } }
    var artworkStyle: ArtworkStyle { didSet { d.set(artworkStyle.rawValue, forKey: "n_artwork") } }
    /// When off, Now Playing skips lyric resolution and hides the lyrics page entirely.
    var lyricsEnabled: Bool { didSet { d.set(lyricsEnabled, forKey: "n_lyricsEnabled") } }

    /// Automatically collect songs listened to from search in a local playlist. Opt-in.
    var saveSearchResults: Bool { didSet { d.set(saveSearchResults, forKey: StorageKeys.saveSearchResults) } }

    /// Shows the AI tab. On by default; turning it off hides the tab entirely rather than
    /// disabling it in place, because a visible-but-dead tab is worse than no tab.
    var aiTabEnabled: Bool { didSet { d.set(aiTabEnabled, forKey: "n_aiTabEnabled") } }

    private let d: UserDefaults

    init(defaults: UserDefaults = .standard) {
        d = defaults
        themeMode = ThemeMode(rawValue: d.string(forKey: "n_themeMode") ?? "") ?? .tintedNight
        accentId = d.string(forKey: "n_accent") ?? Accent.default.id
        brand = BrandDirection(rawValue: d.string(forKey: "n_brand") ?? "") ?? .nocturne
        artworkStyle = ArtworkStyle(rawValue: d.string(forKey: "n_artwork") ?? "") ?? .gradient
        saveSearchResults = d.bool(forKey: StorageKeys.saveSearchResults)
        lyricsEnabled = d.object(forKey: "n_lyricsEnabled") as? Bool ?? true
        aiTabEnabled = d.object(forKey: "n_aiTabEnabled") as? Bool ?? true
    }

    var accent: Accent { Accent.named(accentId) }

    /// Resolve the concrete token set for the current system color scheme.
    func theme(for systemScheme: ColorScheme) -> AppTheme {
        themeMode.resolve(systemScheme: systemScheme, accent: accent,
                          brand: brand, artwork: artworkStyle)
    }

    /// `.preferredColorScheme` override (nil = follow system).
    var preferredColorScheme: ColorScheme? {
        switch themeMode {
        case .day, .dayClassic: .light
        case .night, .tintedNight: .dark
        }
    }
}

// MARK: - Environment

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = ThemeMode.tintedNight.resolve(
        systemScheme: .dark, accent: .default, brand: .nocturne, artwork: .gradient)
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension View {
    /// Inject the resolved theme + set the root tint, so stock controls adopt the accent and
    /// every subview can read `@Environment(\.theme)`. Recomputes when settings or scheme change.
    func nocturneTheme(_ settings: AppSettings, scheme: ColorScheme) -> some View {
        let theme = settings.theme(for: scheme)
        return self
            .environment(\.theme, theme)
            .tint(theme.accentColor)
    }
}
