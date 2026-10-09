import SwiftUI

/// Shared primitives that used to live in the old `Views/` layer (Theme.swift / Brand.swift /
/// ArtistView.swift). Relocated here so the Nocturne UI owns them after the old layer was retired.

/// Navigation value for an artist page (a performer name from track metadata).
struct Artist: Hashable, Identifiable {
    let name: String
    var id: String { name.lowercased() }
}

extension Color {
    /// Build a color from a packed `0xRRGGBB` literal.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

private struct NMiniDockTopKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct NUsesNativePlayerAccessoryKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NMiniDockHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var nMiniDockHeight: CGFloat? {
        get { self[NMiniDockHeightKey.self] }
        set { self[NMiniDockHeightKey.self] = newValue }
    }
    var nUsesNativePlayerAccessory: Bool {
        get { self[NUsesNativePlayerAccessoryKey.self] }
        set { self[NUsesNativePlayerAccessoryKey.self] = newValue }
    }
    /// Global top edge of the mini-player/offline dock; nil on screens without a dock.
    var nMiniDockTop: CGFloat? {
        get { self[NMiniDockTopKey.self] }
        set { self[NMiniDockTopKey.self] = newValue }
    }
}

extension View {
    /// Bottom clearance so scroll content isn't hidden behind the mini-player.
    ///
    /// Native accessories manage scroll safe areas on iOS 26.1+. Conventional per-tab
    /// docks need explicit clearance when playback starts after a screen is laid out.
    /// Pass the screen's resting bottom inset as `base`.
    func nMiniPlayerClearance(_ playing: Bool, offline: Bool = false, base: CGFloat = 0) -> some View {
        modifier(NMiniPlayerClearance(playing: playing, offline: offline, base: base))
    }
    
    func nMiniPlayerClearance(_ playing: Bool, base: CGFloat) -> some View {
        nMiniPlayerClearance(playing, offline: false, base: base)
    }
}

private struct NMiniPlayerClearance: ViewModifier {
    @Environment(\.nUsesNativePlayerAccessory) private var usesNativeAccessory
    @Environment(\.nMiniDockHeight) private var dockHeight
    @Environment(\.nDockOverlap) private var overlap
    let playing: Bool
    let offline: Bool
    let base: CGFloat

    func body(content: Content) -> some View {
        // Native accessories update scroll safe areas themselves; reserving the legacy
        // dock height as well would leave a large empty gap at the end of every list.
        let legacyHeight = (playing || offline) ? (dockHeight ?? (playing ? 72 : 0) + (offline ? 50 : 0)) : 0
        // A late offline notice is custom chrome; unlike the system player accessory,
        // its new safe area can be missed by an already visible navigation scroll view.
        let nativeOfflineHeight = offline ? (dockHeight ?? 50) : 0
        content.padding(.bottom, base + (overlap ?? (usesNativeAccessory ? nativeOfflineHeight : legacyHeight)))
    }
}

extension String {
    /// Up to two uppercase initials for avatars.
    var avatarInitials: String {
        let words = split(separator: " ").prefix(2)
        return words.compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    /// True if the string contains any Persian/Arabic-script characters. Used to fall back from the
    /// display typeface (no Persian glyphs) to the system font for those titles.
    var containsPersian: Bool {
        unicodeScalars.contains { scalar in
            (0x0600...0x06FF).contains(scalar.value) ||   // Arabic
            (0x0750...0x077F).contains(scalar.value) ||   // Arabic Supplement
            (0xFB50...0xFDFF).contains(scalar.value) ||   // Arabic Presentation Forms-A
            (0xFE70...0xFEFF).contains(scalar.value)      // Arabic Presentation Forms-B
        }
    }
}

/// The brand glyph — a paper-plane silhouette that also reads as a play triangle
/// (Telegram heritage + the player Telegram lacks). Drawn in a normalised 100×100 box.
struct PlaneMark: Shape {
    func path(in rect: CGRect) -> Path {
        let pts: [CGPoint] = [
            CGPoint(x: 22, y: 14),   // top tail
            CGPoint(x: 88, y: 50),   // nose / play tip (right)
            CGPoint(x: 22, y: 86),   // bottom tail
            CGPoint(x: 43, y: 50),   // inner fold (concave back — the paper-plane notch)
        ]
        let s = min(rect.width, rect.height) / 100
        let ox = rect.minX + (rect.width  - 100 * s) / 2
        let oy = rect.minY + (rect.height - 100 * s) / 2
        var p = Path()
        p.move(to: CGPoint(x: ox + pts[0].x * s, y: oy + pts[0].y * s))
        for pt in pts.dropFirst() {
            p.addLine(to: CGPoint(x: ox + pt.x * s, y: oy + pt.y * s))
        }
        p.closeSubpath()
        return p
    }
}
