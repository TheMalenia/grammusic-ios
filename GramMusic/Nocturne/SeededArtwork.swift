import SwiftUI

/// Deterministic palette derived from a stable seed string (design-system §9). Same seed
/// ⇒ same art forever. Three harmonised hues + initials + a hero-glow accent.
struct ArtworkSeed {
    let hue: Double, hue2: Double, hue3: Double
    let initials: String

    init(_ seed: String) {
        let h = Double(fnv1aHash(seed) % 360)
        hue = h
        hue2 = (h + 38).truncatingRemainder(dividingBy: 360)
        hue3 = (h + 320).truncatingRemainder(dividingBy: 360)
        let words = seed.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap { $0.first }.map(String.init).joined()
        initials = (letters.isEmpty ? String(seed.prefix(1)) : letters).uppercased()
    }

    /// Hero-glow / tint color for the seed.
    var accent: Color { Color(oklchL: 0.66, c: 0.17, h: hue) }
}

/// The seeded fallback cover. Renders one of four styles; real cover art (when present)
/// is layered on top by `Artwork` (components). Cheap enough to use directly in long lists.
struct SeededArtwork: View {
    let seed: String
    var style: ArtworkStyle = .gradient
    var kind: Kind = .track
    var size: CGFloat = 48
    var circle: Bool = false
    /// When true, the fill/glyph stretch to fill the parent's frame (e.g. a full-bleed hero)
    /// instead of clamping to a fixed `size × size` square. `size` still scales the glyph.
    var fillsContainer: Bool = false

    enum Kind { case track, chat, artist, playlist }

    /// Computed, this rebuilt the whole `ArtworkSeed` — hashing the string and splitting it for
    /// initials the gradient path never uses — once per `s.` access, i.e. 3–4× per body.
    private var s: ArtworkSeed { ArtworkSeed(seed) }

    /// Asset-catalog lookup hoisted out of `body`: this is the fallback glyph for every track
    /// without art, in every list.
    private static let fallbackIcon = UIImage(named: "AppIcon")
    private var radius: CGFloat { circle ? size / 2 : max(8, size * 0.16) }

    var body: some View {
        if fillsContainer {
            fill
                .overlay { sheen }
                .overlay { glyph }
        } else {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            fill
                .overlay { sheen }
                .overlay { glyph }
                .frame(width: size, height: size)
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                }
        }
    }

    @ViewBuilder private var fill: some View {
        switch style {
        case .gradient:
            LinearGradient(stops: [
                .init(color: Color(oklchL: 0.64, c: 0.165, h: s.hue), location: 0),
                .init(color: Color(oklchL: 0.50, c: 0.16, h: s.hue2), location: 0.52),
                .init(color: Color(oklchL: 0.40, c: 0.13, h: s.hue3), location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .duotone:
            LinearGradient(colors: [Color(oklchL: 0.58, c: 0.16, h: s.hue),
                                    Color(oklchL: 0.30, c: 0.10, h: s.hue2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .type:
            LinearGradient(colors: [Color(oklchL: 0.42, c: 0.13, h: s.hue),
                                    Color(oklchL: 0.26, c: 0.09, h: s.hue2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .mesh:
            ZStack {
                Color(oklchL: 0.32, c: 0.08, h: s.hue)
                blob(Color(oklchL: 0.68, c: 0.17, h: s.hue), at: .init(x: 0.2, y: 0.2))
                blob(Color(oklchL: 0.62, c: 0.16, h: s.hue2), at: .init(x: 0.85, y: 0.25))
                blob(Color(oklchL: 0.50, c: 0.15, h: s.hue3), at: .init(x: 0.6, y: 0.9))
            }
        }
    }

    private func blob(_ color: Color, at point: UnitPoint) -> some View {
        RadialGradient(colors: [color, .clear], center: point, startRadius: 0, endRadius: size * 0.7)
    }

    private var sheen: some View {
        LinearGradient(stops: [.init(color: .white.opacity(0.18), location: 0),
                               .init(color: .clear, location: 0.42)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder private var glyph: some View {
        switch style {
        case .mesh:
            EmptyView()                                  // mesh carries no glyph
        case .type:
            Text(s.initials)
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        default:
            if kind == .artist {
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            } else {
                if let icon = Self.fallbackIcon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.42, height: size * 0.42)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.1, style: .continuous))
                } else {
                    PlaneMark().fill(Color.white.opacity(0.95))
                        .frame(width: size * 0.42, height: size * 0.42)
                }
            }
        }
    }
}

#Preview {
    let seeds = ["Midnight Drive", "Lo-fi Beats", "Avery Park", "Saved Messages"]
    return VStack(spacing: 16) {
        ForEach(ArtworkStyle.allCases) { style in
            HStack(spacing: 12) {
                ForEach(seeds, id: \.self) { SeededArtwork(seed: $0, style: style, size: 64) }
            }
        }
    }.padding().background(Color.black)
}
