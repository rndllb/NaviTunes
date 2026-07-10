import SwiftUI
#if canImport(UIKit)
import UIKit

/// UIKit anchor for the mini-player zoom source. ``tabViewBottomAccessory`` lives in a
/// separate presentation layer from ``fullScreenCover``, and SwiftUI's
/// ``matchedTransitionSource`` pairing is unreliable there (especially when the accessory
/// re-renders as ``PlaybackEngine`` publishes). We keep the SwiftUI markers for when the
/// system can pair them, and register a concrete ``UIView`` here for
/// ``UIViewController.Transition/zoom(sourceViewProvider:)`` as a fallback.
@MainActor
enum MiniPlayerZoomSourceRegistry {
    weak static var sourceView: UIView?
}

struct MiniPlayerZoomSourceAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        MiniPlayerZoomSourceRegistry.sourceView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        MiniPlayerZoomSourceRegistry.sourceView = uiView
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        if MiniPlayerZoomSourceRegistry.sourceView === uiView {
            MiniPlayerZoomSourceRegistry.sourceView = nil
        }
    }
}

/// Installs UIKit's zoom transition on the Now Playing ``fullScreenCover`` host so dismiss
/// morphs back into the mini player even when SwiftUI's namespace pairing fails.
struct NowPlayingZoomDestinationInstaller: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> InstallerViewController {
        InstallerViewController()
    }

    func updateUIViewController(_ uiViewController: InstallerViewController, context: Context) {
        uiViewController.installZoomIfNeeded()
    }

    final class InstallerViewController: UIViewController {
        private var didInstall = false

        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            scheduleInstall()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            scheduleInstall()
        }

        private func scheduleInstall() {
            guard !didInstall else { return }
            installZoomIfNeeded()
            guard !didInstall else { return }
            // The hosting controller may not be linked into the presentation chain
            // until the first layout pass — retry briefly so open *and* dismiss morphs
            // can pick up the UIKit zoom fallback.
            Task { @MainActor in
                for _ in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(16))
                    installZoomIfNeeded()
                    if didInstall { return }
                }
            }
        }

        func installZoomIfNeeded() {
            guard !didInstall, let presented = presentedHost else { return }
            presented.preferredTransition = .zoom(sourceViewProvider: { _ in
                MiniPlayerZoomSourceRegistry.sourceView
            })
            didInstall = true
        }

        private var presentedHost: UIViewController? {
            var root: UIViewController = self
            while let parent = root.parent {
                root = parent
            }
            if root.presentingViewController != nil { return root }
            // Fallback while the hierarchy is still wiring up.
            var current: UIViewController? = self
            while let vc = current {
                if vc.presentingViewController != nil { return vc }
                current = vc.parent
            }
            return nil
        }
    }
}
#endif
