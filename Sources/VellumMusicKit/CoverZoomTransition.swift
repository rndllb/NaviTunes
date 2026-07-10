import SwiftUI

#if DEBUG
/// A/B switch for on-simulator verification: launching with
/// `VELLUM_DEBUG_DISABLE_DISMISS_FIXES=1` restores pre-fix dismiss behavior.
/// Always false in Release.
let vellumDismissFixesDisabledForAB =
    ProcessInfo.processInfo.environment["VELLUM_DEBUG_DISABLE_DISMISS_FIXES"] != nil
#else
let vellumDismissFixesDisabledForAB = false
#endif

/// Whether pushed album/playlist detail chrome should accept taps. Disabled while
/// the cover-zoom push/pop is in flight so a finger still down from the list tap
/// — or a fast re-tap during dismiss — cannot fire Play / Request / + underneath.
func coverZoomDetailInteractionEnabled(
    phase: CoverZoomTransitionPhase,
    isBeingDismissed: Bool = false
) -> Bool {
    guard !vellumDismissFixesDisabledForAB else { return true }
    return !isBeingDismissed && phase == .idle
}

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

/// Where a pushed detail sits in its transition lifecycle. Driven by UIKit
/// appearance callbacks, which — unlike SwiftUI's `isPresented` — fire at the
/// *start* of an interactive pop gesture and again when it cancels.
enum CoverZoomTransitionPhase {
    /// Fully presented or fully covered — safe to mutate.
    case idle
    /// The push (or a return-to-this-view transition) is animating. The
    /// initial synchronous render is fine, but *async* results must not land
    /// now: a swipe-back that interrupts a push mid-mutation strands the
    /// detail's navigation chrome over the list (the "stuck top buttons"
    /// state) — park them until `.idle`.
    case appearing
    /// A disappearance transition is running: the user is mid-swipe-back, a
    /// pop animation is settling, or a forward push is animating over this
    /// view. Mutating the view now cancels/derails an interactive transition
    /// and holds the gesture system captive — park async results until the
    /// transition resolves.
    case dismissing
    /// Pop committed: `viewDidDisappear` fired and `isMovingFromParent` was
    /// true — the view is no longer in the navigation stack. This is a
    /// stronger drop signal than `.idle` from `isBeingDismissed`, which is
    /// set via a SwiftUI `onChange` that can lag one render cycle behind
    /// UIKit. Using `.gone` closes the narrow window where the loop exits
    /// with `.idle` before `isBeingDismissed` has been written.
    case gone
}

private struct CoverZoomDestination: ViewModifier {
    let id: String
    var dismissalPhase: Binding<CoverZoomTransitionPhase>?
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
    @Binding var phase: CoverZoomTransitionPhase

    func makeUIViewController(context: Context) -> Helper {
        let helper = Helper()
        helper.report = { phase = $0 }
        return helper
    }

    func updateUIViewController(_ controller: Helper, context: Context) {
        controller.report = { phase = $0 }
    }

    final class Helper: UIViewController {
        var report: (CoverZoomTransitionPhase) -> Void = { _ in }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
#if DEBUG
            DebugUIRemote.log("PHASE willAppear animated=\(animated)")
#endif
            // Returning from a deeper push (e.g. the Kill Mode list): restore
            // the bar items hidden in viewWillDisappear as early as possible —
            // waiting for didAppear leaves them invisible through the whole
            // pop-back animation.
            setBarItemAlpha(1, animated: false)
            // No `animated` gate: zoom pushes report animated=false here, and
            // for genuinely instant appearances viewDidAppear follows right
            // behind and clears the phase anyway.
            report(.appearing)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
#if DEBUG
            DebugUIRemote.log("PHASE willDisappear")
#endif
            report(.dismissing)
            // Fade the bar-item content out in place as the dismissal/pop begins.
            // SwiftUI toolbar items live in the navigation item's leading/trailing
            // item *groups* (rightBarButtonItems stays empty), and UINavigationBar
            // animates the item containers itself during a pop — alpha on the
            // hosted customView is the one knob it leaves alone, so the buttons
            // cross-fade where they sit instead of sweeping right with the bar.
            // Fires for both pops and forward pushes; restored in viewDidAppear
            // (cancelled swipe-back or return from a deeper push).
            if !vellumDismissFixesDisabledForAB {
                setBarItemAlpha(0, animated: true)
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            // A committed pop reports .gone so the load pipeline can drop its
            // result without waiting for the SwiftUI onChange that sets
            // isBeingDismissed — that onChange fires one render cycle after
            // this UIKit callback, leaving a race window. `isMovingFromParent`
            // alone is unreliable here: it's set on the popped *hosting
            // controller* (this helper's parent), only propagates to child
            // controllers for interactive pops, and by didDisappear the
            // hosting controller is often already detached (flag reset). The
            // detachment itself is the durable commit signal. CAVEAT: a view
            // covered by a forward push can ALSO be detached by NavigationStack
            // (seen with the Kill Mode list push), so `.gone` may be a false
            // positive here — every appearance hook above must fully recover
            // (bar alpha + phase), and the SwiftUI side resets `.gone` on
            // reappear too.
            let popped = isMovingFromParent
                || (parent?.isMovingFromParent ?? false)
                || parent?.parent == nil
#if DEBUG
            DebugUIRemote.log("PHASE didDisappear popped=\(popped)")
#endif
            report(popped ? .gone : .idle)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Fully presented again — first appearance, a cancelled swipe-back,
            // or a return from a deeper push. Restore nav-bar items hidden in
            // viewWillDisappear.
#if DEBUG
            DebugUIRemote.log("PHASE didAppear")
#endif
            setBarItemAlpha(1, animated: false)
            report(.idle)
        }

        /// Applies `alpha` to the hosted content of every leading/trailing
        /// bar item group on the navigation stack entry's navigation item.
        private func setBarItemAlpha(_ alpha: CGFloat, animated: Bool) {
            guard let item = parent?.navigationItem else { return }
            let views = (item.trailingItemGroups + item.leadingItemGroups)
                .flatMap(\.barButtonItems)
                .compactMap(\.customView)
            guard !views.isEmpty else { return }
            if animated {
                UIView.animate(withDuration: 0.15) {
                    views.forEach { $0.alpha = alpha }
                }
            } else {
                views.forEach { $0.alpha = alpha }
            }
        }
    }
}
#endif

/// Flags a pushed detail view the moment its pop begins.
struct DetailDismissTracker: ViewModifier {
    @Environment(\.isPresented) private var isPresented
    @Binding var isBeingDismissed: Bool

    func body(content: Content) -> some View {
        content.onChange(of: isPresented) { _, presented in
            if !presented {
                if !vellumDismissFixesDisabledForAB { isBeingDismissed = true }
            }
        }
    }
}

private struct CoverZoomDetailInteractionGate: ViewModifier {
    @Binding var phase: CoverZoomTransitionPhase
    @Binding var isBeingDismissed: Bool
    @State private var interactionArmed = false
    @State private var armGeneration = 0

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(
                vellumDismissFixesDisabledForAB
                    || (interactionArmed
                        && coverZoomDetailInteractionEnabled(
                            phase: phase,
                            isBeingDismissed: isBeingDismissed
                        ))
            )
            .onAppear { scheduleInteractionArming() }
            .onChange(of: phase) { _, _ in scheduleInteractionArming() }
            .onChange(of: isBeingDismissed) { _, _ in scheduleInteractionArming() }
    }

    private func scheduleInteractionArming() {
        guard !vellumDismissFixesDisabledForAB else {
            interactionArmed = true
            return
        }
        interactionArmed = false
        guard coverZoomDetailInteractionEnabled(phase: phase, isBeingDismissed: isBeingDismissed) else {
            return
        }
        armGeneration &+= 1
        let generation = armGeneration
        Task { @MainActor in
            // UIKit reports `.idle` before the zoom morph finishes; hold hero
            // buttons briefly so a list-tap release cannot land on Play / +.
            try? await Task.sleep(for: .milliseconds(180))
            guard generation == armGeneration,
                  coverZoomDetailInteractionEnabled(phase: phase, isBeingDismissed: isBeingDismissed)
            else { return }
            interactionArmed = true
        }
    }
}

extension View {
    /// Provides the zoom namespace for one `NavigationStack`. Apply to the
    /// stack itself so cells and pushed destinations share it.
    func coverZoomContext() -> some View {
        modifier(CoverZoomContext())
    }

    func detailDismissTracker(isBeingDismissed: Binding<Bool>) -> some View {
        modifier(DetailDismissTracker(isBeingDismissed: isBeingDismissed))
    }

    /// Gate hero Play / Request / + and track rows during cover-zoom transitions.
    func coverZoomDetailHitTesting(
        phase: Binding<CoverZoomTransitionPhase>,
        isBeingDismissed: Binding<Bool> = .constant(false)
    ) -> some View {
        modifier(CoverZoomDetailInteractionGate(phase: phase, isBeingDismissed: isBeingDismissed))
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
        dismissalPhase: Binding<CoverZoomTransitionPhase>? = nil
    ) -> some View {
        modifier(CoverZoomDestination(id: id, dismissalPhase: dismissalPhase))
    }
}
