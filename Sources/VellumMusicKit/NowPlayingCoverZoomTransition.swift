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

    /// Closes the cover *now*, without waiting for the shell to render.
    ///
    /// Setting the presentation binding is not enough on its own, and the device log says so.
    /// `NowPlayingCoverPresenter` acts on the binding from `updateUIViewController` — i.e. only
    /// when SwiftUI re-evaluates the shell — and while the cover is up the shell is entirely
    /// covered, so SwiftUI stops updating it. "Go to Playlist" at t=462.13 wrote the binding
    /// (`NP-NAV binding written false (readback=false)`) and the next `NP-SYNC` did not arrive
    /// for 1.3s — when the user gave up and swiped the player away by hand. The queued deep
    /// link then pushed behind a player that had never left.
    ///
    /// The drag never had this problem because it calls the presenter directly. This is that
    /// same door, opened to the code inside the cover: write the binding so SwiftUI's state
    /// stays truthful, then call this so UIKit acts on it in the same runloop turn.
    var requestDismiss: (() -> Void)?
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
#if DEBUG
    /// T054 investigation: numbers the drag deltas so the log names the slow frame.
    private var dragUpdateIndex = 0
#endif

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
        // **The window, not the player's view.**
        //
        // The animator reparents the player into its clip view, and removing a view from its
        // superview cancels the gesture recognizers attached to it — mid-`prepare`, before the
        // animator has marked itself as dragging. The cancel handler then returned early, so
        // nothing ever completed the transition: it stayed in flight forever, every later swipe
        // was refused with `coordinator=true`, and the abandoned card sat over the app as a
        // cover stuck in the middle of the screen.
        //
        // The window is never reparented. `gestureRecognizerShouldBegin` does the gating that
        // attaching to the player used to do implicitly.
        guard pan == nil, let view = host?.view.window ?? host?.view else { return }
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        recognizer.maximumNumberOfTouches = 1
        view.addGestureRecognizer(recognizer)
        pan = recognizer
    }

    /// Moves the drag onto the window once there is one. Called from the present completion,
    /// because the host has no window until it is on screen.
    func reinstallPanIfNeeded() {
        guard let window = host?.view.window else { return }
        if let pan, pan.view === window { return }
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
            dragUpdateIndex = 0
            DebugUIRemote.log("NP-DRAG began at \(Int(finger.x)),\(Int(finger.y))")
#endif
            // SwiftUI drives the dismissal; UIKit then asks us for the animator and the
            // interaction controller, in that order, and the drag takes over from there.
#if DEBUG
            DebugUIRemote.span("began.requestDismiss") { requestDismiss() }
#else
            requestDismiss()
#endif
        case .changed:
#if DEBUG
            // Every delta is numbered so the log shows *which* frame of the drag went long,
            // not just that one did. Threshold is low on purpose: at 60Hz anything over ~8ms
            // has already missed, and we want the shape of the whole drag, not only the worst.
            dragUpdateIndex += 1
            DebugUIRemote.span("drag.update#\(dragUpdateIndex)", minMs: 4) {
                interaction?.update(translation: finger.y - dragStart.y)
            }
#else
            interaction?.update(translation: finger.y - dragStart.y)
#endif
        case .ended:
            let translation = finger.y - dragStart.y
            let velocity = pan.velocity(in: space).y
            endDrag(committed: translation > 120 || velocity > 700, velocity: velocity)
        case .cancelled, .failed:
            endDrag(committed: false, velocity: 0)
        default:
            break
        }
    }

    private func endDrag(committed: Bool, velocity: CGFloat) {
        guard isInteractiveDismiss else { return }
        isInteractiveDismiss = false
        interaction?.finish(committed: committed, velocity: velocity)
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
            + "overScroll=\(isOverScrolledContent(at: pan.location(in: view), in: view)) "
            + "excluded=\(NowPlayingDismissExclusion.contains(pan.location(in: view), in: view))"
        )
#endif
        // Never start a close on top of an unfinished open, and never start a second one.
        // The recognizer lives on the window now, so this also has to answer "is the player
        // even on screen" — which used to be implied by where it was attached.
        guard host?.presentingViewController != nil else { return false }
        guard isSettled, canDismiss(), !isInteractiveDismiss else { return false }
        guard host?.transitionCoordinator == nil else { return false }
        // Downward, and more vertical than horizontal — everything else belongs to the player's
        // own content (the paged artwork/lyrics/queue scroll).
        let translation = pan.translation(in: view)
        guard translation.y > 0, abs(translation.y) > abs(translation.x) else { return false }
        // The two scrubbers are the exception the angle check above cannot cover. They are not
        // inside a scroll view, so ``isOverScrolledContent`` cannot see them, and a diagonal
        // thumb drag on the progress or volume bar crosses 45° as a matter of course — which
        // handed a seek to the dismiss and closed the player mid-scrub. Direction is committed
        // once off the first few points and never re-checked, so this has to be answered here,
        // at `shouldBegin`, or not at all.
        let location = pan.location(in: view)
        guard !NowPlayingDismissExclusion.contains(location, in: view) else { return false }
        // A list inside the player (queue, lyrics) scrolls first and only hands the drag over
        // once it is at its top, the way a sheet behaves.
        return !isOverScrolledContent(at: location, in: view)
    }

    /// True while *any* scroll view under the finger still has content above its top edge.
    ///
    /// The walk must not stop at the innermost one, and the queue is why. Its rows live in a
    /// `List` that sits at its own top the moment the queue opens (nothing to reveal above),
    /// nested inside the paged scroll that carries History above the Now Playing page — parked
    /// one page down with everything to reveal (measured: list `offset=0 content=614
    /// bounds=426`, paged scroll `offset=426 content=854`). Answering from the list alone
    /// reported "already at the top" and handed a swipe meant for History to the dismiss, which
    /// closed the player instead. It only misfired when the list was both scrollable and
    /// untouched — scroll it at all, or leave the queue short enough not to overflow, and the
    /// walk reached the paged scroll and got the right answer.
    private func isOverScrolledContent(at point: CGPoint, in view: UIView) -> Bool {
        var candidate = view.hitTest(point, with: nil)
        while let current = candidate {
            if let scroll = current as? UIScrollView,
               scroll.isScrollEnabled,
               scroll.contentSize.height > scroll.bounds.height,
               scroll.contentOffset.y > -scroll.adjustedContentInset.top + 0.5 {
                return true
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
    /// Every *value*-typed input baked into `content`, collapsed into one comparable token.
    ///
    /// The reference-typed inputs — the four `environmentObject`s — reach the player on their
    /// own, because it observes them. A value like `.tint` cannot: a `UIHostingController` only
    /// picks up a new one when `rootView` is reassigned, and that reassignment was firing on
    /// every shell render (`PlaybackEngine` publishes several times a second) to deliver a value
    /// that had almost never changed. Comparing the values instead means the off-screen player
    /// is rebuilt when one of them actually moves, and not otherwise.
    ///
    /// **Anything value-typed added to `content` must be added here too**, or it will not reach
    /// the player until something else invalidates this token.
    let contentRevision: AnyHashable
    /// False while the player has something pushed inside it.
    let canDismiss: () -> Bool

    func makeUIViewController(context: Context) -> Presenter<Content> {
        let presenter = Presenter<Content>()
        presenter.view.isUserInteractionEnabled = false
        presenter.configure(
            isPresented: $isPresented,
            content: content,
            contentRevision: contentRevision,
            canDismiss: canDismiss,
        )
        return presenter
    }

    func updateUIViewController(_ presenter: Presenter<Content>, context: Context) {
        presenter.configure(
            isPresented: $isPresented,
            content: content,
            contentRevision: contentRevision,
            canDismiss: canDismiss,
        )
        presenter.sync()
    }

    @MainActor
    final class Presenter<C: View>: UIViewController {
        private let zoom = NowPlayingCoverZoomController()
        private var cover: UIHostingController<C>?
        private var isPresentedBinding: Binding<Bool> = .constant(false)
        private var makeContent: (() -> C)?
        /// The `contentRevision` the off-screen `rootView` was last built from. `nil` until the
        /// first refresh, so the player picks up whatever is current the first time it goes idle.
        private var lastContentRevision: AnyHashable?
        private var isSyncScheduled = false

        func configure(
            isPresented: Binding<Bool>,
            content: @escaping () -> C,
            contentRevision: AnyHashable,
            canDismiss: @escaping () -> Bool,
        ) {
            isPresentedBinding = isPresented
            makeContent = content
            zoom.canDismiss = canDismiss
            zoom.requestDismiss = { [weak self] in self?.dismissNow() }
            // The same door for code *inside* the cover — "Go to Album / Playlist / Artist".
            // See ``NowPlayingCoverState/requestDismiss``: the binding alone cannot close this,
            // because acting on it needs a shell render and the shell is covered.
            NowPlayingCoverState.shared.requestDismiss = { [weak self] in self?.dismissNow() }
            zoom.restorePresentation = { [weak self] in
                // The drag was released short of the threshold: UIKit cancelled the dismissal
                // and the cover never left, so only the binding needs putting back.
                self?.isPresentedBinding.wrappedValue = true
            }
            // **Never while it is on screen.**
            //
            // `updateUIViewController` runs on every shell render and `PlaybackEngine` publishes
            // several times a second, so this was replacing the player's entire root view that
            // often. Device log: taps landed squarely on `_UIHostingView<…NowPlayingGestureHost…>`
            // with `window/container/player=true` and no transition coordinator, and nothing
            // happened — because the tree recognising the tap was being swapped out from under
            // it before it could complete.
            //
            // Reassigning is not needed for anything the player *observes*: it reads those
            // through `@EnvironmentObject` and `@ObservedObject`, so it updates itself. Refresh
            // only while it is off screen, where a rebuild cannot eat a touch — and only when a
            // value-typed input actually changed, which is what `contentRevision` answers.
            // Without that second test this ran on every shell render, re-diffing the whole
            // ~2,800-line tree several times a second for the entire time the player was closed.
            if let cover, let makeContent, cover.presentingViewController == nil,
               contentRevision != lastContentRevision {
                lastContentRevision = contentRevision
                cover.rootView = makeContent()
            }
        }

        func sync() {
#if DEBUG
            // "Go to Album" sets the binding false and the cover stays up until the user swipes
            // it away by hand (device log 12:03 — menu cell tapped at t=428.58, no
            // `NP-ANIM prepare present=false` until the manual drag at t=432.07). Three links in
            // that chain can break it and only a log separates them: the binding never reaching
            // here, `dismissCover` refusing, or the dismiss being aimed at the context menu
            // instead of the cover.
            DebugUIRemote.log("NP-SYNC wanted=\(isPresentedBinding.wrappedValue) "
                + "onScreen=\(isCoverOnScreen) busy=\(isBusy) scheduled=\(isSyncScheduled)")
#endif
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
            // Tear down a flight that is still on screen first. Without this the abandoned card
            // and its cover snapshot stay in the window, floating over the app — the "album
            // cover stuck in the middle blocking everything" a wedged drag left behind.
            NowPlayingCoverAnimator.current?.finish(committed: !wanted)
            if let host = cover, host.presentingViewController != nil, !wanted {
                host.dismiss(animated: false) { [weak self] in
                    self?.cover = nil
                    self?.zoom.isSettled = false
                }
            } else if !wanted {
                cover = nil
                zoom.isSettled = false
            } else if isCoverOnScreen {
                // The stuck side was the *present*, and the player is up. `isSettled` is only
                // ever set true from `presentCover`'s completion closure — which a forced
                // resolve, by definition, never reaches. Leaving it false was silent and
                // permanent: `gestureRecognizerShouldBegin` guards on it, so swipe-to-dismiss
                // on the player was dead for the rest of the session, with no crash and nothing
                // on screen to say so. Re-arm it here, exactly as the completion would have.
                zoom.isSettled = true
                // The completion also does this, and for the same reason: SwiftUI can replace
                // the hosting view during the first render pass, and a recognizer left on a
                // discarded view never fires.
                zoom.reinstallPanIfNeeded()
            } else {
                // Wanted up, nothing on screen — the present never landed at all. Throw the
                // reused controller away so the next open rebuilds cleanly. `sync()` runs again
                // on the shell's next render, which is several times a second.
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
#if DEBUG
                // Why can't the player be touched right after it opens? Same question the
                // dismiss probe already answers for the other direction, and guessing at it is
                // what cost several attempts earlier: this logs what a tap actually lands on,
                // plus the interaction flags UIKit and we have each set.
                NowPlayingTouchProbe.start(in: host.viewIfLoaded?.window, tag: "OPEN")
                NowPlayingTouchProbe.logInteractionFlags(host: host)
                NowPlayingTouchProbe.sampleMainThread()
#endif
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

        /// Take the cover down on this runloop turn rather than after a SwiftUI update.
        ///
        /// Both callers need that. The drag starts its interactive dismissal on touch-down, and
        /// a "Go to …" inside the player has no SwiftUI update coming at all — the shell it
        /// would arrive on is covered, and SwiftUI does not render a covered hierarchy.
        private func dismissNow() {
#if DEBUG
            // Split deliberately: the binding write is a SwiftUI state change that re-renders the
            // shell, `dismissCover()` is the UIKit teardown. They are very different costs and
            // the hang watcher cannot tell them apart.
            DebugUIRemote.span("dismissNow.binding") { isPresentedBinding.wrappedValue = false }
            DebugUIRemote.span("dismissNow.dismissCover") { dismissCover() }
#else
            isPresentedBinding.wrappedValue = false
            dismissCover()
#endif
        }

        private func dismissCover() {
            // The controller is kept for reuse, so "do we hold one" says nothing about whether
            // anything is on screen. Only `presentingViewController` does.
            guard let host = cover, isCoverOnScreen else {
#if DEBUG
                DebugUIRemote.log("NP-DISMISS skip haveCover=\(cover != nil) onScreen=\(isCoverOnScreen)")
#endif
                return
            }
#if DEBUG
            // `presentedViewController` is the one thing the guard below does *not* test, and
            // the reported failure arrives straight out of a `UIMenu` selection — so whether
            // the cover is itself presenting the context menu at this instant is the fact that
            // decides between "the dismiss was refused" and "the dismiss hit the menu".
            DebugUIRemote.log("NP-DISMISS enter "
                + "presenting=\(host.presentedViewController.map { String(describing: type(of: $0)) } ?? "nil") "
                + "beingDismissed=\(host.isBeingDismissed) beingPresented=\(host.isBeingPresented) "
                + "hostCoordinator=\(host.transitionCoordinator != nil) selfCoordinator=\(transitionCoordinator != nil)")
#endif
            guard !host.isBeingDismissed, !host.isBeingPresented, host.transitionCoordinator == nil else {
#if DEBUG
                DebugUIRemote.log("NP-DISMISS deferred — waiting for UIKit")
#endif
                syncWhenIdle()
                return
            }
#if DEBUG
            let probeWindow = host.viewIfLoaded?.window
#endif
            host.dismiss(animated: true) { [weak self] in
                guard let self else { return }
#if DEBUG
                DebugUIRemote.log("NP-DISMISS done stillPresented=\(host.presentingViewController != nil)")
#endif
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
    static func start(in window: UIWindow?, tag: String = "CLOSE") {
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
                "NP-PROBE[\(tag)] tap=\(Int(point.x)),\(Int(point.y)) hit=\(chain.joined(separator: " < "))"
            )
        }
        window.addGestureRecognizer(probe)
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .seconds(8))
            window?.removeGestureRecognizer(probe)
        }
    }

    /// Samples the interaction flags for a few seconds after an open, so a window or container
    /// left non-interactive by UIKit shows up as a fact rather than a theory.
    static func logInteractionFlags(host: UIViewController) {
        Task { @MainActor in
            for delay in [0, 200, 600, 1200, 2500] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                let view = host.viewIfLoaded
                let window = view?.window
                DebugUIRemote.log(
                    "NP-FLAGS +\(delay)ms window=\(window?.isUserInteractionEnabled.description ?? "nil") "
                    + "container=\(view?.superview?.isUserInteractionEnabled.description ?? "nil") "
                    + "player=\(view?.isUserInteractionEnabled.description ?? "nil") "
                    + "alpha=\(String(format: "%.2f", view?.alpha ?? -1)) "
                    + "coordinator=\(host.transitionCoordinator != nil)"
                )
            }
        }
    }

    /// Samples main-thread responsiveness for three seconds after an open.
    ///
    /// The hang watcher only reports gaps over 120ms, so a main thread that is merely *busy* —
    /// enough to drop touches without ever stalling outright — is invisible to it. This ticks
    /// every frame and reports the worst gap it saw, which rules the main thread in or out.
    static func sampleMainThread() {
        Task { @MainActor in
            var worst: Double = 0
            var last = CFAbsoluteTimeGetCurrent()
            for _ in 0..<180 {
                try? await Task.sleep(for: .milliseconds(16))
                let now = CFAbsoluteTimeGetCurrent()
                worst = max(worst, now - last)
                last = now
            }
            DebugUIRemote.log(String(format: "NP-MAINTHREAD worst gap over 3s = %.0fms", worst * 1000))
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

#if DEBUG
/// Counts `NowPlayingView.body` evaluations and reports the rate once a second.
///
/// The question it answers: taps reach SwiftUI's gesture recogniser (`NP-SWIFTUI tap recognised`)
/// and the main thread is healthy (`NP-MAINTHREAD worst gap ≈ 85ms`), yet controls in the player
/// do not fire for a second or two after it opens. A subtree rebuilt between touch-down and
/// touch-up cannot complete a tap, and every view here observes the whole of `AppModel`, so any
/// publish re-runs the entire player body (`Rules/swiftui-body-cost.md`).
@MainActor
final class NowPlayingBodyCounter {
    static let shared = NowPlayingBodyCounter()

    private var count = 0
    private var windowStart: CFAbsoluteTime = 0

    func tick() {
        count += 1
        let now = CFAbsoluteTimeGetCurrent()
        if windowStart == 0 { windowStart = now }
        let elapsed = now - windowStart
        guard elapsed >= 1 else { return }
        DebugUIRemote.log(String(format: "NP-BODY %d evaluations in %.1fs", count, elapsed))
        count = 0
        windowStart = now
    }
}
#endif


// MARK: - Dismiss exclusion zones

#if canImport(UIKit)
/// Regions of the player that must never hand their drag to the dismiss.
///
/// ``NowPlayingCoverZoomController/isOverScrolledContent(at:in:)`` answers "does the content
/// under this finger want the drag" by walking for `UIScrollView` ancestors — which is the right
/// question everywhere the content *is* a scroll view, and the wrong one for the two horizontal
/// scrubbers. `pinnedBottomChrome` is a sibling of the mode-switching `ZStack`, not a descendant
/// of any scroll view, so a touch on the progress bar or the volume bar walks all the way to the
/// window without meeting one, `isOverScrolledContent` returns false, and the only thing left
/// standing between a scrub and a dismiss is the 45° angle check. A thumb dragging a slider does
/// not travel in a straight horizontal line: a natural diagonal seek crosses 45° and starts
/// closing the player mid-scrub.
///
/// Rect-based rather than hit-test-based on purpose. A marker view that answered `hitTest` would
/// have to be interactive, and an interactive view over a slider eats the slider's own drag. The
/// markers here are `isUserInteractionEnabled = false`, invisible to hit-testing and to the eye,
/// and only their geometry is consulted — once per touch-down, never per frame.
@MainActor
enum NowPlayingDismissExclusion {
    private static let zones = NSHashTable<UIView>.weakObjects()

    static func register(_ view: UIView) {
        zones.add(view)
    }

    static func unregister(_ view: UIView) {
        zones.remove(view)
    }

    /// True when `point` (expressed in `view`'s coordinate space) falls inside a registered zone.
    static func contains(_ point: CGPoint, in view: UIView) -> Bool {
        for zone in zones.allObjects {
            guard zone.window != nil, !zone.isHidden, zone.alpha > 0 else { continue }
            let rect = zone.convert(zone.bounds, to: view)
            if rect.contains(point) { return true }
        }
        return false
    }
}

/// Marks the view it backs as a ``NowPlayingDismissExclusion`` zone.
///
/// Applied as a `.background`, so it takes exactly the frame of the control it is protecting and
/// draws nothing — a clear, non-interactive `UIView`.
struct NowPlayingDismissExclusionZone: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        NowPlayingDismissExclusion.register(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Re-registering is idempotent (`NSHashTable`), and it covers the case where SwiftUI
        // recycles a representable's backing view across an identity change.
        NowPlayingDismissExclusion.register(uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        NowPlayingDismissExclusion.unregister(uiView)
    }
}
#endif

extension View {
    /// Excludes this view's frame from the player's swipe-to-dismiss pan.
    ///
    /// A no-op off UIKit — there is no window-level dismiss pan to exclude from.
    func nowPlayingDismissExclusionZone() -> some View {
#if canImport(UIKit)
        background(NowPlayingDismissExclusionZone())
#else
        self
#endif
    }
}
