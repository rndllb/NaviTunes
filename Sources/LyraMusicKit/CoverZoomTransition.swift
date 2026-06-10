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

/// Where a pushed detail sits in its dismissal lifecycle. Driven by UIKit
/// appearance callbacks, which — unlike SwiftUI's `isPresented` — fire at the
/// *start* of an interactive pop gesture and again when it cancels.
enum CoverZoomDismissalPhase {
    /// Fully presented or fully covered — safe to mutate.
    case idle
    /// A disappearance transition is running: the user is mid-swipe-back, a
    /// pop animation is settling, or a forward push is animating over this
    /// view. Mutating the view now cancels/derails an interactive transition
    /// and holds the gesture system captive — park async results until the
    /// transition resolves. (Whether to then drop them is decided by the
    /// `isPresented`-based commit tracker, since SwiftUI's NavigationStack
    /// never sets `isMovingFromParent` on popped hosting controllers.)
    case dismissing
}

private struct CoverZoomDestination: ViewModifier {
    let id: String
    var dismissalPhase: Binding<CoverZoomDismissalPhase>?
    @Environment(\.coverZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content
                .navigationTransition(.zoom(sourceID: id, in: namespace))
#if os(iOS)
                .background {
                    if let dismissalPhase {
                        CoverZoomDismissalObserver(phase: dismissalPhase)
                    }
                }
#endif
        } else {
            content
        }
    }
}

#if os(iOS)
/// Reports the host detail view's dismissal lifecycle through UIKit's
/// appearance callbacks. As a child view controller of the SwiftUI hosting
/// controller it receives the same callbacks, and they fire at interactive-pop
/// *gesture start* (`viewWillDisappear`), at commit (`viewDidDisappear`), and
/// on gesture cancel (`viewDidAppear` again) — none of which SwiftUI exposes.
/// Forward navigation (pushing deeper, presenting the player) also reports
/// `.dismissing` while its transition runs; that's deliberate — mutating mid
/// transition is never safe — and it resolves to `.idle` at `didDisappear`.
private struct CoverZoomDismissalObserver: UIViewControllerRepresentable {
    @Binding var phase: CoverZoomDismissalPhase

    func makeUIViewController(context: Context) -> Helper {
        let helper = Helper()
        helper.report = { phase = $0 }
        return helper
    }

    func updateUIViewController(_ controller: Helper, context: Context) {
        controller.report = { phase = $0 }
    }

    final class Helper: UIViewController {
        var report: (CoverZoomDismissalPhase) -> Void = { _ in }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
#if DEBUG
            DebugUIRemote.log("PHASE willDisappear")
#endif
            report(.dismissing)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
#if DEBUG
            DebugUIRemote.log("PHASE didDisappear")
#endif
            report(.idle)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Fully presented again — first appearance or a canceled
            // interactive dismissal.
#if DEBUG
            DebugUIRemote.log("PHASE didAppear")
#endif
            report(.idle)
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
    /// Pass `dismissalPhase` when the detail mutates state from async work —
    /// hydrating while `.dismissing` cancels the user's swipe-to-go-back and
    /// holds the gesture system captive, so such work must wait the phase out.
    func coverZoomDestination(
        id: String,
        dismissalPhase: Binding<CoverZoomDismissalPhase>? = nil
    ) -> some View {
        modifier(CoverZoomDestination(id: id, dismissalPhase: dismissalPhase))
    }
}
