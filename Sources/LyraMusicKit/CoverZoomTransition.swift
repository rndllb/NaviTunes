import SwiftUI

/// Shared-element "cover zoom" for album / playlist detail pushes.
///
/// Apple-Music-style hero transition built from the stock zoom navigation
/// transition (the NavigationStack equivalent of `matchedGeometryEffect`,
/// matching the player-artwork morph in `RootView`): the tapped cover cell
/// marks itself with ``coverZoomSource(id:)`` and the pushed detail view
/// applies ``coverZoomDestination(id:)``, so the detail grows out of — and
/// collapses back into — the cover's place in the list.
///
/// The `Namespace` is injected through the environment by
/// ``coverZoomContext()`` (applied once per `NavigationStack`), which keeps
/// the source markers one-liners at the ~30 album/playlist entry points and
/// lets the two detail views self-apply the destination side. Everything
/// degrades gracefully: with no context (previews, the deep-link stack) or no
/// visible source for the id (deep links, Go to Album), the push falls back
/// to the standard slide transition.
private struct CoverZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var coverZoomNamespace: Namespace.ID? {
        get { self[CoverZoomNamespaceKey.self] }
        set { self[CoverZoomNamespaceKey.self] = newValue }
    }
}

private struct CoverZoomContext: ViewModifier {
    @Namespace private var namespace

    func body(content: Content) -> some View {
        content.environment(\.coverZoomNamespace, namespace)
    }
}

private struct CoverZoomSource: ViewModifier {
    let id: String
    @Environment(\.coverZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

private struct CoverZoomDestination: ViewModifier {
    let id: String
    @Environment(\.coverZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content
                .navigationTransition(.zoom(sourceID: id, in: namespace))
#if os(iOS)
                .background(ZoomDismissGestureTuner())
#endif
        } else {
            content
        }
    }
}

#if os(iOS)
/// The zoom transition's *gesture* dismissals (edge pan, swipe down, pinch)
/// run an interruptible settle that monopolizes the gesture system — after a
/// swipe-back, the revealed list ignores scrolls until the spring fully lands,
/// while the back button's non-interactive zoom pop delivers touches
/// immediately. There's no SwiftUI API for this, so this helper introspects
/// the navigation controller, disables the zoom-specific dismiss recognizers
/// (identified by class name; unknown names are left untouched, so an OS
/// rename simply restores stock behavior), and revives the classic interactive
/// swipe-back. Net effect: push and back-button pop keep the zoom morph,
/// swipe-back becomes the standard slide pop that scrolls responsively.
private struct ZoomDismissGestureTuner: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Helper { Helper() }
    func updateUIViewController(_ controller: Helper, context: Context) {}

    final class Helper: UIViewController, UIGestureRecognizerDelegate {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let nav = navigationControllerInChain else { return }
            for recognizer in nav.view.gestureRecognizers ?? [] {
                let name = String(describing: type(of: recognizer))
                if name.contains("Parallex") || name.contains("SwipeDown") || name.contains("TransformGesture") {
                    recognizer.isEnabled = false
                }
            }
            if let pop = nav.interactivePopGestureRecognizer {
                pop.isEnabled = true
                pop.delegate = self
            }
        }

        /// Only allow swipe-back when there's something to pop — the
        /// delegate-replacement trick otherwise freezes the stack root.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationControllerInChain?.viewControllers.count ?? 0) > 1
        }

        private var navigationControllerInChain: UINavigationController? {
            var current: UIViewController? = parent
            while let vc = current {
                if let nav = vc.navigationController { return nav }
                current = vc.parent
            }
            return nil
        }
    }
}
#endif

extension View {
    /// Provides the zoom namespace for one `NavigationStack`. Apply to the
    /// stack itself so cells and pushed destinations share it.
    func coverZoomContext() -> some View {
        modifier(CoverZoomContext())
    }

    /// Marks an album/playlist cover cell as the zoom origin. `id` must match
    /// the id the pushed detail passes to ``coverZoomDestination(id:)``
    /// (album id / playlist id / home-mix id).
    func coverZoomSource(id: String) -> some View {
        modifier(CoverZoomSource(id: id))
    }

    /// Applies the zoom transition on a pushed album/playlist detail root.
    func coverZoomDestination(id: String) -> some View {
        modifier(CoverZoomDestination(id: id))
    }
}
