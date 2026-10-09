import SwiftUI
import UIKit

/// Thin bridge so the SwiftUI chevron's "close" runs the controller's interactive dismiss animation
/// (same motion as the swipe), rather than a plain cut.
@MainActor final class PlayerPresenter {
    var requestClose: () -> Void = {}
}

public struct InteractiveDismissingKey: EnvironmentKey {
    public static let defaultValue = false
}

public extension EnvironmentValues {
    var isInteractiveDismissing: Bool {
        get { self[InteractiveDismissingKey.self] }
        set { self[InteractiveDismissingKey.self] = newValue }
    }
}

/// Presents the Now Playing SwiftUI content **edge-to-edge full-screen** with a native,
/// compositor-driven swipe-down dismiss.
///
/// Why UIKit: a smooth full-bleed interactive dismiss needs the card moved via a layer transform
/// (what `UISheetPresentationController` does), not a per-frame SwiftUI `.offset` — that re-renders
/// and lags. And the swipe must only dismiss when the inner paging scroll is at its top (so it
/// coexists with swipe-up-for-lyrics) — which we get by reading the scroll's offset and disabling
/// its top bounce, then driving the transform ourselves. The player UI stays 100% SwiftUI.
struct InteractivePlayerHost<Content: View>: UIViewControllerRepresentable {
    var presenter: PlayerPresenter
    var onClose: () -> Void
    var onDrivingChanged: (Bool) -> Void
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> InteractivePlayerController {
        let controller = InteractivePlayerController(rootView: AnyView(content()), onClose: onClose)
        controller.onDrivingChanged = onDrivingChanged
        presenter.requestClose = { [weak controller] in controller?.animateDismiss() }
        return controller
    }

    func updateUIViewController(_ controller: InteractivePlayerController, context: Context) {
        controller.onClose = onClose
        controller.onDrivingChanged = onDrivingChanged
        controller.setRootView(AnyView(content()))
        presenter.requestClose = { [weak controller] in controller?.animateDismiss() }
    }
}

final class InteractivePlayerController: UIViewController, UIGestureRecognizerDelegate {
    private let hosting: UIHostingController<AnyView>
    var onClose: () -> Void
    var onDrivingChanged: ((Bool) -> Void)?
    private weak var scrollView: UIScrollView?
    /// True once a downward drag that *started at the top of the scroll* is moving the card.
    private var driving = false {
        didSet {
            if driving != oldValue {
                onDrivingChanged?(driving)
            }
        }
    }

    init(rootView: AnyView, onClose: @escaping () -> Void) {
        self.hosting = UIHostingController(rootView: rootView)
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setRootView(_ view: AnyView) { hosting.rootView = view }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Transparent so the app (tab bar + mini-player) shows behind the card as it slides down,
        // instead of a black gap. Paired with `.presentationBackground(.clear)` on the cover.
        view.backgroundColor = .clear

        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        hosting.view.layer.cornerCurve = .continuous
        hosting.view.layer.masksToBounds = true
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hosting.didMove(toParent: self)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        // Never swallow touches meant for the SwiftUI buttons / scroll — we only *read* the drag.
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
    }

    /// Find the paging scroll once, and keep its top bounce off so a top-pull goes to dismiss
    /// (not an elastic overscroll) — SwiftUI resets it on updates, so re-assert each gesture.
    private func ensureScrollView() {
        if scrollView == nil { scrollView = firstScrollView(in: hosting.view) }
        scrollView?.bounces = false
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        ensureScrollView()
        switch gesture.state {
        case .began:
            driving = false
        case .changed:
            let t = gesture.translation(in: view)
            if !driving {
                let atTop = (scrollView?.contentOffset.y ?? 0) <= 0.5
                if atTop, t.y > 0, abs(t.y) > abs(t.x) {
                    driving = true
                    gesture.setTranslation(.zero, in: view)   // start clean from here
                }
            }
            if driving {
                apply(offset: max(0, gesture.translation(in: view).y))
            }
        case .ended, .cancelled, .failed:
            guard driving else { return }
            driving = false
            let dy = max(0, gesture.translation(in: view).y)
            let vy = gesture.velocity(in: view).y
            if dy > 140 || vy > 900 { animateDismiss() } else { animateBack() }
        default:
            break
        }
    }

    private func apply(offset dy: CGFloat) {
        hosting.view.transform = CGAffineTransform(translationX: 0, y: dy)
        hosting.view.layer.cornerRadius = min(dy / 12, 44)   // rounds as it leaves
    }

    /// Slide the card fully off (rounded), then hand back to SwiftUI to remove the cover.
    func animateDismiss() {
        let h = max(view.bounds.height, 1)
        if hosting.view.layer.cornerRadius == 0 { hosting.view.layer.cornerRadius = 44 }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseIn]) {
            self.hosting.view.transform = CGAffineTransform(translationX: 0, y: h)
        } completion: { _ in
            self.onClose()
        }
    }

    private func animateBack() {
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.hosting.view.transform = .identity
            self.hosting.view.layer.cornerRadius = 0
        }
    }

    // Coexist with the SwiftUI scroll/buttons; we only *act* on a top-started downward drag.
    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }
}
