import SwiftUI

/// One of the 7 user-selectable accent colors. Harmonious set (similar lightness/chroma,
/// varying hue). Order matters — shown as a row of dots in Settings. Default is Indigo.
struct Accent: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let hex: UInt32

    var color: Color { Color(hex: hex) }

    /// The accent fill gradient used on the PlaneMark logo tile and smart-playlist covers:
    /// `linear(150°, mix(accent,white 14%), accent @52%, mix(accent,black 30%))`.
    var fillGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: color.blended(with: .white, amount: 0.14), location: 0),
                .init(color: color, location: 0.52),
                .init(color: color.blended(with: .black, amount: 0.30), location: 1),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let all: [Accent] = [
        Accent(id: "logo", name: "Logo", hex: 0x5FB0EC),       // default
        Accent(id: "indigo", name: "Indigo", hex: 0x6A4FE6),
        Accent(id: "blue",   name: "Telegram", hex: 0x3FA0F2),
        Accent(id: "violet", name: "Violet", hex: 0x9A45E0),
        Accent(id: "cyan",   name: "Cyan", hex: 0x22B8D6),
        Accent(id: "green",  name: "Green", hex: 0x2BC07E),
        Accent(id: "amber",  name: "Amber", hex: 0xE8A33C),
        Accent(id: "rose",   name: "Rose", hex: 0xF2588E),
    ]

    static let `default` = all[0]
    static func named(_ id: String) -> Accent { all.first { $0.id == id } ?? `default` }
}

/// Brand flavor. Nocturne (default) = flat accent fills; Aurora = the legacy blue→violet
/// gradient fills and a deeper indigo background.
enum BrandDirection: String, CaseIterable, Identifiable {
    case nocturne, aurora
    var id: String { rawValue }
    var label: String { self == .nocturne ? "Nocturne" : "Aurora" }

    /// Legacy Aurora gradient (135°, blue→indigo→violet).
    static let auroraGradient = LinearGradient(
        stops: [
            .init(color: Color(hex: 0x3FA0F2), location: 0),
            .init(color: Color(hex: 0x6A4FE6), location: 0.52),
            .init(color: Color(hex: 0x9A45E0), location: 1),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Seeded-artwork fallback style (user setting).
enum ArtworkStyle: String, CaseIterable, Identifiable {
    case gradient, mesh, type, duotone
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
