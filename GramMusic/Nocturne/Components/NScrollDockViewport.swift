import SwiftUI

private struct NDockOverlapKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var nDockOverlap: CGFloat? {
        get { self[NDockOverlapKey.self] }
        set { self[NDockOverlapKey.self] = newValue }
    }
}

/// Native scroll content passes behind glass; its resting bottom margin clears the controls.
/// Compatibility docks reserve only their measured overlap.
struct NScrollDockViewport: ViewModifier {
    @Environment(\.nUsesNativePlayerAccessory) private var usesNativeAccessory
    @Environment(\.nMiniDockTop) private var dockTop
    @State private var visibleBottom: CGFloat?
    var base: CGFloat = 0

    private var overlap: CGFloat {
        guard let dockTop, let visibleBottom else { return 0 }
        return max(0, visibleBottom - dockTop)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesNativeAccessory {
            GeometryReader { geometry in
                // Extend the viewport behind the glass. Reserve space inside the scroll
                // content, so its final row can still be brought above the controls.
                let bottomInset = geometry.safeAreaInsets.bottom
                let extraOverlap = dockTop.map {
                    max(0, geometry.frame(in: .global).maxY - $0)
                } ?? 0
                content
                    .contentMargins(.bottom, base + bottomInset + extraOverlap, for: .scrollContent)
                    .environment(\.nDockOverlap, 0)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        } else {
            content
                .contentMargins(.bottom, base, for: .scrollContent)
                .padding(.bottom, overlap)
                .environment(\.nDockOverlap, 0)
                .onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .global).maxY
                } action: { visibleBottom = $0 }
        }
    }
}
