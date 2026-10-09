import SwiftUI

/// Display typeface for big titles / artwork headers. The spec's display face is
/// **Bricolage Grotesque** (bundled variable TTF in `Resources/Fonts`, registered via
/// `UIAppFonts`). We scale it relative to `.title` so it still honors Dynamic Type, and
/// fall back to SF Pro rounded automatically if the font ever fails to resolve.
extension Font {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .custom("Bricolage Grotesque", size: size, relativeTo: .title).weight(weight)
    }
}

/// Press feedback used across Nocturne buttons.
struct NPressable: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.75 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
