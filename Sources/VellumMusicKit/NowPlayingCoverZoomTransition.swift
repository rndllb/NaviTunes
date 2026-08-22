import SwiftUI

/// Identity for the mini-player ↔ full-player cover zoom.
///
/// Outside the UIKit guard on purpose: the call sites that mark the two anchors
/// (`MiniPlayerView`, `NowPlayingView`) also build for macOS, where the anchor modifiers are
/// no-ops but the id still has to resolve.
enum NowPlayingCoverZoom {
    /// Matched by `CoverZoomRegistry.heroKind(for:)` so the player's hero rect is cached under
    /// its own kind and never overwrites the album detail's.
    static let id = "__now_playing__"
}

/// Hides the player's *own* hero artwork while the transition carries a copy of it.
///
/// Only one cover may be on screen at a time — two is what reads as the artwork swapping
/// identity partway through. The animator snapshots the player's cover, hides the original, and
/// flies the snapshot; this is the switch.
///
/// Observed by the artwork subview alone, never by `NowPlayingView` itself: a publish here must
/// not re-run the whole player body mid-transition (`Rules/swiftui-body-cost.md`).
@MainActor
final class NowPlayingHeroFlight: ObservableObject {
    static let shared = NowPlayingHeroFlight()

    @Published var isHidden = false
}

/// Applied to the player's hero artwork so ``NowPlayingHeroFlight`` can take it off screen for
/// the length of a transition.
struct NowPlayingHeroFlightModifier: ViewModifier {
    @ObservedObject private var flight = NowPlayingHeroFlight.shared

    func body(content: Content) -> some View {
        content.opacity(flight.isHidden ? 0 : 1)
    }
}

extension View {
    func nowPlayingHeroFlightHiding() -> some View {
        modifier(NowPlayingHeroFlightModifier())
    }
}

/// The one piece of player state the dismiss gesture needs, kept off `AppModel` on purpose:
/// every view observes the whole of that object, so a publish re-runs every visible `body`
/// (`Rules/swiftui-body-cost.md`). This is read imperatively by a gesture recognizer and never
/// drives a render.
@MainActor
final class NowPlayingCoverState {
    static let shared = NowPlayingCoverState()

    /// How deep the player's own navigation is. A swipe down inside a pushed artist or album
    /// belongs to that screen, not to the dismiss.
    var libraryNavigationDepth = 0
}

#if canImport(UIKit)
import UIKit

/// The mini player's cover zoom, driven by the **same animator** as album / playlist detail.
///
/// Why this exists, in one paragraph: the pill used UIKit's system `.zoom`
/// (`preferredTransition = .zoom(sourceViewProvider:)`), and opening the player then immediately
/// swiping it back down left the app unresponsive — device log, `NP-PROBE`: taps landed on real
/// views (`UIKitTabBarBottomAccessory`, the list) with no navigation transition in flight, yet
/// nothing responded, and the app's content was still inside a `UITransitionView` — the modal
/// presentation container — seconds after the cover had animated away. An interrupted system
/// zoom does not finish tearing its presentation down. That is the same class of failure
/// `CoverZoomCustomTransition.swift` was written for on the navigation side, and the fix is the
/// same one: stop asking UIKit to own the motion. Our animator always reaches
/// `completeTransition`, and its `finish(committed:)` is the single place a transition can end.
///
/// Nothing in `CoverZoomCustomTransition.swift` is modified by this file. `CoverZoomAnimator` is
/// a plain `UIViewControllerAnimatedTransitioning`, and that protocol is identical for a modal
/// present/dismiss and a navigation push/pop — `.push` is the open, `.pop` is the close. What
/// this file adds is the three things that were navigation-shaped: a
/// `UIViewControllerTransitioningDelegate` instead of a `UINavigationControllerDelegate`, a
/// downward drag instead of a left-edge one, and the two anchors that give the animator its
/// geometry (the pill's artwork, the player's hero artwork).

// MARK: - Transitioning delegate

/// Vends the animator for the cover's present and dismiss, and owns the drag that drives the
/// interactive close.
///
/// The presentation itself belongs to ``NowPlayingCoverPresenter``, not to SwiftUI. That is the
/// second half of the fix and the more important one: while `fullScreenCover` owned it, every
/// dismiss went through `SwiftUI.SheetBridge.preferencesDidChange`, and both crash reports off
/// the device end there —
///
///     -[UIViewController dismissViewControllerAnimated:completion:]
///     -[UIViewController _dismissViewControllerWithAnimationController:interactionController:…]
///         → objc_exception_throw
///
/// SheetBridge dismisses whenever the binding changes, including on top of a transition that has
/// not finished, and no animator can make that safe. Owning `present`/`dismiss` means the calls
/// can simply be refused while UIKit is busy.
@MainActor
final class NowPlayingCoverZoomController: NSObject, UIViewControllerTransitioningDelegate, UIGestureRecognizerDelegate {
    /// Starts the interactive close. Set by the presenter, which dismisses immediately rather
    /// than waiting for a SwiftUI round-trip — the drag must not lose its first frames.
    var requestDismiss: () -> Void = {}
    /// Called when a drag is released short of the threshold. UIKit has cancelled the dismissal
    /// by then, so the cover never left and this only puts SwiftUI's binding back.
    var restorePresentation: () -> Void = {}
    /// True once the present transition has finished, straight from its completion handler.
    var isSettled = false
    /// False while the player has something pushed inside it — a swipe down there belongs to
    /// that screen.
    var canDismiss: () -> Bool = { true }

    private weak var host: UIViewController?
    private weak var pan: UIPanGestureRecognizer?
    private weak var dismissAnimator: NowPlayingCoverAnimator?
    private var interaction: NowPlayingCoverInteraction?
    /// True from the drag's `.began` until UIKit has been told how it ended. Read by the
    /// presenter's stuck-transition guardrail: a finger still down is not a stuck transition,
    /// and treating it as one tore the cover away mid-drag.
    private(set) var isInteractiveDismiss = false
    private var dragStart: CGPoint = .zero

    // MARK: Install

    func attach(to host: UIViewController) {
        if self.host !== host {
            self.host = host
            // Never both mechanisms: `preferredTransition` takes precedence over a
            // transitioning delegate, so the system zoom would simply win and nothing here
            // would ever be asked for an animator.
            host.preferredTransition = nil
            host.modalPresentationStyle = .fullScreen
            host.transitioningDelegate = self
        }
        installPan()
    }

    private func installPan() {
        // `host.view`, not `viewIfLoaded`: attach happens before the controller is presented, so
        // the view does not exist yet and the guarded version installed nothing at all — which
        // is why swipe-to-dismiss did nothing on the first build of this. The presenter loads
        // and lays the view out before presenting anyway (see `presentCover`).
        guard pan == nil, let view = host?.view else { return }
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        recognizer.maximumNumberOfTouches = 1
        view.addGestureRecognizer(recognizer)
        pan = recognizer
    }

    /// Re-attaches the drag if the recognizer's view is no longer the controller's.
    func reinstallPanIfNeeded() {
        guard let host else { return }
        if let pan, pan.view === host.viewIfLoaded { return }
        if let pan { pan.view?.removeGestureRecognizer(pan) }
        self.pan = nil
        installPan()
    }

    // MARK: UIViewControllerTransitioningDelegate

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        NowPlayingCoverAnimator(direction: .present)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        let animator = NowPlayingCoverAnimator(direction: .dismiss)
        dismissAnimator = animator
        // A drag already under way needs its interaction controller built against *this*
        // animator — `interactionControllerForDismissal` is asked immediately after this.
        if isInteractiveDismiss {
            interaction = NowPlayingCoverInteraction(animator: animator)
        }
        return animator
    }

    func interactionControllerForDismissal(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        // Only a finger-driven close is interactive. A tap-away or a deep link dismisses with
        // the plain animation.
        isInteractiveDismiss ? interaction : nil
    }

    // MARK: Drag

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        // **Window coordinates, never the pan's own view.** The animator moves that view every
        // frame (`clip.frame`, `detail.center`), so measuring the finger against it feeds each
        // update back into the next: on device the page jittered across the screen, several
        // frames of it half off the left edge. The window does not move, and for a full-screen
        // presentation it shares the transition container's coordinate space — which is what
        // `CoverZoomAnimator.updateDrag(start:finger:)` expects.
        guard let space = pan.view?.window ?? pan.view else { return }
        let finger = pan.location(in: space)

        switch pan.state {
        case .began:
            dragStart = finger
            isInteractiveDismiss = true
#if DEBUG
            DebugUIRemote.log("NP-DRAG began at \(Int(finger.x)),\(Int(finger.y))")
#endif
            // SwiftUI drives the dismissal; UIKit then asks us for the animator and the
            // interaction controller, in that order, and the drag takes over from there.
            requestDismiss()
        case .changed:
            interaction?.update(fraction: dismissFraction(for: finger, in: space))
        case .ended:
            let translation = pan.translation(in: space).y
            let velocity = pan.velocity(in: space).y
            endDrag(committed: translation > 140 || velocity > 900)
        case .cancelled, .failed:
            endDrag(committed: false)
        default:
            break
        }
    }

    /// How far through the dismiss the finger is. Travel is measured against the screen so the
    /// card is roughly back in the pill by the time the finger reaches the bottom.
    private func dismissFraction(for finger: CGPoint, in space: UIView) -> CGFloat {
        let travel = max(space.bounds.height * 0.55, 1)
        return max(0, min(1, (finger.y - dragStart.y) / travel))
    }

    private func endDrag(committed: Bool) {
        guard isInteractiveDismiss else { return }
        isInteractiveDismiss = false
        interaction?.finish(committed: committed)
        if !committed {
            // UIKit cancelled the dismissal, so the cover never left. SwiftUI was told it did.
            restorePresentation()
        }
        interaction = nil
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
#if DEBUG
        let t = pan.translation(in: view)
        DebugUIRemote.log(
            "NP-DRAG shouldBegin settled=\(isSettled) canDismiss=\(canDismiss()) "
            + "inFlight=\(isInteractiveDismiss) coordinator=\(host?.transitionCoordinator != nil) "
            + "dx=\(Int(t.x)) dy=\(Int(t.y)) "
            + "overScroll=\(isOverScrolledContent(at: pan.location(in: view), in: view))"
        )
#endif
        // Never start a close on top of an unfinished open, and never start a second one.
        guard isSettled, canDismiss(), !isInteractiveDismiss else { return false }
        guard host?.transitionCoordinator == nil else { return false }
        // Downward, and more vertical than horizontal — everything else belongs to the player's
        // own content (the paged artwork/lyrics/queue scroll, the scrubbers).
        let translation = pan.translation(in: view)
        guard translation.y > 0, abs(translation.y) > abs(translation.x) else { return false }
        // A list inside the player (queue, lyrics) scrolls first and only hands the drag over
        // once it is at its top, the way a sheet behaves.
        return !isOverScrolledContent(at: pan.location(in: view), in: view)
    }

    private func isOverScrolledContent(at point: CGPoint, in view: UIView) -> Bool {
        var candidate = view.hitTest(point, with: nil)
        while let current = candidate {
            if let scroll = current as? UIScrollView,
               scroll.isScrollEnabled,
               scroll.contentSize.height > scroll.bounds.height {
                return scroll.contentOffset.y > -scroll.adjustedContentInset.top + 0.5
            }
            candidate = current.superview
        }
        return false
    }

    /// The player's content owns its own gestures; this one only ever *observes* until it
    /// decides the drag is a downward dismiss, so it must not starve them in the meantime.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// A scroll view inside the player wins while it still has somewhere to go; the dismiss
    /// only takes over at the top. Without this the drag fights the paged artwork scroll.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        false
    }
}


// MARK: - Presenter

/// Presents the Now Playing cover, instead of `fullScreenCover`.
///
/// SwiftUI's own presentation is what the crash reports point at: `SheetBridge` calls
/// `dismissViewControllerAnimated:` the moment the binding changes, and on an
/// open-then-immediately-close that lands on top of an unfinished present — UIKit throws inside
/// `_dismissViewControllerWithAnimationController:interactionController:`, and when it does not
/// throw it leaves the presentation container (`UITransitionView`) standing over the app with
/// every tap going nowhere. Both symptoms come from the same place, and neither is reachable
/// from an animator.
///
/// Here the binding is an *intent*, not a command. `sync()` refuses to act while UIKit is mid
/// transition and re-checks when it is idle, so present and dismiss can never overlap.
///
/// The shell is untouched: this is a zero-sized, non-interactive representable in the tab view's
/// background. The `TabView`, the accessory mini player and every toolbar stay pure SwiftUI.
struct NowPlayingCoverPresenter<Content: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    /// Re-evaluated on every SwiftUI update so the presented tree stays live.
    let content: () -> Content
    /// False while the player has something pushed inside it.
    let canDismiss: () -> Bool

    func makeUIViewController(context: Context) -> Presenter<Content> {
        let presenter = Presenter<Content>()
        presenter.view.isUserInteractionEnabled = false
        presenter.configure(isPresented: $isPresented, content: content, canDismiss: canDismiss)
        return presenter
    }

    func updateUIViewController(_ presenter: Presenter<Content>, context: Context) {
        presenter.configure(isPresented: $isPresented, content: content, canDismiss: canDismiss)
        presenter.sync()
    }

    @MainActor
    final class Presenter<C: View>: UIViewController {
        private let zoom = NowPlayingCoverZoomController()
        private var cover: UIHostingController<C>?
        private var isPresentedBinding: Binding<Bool> = .constant(false)
        private var makeContent: (() -> C)?
        private var isSyncScheduled = false

        func configure(isPresented: Binding<Bool>, content: @escaping () -> C, canDismiss: @escaping () -> Bool) {
            isPresentedBinding = isPresented
            makeContent = content
            zoom.canDismiss = canDismiss
            zoom.requestDismiss = { [weak self] in self?.beginInteractiveDismiss() }
            zoom.restorePresentation = { [weak self] in
                // The drag was released short of the threshold: UIKit cancelled the dismissal
                // and the cover never left, so only the binding needs putting back.
                self?.isPresentedBinding.wrappedValue = true
            }
            // Keep the presented tree current with the rest of the app — but never mid
            // transition. `updateUIViewController` runs on every shell render, and
            // `PlaybackEngine` publishes constantly, so reassigning `rootView` while the card is
            // in flight re-renders and relayouts the player inside the moving view on almost
            // every frame of the drag.
            if let cover, let makeContent, !isBusy { cover.rootView = makeContent() }
        }

        func sync() {
            if isPresentedBinding.wrappedValue {
                presentCover()
            } else {
                dismissCover()
            }
        }

        /// Re-runs `sync()` once UIKit is idle. The whole point of owning the presentation is
        /// that a request arriving mid-transition can wait instead of being forced through.
        private func syncWhenIdle() {
            guard !isSyncScheduled else { return }
            isSyncScheduled = true
            Task { @MainActor [weak self] in
                var waited = 0
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard let self else { return }
                    guard self.isBusy else { break }
                    // A finger still on the screen is not a stuck transition. Counting it as one
                    // is what made a slow drag give up partway: three seconds in, the guardrail
                    // fired, force-resolved the presentation, and the player snapped back with
                    // the rest of the drag ignored.
                    if self.zoom.isInteractiveDismiss { waited = 0 } else { waited += 1 }
                }
                guard let self else { return }
                self.isSyncScheduled = false
                // Guardrail. A transition that never completes is the failure mode this whole
                // area keeps producing — one stuck present or dismiss and the player will not
                // open again for the rest of the session. If UIKit is still claiming to be busy
                // three seconds later it is not going to stop on its own, so force the state
                // the binding asked for without animation and let the next open be clean.
                if waited >= 60, self.isBusy {
#if DEBUG
                    DebugUIRemote.log("NP-COVER stuck transition — forcing resolve")
#endif
                    self.forceResolve()
                    return
                }
                self.sync()
            }
        }

        /// Last-resort unwedge: put the presentation where the binding says it should be, with
        /// no animation, and throw away the reused controller so the next open rebuilds cleanly.
        private func forceResolve() {
            let wanted = isPresentedBinding.wrappedValue
            if let host = cover, host.presentingViewController != nil, !wanted {
                host.dismiss(animated: false) { [weak self] in
                    self?.cover = nil
                    self?.zoom.isSettled = false
                }
            } else if !wanted {
                cover = nil
                zoom.isSettled = false
            }
        }

        /// Any transition in flight anywhere on this presentation chain.
        private var isBusy: Bool {
            if transitionCoordinator != nil { return true }
            if let cover, cover.transitionCoordinator != nil { return true }
            if let cover, cover.isBeingPresented || cover.isBeingDismissed { return true }
            return false
        }

        // MARK: Present

        /// Whether the cover is actually on screen, asked of UIKit rather than of our own
        /// bookkeeping. Holding a controller reference is *not* the same as it being presented,
        /// and conflating the two is what made the player refuse to open at all after a fast
        /// open/close: `cover` was still set, the open bailed on that, and nothing ever cleared
        /// it. Nothing in here may gate on the reference.
        private var isCoverOnScreen: Bool { cover?.presentingViewController != nil }

        private func presentCover() {
            guard let makeContent else { return }
            guard !isCoverOnScreen else { return }
            guard view.window != nil else { return }
            guard !isBusy, presentedViewController == nil else {
                syncWhenIdle()
                return
            }
            // Reused, not rebuilt. A fresh `UIHostingController` starts with an unrendered
            // SwiftUI tree whose `.task`s have never run, so `AlbumArtworkView` has not loaded
            // its image yet — the card flew with an empty square where the cover should be,
            // which is the "it doesn't move the album cover at all" the open looked like.
            // Keeping the controller means every open after the first carries a live player.
            let host = cover ?? makeHost(makeContent)
            zoom.isSettled = false
            present(host, animated: true) { [weak self] in
                // Straight from the completion handler: no timer can know this, and every
                // timer-shaped guess at it has been wrong.
                self?.zoom.isSettled = true
                // Belt and braces on the drag: SwiftUI can replace the hosting view during the
                // first render pass, and a recognizer on a discarded view never fires.
                self?.zoom.reinstallPanIfNeeded()
                self?.sync()
            }
        }

        private func makeHost(_ makeContent: () -> C) -> UIHostingController<C> {
            let host = UIHostingController(rootView: makeContent())
            // Build and lay the player out before the transition starts. The card the animator
            // flies carries this view, and an unrendered `UIHostingController` is a blank
            // rectangle — the first build of this opened onto a black page that only became the
            // player once the animation had finished.
            host.loadViewIfNeeded()
            host.view.frame = view.window?.bounds ?? host.view.frame
            host.view.layoutIfNeeded()
            zoom.attach(to: host)
            cover = host
            return host
        }

        // MARK: Dismiss

        /// Called by the drag on touch-down, so the interactive dismissal starts on the same
        /// runloop turn as the gesture rather than after a SwiftUI update.
        private func beginInteractiveDismiss() {
            isPresentedBinding.wrappedValue = false
            dismissCover()
        }

        private func dismissCover() {
            // The controller is kept for reuse, so "do we hold one" says nothing about whether
            // anything is on screen. Only `presentingViewController` does.
            guard let host = cover, isCoverOnScreen else { return }
            guard !host.isBeingDismissed, !host.isBeingPresented, host.transitionCoordinator == nil else {
                syncWhenIdle()
                return
            }
#if DEBUG
            let probeWindow = host.viewIfLoaded?.window
#endif
            host.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                if host.presentingViewController == nil {
                    self.zoom.isSettled = false
#if DEBUG
                    NowPlayingTouchProbe.start(in: probeWindow)
#endif
                } else {
                    // An interactive dismiss that was cancelled — still presented, still ours.
                    self.isPresentedBinding.wrappedValue = true
                }
            }
        }
    }
}

#if DEBUG
// MARK: - Post-dismiss touch probe

/// Logs what a touch actually lands on for 8s after the player closes.
///
/// Kept because it is the only thing in this whole investigation that produced a straight
/// answer. Reading `NP-PROBE` in `vellum-hangwatch.log` is how the stray volume touch was
/// traced to the cover's hosting view, and how the wedged presentation was found: taps
/// resolving to real views (`UIKitTabBarBottomAccessory`, the list) that still did nothing,
/// with `UITransitionView` — the modal presentation container — left standing over the app.
@MainActor
enum NowPlayingTouchProbe {
    static func start(in window: UIWindow?) {
        guard let window else { return }
        let probe = Recognizer()
        probe.cancelsTouchesInView = false
        probe.delaysTouchesBegan = false
        probe.delaysTouchesEnded = false
        probe.onTouch = { [weak window] point in
            guard let window else { return }
            var chain: [String] = []
            var next: UIView? = window.hitTest(point, with: nil)
            while let view = next, chain.count < 8 {
                chain.append(String(describing: type(of: view)))
                next = view.superview
            }
            DebugUIRemote.log(
                "NP-PROBE tap=\(Int(point.x)),\(Int(point.y)) hit=\(chain.joined(separator: " < "))"
            )
        }
        window.addGestureRecognizer(probe)
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .seconds(8))
            window?.removeGestureRecognizer(probe)
        }
    }

    /// Watches, never recognizes, never consumes.
    private final class Recognizer: UIGestureRecognizer {
        var onTouch: ((CGPoint) -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            if let point = touches.first?.location(in: view) { onTouch?(point) }
            state = .failed
        }
    }
}
#endif
#endif
