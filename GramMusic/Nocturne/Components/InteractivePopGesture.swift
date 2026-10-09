import SwiftUI
import UIKit

/// Restores the swipe-from-the-left-edge "back" gesture on screens that hide the navigation bar.
///
/// SwiftUI disables `interactivePopGestureRecognizer` whenever the nav bar (or its system back
/// button) is hidden — which is exactly what the Nocturne detail screens do to draw their own
/// floating glass back button (`NDetailScroll`, `NPlaylistDetailView`). Dropping this in the
/// background of such a screen rewires the gesture's delegate so the edge swipe pops the stack
/// again, without showing any UIKit chrome. The `count > 1` guard stops it firing on the root.
struct InteractivePopGesture: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { GestureController() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private final class GestureController: UIViewController, UIGestureRecognizerDelegate {
        // Re-assert on every appearance, not just `didMove`: the recognizer's delegate is weak, so
        // when a deeper screen is popped this controller must reclaim it or the swipe goes dead.
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let recognizer = navigationController?.interactivePopGestureRecognizer else { return }
            recognizer.delegate = self
            recognizer.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

extension View {
    /// Restores the edge-swipe-back gesture on a nav-bar-hidden screen (see `InteractivePopGesture`).
    func interactiveBackSwipe() -> some View {
        background(InteractivePopGesture().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
