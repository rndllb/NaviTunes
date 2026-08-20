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

        // MARK: Pull-to-reveal search (refresh-control semantics)
        /// The bar's row is always laid out (`hidesSearchBarWhenScrolling = false`) so the
        /// content never shifts; the bar itself is invisible and non-interactive until a
        /// finger-driven pull past the threshold is released, and fades out again once the
        /// user scrolls down. The real list stays the navigation bar's content scroll view,
        /// so pull-to-refresh (whose spinner shares that strip on iOS 26) keeps working.
        private weak var trackedContentScrollView: UIScrollView?
        private var trackedOffsetObservation: NSKeyValueObservation?
        private var isSearchBarRevealed = false
        /// The search controller SwiftUI attached, held here while the bar is hidden so the
        /// navigation item has *no* search row at all (nothing to snap open on a bounce).
        private var parkedSearchController: UISearchController?
        /// Whether the current pan began at rest at the top. Only such a pull may reveal;
        /// a drag that starts lower and carries past the top is "arriving", not "pulling".
        private var panBeganAtTop = false
        /// Finger-driven overscroll (points past the top) at which the bar is attached and
        /// shown, live, during the pull — roughly half a row, so a short overshoot at the top
        /// never shows anything.
        private static let pullRevealThreshold: CGFloat = 16
        /// How far into the content the user must have scrolled (with the row already fully
        /// collapsed) before the controller is parked again.
        private static let scrollAwayCollapseDistance: CGFloat = 24

        /// Parks the search controller the instant SwiftUI attaches it while the bar is
        /// hidden — on a deep-link push that happens *after* `viewWillAppear`, and SwiftUI
        /// can re-attach it on later updates too.
        private var searchControllerObservation: NSKeyValueObservation?

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
            disableZoomContentDismissGestures()
            forceStackedSearchBarPlacement()
            // The bar starts hidden (it's revealed only by a pull, see
            // `installPullToRevealSearch`): park the controller the instant SwiftUI
            // attaches it during the push so no row ever exists mid-transition.
            applySearchBarVisibility(animated: false)
            if let item = parent?.navigationItem {
                searchControllerObservation = item.observe(\.searchController, options: [.new, .initial]) { [weak self] item, _ in
                    guard let self, item.searchController != nil, !self.isSearchBarRevealed else { return }
                    DispatchQueue.main.async { [weak self] in self?.applySearchBarVisibility(animated: false) }
                }
            }
            // No `animated` gate: zoom pushes report animated=false here, and
            // for genuinely instant appearances viewDidAppear follows right
            // behind and clears the phase anyway.
            report(.appearing)
        }

        /// SwiftUI's `.searchable(placement: .automatic)` lets UIKit choose the navigation
        /// item's search placement. On iOS 26 that can resolve to the new *integrated*
        /// placement — the field sits in the title row next to the bar buttons, and
        /// `hidesSearchBarWhenScrolling` is documented as "not applicable and ignored" for
        /// it. On iOS 26.6 this screen (empty inline title, hidden bar background) gets
        /// exactly that: a full-width field jammed under the floating back / ⋯ buttons that
        /// never hides. Force the classic *stacked* placement — its own row below the
        /// buttons, collapsed until the user overscrolls at the top, re-collapsing on
        /// scroll — which is the behaviour SwiftUI offered on 26.3–26.5. Applied on every
        /// appearance so a navigation-item refresh can't flip it back.
        private func forceStackedSearchBarPlacement() {
            guard let item = parent?.navigationItem else { return }
            if item.preferredSearchBarPlacement != .stacked {
                item.preferredSearchBarPlacement = .stacked
            }
            // Native geometry: the row lives in the scroll distance above the content and
            // expands/collapses with the pull. Only *visibility* is ours (see
            // `installPullToRevealSearch`).
            item.hidesSearchBarWhenScrolling = true
        }

        /// Pull-to-reveal with refresh-control semantics. While hidden, the navigation item
        /// has *no* search controller (it is parked here), so no row exists: arriving at the
        /// top — by drag or fling, with or without a bounce — can never show or reserve
        /// space for the bar. A finger-driven pull that *began at rest at the top* and passes
        /// ``pullRevealThreshold`` attaches the controller mid-pull: UIKit lays the row out
        /// under the finger and the bar appears. From then on the row is native
        /// (`hidesSearchBarWhenScrolling`): it shrinks 1:1 as the user scrolls down, and once
        /// fully collapsed the controller is parked again, so scrolling back up does not
        /// re-add it — only the next pull does. Nothing is ever fought mid-gesture, and the
        /// real list stays the bar's content scroll view so pull-to-refresh keeps working.
        private func installPullToRevealSearch() {
            guard let host = parent,
                  let list = Self.firstScrollView(in: host.view) else { return }
            applySearchBarVisibility(animated: false)
            guard trackedContentScrollView !== list else { return }
            trackedContentScrollView = list
            list.panGestureRecognizer.addTarget(self, action: #selector(listPanChanged(_:)))
            trackedOffsetObservation = list.observe(\.contentOffset, options: [.new]) { [weak self] list, _ in
                self?.listOffsetChanged(list)
            }
        }

        @objc private func listPanChanged(_ pan: UIPanGestureRecognizer) {
            guard let list = trackedContentScrollView else { return }
            switch pan.state {
            case .began:
                // `.began` fires after ~10pt of movement; reconstruct the true start offset
                // from the translation (finger down = offset up, 1:1 before any bounce).
                let top = -list.adjustedContentInset.top
                let startOffsetY = list.contentOffset.y + pan.translation(in: list).y
                panBeganAtTop = startOffsetY <= top + 4
            default:
                break
            }
        }

        private func listOffsetChanged(_ list: UIScrollView) {
            let top = -list.adjustedContentInset.top
            let overscroll = top - list.contentOffset.y   // > 0 while pulled past the top
            // Reveal only for a finger-driven pull that *began* at the top and passes the
            // threshold; arriving from below (drag or fling) never counts.
            if panBeganAtTop, list.isDragging, overscroll >= Self.pullRevealThreshold, !isSearchBarRevealed {
                setSearchBarRevealed(true)
            }
            // While revealed, UIKit shrinks the row 1:1 with the finger as the user scrolls
            // down. Only once it has *fully* collapsed (row height 0) do we park the
            // controller — removing it then is invisible, and scrolling back up can no
            // longer re-add the row; only a fresh pull at the top can.
            if isSearchBarRevealed,
               let bar = parent?.navigationItem.searchController?.searchBar,
               bar.bounds.height <= 1,
               list.contentOffset.y > top + Self.scrollAwayCollapseDistance {
                setSearchBarRevealed(false)
            }
        }

        private func setSearchBarRevealed(_ revealed: Bool) {
            guard isSearchBarRevealed != revealed else { return }
            isSearchBarRevealed = revealed
            applySearchBarVisibility(animated: true)
        }

        /// Hidden = the navigation item has no search controller (no row exists at all).
        /// Revealed = the controller is attached and the bar is visible; UIKit lays the row
        /// out under the finger during the qualifying pull.
        private func applySearchBarVisibility(animated: Bool) {
            guard let item = parent?.navigationItem else { return }
            if isSearchBarRevealed {
                if item.searchController == nil, let parked = parkedSearchController {
                    parked.searchBar.alpha = 1
                    parked.searchBar.isUserInteractionEnabled = true
                    if animated {
                        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                            item.searchController = parked
                            item.searchController?.searchBar.superview?.layoutIfNeeded()
                        }
                    } else {
                        item.searchController = parked
                    }
                } else if let sc = item.searchController {
                    sc.searchBar.alpha = 1
                    sc.searchBar.isUserInteractionEnabled = true
                }
            } else if let sc = item.searchController {
                // Park it: row gone, nothing for a bounce to open. Done at rest / while the
                // row is already collapsed, so there is no visible change.
                parkedSearchController = sc
                item.searchController = nil
            }
        }

        private static func firstScrollView(in view: UIView) -> UIScrollView? {
            if let s = view as? UIScrollView { return s }
            for sub in view.subviews {
                if let found = firstScrollView(in: sub) { return found }
            }
            return nil
        }

        /// The zoom navigation transition installs two extra interactive-dismiss gestures
        /// on the zoomed screen: a pull-down ("content swipe dismiss") and a pinch
        /// ("transform"). Pulling down at the top of a playlist/album popped the whole
        /// screen, which fights scrolling the hero and is easy to trigger by accident.
        /// SwiftUI's `.navigationTransition(.zoom)` exposes no `UIZoomTransitionOptions`
        /// (`interactiveDismissShouldBegin`), so the recognizers are switched off by class
        /// name here. The edge swipe-back (`_UIParallaxTransitionPanGestureRecognizer`)
        /// is deliberately left alone. Runs on every appearance because UIKit can
        /// re-enable them across transitions.
        private func disableZoomContentDismissGestures() {
            guard let hostView = parent?.view else { return }
            for recognizer in hostView.gestureRecognizers ?? [] {
                let name = String(describing: type(of: recognizer))
                if name.contains("ContentSwipeDismiss") || name.contains("TransformGesture") {
                    recognizer.isEnabled = false
                }
            }
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
            disableZoomContentDismissGestures()
            forceStackedSearchBarPlacement()
            setBarItemAlpha(1, animated: false)
            report(.idle)
            installPullToRevealSearch()
            // Keep the KVO alive for the screen's lifetime: whenever SwiftUI (re)attaches
            // a search controller while the bar is hidden, park it again immediately so
            // the row never materialises. Deferred one turn to avoid mutating inside KVO.
            searchControllerObservation = parent?.navigationItem.observe(\.searchController, options: [.new]) { [weak self] item, _ in
                guard let self, item.searchController != nil, !self.isSearchBarRevealed else { return }
                DispatchQueue.main.async { [weak self] in self?.applySearchBarVisibility(animated: false) }
            }
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
        let enabledNow = coverZoomDetailInteractionEnabled(phase: phase, isBeingDismissed: isBeingDismissed)
        // Already interactive and the phase just settled to `.idle`: stay armed. Re-arming
        // from scratch here flipped `allowsHitTesting` off for 180ms in the middle of
        // whatever the user was doing (e.g. a scroll that began during the push).
        if interactionArmed, enabledNow { return }
        interactionArmed = false
        armGeneration &+= 1
        let generation = armGeneration
        if enabledNow {
            Task { @MainActor in
                // UIKit reports `.idle` before the zoom morph finishes; hold hero
                // buttons briefly so a list-tap release cannot land on Play / +.
                try? await Task.sleep(for: .milliseconds(180))
                guard generation == armGeneration,
                      coverZoomDetailInteractionEnabled(phase: phase, isBeingDismissed: isBeingDismissed)
                else { return }
                interactionArmed = true
            }
        } else if phase == .appearing, !isBeingDismissed {
            // The zoom push takes ~0.9s to report `viewDidAppear` on device, and waiting
            // for it froze the whole detail (scrolling included) for over a second after
            // every open. The only thing the gate must stop is a finger still down from
            // the list tap landing on a control under the morph, which a short hold
            // covers — so arm early while the push is still animating. Dismissals
            // (`isBeingDismissed` / `.dismissing`) keep the full gate.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard generation == armGeneration,
                      !isBeingDismissed,
                      phase == .appearing || phase == .idle
                else { return }
                interactionArmed = true
            }
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
