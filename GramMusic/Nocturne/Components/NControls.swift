import SwiftUI
import UIKit

/// Resign the first responder app-wide — used to drop the keyboard when leaving a screen whose
/// find field was focused (SwiftUI otherwise leaves it up during the back transition).
///
/// `@MainActor` because it touches `UIApplication.shared`; every caller is a view, so this costs
/// nothing and stops it being a nonisolated function reaching into main-actor state.
@MainActor
func nHideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension Animation {
    /// Springy pin/unpin + reorder settle, tuned to feel like Telegram's chat-list motion.
    static let pinSpring = Animation.spring(response: 0.42, dampingFraction: 0.78)
}

// MARK: - Pill (capsule button)

enum PillVariant { case primary, light, ghost, glass }
enum PillSize {
    case sm, md, lg
    var height: CGFloat { self == .sm ? 34 : self == .md ? 44 : 52 }
    var font: CGFloat { self == .sm ? 14 : 16 }
    var hPad: CGFloat { self == .lg ? 26 : 20 }
}

/// Capsule button with the 4 variants from Components §Pill.
struct Pill: View {
    @Environment(\.theme) private var theme
    var title: String
    var systemImage: String? = nil
    var variant: PillVariant = .primary
    var size: PillSize = .md
    var fullWidth: Bool = false
    var isLoading = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading { ProgressView().tint(foreground) }
                else if let systemImage { Image(systemName: systemImage).font(.system(size: 18, weight: .semibold)) }
                Text(title).font(size == .sm ? .subheadline.weight(.semibold) : .body.weight(.semibold)).tracking(-0.1)
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: max(44, size.height))
            .padding(.horizontal, size.hPad)
            .foregroundStyle(foreground)
            .modifier(PillSurface(variant: variant, theme: theme))
            .shadow(color: variant == .primary ? theme.accentColor.opacity(0.27) : .clear,
                    radius: 14, y: 8)
        }
        .buttonStyle(NPressable(scale: 0.96))
    }

    private var foreground: Color {
        switch variant {
        case .primary: theme.accentText
        case .ghost: theme.accentColor
        case .light, .glass: theme.text
        }
    }
}

/// Per-variant background for `Pill`. `.glass` is real Liquid Glass on iOS 26 (tinted material
/// below); `.primary` stays a solid accent fill so the brand CTA keeps full contrast.
private struct PillSurface: ViewModifier {
    let variant: PillVariant
    let theme: AppTheme

    func body(content: Content) -> some View {
        switch variant {
        case .glass:
            content.nGlass(Capsule(), theme: theme)
        case .primary:
            content.background(Capsule().fill(theme.brandFill))
        case .light:
            content.background(Capsule().fill(theme.scheme == .dark
                ? Color.white.opacity(0.12)
                : Color(red: 20/255, green: 20/255, blue: 30/255).opacity(0.06)))
        case .ghost:
            content.overlay(Capsule().strokeBorder(theme.accentColor, lineWidth: 1.5))
        }
    }
}

// MARK: - IconButton

/// Round, transparent, ≥44pt tappable icon. (Components §IconButton.)
struct IconButton: View {
    @Environment(\.theme) private var theme
    var systemName: String
    var active: Bool = false
    var size: CGFloat = 22
    var color: Color? = nil
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(color ?? (active ? theme.accentColor : theme.text2))
                .contentShape(Circle())
        }
        .buttonStyle(NPressable(scale: 0.9))
    }
}

// MARK: - Equalizer (now-playing indicator)

/// 4 bars marking the playing track, driven by the live audio loudness
/// (`PlayerEngine.audioLevel`) so they rise and fall with the actual beat. Static when paused
/// or Reduce Motion is on.
struct Equalizer: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PlayerEngine.self) private var player
    var playing: Bool
    var color: Color? = nil
    var barWidth: CGFloat = 3

    private let maxHeight: CGFloat = 16
    private let floor: CGFloat = 0.22
    /// Per-bar weighting so the four bars differ in height (an equalizer look) while all
    /// still tracking the same loudness — a fake spectrum, but it moves with the music.
    private let weights: [CGFloat] = [0.78, 1.0, 0.88, 0.6]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(color ?? theme.accentColor)
                    .frame(width: barWidth, height: barHeight(i))
            }
        }
        .frame(height: maxHeight)
        .animation(.linear(duration: 0.07), value: player.audioLevel)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        guard playing, !reduceMotion else { return maxHeight * floor }
        let level = CGFloat(player.audioLevel) * weights[i]
        return maxHeight * (floor + (1 - floor) * min(1, level))
    }
}

// MARK: - Search chrome

/// Shared metrics so every search surface in the app — the editable `SearchField`, the
/// tappable `SearchBarButton` (Home / Library / find-in-list), and the search overlay —
/// reads identically. The shape is a fully-rounded **capsule**: the iOS-26 Liquid Glass
/// search look, and "rounder corners" everywhere by definition regardless of height.
enum SearchChrome {
    static let height: CGFloat = 44
    static let iconSize: CGFloat = 16
    static let textSize: CGFloat = 16
    static var shape: Capsule { Capsule(style: .continuous) }
}

// MARK: - SearchField

/// Inline **editable** search field (Home global search uses `.searchable` instead; this is
/// for find-in-list and custom search bars). (Components §SearchField.)
struct SearchField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    var prompt: String = "Search"
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: SearchChrome.iconSize, weight: .medium)).foregroundStyle(theme.text3)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(theme.text3))
                .font(.system(size: SearchChrome.textSize)).foregroundStyle(theme.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.text3).frame(width: 44, height: 44)
                }.buttonStyle(.plain).transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: max(44, compact ? 40 : SearchChrome.height))
        .nGlass(SearchChrome.shape, theme: theme)
        .animation(.snappy(duration: 0.2), value: text.isEmpty)
    }
}

// MARK: - SearchBarButton

/// Tappable search bar that opens a search screen (Home, Library, the find-in-list bars).
/// Visually identical to a resting `SearchField` so search looks the same everywhere.
struct SearchBarButton: View {
    @Environment(\.theme) private var theme
    var prompt: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: SearchChrome.iconSize, weight: .medium)).foregroundStyle(theme.text3)
                Text(prompt).font(.system(size: SearchChrome.textSize)).foregroundStyle(theme.text3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: SearchChrome.height)
            .nGlass(SearchChrome.shape, theme: theme, interactive: true)
            // The label is mostly empty space (Spacer right of the prompt); without an
            // explicit hit shape, taps there fall through and the search never opens.
            .contentShape(SearchChrome.shape)
        }
        .buttonStyle(NPressable(scale: 0.98))
    }
}

// MARK: - SectionTitle

/// Shelf / section header (display 21/600) with an optional trailing action link.
struct SectionTitle: View {
    @Environment(\.theme) private var theme
    var title: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
    /// Shows a small spinner next to the title (e.g. a shelf refreshing in the background).
    var loading: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .center, spacing: 8) {
                Text(title).font(.display(21, .semibold)).tracking(-0.4).foregroundStyle(theme.text)
                if loading { ProgressView().controlSize(.small).tint(theme.text3) }
            }
            Spacer()
            if let action, let actionLabel {
                Button(actionLabel, action: action)
                    .font(.subheadline.weight(.medium)).foregroundStyle(theme.text2)
                    .frame(minHeight: 44)
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Scrubber

/// Now-Playing / volume scrubber. Owns its drag state; renders elapsed / -remaining.
struct Scrubber: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var currentTime: Double
    var duration: Double
    /// How far the track has actually downloaded. Drawn as a band between the empty track and the
    /// played fill, the way every streaming player shows it — so a song buffering in from Telegram
    /// tells you it is ready ahead of the playhead rather than looking stalled.
    var bufferedTime: Double = 0
    var overArt: Bool = false
    var onSeek: (Double) -> Void

    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    private var shown: Double { scrubbing ? scrubValue : currentTime }
    private var fill: Color { overArt ? .white : theme.accentColor }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let dur = max(duration, 1)
                let frac = min(max(shown / dur, 0), 1)
                let buffered = min(max(bufferedTime / dur, 0), 1)
                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Capsule().fill((overArt ? Color.white : theme.text).opacity(0.22))
                        // Buffered band: only meaningful ahead of the playhead, and drawn with the
                        // same offset trick as the fill so all three layers share one capsule.
                        if buffered > frac {
                            Capsule().fill(fill.opacity(0.35))
                                .frame(width: geo.size.width)
                                .offset(x: geo.size.width * (buffered - 1))
                        }
                        Capsule().fill(fill)
                            .frame(width: geo.size.width)
                            .offset(x: geo.size.width * (frac - 1))
                    }
                    .clipShape(Capsule())
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                        .offset(x: geo.size.width * frac - 7)
                        .opacity(scrubbing ? 1 : 0)
                }
                .frame(height: scrubbing ? 8 : 6)
                .frame(maxHeight: .infinity, alignment: .center)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: scrubbing)
                .animation(reduceMotion ? nil : (scrubbing ? .interactiveSpring() : .linear(duration: 0.5)), value: frac)
                .animation(reduceMotion ? nil : .linear(duration: 0.5), value: buffered)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in scrubbing = true; scrubValue = min(max(v.location.x / max(geo.size.width, 1), 0), 1) * dur }
                    .onEnded { _ in onSeek(scrubValue); scrubbing = false })
            }
            .frame(height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(Self.time(shown)) of \(Self.time(duration))")
            .accessibilityAdjustableAction { direction in
                let step = 10.0
                switch direction {
                case .increment: onSeek(min(duration, shown + step))
                case .decrement: onSeek(max(0, shown - step))
                @unknown default: break
                }
            }
            HStack {
                Text(Self.time(shown)); Spacer(); Text("-" + Self.time(max(duration - shown, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(overArt ? Color.white.opacity(0.6) : theme.text3)
        }
    }

    static func time(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let i = Int(s); return String(format: "%d:%02d", i / 60, i % 60)
    }
}
