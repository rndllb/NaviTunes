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

    /// How much of the *close* is spent handing the pill's area back to the real pill — see
    /// step 5 of `applyState`.
    private static let closeHandoffEnd: CGFloat = 0.22

    /// Deliberately **not** `CoverZoomTuning`. Those numbers belong to the album/playlist push,
    /// which is a different motion over a different distance, and this one wants a touch longer
    /// to read — the cover has the full height of the screen to travel.
    private static let presentDuration: TimeInterval = 0.66
    private static let dismissDuration: TimeInterval = 0.60

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
            // Above the card, not inside it — see `applyState`.
            container.addSubview(artworkSnapshot)
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
        Self.current = self
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

        // Live pill geometry, if the pill is on screen. On a **dismiss** it is not: the player
        // is a full-screen presentation, so the accessory and its artwork are off-window and
        // every lookup here returns nil. That is exactly what made the close fall back to a
        // cross-fade every single time — device log, on each of six swipes:
        //
        //     NP-DRAG began at 382,520
        //     NP-ANIM cross-fade present=false — geometry unavailable
        //
        // So the open records what it measured, and the close reads it back. The pill returns
        // to the same place it left from, which makes the recorded rect exact rather than a
        // guess.
        let liveArt = registry.cellRect(for: id, in: container)
        let livePill = MiniPlayerZoomSourceRegistry.sourceView
            .flatMap { $0.window == nil ? nil : $0.convert($0.bounds, to: container) }

        let art: (rect: CGRect, cornerRadius: CGFloat)?
        let pillRect: CGRect?
        if let liveArt, let livePill, liveArt.rect.width > 1, livePill.width > 1 {
            art = liveArt
            pillRect = livePill
            NowPlayingCoverGeometryCache.record(pill: livePill, art: liveArt, in: container)
        } else {
            let cached = NowPlayingCoverGeometryCache.resolve(in: container)
            art = cached?.art
            pillRect = cached?.pill
        }

        guard let art, art.rect.width > 1 else {
#if DEBUG
            DebugUIRemote.log("NP-ANIM geometry: no artwork rect (live=\(liveArt != nil) cached=false)")
#endif
            return nil
        }
        guard let pillRect, pillRect.width > 1, pillRect.height > 1 else {
#if DEBUG
            DebugUIRemote.log("NP-ANIM geometry: no pill rect (live=\(livePill != nil))")
#endif
            return nil
        }
        guard let hero = registry.heroRect(for: id, in: container), hero.rect.width > 1 else {
#if DEBUG
            DebugUIRemote.log("NP-ANIM geometry: no hero rect")
#endif
            return nil
        }

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

    /// `progress` 0 = collapsed into the pill, 1 = full screen. `dragOffset` slides the whole
    /// flight down without morphing it — see `updateDrag`.
    func applyState(progress: CGFloat, dragOffset: CGFloat? = nil) {
        guard let session else { return }
        let p = max(0, min(1, progress))
        session.progress = p
        if let dragOffset { self.dragOffset = dragOffset }
        let g = session.geometry

        // 1. The card. Grows out of the pill; the content behind it is revealed, not scaled.
        //    Drag translation is a `transform`, applied separately — never folded in here, so a
        //    drag costs no layout at all.
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

        // 3. The travelling cover — its **own object**, a sibling of the card rather than a
        //    child of it, living in absolute container coordinates.
        //
        //    That matters on the way down: as the card collapses toward the pill it becomes
        //    smaller than the cover, and a cover parented inside it would be clipped away just
        //    as it needs to be seen flying home. Outside the card it is never clipped, and the
        //    release reads the way it should — the sheet drops, the cover pops out as a single
        //    object and matches into the pill.
        if let artwork = session.artwork {
            artwork.frame = interpolate(g.artStart, g.artEnd, p)
            artwork.layer.cornerRadius = lerp(g.artStartCorner, g.artEndCorner, p)
        }

        // 4. The pill, stretching with the card's top edge and fading as it goes.
        if let pill = session.pillSnapshot {
            pill.frame = CGRect(x: 0, y: 0, width: card.width, height: g.pill.height)
            pill.alpha = 1 - smoothstep(p, 0, Self.pillFadeEnd)
        }

        // 5. Closing only: hand the pill's own area back before the card is taken away.
        //
        //    The card carries the player, so at the end of a close it is a pill-sized window
        //    onto the player's *transport row* sitting exactly where the pill is — and removing
        //    it at `finish` swapped that for the real pill in a single frame. That one-frame
        //    substitution is what reads as the title and artist juddering. Fading the card out
        //    over the last stretch lets the real pill arrive underneath instead.
        //
        //    The travelling cover is a sibling of the card, not a child, so it is unaffected and
        //    still lands on the pill's artwork.
        if direction == .dismiss {
            session.clip.alpha = smoothstep(p, 0, Self.closeHandoffEnd)
        }
    }

    // MARK: Interactive drag

    private(set) var isDragging = false
    /// How far the finger has pulled the page down, before any morph.
    private var dragOffset: CGFloat = 0
    /// An end that arrived before the drag was ready — see `beginDrag`.
    private var pendingEnd: Bool?

    /// The flight currently on screen, so a stuck transition can be torn down from outside.
    /// Weak: this is a recovery handle, never ownership.
    static weak var current: NowPlayingCoverAnimator?

    func beginDrag(context: UIViewControllerContextTransitioning) {
        guard prepare(context: context) != nil else {
            finishOwnedInteractiveContext(context)
            return
        }
        isDragging = true
        ownsInteractiveContext = true
        applyState(progress: 1)
        // `prepare` reparents the player, which can cancel the very gesture driving this before
        // `isDragging` was ever true. That end has to be honoured now rather than dropped —
        // dropping it left the transition in flight forever.
        if let pendingEnd {
            self.pendingEnd = nil
            endDrag(committed: pendingEnd)
        }
    }

    /// The player follows the finger **without morphing**.
    ///
    /// Measured against Apple Music: while the finger is down the cover does not start shrinking
    /// or drifting toward the pill at all — the whole page, cover included, simply slides down.
    /// The geometry match to the pill happens only on release. Scrubbing the morph with the drag
    /// instead is what made the cover "move too quickly" and start reassembling under the finger.
    func updateDrag(translation: CGFloat) {
        guard isDragging, let session else { return }
        // Resist upward drags: this gesture only ever dismisses.
        let offset = translation > 0 ? translation : translation * 0.25
        dragOffset = offset
        // A **transform**, not a frame change. Re-laying the card out every frame meant setting
        // the player's frame every frame too, which forces SwiftUI to lay the whole player out
        // — that is what made the drag feel heavy. A translation on the layer costs nothing and
        // moves the card and the cover as rigid objects, which is exactly what a drag should do.
        let slide = CGAffineTransform(translationX: 0, y: offset)
        session.clip.transform = slide
        session.artwork?.transform = slide
        let fraction = max(0, min(1, offset / max(session.geometry.full.height * 0.55, 1)))
        session.context.updateInteractiveTransition(fraction)
    }

    func endDrag(committed: Bool, velocity: CGFloat = 0) {
        guard isDragging, let session else {
            // Arrived before `beginDrag` finished setting up; replayed there.
            if session == nil { pendingEnd = committed }
            return
        }
        isDragging = false

        // Spring, not a curve. This is the release the sheet settles home on — it slides and
        // settles with a little overshoot rather than easing flatly into place, and seeding it
        // with the finger's velocity is what makes a flick feel like it threw the sheet down.
        let distance = max(session.geometry.full.height - session.geometry.pill.minY, 1)
        let initial = CGVector(dx: 0, dy: min(abs(velocity) / distance, 8))
        let animator = UIViewPropertyAnimator(
            duration: committed ? Self.dismissDuration : 0.42,
            timingParameters: UISpringTimingParameters(
                dampingRatio: committed ? 0.82 : 0.86,
                initialVelocity: initial
            )
        )
        animator.addAnimations { [weak self] in
            guard let self, let session = self.session else { return }
            // The drag translation unwinds and the morph runs in the same breath, so the cover
            // leaves exactly where the finger left it and geometry-matches into the pill from
            // there — rather than snapping back to centre first and then flying.
            self.dragOffset = 0
            session.clip.transform = .identity
            session.artwork?.transform = .identity
            self.applyState(progress: committed ? 0 : 1)
        }
        animator.addCompletion { [weak self] _ in
            self?.finish(committed: committed)
        }
        propertyAnimator = animator
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
        if Self.current === self { Self.current = nil }
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

/// Where the pill was when the player was opened, in **window** coordinates.
///
/// The close cannot measure it: a full-screen presentation takes the accessory off-window, so
/// the pill's artwork and the pill itself both stop resolving. Recorded on the way up, read on
/// the way down — and window coordinates rather than container ones because the two transitions
/// run in different containers.
@MainActor
enum NowPlayingCoverGeometryCache {
    private static var pill: CGRect?
    private static var art: CGRect?
    private static var artCorner: CGFloat = 6

    static func record(pill: CGRect, art: (rect: CGRect, cornerRadius: CGFloat), in container: UIView) {
        let pillWindow = container.convert(pill, to: nil)
        let artWindow = container.convert(art.rect, to: nil)
        guard pillWindow.width > 1, artWindow.width > 1 else { return }
        self.pill = pillWindow
        self.art = artWindow
        artCorner = art.cornerRadius
    }

    static func resolve(in container: UIView) -> (pill: CGRect, art: (rect: CGRect, cornerRadius: CGFloat))? {
        guard let pill, let art else { return nil }
        let pillLocal = container.convert(pill, from: nil)
        let artLocal = container.convert(art, from: nil)
        guard pillLocal.width > 1, artLocal.width > 1 else { return nil }
        return (pillLocal, (artLocal, artCorner))
    }
}

/// Hands the drag to ``NowPlayingCoverAnimator``. Not percent-driven: UIKit's percent scrubbing
/// bakes its end values when it starts, and the geometry here is written directly on every pan
/// update instead.
@MainActor
final class NowPlayingCoverInteraction: NSObject, UIViewControllerInteractiveTransitioning {
    private weak var animator: NowPlayingCoverAnimator?
    private var hasStarted = false
    private var pendingTranslation: CGFloat?

    init(animator: NowPlayingCoverAnimator) {
        self.animator = animator
    }

    nonisolated var wantsInteractiveStart: Bool { true }

    nonisolated func startInteractiveTransition(_ transitionContext: UIViewControllerContextTransitioning) {
        MainActor.assumeIsolated {
            hasStarted = true
            animator?.beginDrag(context: transitionContext)
            if let pendingTranslation { update(translation: pendingTranslation) }
        }
    }

    func update(translation: CGFloat) {
        guard hasStarted else {
            pendingTranslation = translation
            return
        }
        animator?.updateDrag(translation: translation)
    }

    func finish(committed: Bool, velocity: CGFloat) {
        animator?.endDrag(committed: committed, velocity: velocity)
    }
}
#endif
