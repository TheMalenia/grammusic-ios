import SwiftUI
import UIKit

// Color utilities for the "Nocturne" design system: channel access, blending, an
// OKLCH→sRGB converter (for the seeded-artwork engine), and the FNV-1a hash.
// `Color(hex:)` already exists in Views/Theme.swift and is reused.

extension Color {
    /// sRGB components (0–1) of this color, resolved in the given scheme-agnostic space.
    var rgba: (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }

    /// The `#RRGGBB` hex string representation of this color.
    var hexString: String {
        let (r, g, b, _) = rgba
        return String(format: "#%02lX%02lX%02lX",
                      lround(r * 255),
                      lround(g * 255),
                      lround(b * 255))
    }

    /// Linear blend toward `other` by `amount` (0…1), preserving this color's alpha.
    /// `mix(accent 22%, base)` in the spec == `base.blended(with: accent, amount: 0.22)`.
    func blended(with other: Color, amount: Double) -> Color {
        let a = rgba, b = other.rgba
        let t = max(0, min(1, amount))
        return Color(.sRGB,
                     red: a.r + (b.r - a.r) * t,
                     green: a.g + (b.g - a.g) * t,
                     blue: a.b + (b.b - a.b) * t,
                     opacity: a.a)
    }

    /// Construct an sRGB color from OKLCH (L 0–1, C chroma, H degrees). Used by the
    /// seeded-artwork engine for vivid, perceptually-even placeholder gradients.
    init(oklchL L: Double, c C: Double, h Hdeg: Double, opacity: Double = 1) {
        let h = Hdeg * .pi / 180
        let a = C * cos(h), bb = C * sin(h)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * bb
        let m_ = L - 0.1055613458 * a - 0.0638541728 * bb
        let s_ = L - 0.0894841775 * a - 1.2914855480 * bb
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        let r =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        func gamma(_ x: Double) -> Double {
            let x = max(0, min(1, x))
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        self.init(.sRGB, red: gamma(r), green: gamma(g), blue: gamma(b), opacity: opacity)
    }
}

/// 32-bit FNV-1a hash of a string — the basis of the deterministic seeded artwork.
/// Same seed ⇒ same hue forever.
func fnv1aHash(_ string: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for byte in string.utf8 { h = (h ^ UInt32(byte)) &* 16777619 }
    return h
}
