import SwiftUI
#if canImport(UIKit)
import UIKit

/// The mini player's open and close, built to match Apple Music frame for frame.
///
/// Measured off a screen recording of Apple Music at 30fps
/// (`ScreenRecording_08-21-2026 23-57-23_1.MP4`, frames 25–32). It is **not** the album/playlist
/// motion, which is why `CoverZoomAnimator` was the wrong tool here: that one scales the whole
/// destination page as a single card, so the cover only moves because the page does. Apple's is
/// three things happening at once —
///
/// 1. a rounded card whose **top edge grows upward** out of the pill, its bottom staying put;
/// 2. the **pill itself fading out** at the top of that card as it stretches;
/// 3. the **artwork travelling** from the pill's left into the player's hero position;
///
/// with the player's content held at its **final layout** the whole time and revealed by the
/// growing crop — never scaled. That is the "crop expanding outward from the cover" this was
/// asked for, and it is why the content reads as correct at every size.
///
/// Everything that flies is a snapshot taken from the live window at the moment the transition
/// starts. That is deliberate: the player is a SwiftUI tree whose `.task`s have not run on a
/// first open, so asking it to draw its own cover mid-flight produced an empty square — the
/// "it doesn't move the album cover at all" this replaces. A snapshot of what is already on
/// screen cannot be empty.
@MainActor
final class NowPlayingCoverAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    enum Direction { case present, dismiss }

    /// Where the pill fade finishes, as a fraction of the flight. The pill is the *only* thing
    /// that fades — the cover travels and the content is revealed by the crop.
    private static let pillFadeEnd: CGFloat = 0.35

    /// Deliberately **not** `CoverZoomTuning`. Those numbers belong to the album/playlist push,
    /// which is a different motion over a different distance, and this one wants a touch longer
    /// to read — the cover has the full height of the screen to travel.
    private static let presentDuration: TimeInterval = 0.58
    private static let dismissDuration: TimeInterval = 0.52

    private let direction: Direction
    private var session: Session?
    private var propertyAnimator: UIViewPropertyAnimator?
    /// Set when the geometry could not be resolved and a cross-fade owns the context instead.
    private var didCrossFade = false
    private var ownsInteractiveContext = false

    init(direction: Direction) {
        self.direction = direction
    }

    // MARK: Geometry

    struct Geometry {
        /// The whole pill, in container coordinates — the card's collapsed frame.
        var pill: CGRect
        /// The pill's artwork.
        var artStart: CGRect
        /// The player's hero artwork.
        var artEnd: CGRect
        var full: CGRect
        var pillCorner: CGFloat
        var artStartCorner: CGFloat
        var artEndCorner: CGFloat
    }

    final class Session {
        let context: UIViewControllerContextTransitioning
        let container: UIView
        let clip: UIView
        let player: UIView
        let artwork: UIView?
        let pillSnapshot: UIView?
        let geometry: Geometry
        var progress: CGFloat
        var didComplete = false

        init(
            context: UIViewControllerContextTransitioning,
            container: UIView,
            clip: UIView,
            player: UIView,
            artwork: UIView?,
            pillSnapshot: UIView?,
            geometry: Geometry,
            progress: CGFloat
        ) {
            self.context = context
            self.container = container
            self.clip = clip
            self.player = player
            self.artwork = artwork
            self.pillSnapshot = pillSnapshot
            self.geometry = geometry
            self.progress = progress
        }
    }

    // MARK: UIViewControllerAnimatedTransitioning

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        direction == .present ? Self.presentDuration : Self.dismissDuration
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let session = prepare(context: context) else { return }
        let target: CGFloat = direction == .present ? 1 : 0
        applyState(progress: direction == .present ? 0 : 1)
        let animator = UIViewPropertyAnimator(
            duration: transitionDuration(using: context),
            timingParameters: CoverZoomTuning.easeOutQuint
        )
        animator.addAnimations { [weak self] in
            self?.applyState(progress: target)
        }
        animator.addCompletion { [weak self] _ in
            self?.finish(committed: true)
        }
        propertyAnimator = animator
        _ = session
        animator.startAnimation()
    }

    // MARK: Setup

    /// Builds the flight. Returns nil when the geometry is unusable, having already handed the
    /// context to a plain cross-fade — the same degradation the stock zoom makes.
    @discardableResult
    private func prepare(context: UIViewControllerContextTransitioning) -> Session? {
        if let session { return session }
        guard !didCrossFade else { return nil }

        let container = context.containerView
        let isPresent = direction == .present
        guard let playerController = context.viewController(forKey: isPresent ? .to : .from),
              let player = playerController.view
        else {
            crossFade(context: context)
            return nil
        }
        let full = container.bounds

        // The revealed screen has to be in the container for a dismiss, or the card flies over
        // nothing. `finalFrame` is documented to return `.zero` when UIKit does not consider the
        // controller part of the transition, and a zero-sized root is invisible *and*
        // untouchable — which reads exactly like the app having frozen.
        if !isPresent, let below = context.viewController(forKey: .to), let belowView = below.view {
            if belowView.superview == nil {
                let final = context.finalFrame(for: below)
                belowView.frame = final.isEmpty ? full : final
                container.insertSubview(belowView, at: 0)
            }
            belowView.alpha = 1
            belowView.isHidden = false
        }

        guard let geometry = resolveGeometry(in: container) else {
            crossFade(context: context, playerView: player)
            return nil
        }

        let window = container.window

        // The cover that flies is the **player's**, not the pill's.
        //
        // Snapshotting the pill's 28pt thumbnail and scaling it to 296pt gave a soft, visibly
        // lower-bitrate image that then swapped for the crisp one on arrival — the giveaway that
        // it was never the same object. The player's own artwork is already at full size, so
        // taking it from there and flying it *down* to the pill's rect means the cover the user
        // ends up looking at is the cover that travelled. The pill's is the stand-in, not the
        // player's.
        player.frame = full
        player.layoutIfNeeded()
        var artworkSnapshot = player.resizableSnapshotView(
            from: geometry.artEnd,
            afterScreenUpdates: true,
            withCapInsets: .zero
        )
        if artworkSnapshot == nil {
            // First open of a launch: the player's tree has not drawn yet, so fall back to the
            // pill's copy rather than flying nothing.
            artworkSnapshot = window?.resizableSnapshotView(
                from: geometry.artStart,
                afterScreenUpdates: false,
                withCapInsets: .zero
            )
        }
        let pillSnapshot = isPresent
            ? window?.resizableSnapshotView(from: geometry.pill, afterScreenUpdates: false, withCapInsets: .zero)
            : nil

        // Only one copy of the cover is ever on screen: the pill's and the player's own are both
        // taken down for the flight, leaving just the one that is travelling.
        CoverZoomFlight.shared.beginFlight(id: NowPlayingCoverZoom.id)
        NowPlayingHeroFlight.shared.isHidden = true

        let clip = UIView()
        clip.clipsToBounds = true
        clip.layer.cornerCurve = .continuous
        clip.backgroundColor = .clear
        container.addSubview(clip)

        player.removeFromSuperview()
        clip.addSubview(player)

        if let artworkSnapshot {
            artworkSnapshot.layer.cornerCurve = .continuous
            artworkSnapshot.clipsToBounds = true
            clip.addSubview(artworkSnapshot)
        }
        if let pillSnapshot {
            clip.addSubview(pillSnapshot)
        }

        let session = Session(
            context: context,
            container: container,
            clip: clip,
            player: player,
            artwork: artworkSnapshot,
            pillSnapshot: pillSnapshot,
            geometry: geometry,
            progress: isPresent ? 0 : 1
        )
        self.session = session
#if DEBUG
        DebugUIRemote.log(
            "NP-ANIM prepare present=\(isPresent) pill=\(short(geometry.pill)) "
            + "artStart=\(short(geometry.artStart)) artEnd=\(short(geometry.artEnd)) "
            + "art=\(artworkSnapshot != nil) pillSnap=\(pillSnapshot != nil)"
        )
#endif
        applyState(progress: session.progress)
        return session
    }

    private func resolveGeometry(in container: UIView) -> Geometry? {
        let registry = CoverZoomRegistry.shared
        let id = NowPlayingCoverZoom.id
        // The pill's artwork: live while the pill is on screen, otherwise the rect measured when
        // the player was opened. On a dismiss the pill is behind a full-screen player, so the
        // remembered one is the normal path.
        let art = registry.cellRect(for: id, in: container)
            ?? registry.rememberedCellRect(for: id, in: container)
        guard let art, art.rect.width > 1 else { return nil }
        guard let hero = registry.heroRect(for: id, in: container), hero.rect.width > 1 else { return nil }

        // The whole pill, for the card's collapsed frame. Falls back to a band around the
        // artwork so a missing accessory anchor degrades instead of failing.
        let pillRect: CGRect
        if let pillView = MiniPlayerZoomSourceRegistry.sourceView, pillView.window != nil {
            pillRect = pillView.convert(pillView.bounds, to: container)
        } else {
            pillRect = art.rect.insetBy(dx: -art.rect.minX + 8, dy: -6)
        }
        guard pillRect.width > 1, pillRect.height > 1 else { return nil }

        return Geometry(
            pill: pillRect,
            artStart: art.rect,
            artEnd: hero.rect,
            full: container.bounds,
            pillCorner: min(pillRect.height / 2, 28),
            artStartCorner: art.cornerRadius,
            artEndCorner: hero.cornerRadius
        )
    }

    // MARK: State

    /// `progress` 0 = collapsed into the pill, 1 = full screen.
    func applyState(progress: CGFloat) {
        guard let session else { return }
        let p = max(0, min(1, progress))
        session.progress = p
        let g = session.geometry

        // 1. The card. Grows out of the pill; the content behind it is revealed, not scaled.
        let card = interpolate(g.pill, g.full, p)
        session.clip.frame = card
        session.clip.layer.cornerRadius = lerp(g.pillCorner, CoverZoomTuning.screenCornerRadius, p)

        // 2. The player, pinned to its final on-screen position inside the moving card, so the
        //    card crops it rather than squashing it — the sheet reveals its content from the
        //    bottom up as the top edge climbs. Never faded: the content arriving by opacity
        //    instead of by reveal is what made the open read as "everything fades in".
        //
        //    It **slides**, pinned to the card's own top edge rather than to the screen. Held at
        //    the screen position instead, the card merely uncovered a stationary page — "the
        //    sheet showing more crop", not the transport controls and scrubber rising into
        //    place with it. The player's own cover is hidden for the flight
        //    (``NowPlayingHeroFlight``), so this sliding copy brings no second artwork with it.
        session.player.frame = CGRect(
            x: 0,
            y: 0,
            width: g.full.width,
            height: g.full.height
        )
        session.player.alpha = 1

        // 3. The travelling cover. Opaque for the whole flight: this *is* the cover, carried
        //    from the pill into the player, not a stand-in that dissolves into another copy.
        if let artwork = session.artwork {
            let rect = interpolate(g.artStart, g.artEnd, p)
            artwork.frame = rect.offsetBy(dx: -card.minX, dy: -card.minY)
            artwork.layer.cornerRadius = lerp(g.artStartCorner, g.artEndCorner, p)
        }

        // 4. The pill, stretching with the card's top edge and fading as it goes.
        if let pill = session.pillSnapshot {
            pill.frame = CGRect(x: 0, y: 0, width: card.width, height: g.pill.height)
            pill.alpha = 1 - smoothstep(p, 0, Self.pillFadeEnd)
        }
    }

    // MARK: Interactive drag

    private(set) var isDragging = false

    func beginDrag(context: UIViewControllerContextTransitioning) {
        guard prepare(context: context) != nil else {
            finishOwnedInteractiveContext(context)
            return
        }
        isDragging = true
        ownsInteractiveContext = true
        applyState(progress: 1)
    }

    /// `fraction` 0…1 of the way to dismissed.
    func updateDrag(fraction: CGFloat) {
        guard isDragging, let session else { return }
        applyState(progress: 1 - max(0, min(1, fraction)))
        session.context.updateInteractiveTransition(max(0, min(1, fraction)))
    }

    func endDrag(committed: Bool) {
        guard isDragging, let session else { return }
        isDragging = false
        let target: CGFloat = committed ? 0 : 1
        let animator = UIViewPropertyAnimator(
            duration: committed ? CoverZoomTuning.dragReleaseDuration : CoverZoomTuning.dragCancelDuration,
            timingParameters: CoverZoomTuning.easeOutQuint
        )
        animator.addAnimations { [weak self] in
            self?.applyState(progress: target)
        }
        animator.addCompletion { [weak self] _ in
            self?.finish(committed: committed)
        }
        propertyAnimator = animator
        _ = session
        animator.startAnimation()
    }

    // MARK: Completion

    /// Tears the flight down and reports the outcome exactly once. Every exit runs through here
    /// — a transition that never completes is what leaves the app unable to open anything again.
    func finish(committed: Bool) {
        guard let session, !session.didComplete else { return }
        session.didComplete = true

        session.artwork?.removeFromSuperview()
        session.pillSnapshot?.removeFromSuperview()
        session.player.alpha = 1
        session.player.transform = .identity
        session.player.frame = session.geometry.full

        let playerStays = (direction == .present && committed) || (direction == .dismiss && !committed)
        if playerStays {
            session.container.addSubview(session.player)
        } else {
            session.player.removeFromSuperview()
        }
        session.clip.removeFromSuperview()
        CoverZoomFlight.shared.endFlight(id: NowPlayingCoverZoom.id)
        NowPlayingHeroFlight.shared.isHidden = false

        if ownsInteractiveContext {
            ownsInteractiveContext = false
            if committed {
                session.context.finishInteractiveTransition()
            } else {
                session.context.cancelInteractiveTransition()
            }
        }
        session.context.completeTransition(committed)
#if DEBUG
        DebugUIRemote.log("NP-ANIM finish present=\(direction == .present) committed=\(committed)")
#endif
        self.session = nil
    }

    private func finishOwnedInteractiveContext(_ context: UIViewControllerContextTransitioning) {
        guard ownsInteractiveContext else { return }
        ownsInteractiveContext = false
        context.finishInteractiveTransition()
    }

    // MARK: Fallback

    /// What the stock transition degrades to in the same situations, and the only exit that does
    /// not go through `finish`. It must still complete the context, interactive or not.
    private func crossFade(context: UIViewControllerContextTransitioning, playerView: UIView? = nil) {
        didCrossFade = true
        let isPresent = direction == .present
        let container = context.containerView
        let view = playerView ?? context.view(forKey: isPresent ? .to : .from)
        if let view, view.superview == nil {
            view.frame = container.bounds
            container.addSubview(view)
        }
        if !isPresent, let below = context.viewController(forKey: .to), let belowView = below.view {
            if belowView.superview == nil {
                let final = context.finalFrame(for: below)
                belowView.frame = final.isEmpty ? container.bounds : final
                container.insertSubview(belowView, at: 0)
            }
            belowView.alpha = 1
            belowView.isHidden = false
        }
        view?.alpha = isPresent ? 0 : 1
#if DEBUG
        DebugUIRemote.log("NP-ANIM cross-fade present=\(isPresent) — geometry unavailable")
#endif
        var completed = false
        let complete = { [weak self] in
            guard !completed else { return }
            completed = true
            view?.alpha = 1
            if !isPresent { view?.removeFromSuperview() }
            self?.finishOwnedInteractiveContext(context)
            context.completeTransition(!context.transitionWasCancelled)
        }
        UIView.animate(withDuration: transitionDuration(using: context)) {
            view?.alpha = isPresent ? 1 : 0
        } completion: { _ in
            complete()
        }
    }

    // MARK: Maths

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    private func interpolate(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: lerp(a.minX, b.minX, t),
            y: lerp(a.minY, b.minY, t),
            width: lerp(a.width, b.width, t),
            height: lerp(a.height, b.height, t)
        )
    }

    /// Eased 0→1 ramp between two progress points, flat outside them.
    private func smoothstep(_ x: CGFloat, _ edge0: CGFloat, _ edge1: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

#if DEBUG
    private func short(_ rect: CGRect) -> String {
        String(format: "(%.0f,%.0f,%.0f,%.0f)", rect.minX, rect.minY, rect.width, rect.height)
    }
#endif
}

/// Hands the drag to ``NowPlayingCoverAnimator``. Not percent-driven: UIKit's percent scrubbing
/// bakes its end values when it starts, and the geometry here is written directly on every pan
/// update instead.
@MainActor
final class NowPlayingCoverInteraction: NSObject, UIViewControllerInteractiveTransitioning {
    private weak var animator: NowPlayingCoverAnimator?
    private var hasStarted = false
    private var pendingFraction: CGFloat?

    init(animator: NowPlayingCoverAnimator) {
        self.animator = animator
    }

    nonisolated var wantsInteractiveStart: Bool { true }

    nonisolated func startInteractiveTransition(_ transitionContext: UIViewControllerContextTransitioning) {
        MainActor.assumeIsolated {
            hasStarted = true
            animator?.beginDrag(context: transitionContext)
            if let pendingFraction { update(fraction: pendingFraction) }
        }
    }

    func update(fraction: CGFloat) {
        guard hasStarted else {
            pendingFraction = fraction
            return
        }
        animator?.updateDrag(fraction: fraction)
    }

    func finish(committed: Bool) {
        animator?.endDrag(committed: committed)
    }
}
#endif
