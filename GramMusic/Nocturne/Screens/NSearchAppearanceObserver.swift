import SwiftUI
import UIKit

/// SwiftUI's onAppear runs during a navigation push. Keyboard focus must wait for
/// UIKit's completed appearance so it doesn't resize the page mid-transition.
struct NSearchAppearanceObserver: UIViewControllerRepresentable {
    var onReady: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onReady = onReady
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onReady = onReady
    }

    final class Controller: UIViewController {
        var onReady: (() -> Void)?

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onReady?()
        }
    }
}
