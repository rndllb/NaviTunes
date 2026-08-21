import SwiftUI

// MARK: - Style

/// Which transition a given cover id uses. Registered by the source cell and read back by the
/// pushed detail, so a call site opts in at one place and the destination follows.
///
/// Declared outside the platform guard because ``coverZoomSource(id:style:)`` is cross-platform.
enum CoverZoomStyle {
    /// SwiftUI's `.navigationTransition(.zoom)`.
    case system
    /// The animator in this file.
    case custom
}

#if os(iOS)
import UIKit

/// A local reimplementation of `navigationTransition(.zoom)`.
///
/// The stock transition is right about the *motion* — measured frame by frame against Apple
/// Music (`docs/reference-apple-music-vs-vellum-dismiss.MP4`), both animate a rounded card
/// containing the whole destination page, growing out of the tapped cell's artwork with the
/// content inside scaled about the cover, over a list that never moves. What it will not let
/// us control is everything around that:
///
/// - **The source cell stays visible.** Apple Music empties the row for the whole flight, so
///   only one cover is ever on screen. Ours leaves both up, which reads as the cover being
///   swapped for a different object partway through. See ``CoverZoomFlight``.
/// - **The navigation bar strands.** The detail's title and items linger over the revealed
///   list for ~600ms after it has settled (Apple's own bug — Developer Forums 774524).
/// - **The duration.** The zoom holds a transition coordinator for ~1.1s, and `NavigationStack`
///   discards navigation requests raised while one is alive: the "swipe straight back out and
///   the list ignores taps for a second" soft lock. The plain slide's ~0.35s does not trigger
///   it. Here the number is ``CoverZoomTuning/pushDuration``.
///
/// Nothing about the app shell changes: this is a `UINavigationControllerDelegate` on the
/// navigation controller `NavigationStack` already creates, not a UIKit port. The `TabView`,
/// `tabViewBottomAccessory` mini player, `.toolbar` content and every existing
/// ``coverZoomSource(id:)`` call site stay exactly as they are.
///
/// Opt in per call site with `coverZoomSource(id:style:)`; anything left `.system` keeps the
/// stock zoom.
///
/// The motion is driven by a `CADisplayLink` rather than `UIViewPropertyAnimator`, and the
/// interactive pop implements `UIViewControllerInteractiveTransitioning` directly rather than
/// subclassing `UIPercentDrivenInteractiveTransition`. Both are deliberate: a property animator
/// bakes its end values when it starts, so a card already in flight cannot follow a cell that
/// moves under it, and percent-driven interaction requires exactly those baked `CAAnimation`s.
/// Owning progress ourselves means ``CoverZoomAnimator/applyState(progress:)`` re-reads the
/// cell's live position every frame.

// MARK: - Tuning

/// Every number the motion depends on, in one place. The user rejects animation that is 90%
/// right, so expect these to be adjusted one at a time between device builds.
enum CoverZoomTuning {
    /// Shipping durations. The pop is a touch quicker than the push, matching the reference
    /// footage — and both are far short of the ~1.1s the stock zoom holds its transition
    /// coordinator for, which is what caused the "list ignores taps for a second" soft lock.
    static let pushDuration: TimeInterval = 0.50
    static let popDuration: TimeInterval = 0.50

    /// Display corner radius the card converges on. `_displayCornerRadius` is private API, so
    /// this is a constant — 48 reads correctly on the 17 Pro.
    static let screenCornerRadius: CGFloat = 48

    /// How far the vertical travel lags the horizontal.
    ///
    /// With both axes on the same curve the cover runs a dead-straight diagonal, which reads as
    /// the cover rising to the top of the screen and then sliding sideways. Raising this makes
    /// y lag x, so the path bows *below* the straight line and meets it again at the end —
    /// 1.0 is the straight line, higher sags more.
    ///
    /// Left at 1.0 for now: the same symptom had a more direct cause — the card used to be
    /// interpolated independently of the cover, so it expanded about its own centre. With the
    /// card derived from the cover the path should already read straight. This knob is here if
    /// it still wants a bow.
    static let verticalLag: CGFloat = 1.0

    /// How quickly the navigation bar's buttons leave at the start of a transition, and how
    /// long the incoming set takes to arrive at the end. The reference footage has them gone
    /// well before the halfway point.
    static let barFadeOut: TimeInterval = 0.12
    static let barFadeIn: TimeInterval = 0.18

    /// Fraction of the width past which releasing the edge swipe commits the pop.
    static let popCommitFraction: CGFloat = 0.33
    /// Rightward velocity (pt/s) that commits regardless of distance.
    static let popCommitVelocity: CGFloat = 600

    /// `easeOutQuint`, as the cubic Bézier UIKit can actually run: leaves fast and settles long,
    /// so the cover arrives on its destination without a visible stop.
    ///
    /// This is what the transition is timed on. `UIView.AnimationCurve` has no quintic case, and
    /// the animation is driven by a `UIViewPropertyAnimator` — which is required, because UIKit
    /// can only scrub an interactive pop through one of those.
    static let easeOutQuint = UICubicTimingParameters(
        controlPoint1: CGPoint(x: 0.23, y: 1),
        controlPoint2: CGPoint(x: 0.32, y: 1)
    )
}

// MARK: - Flight state

/// Carries "which cover is currently in flight" to the source cell so it can take itself off
/// screen for the duration.
///
/// This is the fix for the cover appearing to swap identity mid-transition: there is only ever
/// one copy of the artwork visible, the one inside the animating card. Matching the artwork URL
/// and matching the corner radius were both tried before and neither helped, because neither
/// addressed two covers being on screen at once.
///
/// Deliberately *not* state on `AppModel` — every view observes the whole of that object, so a
/// publish re-runs every visible `body` (see `Rules/swiftui-body-cost.md`). Only the anchor
/// modifier subscribes here.
@MainActor
final class CoverZoomFlight: ObservableObject {
    static let shared = CoverZoomFlight()

    @Published private(set) var hiddenID: String?

    func beginFlight(id: String) {
        guard hiddenID != id else { return }
        hiddenID = id
    }

    func endFlight(id: String) {
        guard hiddenID == id else { return }
        hiddenID = nil
    }
}

// MARK: - Geometry registry

/// Where the artwork is, on both sides of the transition.
///
/// The animator needs two rects: the tapped cell's artwork, and the detail's hero artwork.
/// Neither is knowable from SwiftUI, so each side plants a non-interactive probe view sized to
/// the artwork and registers it here — the same way `CoverZoomDismissalObserver` already
/// reaches UIKit from a SwiftUI leaf.
///
/// Anchors are weak. A cell scrolled out of the list simply stops resolving, and a transition
/// with no resolvable anchor falls back to a cross-fade rather than animating to a stale rect.
/// Styles are *not* weak: they persist for the process lifetime so a pushed detail can still
/// ask "was I opened from a custom-style cell?" after its cell has been recycled.
@MainActor
final class CoverZoomRegistry {
    static let shared = CoverZoomRegistry()

    struct Anchor {
        weak var view: UIView?
        var cornerRadius: CGFloat
    }

    private var styles: [String: CoverZoomStyle] = [:]
    private var cells: [String: Anchor] = [:]
    private var heroes: [String: Anchor] = [:]
    /// Whole-cell rects, used to work out which row a touch landed on.
    private var rows: [String: Anchor] = [:]

    /// The cover the user just touched.
    ///
    /// UIKit asks the delegate for a push animator *before* the pushed detail's
    /// `viewWillAppear`, so the detail cannot report which cover is in play — that ordering
    /// made every first push fall back to a plain slide.
    ///
    /// Two earlier attempts at recording it are worth not repeating. A
    /// `simultaneousGesture(TapGesture())` on the cell swallowed the `NavigationLink`'s own
    /// activation and playlists stopped opening at all. Setting it from the link's *destination
    /// closure* looked right but is worse than useless: SwiftUI evaluates those closures when
    /// it builds rows, and a `LazyVStack` builds a buffer past the fold — so this ended up
    /// holding an off-screen row and the card flew in from below the bottom of the display
    /// (`cell=(20, 1128, 52, 52)` on a 956pt screen).
    ///
    /// It is now written only by a touch observer that hit-tests the registered row rects, so
    /// it can only ever name a row that was actually under the finger.
    var pendingPushID: String?

    /// The cover artwork's rect, in **window** coordinates, at the moment it was touched.
    ///
    /// Measuring it when the push animation starts gives a subtly different answer — the row
    /// has already shifted by then, which is why the push landed slightly above the artwork
    /// while the pop (measured against a settled list) was correct. This is the layout the user
    /// actually saw when they tapped.
    var pendingPushCellWindowRect: CGRect?
    var pendingPushCellCornerRadius: CGFloat = 0

    /// Last hero rect actually measured, in **window** coordinates, plus its corner radius.
    ///
    /// A first push has no hero to measure: the detail's hosting controller builds its SwiftUI
    /// body on a later render pass, so the probe does not exist when the animator needs it.
    /// Neither extra layout passes nor a runloop tick fix that — device logs showed
    /// `hero=nil` on every first push and a correctly measured hero on every subsequent one.
    ///
    /// Those same logs showed the measured rect is *identical* for every playlist —
    /// `(60, 124, 320, 320)` on a 17 Pro — because the hero's geometry comes from the detail's
    /// layout, not its content. So the last measurement is an exact predictor, not a guess.
    /// Persisted so the first push after a cold launch is right too.
    private var lastHeroWindowRect: CGRect?
    private var lastHeroCornerRadius: CGFloat = 14

    private static let heroRectDefaultsKey = "coverZoom.lastHeroWindowRect"
    private static let heroRadiusDefaultsKey = "coverZoom.lastHeroCornerRadius"

    private init() {
        if let stored = UserDefaults.standard.string(forKey: Self.heroRectDefaultsKey) {
            let rect = NSCoder.cgRect(for: stored)
            if rect.width > 1, rect.height > 1 { lastHeroWindowRect = rect }
        }
        let radius = UserDefaults.standard.double(forKey: Self.heroRadiusDefaultsKey)
        if radius > 0 { lastHeroCornerRadius = radius }
    }

    // MARK: Style

    func setStyle(_ style: CoverZoomStyle, for id: String) {
        styles[id] = style
    }

    func style(for id: String) -> CoverZoomStyle {
        styles[id] ?? .system
    }

    // MARK: Registration

    func registerCell(_ view: UIView, cornerRadius: CGFloat, for id: String) {
        cells[id] = Anchor(view: view, cornerRadius: cornerRadius)
    }

    func registerHero(_ view: UIView, cornerRadius: CGFloat, for id: String) {
        heroes[id] = Anchor(view: view, cornerRadius: cornerRadius)
    }

    func registerRow(_ view: UIView, for id: String) {
        rows[id] = Anchor(view: view, cornerRadius: 0)
    }

    func unregisterRow(_ view: UIView, for id: String) {
        if rows[id]?.view === view { rows[id] = nil }
    }

    /// Which registered row, if any, is under `point` (expressed in `view`'s space). Only rows
    /// currently on screen can match, so this cannot name a buffered row past the fold.
    func rowID(containing point: CGPoint, in view: UIView) -> String? {
        for (id, anchor) in rows {
            guard let rowView = anchor.view, rowView.window != nil else { continue }
            if rowView.convert(rowView.bounds, to: view).contains(point) { return id }
        }
        return nil
    }

    func unregisterCell(_ view: UIView, for id: String) {
        if cells[id]?.view === view { cells[id] = nil }
    }

    func unregisterHero(_ view: UIView, for id: String) {
        if heroes[id]?.view === view { heroes[id] = nil }
    }

    // MARK: Resolution

    /// The cell artwork's rect in `container`'s coordinate space, or `nil` if the cell is gone
    /// (scrolled away, deep link, "Go to Playlist" with no list behind).
    func cellRect(for id: String, in container: UIView) -> (rect: CGRect, cornerRadius: CGFloat)? {
        resolve(cells[id], in: container)
    }

    /// The hero artwork's measured rect, or `nil` if its probe does not exist yet.
    func measuredHeroRect(for id: String, in container: UIView) -> (rect: CGRect, cornerRadius: CGFloat)? {
        guard let resolved = resolve(heroes[id], in: container) else { return nil }
        recordHero(resolved, in: container)
        return resolved
    }

    /// The hero rect to animate to, falling back to the last measurement when this detail has
    /// not built its body yet. See ``lastHeroWindowRect``.
    func heroRect(for id: String, in container: UIView) -> (rect: CGRect, cornerRadius: CGFloat)? {
        if let measured = measuredHeroRect(for: id, in: container) { return measured }
        guard let windowRect = lastHeroWindowRect else { return nil }
        let rect = container.convert(windowRect, from: nil)
        guard rect.width > 1, rect.height > 1 else { return nil }
        return (rect, lastHeroCornerRadius)
    }

    private func recordHero(_ resolved: (rect: CGRect, cornerRadius: CGFloat), in container: UIView) {
        let windowRect = container.convert(resolved.rect, to: nil)
        guard windowRect.width > 1, windowRect.height > 1 else { return }
        guard windowRect != lastHeroWindowRect || resolved.cornerRadius != lastHeroCornerRadius else { return }
        lastHeroWindowRect = windowRect
        lastHeroCornerRadius = resolved.cornerRadius
        UserDefaults.standard.set(NSCoder.string(for: windowRect), forKey: Self.heroRectDefaultsKey)
        UserDefaults.standard.set(resolved.cornerRadius, forKey: Self.heroRadiusDefaultsKey)
    }

    private func resolve(_ anchor: Anchor?, in container: UIView) -> (rect: CGRect, cornerRadius: CGFloat)? {
        guard let anchor, let view = anchor.view, view.window != nil else { return nil }
        let rect = view.convert(view.bounds, to: container)
        guard rect.width > 1, rect.height > 1 else { return nil }
        return (rect, anchor.cornerRadius)
    }
}

// MARK: - Anchor probe

/// Reports its own frame — which SwiftUI has sized to the artwork — into the registry.
/// Draws nothing and never takes a touch.
private struct CoverZoomAnchorProbe: UIViewRepresentable {
    enum Role { case cell, hero, row }

    let id: String
    let role: Role
    let cornerRadius: CGFloat

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onMove = { register($0) }
        register(view)
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        register(view)
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: ()) {
        MainActor.assumeIsolated {
            CoverZoomRegistry.shared.unregisterCell(view, for: view.registeredID)
            CoverZoomRegistry.shared.unregisterHero(view, for: view.registeredID)
            CoverZoomRegistry.shared.unregisterRow(view, for: view.registeredID)
        }
    }

    private func register(_ view: ProbeView) {
        view.registeredID = id
        view.isCell = role == .cell
        switch role {
        case .cell: CoverZoomRegistry.shared.registerCell(view, cornerRadius: cornerRadius, for: id)
        case .hero: CoverZoomRegistry.shared.registerHero(view, cornerRadius: cornerRadius, for: id)
        case .row: CoverZoomRegistry.shared.registerRow(view, for: id)
        }
    }

    final class ProbeView: UIView {
        var registeredID: String = ""
        var isCell = false
        var onMove: ((ProbeView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            onMove?(self)
            // Install the delegate as soon as a custom cell is on screen. Doing it from the
            // pushed detail is too late: the very first push of a session would find no
            // delegate at all and use the default slide.
            if isCell, let nav = Self.enclosingNavigationController(of: self) {
                CoverZoomNavigationDelegate.installIfNeeded(on: nav)
            }
        }

        static func enclosingNavigationController(of view: UIView) -> UINavigationController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController {
                    return controller.navigationController
                }
                responder = current.next
            }
            return nil
        }
    }
}

// MARK: - Animator

/// Grows (or collapses) a rounded card between the cell's artwork rect and the full screen,
/// transforming the detail inside it so the hero artwork stays pinned to the cell artwork at
/// the collapsed end.
///
/// Progress is ours, ticked by a `CADisplayLink`. Every frame re-reads the cell's rect, so a
/// list that scrolls under an in-flight card retargets instead of flying to a stale position.
@MainActor
final class CoverZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    enum Direction { case push, pop }

    let direction: Direction
    let id: String
    private var session: Session?
    private var propertyAnimator: UIViewPropertyAnimator?

    init(direction: Direction, id: String) {
        self.direction = direction
        self.id = id
    }

    // MARK: Session

    /// Everything one running transition needs. Held for the transition's lifetime and torn
    /// down exactly once.
    final class Session {
        let context: UIViewControllerContextTransitioning
        let container: UIView
        let clip: UIView
        let detail: UIView
        let full: CGRect
        let heroRect: CGRect
        let cellCornerRadius: CGFloat
        /// Last resolvable cell rect. Kept so a cell that scrolls *out* of the list mid-flight
        /// leaves the card heading somewhere sensible rather than snapping.
        var cellRect: CGRect
        var progress: CGFloat
        var link: CADisplayLink?
        var legStart: CFTimeInterval = 0
        var legFrom: CGFloat = 0
        var legTo: CGFloat = 0
        var legDuration: TimeInterval = 0
        var didComplete = false
        /// The list, made deaf for the length of a push so a second tap cannot start a second
        /// push over the first. Restored in `finish`.
        var suspendedList: UIView?
        /// Cross-faded across the transition so the outgoing screen's bar buttons leave early
        /// and the incoming screen's arrive as it settles. Restored in `finish`.
        weak var navigationBar: UINavigationBar?
        /// Watches the row's live position during a dismiss so the card can follow a list that
        /// scrolls under it. See `startRetargetWatch`.
        var retargetLink: CADisplayLink?
        /// Wall clock at transition start, used to bound retargeting so a continuously
        /// scrolling list cannot keep the transition alive forever.
        var startedAt: CFTimeInterval = CACurrentMediaTime()

        init(
            context: UIViewControllerContextTransitioning,
            container: UIView,
            clip: UIView,
            detail: UIView,
            full: CGRect,
            heroRect: CGRect,
            cellRect: CGRect,
            cellCornerRadius: CGFloat,
            progress: CGFloat
        ) {
            self.context = context
            self.container = container
            self.clip = clip
            self.detail = detail
            self.full = full
            self.heroRect = heroRect
            self.cellRect = cellRect
            self.cellCornerRadius = cellCornerRadius
            self.progress = progress
        }
    }

    // MARK: UIViewControllerAnimatedTransitioning

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        direction == .push ? CoverZoomTuning.pushDuration : CoverZoomTuning.popDuration
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        (interruptibleAnimator(using: context) as? UIViewPropertyAnimator)?.startAnimation()
    }

    /// Required for the swipe to work at all.
    ///
    /// UIKit's interactive pop can only *scrub* an animator that vends one of these. Without
    /// it, a gesture-driven pop cannot drive our animation, so UIKit substitutes its own
    /// parallax slide for the drag and only runs our animator for the final leg — which is
    /// exactly what the screen recording showed: the page sliding right unscaled with the list
    /// coming in from the left, then a correct shrink at the very end.
    ///
    /// This is also why driving progress by hand never worked, in either of the two attempts:
    /// the problem was never who owned the gesture, it was that there was nothing here for
    /// UIKit to scrub.
    func interruptibleAnimator(using context: UIViewControllerContextTransitioning) -> UIViewImplicitlyAnimating {
        if let propertyAnimator { return propertyAnimator }

        let isPush = direction == .push
        guard prepare(context: context) != nil else {
            // Geometry unavailable — `prepare` has already run the cross-fade. Hand back an
            // inert animator so UIKit has something to hold.
            let inert = UIViewPropertyAnimator(duration: transitionDuration(using: context), curve: .linear) {}
            propertyAnimator = inert
            return inert
        }

        applyState(progress: isPush ? 0 : 1)

        let animator = UIViewPropertyAnimator(
            duration: transitionDuration(using: context),
            timingParameters: CoverZoomTuning.easeOutQuint
        )
        animator.addAnimations { [weak self] in
            self?.applyState(progress: isPush ? 1 : 0)
        }
        animator.addCompletion { [weak self] position in
            guard let self else { return }
            // `.start` means the interactive pop was cancelled and ran backwards.
            finish(committed: position == .end)
        }
        propertyAnimator = animator
        if let session { startRetargetWatch(session) }
        scheduleCompletionWatchdog(nominal: transitionDuration(using: context))
        return animator
    }

    func animationEnded(_ transitionCompleted: Bool) {
        // Belt and braces: never leave the list deaf or a display link running, even if
        // `finish` was bypassed.
        session?.retargetLink?.invalidate()
        session?.suspendedList?.isUserInteractionEnabled = true
        session = nil
        propertyAnimator = nil
    }

    // MARK: Setup

    /// Builds the card and measures both ends. Returns `nil` when the geometry cannot be
    /// resolved, having already run a plain cross-fade in its place.
    @discardableResult
    func prepare(context: UIViewControllerContextTransitioning) -> Session? {
        if let session { return session }

        let isPush = direction == .push
        let container = context.containerView
        let detailKey: UITransitionContextViewControllerKey = isPush ? .to : .from
        let listKey: UITransitionContextViewControllerKey = isPush ? .from : .to

        guard let detailController = context.viewController(forKey: detailKey),
              let detailView = detailController.view else {
            crossFade(context: context)
            return nil
        }

        // The list stays at full size and full opacity for the whole transition — measured:
        // Apple Music never scales or dims it. On a pop it has to be *added*; on a push it is
        // already in the container.
        var suspendedList: UIView?
        if !isPush, let listController = context.viewController(forKey: listKey),
           let listView = listController.view {
            listView.frame = context.finalFrame(for: listController)
            container.insertSubview(listView, at: 0)
            listView.layoutIfNeeded()
            // Tried and reverted: making the list deaf during the dismiss as well. It does stop
            // a tap landing inside the close and stacking a second transition — device log:
            //   touchDown … coordinator=true depth=1
            //   didDisappear popped=true
            //   ask op=1 → run push=true
            // — but the list staying live through the dismiss is the entire point of this work,
            // and blocking it for the length of the pop defeats the purpose. The stacking has to
            // be handled without deafening the list.
        } else if isPush, let listView = context.viewController(forKey: listKey)?.view {
            // Deaf for the length of the push. Otherwise a second tap on another row starts a
            // second push over the first: the two covers disagree, the pop is declined, and the
            // back button stops working — the "tap two playlists quickly and get stuck" bug.
            listView.isUserInteractionEnabled = false
            suspendedList = listView
        }

        let full = container.bounds
        let clip = CoverZoomClipView(frame: full)
        clip.clipsToBounds = true
        clip.backgroundColor = .clear
        // Inert on the way *out* only: otherwise the shrinking card still takes touches and its
        // track list can be scrolled while it is on its way back to the row. On the way in the
        // card holds the page you are arriving at, and that must be usable immediately — making
        // it deaf in both directions meant you could not scroll a playlist until the open had
        // finished.
        clip.isUserInteractionEnabled = isPush
        container.addSubview(clip)

        // Size is fixed for the whole transition; only `transform` and `center` move per frame
        // (writing `bounds` each frame re-runs the hosting view's layout and makes it jitter).
        detailView.transform = .identity
        detailView.frame = full
        clip.addSubview(detailView)
        detailView.setNeedsLayout()
        detailView.layoutIfNeeded()

        // A push uses the rect captured at touch-down; a pop measures the settled list.
        let capturedCell: (rect: CGRect, cornerRadius: CGFloat)? = {
            guard isPush, let windowRect = CoverZoomRegistry.shared.pendingPushCellWindowRect else { return nil }
            let rect = container.convert(windowRect, from: nil)
            guard rect.width > 1, rect.height > 1 else { return nil }
            return (rect, CoverZoomRegistry.shared.pendingPushCellCornerRadius)
        }()

        guard let cell = capturedCell ?? CoverZoomRegistry.shared.cellRect(for: id, in: container),
              let hero = CoverZoomRegistry.shared.heroRect(for: id, in: container),
              hero.rect.width > 1 else {
#if DEBUG
            DebugUIRemote.log("COVERZOOM fallback id=\(id) push=\(isPush) "
                + "cell=\(CoverZoomRegistry.shared.cellRect(for: id, in: container)?.rect.debugDescription ?? "nil") "
                + "hero=\(CoverZoomRegistry.shared.heroRect(for: id, in: container)?.rect.debugDescription ?? "nil")")
#endif
            detailView.transform = .identity
            detailView.frame = full
            container.addSubview(detailView)
            clip.removeFromSuperview()
            crossFade(context: context, detailView: detailView)
            return nil
        }

#if DEBUG
        DebugUIRemote.log("COVERZOOM run id=\(id) push=\(isPush) cell=\(cell.rect) hero=\(hero.rect)")
#endif

        CoverZoomFlight.shared.beginFlight(id: id)

        let built = Session(
            context: context,
            container: container,
            clip: clip,
            detail: detailView,
            full: full,
            heroRect: hero.rect,
            cellRect: cell.rect,
            cellCornerRadius: cell.cornerRadius,
            progress: isPush ? 0 : 1
        )
        built.suspendedList = suspendedList
        built.navigationBar = detailController.navigationController?.navigationBar
        session = built
        return built
    }

    // MARK: State

    /// Places the card and its contents for `progress` — 0 collapsed onto the cell, 1 filling
    /// the screen. Re-reads the cell's live rect so the target follows a scrolling list.
    func applyState(progress: CGFloat) {
        guard let session else { return }
        let p = max(0, min(1, progress))
        session.progress = p

        // Re-read the row live only while dismissing — that is where a list scrolling under an
        // in-flight card has to be followed. During a push the rect stays frozen at the one
        // captured on touch-down, so the list settling underneath cannot shift the target.
        if direction == .pop, let live = CoverZoomRegistry.shared.cellRect(for: id, in: session.container) {
            session.cellRect = live.rect
        }

        let cell = session.cellRect
        let hero = session.heroRect
        let full = session.full

        // Scale that makes the hero exactly cover the cell when collapsed.
        let collapsedScale = hero.width > 0 ? cell.width / hero.width : 1
        let scale = collapsedScale + (1 - collapsedScale) * p

        // Where the detail's centre must sit, in container coordinates, for the hero to land
        // on the cell at p = 0 and sit naturally at p = 1.
        let dx = hero.midX - full.midX
        let dy = hero.midY - full.midY
        // Vertical travel lags horizontal, bowing the cover's path below the straight diagonal
        // and rejoining it at the end. See `CoverZoomTuning.verticalLag`.
        let pv = pow(p, CoverZoomTuning.verticalLag)

        let collapsedCenter = CGPoint(x: cell.midX - dx * collapsedScale, y: cell.midY - dy * collapsedScale)
        let expandedCenter = CGPoint(x: full.midX, y: full.midY)
        let center = CGPoint(
            x: collapsedCenter.x + (expandedCenter.x - collapsedCenter.x) * p,
            y: collapsedCenter.y + (expandedCenter.y - collapsedCenter.y) * pv
        )

        // The card is a crop that opens outward *from the cover*, and both of its ends are
        // anchored on the cover rather than interpolated on their own.
        //
        //   p = 0  the card is exactly the cover — nothing else of the page is visible
        //   p = 1  the card is the whole page
        //
        // Interpolating the card's frame independently made it expand about its own centre
        // while the cover drifted inside it (the cover "hitting the ceiling then sliding
        // sideways"); deriving it straight from the page made the entire page visible at once
        // with no crop at all. Blending the two cover-anchored rects gives the outward crop.
        let pageSize = CGSize(width: full.width * scale, height: full.height * scale)
        let pageRect = CGRect(
            x: center.x - pageSize.width / 2,
            y: center.y - pageSize.height / 2,
            width: pageSize.width,
            height: pageSize.height
        )
        // Where the cover itself sits right now, in container coordinates.
        let coverRect = CGRect(
            x: center.x + (hero.midX - full.midX) * scale - hero.width * scale / 2,
            y: center.y + (hero.midY - full.midY) * scale - hero.height * scale / 2,
            width: hero.width * scale,
            height: hero.height * scale
        )
        let cardFrame = CGRect(
            x: coverRect.minX + (pageRect.minX - coverRect.minX) * p,
            y: coverRect.minY + (pageRect.minY - coverRect.minY) * p,
            width: coverRect.width + (pageRect.width - coverRect.width) * p,
            height: coverRect.height + (pageRect.height - coverRect.height) * p
        )

        session.clip.frame = cardFrame
        session.clip.layer.cornerRadius = session.cellCornerRadius
            + (CoverZoomTuning.screenCornerRadius - session.cellCornerRadius) * p

        // Only transform and position per frame. Writing `bounds` here would re-trigger
        // `layoutSubviews` on the SwiftUI hosting view every single frame, which is what made
        // the motion jitter — the size is set once in `prepare`.
        session.detail.transform = CGAffineTransform(scaleX: scale, y: scale)
        session.detail.center = CGPoint(x: center.x - cardFrame.minX, y: center.y - cardFrame.minY)

#if DEBUG
        // Only the endpoints — enough to check the card against what is actually on screen
        // without writing a line every frame.
        if p <= 0.001 || p >= 0.999 {
            DebugUIRemote.log("COVERZOOM state p=\(String(format: "%.2f", p)) "
                + "card=\(cardFrame) detailCenter=\(session.detail.center) scale=\(String(format: "%.3f", scale)) "
                + "clipSuper=\(session.clip.superview.map { String(describing: type(of: $0)) } ?? "nil")")
        }
#endif
    }

    // MARK: Safety

    /// Guarantees the transition ends.
    ///
    /// While a transition is live the navigation controller accepts nothing else, so any path
    /// that fails to reach `completeTransition` freezes the whole screen — reported as "I can't
    /// back out", and as the app going inert after scrolling the row out of view during a
    /// dismiss. Retargeting makes that reachable in ordinary use, because each retarget extends
    /// the animation. This is the backstop: past a generous deadline the transition is finished
    /// regardless of what the animator is doing.
    @MainActor
    private func scheduleCompletionWatchdog(nominal: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(nominal * 2 + 0.3))
            guard let self, let session, !session.didComplete else { return }
#if DEBUG
            DebugUIRemote.log("COVERZOOM watchdog — transition never completed, forcing it")
#endif
            session.retargetLink?.invalidate()
            session.retargetLink = nil
            completeImmediately()
            if let session = self.session, !session.didComplete {
                finish(committed: true)
            }
        }
    }

    // MARK: Retargeting

    /// Keeps a dismissing card aimed at the row's *live* position.
    ///
    /// `UIViewPropertyAnimator` bakes its end values when it starts — which is why the card
    /// stopped following a scrolling list the moment the animation moved off a display link (it
    /// had to, so UIKit could scrub an interactive pop). Rather than give that up, watch the
    /// row each frame and retarget when it moves: pause, re-declare the end state from the new
    /// rect, and continue with whatever duration is left. The card keeps being pulled toward
    /// wherever the row actually is instead of flying to where it was when the dismiss began.
    @MainActor
    private func startRetargetWatch(_ session: Session) {
        guard direction == .pop else { return }
        session.retargetLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(retargetTick))
        link.add(to: .main, forMode: .common)
        session.retargetLink = link
    }

    @objc private func retargetTick() {
        guard let session,
              let animator = propertyAnimator,
              animator.state == .active,
              animator.isRunning,
              let live = CoverZoomRegistry.shared.cellRect(for: id, in: session.container)
        else { return }

        // Hard deadline. Every retarget pauses and continues the animator, which extends it —
        // so a finger that keeps scrolling can outrun the animation indefinitely and the
        // transition never completes, leaving the whole UI inert. Past this point the card
        // lands wherever it is aimed, scrolling or not.
        let nominal = transitionDuration(using: session.context)
        if CACurrentMediaTime() - session.startedAt > nominal * 1.5 {
            session.retargetLink?.invalidate()
            session.retargetLink = nil
            return
        }

        // Stop retargeting near the end so the last stretch always lands.
        guard animator.fractionComplete < 0.85 else { return }

        // Ignore small movement; only a real scroll retargets.
        guard abs(live.rect.midX - session.cellRect.midX) > 2
            || abs(live.rect.midY - session.cellRect.midY) > 2 else { return }

        session.cellRect = live.rect
        let remaining = max(0.15, 1 - animator.fractionComplete)
        animator.pauseAnimation()
        animator.addAnimations { [weak self] in
            self?.applyState(progress: 0)
        }
        animator.continueAnimation(
            withTimingParameters: CoverZoomTuning.easeOutQuint,
            durationFactor: remaining
        )
    }

    // MARK: Navigation bar

    /// **Not called — kept as a record of why this approach is wrong.**
    ///
    /// Fading `UINavigationController.navigationBar` cross-fades whichever item set is current,
    /// which looked like an easy way to match the reference footage. But that bar is shared by
    /// every screen on the stack: it took the *playlists list's* own header buttons with it, and
    /// any transition that did not reach `finish` left them invisible and untappable — a soft
    /// lock, and far worse than a late fade.
    ///
    /// A correct version has to fade only the outgoing view controller's own items, and hand
    /// over to the incoming one's — see `setBarItemAlpha` in `CoverZoomTransition.swift`, which
    /// is scoped to a single `navigationItem`.
    @MainActor
    private func crossFadeNavigationBar(_ session: Session) {
        guard let bar = session.navigationBar else { return }
        let total = direction == .push ? CoverZoomTuning.pushDuration : CoverZoomTuning.popDuration
        UIView.animate(withDuration: CoverZoomTuning.barFadeOut, delay: 0, options: [.curveEaseOut]) {
            bar.alpha = 0
        }
        UIView.animate(
            withDuration: CoverZoomTuning.barFadeIn,
            delay: max(0, total - CoverZoomTuning.barFadeIn),
            options: [.curveEaseIn]
        ) {
            bar.alpha = 1
        }
    }

    // MARK: Interruption

    /// True while this animator still owns an un-torn-down transition — its clip may still be
    /// on screen even if nothing is animating.
    var hasLiveSession: Bool {
        guard let session else { return false }
        return !session.didComplete
    }

    /// True while this animator's transition is still running.
    var isRunning: Bool {
        guard let propertyAnimator else { return false }
        return propertyAnimator.state == .active || propertyAnimator.isRunning
    }

    /// Jumps the animation to its end and completes the transition now.
    ///
    /// `UINavigationController` refuses to begin a pop while a transition is in flight, and it
    /// rejects the back button's `popViewController` outright — so the open duration is also the
    /// window in which the back button does nothing. Rather than shorten the animation to hide
    /// that, the delegate calls this on touch-down: touches are delivered before the button's
    /// action fires, so by the time the tap is acted on the stack is settled and the pop runs
    /// immediately.
    func completeImmediately() {
        if let propertyAnimator, propertyAnimator.state == .active {
            propertyAnimator.stopAnimation(false)
            propertyAnimator.finishAnimation(at: .end)
        }
        // Tear down even when the animator was not in a state that could be finished. This used
        // to return early, and a superseded transition then left its clip — a full-screen,
        // interactive container — sitting over the real navigation bar. The back button was
        // visible and simply could not be pressed, because the taps were landing on a leftover
        // transition view.
        if let session, !session.didComplete {
            finish(committed: true)
        }
    }

    // MARK: Completion

    /// Tears the card down and reports the outcome exactly once.
    func finish(committed: Bool) {
        guard let session, !session.didComplete else { return }
        session.didComplete = true
        session.retargetLink?.invalidate()
        session.retargetLink = nil
        session.suspendedList?.isUserInteractionEnabled = true
        session.suspendedList = nil
        // Never leave the bar faded — a cancelled swipe ends here too.
        session.navigationBar?.alpha = 1

        session.detail.transform = .identity
        session.detail.frame = session.full

        // A cancelled pop leaves the detail on screen; a committed push does too. In both
        // cases it has to be handed back to the container intact.
        let detailStays = (direction == .push && committed) || (direction == .pop && !committed)
        if detailStays {
            session.container.addSubview(session.detail)
        }
        session.clip.removeFromSuperview()
        CoverZoomFlight.shared.endFlight(id: id)

        if committed {
            session.context.completeTransition(!session.context.transitionWasCancelled)
        } else {
            session.context.completeTransition(false)
        }
    }

    // MARK: Fallback

    /// Used when the geometry cannot be resolved — a plain cross-fade, which is what the stock
    /// transition degrades to in the same situations.
    private func crossFade(context: UIViewControllerContextTransitioning, detailView: UIView? = nil) {
        let isPush = direction == .push
        let container = context.containerView
        let view = detailView ?? context.view(forKey: isPush ? .to : .from)
        if let view, view.superview == nil {
            view.frame = container.bounds
            container.addSubview(view)
        }
        if !isPush, let listController = context.viewController(forKey: .to),
           let listView = listController.view, listView.superview == nil {
            listView.frame = context.finalFrame(for: listController)
            container.insertSubview(listView, at: 0)
        }
        view?.alpha = isPush ? 0 : 1

        UIView.animate(withDuration: transitionDuration(using: context)) {
            view?.alpha = isPush ? 1 : 0
        } completion: { _ in
            view?.alpha = 1
            context.completeTransition(!context.transitionWasCancelled)
        }
    }
}

// MARK: - Interactive pop

/// The edge swipe, driving ``CoverZoomAnimator`` directly.
///
/// Not a `UIPercentDrivenInteractiveTransition` subclass: that class scrubs baked
/// `CAAnimation`s, which is exactly what prevents an in-flight card from retargeting when the
/// list scrolls underneath it. Owning progress here keeps the animator's per-frame geometry
/// read in play for the gesture as well as the released tail.
final class CoverZoomInteractivePop: UIPercentDrivenInteractiveTransition {
    private var isRunning = true

    func finish(velocity: CGFloat) {
        guard isRunning else { return }
        isRunning = false
        completionSpeed = 1
        finish()
    }

    func abort() {
        guard isRunning else { return }
        isRunning = false
        completionSpeed = 1
        cancel()
    }
}

/// The container the animating page rides in. Named so a leftover one can be found again.
///
/// It is full-screen and interactive during a push, so one that outlives its transition sits over
/// the real chrome and silently eats every tap — the screen looks completely normal and the back
/// button simply does not respond. Searching for the animator that made it is not enough: once
/// UIKit releases the animator, nothing holds a reference to it and the view is orphaned.
final class CoverZoomClipView: UIView {}

/// A recognizer that only ever watches. It reports the first touch of every sequence and then
/// immediately fails, so it never competes with, delays, or starves another recognizer.
///
/// This replaces a zero-duration `UILongPressGestureRecognizer`, which recognizes on touch-down
/// and holds until lift — on device that stopped `_UIParallaxTransitionPanGestureRecognizer`
/// receiving the swipe at all (the log showed our pan target never firing once, and UIKit never
/// even asking whether the gesture should begin).
final class CoverZoomTouchSpy: UIGestureRecognizer {
    var onTouchDown: ((CGPoint) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if let point = touches.first?.location(in: view) {
            onTouchDown?(point)
        }
        // Never recognize: this is a passive observer, not a gesture.
        state = .failed
    }
}

// MARK: - Navigation controller delegate

/// Installed on the `UINavigationController` that `NavigationStack` creates.
///
/// SwiftUI keeps its own delegate there and relies on the callbacks to sync its path, so this
/// is a proxy: it answers only the two transitioning questions, and forwards every other
/// selector to whatever was there before. The original is retained (the property is `weak`, so
/// simply replacing it could deallocate it), and the proxy itself is retained by the navigation
/// controller through an associated object.
@MainActor
final class CoverZoomNavigationDelegate: NSObject, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
    private let original: UINavigationControllerDelegate?
    private weak var navigationController: UINavigationController?

    private var interactionController: CoverZoomInteractivePop?
    /// True only in the fallback case where UIKit vended-but-did-not-drive the interaction
    /// controller and ``handleSystemPan(_:)`` had to scrub it by hand.
    private var isDrivingInteractionManually = false
    private weak var observedPan: UIGestureRecognizer?
    /// Every pop recognizer on the navigation controller's view, not just the one
    /// `interactivePopGestureRecognizer` vends. See `syncGestures`.
    private var observedPans: [UIGestureRecognizer] = []
    /// The push currently animating, if any. Weak: the animator lives only as long as UIKit
    /// holds it for the transition.
    /// The transition currently animating, in either direction. Weak: the animator lives only
    /// as long as UIKit holds it.
    private weak var runningAnimator: CoverZoomAnimator?
    /// The push currently animating, if any — used to cut an open short on touch-down.
    private weak var runningPushAnimator: CoverZoomAnimator?
    private var touchObserver: CoverZoomTouchSpy?
    /// The controller we pushed with our animator. Pops only belong to us when *this* is the
    /// one going away — otherwise popping the playlist *list* back to Library would zoom too,
    /// when it should be an ordinary slide.
    private weak var customDetailController: UIViewController?
    /// The id of the detail currently on top, if it was opened from a custom-style cell.
    private var activeCustomID: String?
    /// The last cover we actually pushed with. `activeCustomID` is cleared by the pushed
    /// detail's `viewDidDisappear`, and device logs showed pops arriving with it already nil —
    /// every pop fell through to SwiftUI's slide. This is the durable answer to "which cover
    /// does the screen on top belong to".
    private var lastPushedCustomID: String?

    private static var associationKey: UInt8 = 0

    init(navigationController: UINavigationController) {
        self.original = navigationController.delegate
        self.navigationController = navigationController
        super.init()
    }

    /// Installs (or re-asserts) the proxy without claiming an active cover. Called from the
    /// *source list* so the delegate is in place before any push begins.
    @discardableResult
    static func installIfNeeded(on navigationController: UINavigationController) -> CoverZoomNavigationDelegate {
        let existing = objc_getAssociatedObject(navigationController, &associationKey) as? CoverZoomNavigationDelegate
        let proxy = existing ?? CoverZoomNavigationDelegate(navigationController: navigationController)
        if existing == nil {
            objc_setAssociatedObject(
                navigationController,
                &associationKey,
                proxy,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        if navigationController.delegate !== proxy {
            navigationController.delegate = proxy
        }
        proxy.syncGestures()
        return proxy
    }

    /// Called from the pushed detail once it is on screen: from here on, pops belong to us.
    static func install(on navigationController: UINavigationController, activeID: String?) {
        let proxy = installIfNeeded(on: navigationController)
        proxy.activeCustomID = activeID
        proxy.syncGestures()
    }

    static func clearActiveID(on navigationController: UINavigationController, id: String) {
        guard let proxy = objc_getAssociatedObject(navigationController, &associationKey) as? CoverZoomNavigationDelegate
        else { return }
        if proxy.activeCustomID == id {
            proxy.activeCustomID = nil
            proxy.syncGestures()
        }
    }

    // MARK: Gestures

    /// Observes UIKit's own pop gesture rather than replacing it.
    ///
    /// An earlier version installed a private `UIScreenEdgePanGestureRecognizer` and called
    /// `popViewController` from it. That popped the view controller but left SwiftUI's
    /// `NavigationLink` still believing its destination was on screen, so tapping the *same*
    /// playlist a second time did nothing — a navigation-state desync, visible immediately on
    /// device. SwiftUI's own bookkeeping rides on the built-in gesture, so the built-in gesture
    /// has to stay in charge of *starting* the pop; we only need its progress, which a target
    /// added to the same recognizer gives us for free.
    private func syncGestures() {
        guard let navigationController else { return }
        guard let systemPan = navigationController.interactivePopGestureRecognizer else { return }
        systemPan.isEnabled = true

        // This recognizer's `delegate` is UIKit's own `_UINavigationInteractiveTransitionBase`.
        // **It must stay installed.** That object is the only thing that consults
        // `UINavigationControllerDelegate` on a gesture-driven pop: its
        // `gestureRecognizerShouldBegin:` is where UIKit asks for
        // `animationControllerFor:` / `interactionControllerFor:` and wires the answers into
        // the interactive transition. A programmatic pop (the back button) reaches the delegate
        // through `popViewController(animated:)` instead, which is why that path always worked.
        //
        // Two earlier versions removed it and both failed for the same underlying reason:
        //
        //  - Replacing it and answering `gestureRecognizerShouldBegin` ourselves let the
        //    gesture recognize but never armed the pop — we approved six `shouldBegin` calls
        //    and not one pop reached the delegate, because the object that does the arming was
        //    no longer being asked.
        //  - Clearing it to `nil` left the recognizer's target/action intact, so a pop *did*
        //    happen — with UIKit's built-in parallax, because nothing was left to ask us for an
        //    animator. That is exactly the reported bug: `PHASE didDisappear popped=true` with
        //    no `COVERZOOM ask op=2` between the appearance callbacks.
        //
        // Leaving it alone used to make the swipe do nothing at all, because UIKit vetoes the
        // gesture when the delegate hands back a custom animator with no interaction controller
        // — and `interactionControllerFor:` used to return `nil` at that moment, since it tested
        // for a pan already in `.began`/`.changed`. At `shouldBegin` time the pan is still
        // `.possible`. See `isSystemPanActive`, which now recognises that instant.
        //
        // Nothing here touches `systemPan.delegate` any more. If a device log ever shows
        // `panDelegate=nil` in the `COVERZOOM syncGestures` line below, that is the first
        // regression to look for.

        installTouchObserver(on: navigationController)

#if DEBUG
        DebugUIRemote.log("COVERZOOM syncGestures "
            + "nav=\(UInt(bitPattern: ObjectIdentifier(navigationController).hashValue) & 0xffff) "
            + "navDelegate=\(navigationController.delegate.map { String(describing: type(of: $0)) } ?? "nil") "
            + "isUs=\(navigationController.delegate === self) "
            + "pan=\(String(describing: type(of: systemPan))) "
            + "panDelegate=\(systemPan.delegate.map { String(describing: type(of: $0)) } ?? "nil") "
            + "active=\(activeCustomID ?? "nil") "
            + "top=\(navigationController.topViewController.map { String(describing: type(of: $0)) } ?? "nil") "
            + "topPreferredTransition=\(navigationController.topViewController?.preferredTransition == nil ? "nil" : "set")")
#endif

        // iOS installs *two* pop recognizers on the navigation controller's view — an edge one
        // and a full-width one — and `interactivePopGestureRecognizer` only ever returns one of
        // them. Watching just that one meant the swipe was handled by the other: our target
        // never fired, and `isSystemPanActive` reported "no swipe" at the exact moment UIKit
        // asked, so we handed back a custom animator with a nil interaction controller and
        // UIKit vetoed the gesture. Device log, touch-down at the left edge:
        //
        //   recognizers=[_UIParallaxTransitionPanGestureRecognizer/en=true/st=0,
        //                _UIParallaxTransitionPanGestureRecognizer/en=true/st=0, ...]
        //
        // Observe all of them.
        var candidates: [UIGestureRecognizer] = [systemPan]
        for recognizer in navigationController.view.gestureRecognizers ?? []
        where String(describing: type(of: recognizer)).contains("Parallax") {
            if !candidates.contains(where: { $0 === recognizer }) { candidates.append(recognizer) }
        }
        for recognizer in candidates where !observedPans.contains(where: { $0 === recognizer }) {
            recognizer.removeTarget(self, action: #selector(handleSystemPan(_:)))
            recognizer.addTarget(self, action: #selector(handleSystemPan(_:)))
            observedPans.append(recognizer)
        }
        observedPan = systemPan
    }

    /// Watches touch-down without consuming it, so the cover a push belongs to can be resolved
    /// from what is actually under the finger.
    ///
    /// A zero-duration long press fires on touch-down and, with `cancelsTouchesInView` and the
    /// delays switched off plus simultaneous recognition, is invisible to the SwiftUI button
    /// underneath. That matters: a `TapGesture` in SwiftUI ate the `NavigationLink`'s
    /// activation outright.
    private func installTouchObserver(on navigationController: UINavigationController) {
        guard touchObserver == nil else { return }
        let observer = CoverZoomTouchSpy()
        observer.onTouchDown = { [weak self] point in
            self?.noteTouchDown(at: point)
        }
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        navigationController.view.addGestureRecognizer(observer)
        touchObserver = observer
    }

    /// Whether a touch landed on the navigation bar's back button. Generous on width — the tap
    /// target extends past the chevron — and bounded by the bar itself.
    private func isBackButtonRegion(_ point: CGPoint, in view: UIView) -> Bool {
        guard let bar = navigationController?.navigationBar else { return false }
        let barFrame = bar.convert(bar.bounds, to: view)
        return point.y <= barFrame.maxY && point.x <= barFrame.minX + 110
    }

    private func noteTouchDown(at point: CGPoint) {
        guard let navigationController,
              let view = navigationController.view else { return }

        // Cut an in-flight open short so the stack is settled by the time this touch's action
        // runs. Without this, the back button is inert for the whole push duration, because
        // UIKit rejects `popViewController` while a transition is running.
        // "The button is there but I cannot press it." A superseded transition can leave its
        // clip — full-screen and interactive — over the real chrome, swallowing every tap while
        // everything still looks normal. Any touch is a chance to notice a transition that is no
        // longer animating but has not torn itself down, and end it.
#if DEBUG
        // Unconditional: when the back button will not respond, this line is what separates
        // "the touch never reached us" from "it did, and the button's action still did not
        // fire" — which have nothing in common as fixes.
        DebugUIRemote.log("COVERZOOM touchDown x=\(String(format: "%.0f", point.x)) y=\(String(format: "%.0f", point.y)) "
            + "coordinator=\(navigationController.transitionCoordinator != nil) "
            + "depth=\(navigationController.viewControllers.count) "
            + "hit=\(navigationController.view.hitTest(point, with: nil).map { String(describing: type(of: $0)) } ?? "nil")")
#endif

        // Orphaned containers first: with no transition running, nothing of ours should still be
        // covering the screen. Made inert rather than removed — it may still be holding the
        // detail view, and losing that is worse than leaving an invisible, harmless view behind.
        if navigationController.transitionCoordinator == nil {
            var orphans: [CoverZoomClipView] = []
            func sweep(_ candidate: UIView) {
                if let clip = candidate as? CoverZoomClipView {
                    if clip.isUserInteractionEnabled { orphans.append(clip) }
                    return
                }
                candidate.subviews.forEach(sweep)
            }
            sweep(navigationController.view)
            if !orphans.isEmpty {
#if DEBUG
                DebugUIRemote.log("COVERZOOM \(orphans.count) orphaned clip(s) over the UI — disarming")
#endif
                orphans.forEach { $0.isUserInteractionEnabled = false }
            }
        }

        for stranded in [runningAnimator, runningPushAnimator] {
            guard let stranded, !stranded.isRunning, stranded.hasLiveSession else { continue }
#if DEBUG
            DebugUIRemote.log("COVERZOOM stranded transition found on touch — tearing it down")
#endif
            stranded.completeImmediately()
        }
        if runningAnimator?.hasLiveSession == false { runningAnimator = nil }
        if runningPushAnimator?.hasLiveSession == false { runningPushAnimator = nil }

        if let running = runningPushAnimator, running.isRunning {
#if DEBUG
            DebugUIRemote.log("COVERZOOM touch during push — completing it now")
#endif
            running.completeImmediately()
            runningPushAnimator = nil

            // Completing the push frees the stack, but this touch's own button action has
            // already been rejected by UIKit — which is why the first back tap did nothing and
            // a second was needed. If the touch was on the back button and nothing popped by
            // the next runloop turn, perform the pop ourselves.
            if isBackButtonRegion(point, in: view) {
                let depthBefore = navigationController.viewControllers.count
                Task { @MainActor [weak self, weak navigationController] in
                    guard let self, let navigationController else { return }
                    guard navigationController.viewControllers.count == depthBefore,
                          depthBefore > 1,
                          navigationController.topViewController === self.customDetailController
                    else { return }
#if DEBUG
                    DebugUIRemote.log("COVERZOOM back tap was swallowed by the push — popping")
#endif
                    navigationController.popViewController(animated: true)
                }
            }
        }

#if DEBUG
        // The edge swipe never reaches `_UIParallaxTransitionPanGestureRecognizer` — it never
        // changes state, so our target never fires and UIKit never asks whether it should
        // begin. Dump every recognizer in play at touch-down so it is visible *who* is taking
        // the touch, rather than narrowing by elimination.
        if point.x < 40 {
            let pan = navigationController.interactivePopGestureRecognizer
            var lines: [String] = []
            for host in [navigationController.view, navigationController.topViewController?.view] {
                guard let host else { continue }
                for recognizer in host.gestureRecognizers ?? [] {
                    lines.append("\(type(of: recognizer))/en=\(recognizer.isEnabled)/st=\(recognizer.state.rawValue)")
                }
            }
            DebugUIRemote.log("COVERZOOM edgeTouch x=\(String(format: "%.1f", point.x)) "
                + "panEnabled=\(pan?.isEnabled ?? false) panState=\(pan?.state.rawValue ?? -1) "
                + "panView=\(pan?.view.map { String(describing: type(of: $0)) } ?? "nil") "
                + "recognizers=[\(lines.joined(separator: ", "))]")
        }
#endif

        // SwiftUI takes `UINavigationController.delegate` back after a push, and a pop that
        // starts while it owns the property never reaches us — that is why the back button
        // animated correctly (the delegate is re-asserted on `viewDidAppear`) while an edge
        // swipe silently used SwiftUI's parallax slide: device logs showed the swipe popping
        // the screen with no `animationControllerFor` call at all. This fires on every
        // touch-down, including the first moment of that swipe, so ownership is settled before
        // any pop can begin.
        if navigationController.delegate !== self {
#if DEBUG
            DebugUIRemote.log("COVERZOOM delegate reclaimed by SwiftUI — reasserting on touch")
#endif
            navigationController.delegate = self
        }

        // Cleared when the touch is not on a cover cell, so a stale id can never claim an
        // unrelated push — Library → Playlists must stay an ordinary slide.
        let registry = CoverZoomRegistry.shared
        let id = registry.rowID(containing: point, in: view)
        registry.pendingPushID = id
        // Freeze the artwork's geometry now, before the push disturbs the list's layout.
        if let id, let measured = registry.cellRect(for: id, in: view) {
            registry.pendingPushCellWindowRect = view.convert(measured.rect, to: nil)
            registry.pendingPushCellCornerRadius = measured.cornerRadius
        } else {
            registry.pendingPushCellWindowRect = nil
        }
    }

    /// True when the pop being set up belongs to the built-in edge swipe — the signal that it
    /// should be interactive. A back-button pop must answer `false` here so it animates
    /// straight through instead of stalling on an interaction controller nothing will drive.
    ///
    /// The `.possible` case is the whole fix. UIKit asks the delegate for the animator *and*
    /// the interaction controller from `_UINavigationInteractiveTransitionBase`'s
    /// `gestureRecognizerShouldBegin:` — one instant *before* the recognizer moves to
    /// `.began`. Testing only for `.began`/`.changed` therefore returned `nil` at the one
    /// moment it mattered, and UIKit vetoes a gesture whose delegate offers a custom animator
    /// with no interaction controller. That veto is what made "leave UIKit's pan delegate
    /// alone" look like a dead end, which in turn led to clearing that delegate — which
    /// removed the veto *and* the only code that asks us anything.
    ///
    /// At that instant the recognizer is already tracking the finger and has satisfied its own
    /// rightward threshold, so touches plus a positive translation identify it precisely. A
    /// back-button pop arrives with the pan idle: no touches, no translation.
    /// True when *any* of the pop recognizers is mid-swipe.
    ///
    /// At `gestureRecognizerShouldBegin:` time the recognizer is still `.possible`, so that
    /// state has to count — it is the moment UIKit decides whether the gesture may run, and
    /// returning `nil` for the interaction controller there is what makes UIKit veto the swipe
    /// and fall back to nothing at all. A back-button pop arrives with every recognizer idle
    /// (no touches, no translation) and so still gets a non-interactive pop.
    private var activeSystemPan: UIPanGestureRecognizer? {
        for recognizer in observedPans {
            switch recognizer.state {
            case .began, .changed:
                return recognizer as? UIPanGestureRecognizer
            case .possible:
                guard recognizer.numberOfTouches > 0,
                      let pan = recognizer as? UIPanGestureRecognizer,
                      pan.translation(in: pan.view).x > 0 else { continue }
                return pan
            default:
                continue
            }
        }
        return nil
    }

    private var isSystemPanActive: Bool { activeSystemPan != nil }

    /// Safety net only.
    ///
    /// Once `interactionControllerFor:` hands UIKit a `UIPercentDrivenInteractiveTransition`,
    /// UIKit's own pop gesture drives it — that is the entire reason it refuses to begin
    /// without one. Driving it from here as well would have two writers scrubbing the same
    /// animator with slightly different arithmetic, and two commit rules racing at `.ended`.
    ///
    /// So this only steps in when UIKit demonstrably is not driving: `percentComplete` still
    /// parked at zero after the finger has clearly moved. That keeps the screen from stranding
    /// at 0% if this UIKit version behaves differently, without fighting it when it doesn't.
    @objc private func handleSystemPan(_ pan: UIGestureRecognizer) {
        guard let view = navigationController?.view else { return }
        let width = max(view.bounds.width, 1)
        let translation = (pan as? UIPanGestureRecognizer)?.translation(in: view).x ?? 0
        let fraction = max(0, min(1, translation / width))

#if DEBUG
        if pan.state != .changed || Int(fraction * 20) % 5 == 0 {
            DebugUIRemote.log("COVERZOOM pan state=\(pan.state.rawValue) "
                + "frac=\(String(format: "%.2f", fraction)) "
                + "interaction=\(interactionController != nil) "
                + "pct=\(String(format: "%.2f", interactionController?.percentComplete ?? -1)) "
                + "manual=\(isDrivingInteractionManually)")
        }
#endif

        switch pan.state {
        case .changed:
            guard let controller = interactionController else { return }
            if !isDrivingInteractionManually {
                guard controller.percentComplete <= 0.0001, fraction > 0.02 else { return }
#if DEBUG
                DebugUIRemote.log("COVERZOOM taking over interactive drive (UIKit left it at 0)")
#endif
                isDrivingInteractionManually = true
            }
            controller.update(fraction)
        case .ended:
            defer { interactionController = nil; isDrivingInteractionManually = false }
            guard isDrivingInteractionManually, let controller = interactionController else { return }
            let velocity = (pan as? UIPanGestureRecognizer)?.velocity(in: view).x ?? 0
            let commits = fraction > CoverZoomTuning.popCommitFraction
                || velocity > CoverZoomTuning.popCommitVelocity
            if commits {
                controller.finish(velocity: velocity)
            } else {
                controller.abort()
            }
        case .cancelled, .failed:
            defer { interactionController = nil; isDrivingInteractionManually = false }
            guard isDrivingInteractionManually else { return }
            interactionController?.abort()
        default:
            break
        }
    }

    // MARK: UIGestureRecognizerDelegate

    /// We are the delegate of the passive touch observer only. UIKit's pop gesture keeps its
    /// own delegate — see `syncGestures()` — because that object is what asks us for an
    /// animator in the first place.
    nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        MainActor.assumeIsolated {
            // The observer has to coexist with everything — scrolling, buttons, the pop swipe.
            gestureRecognizer === touchObserver || other === touchObserver
        }
    }

    // MARK: UINavigationControllerDelegate

    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
#if DEBUG
        DebugUIRemote.log("COVERZOOM ask op=\(operation.rawValue) "
            + "nav=\(UInt(bitPattern: ObjectIdentifier(navigationController).hashValue) & 0xffff) "
            + "installedNav=\(self.navigationController.map { UInt(bitPattern: ObjectIdentifier($0).hashValue) & 0xffff } ?? 0) "
            + "from=\(String(describing: type(of: fromVC))) to=\(String(describing: type(of: toVC))) "
            + "detail=\(customDetailController.map { String(describing: type(of: $0)) } ?? "nil") "
            + "fromIsDetail=\(fromVC === customDetailController) "
            + "panState=\(observedPan?.state.rawValue ?? -1) "
            + "panTouches=\(observedPan?.numberOfTouches ?? -1) "
            + "panActive=\(isSystemPanActive) "
            + "fromPreferredTransition=\(fromVC.preferredTransition == nil ? "nil" : "set") "
            + "toPreferredTransition=\(toVC.preferredTransition == nil ? "nil" : "set")")
#endif
        // Any transition still animating when the next one is asked for must be settled first —
        // two cards in flight is the state that strands the stack, and it is reachable by
        // opening and closing quickly in succession. This covers pops as well as pushes; only
        // pushes were settled before, which is why "open, close fast, open another, close fast"
        // could still wedge it.
        if let running = runningAnimator, running.isRunning {
            running.completeImmediately()
            runningAnimator = nil
        }

        switch operation {
        case .push:
            // The tap, not the pushed detail — see `CoverZoomRegistry.pendingPushID`.
            if let id = CoverZoomRegistry.shared.pendingPushID,
               CoverZoomRegistry.shared.style(for: id) == .custom {
                CoverZoomRegistry.shared.pendingPushID = nil
                activeCustomID = id
                lastPushedCustomID = id
                customDetailController = toVC
                let animator = CoverZoomAnimator(direction: .push, id: id)
                // Held so a touch during the open can cut the push short — see
                // `CoverZoomAnimator.completeImmediately`.
                runningPushAnimator = animator
                runningAnimator = animator
                return animator
            }
        case .pop:
            // Only the detail we pushed. Popping the playlist *list* back to Library is an
            // ordinary slide and must stay one.
            if fromVC === customDetailController,
               let id = activeCustomID ?? lastPushedCustomID,
               CoverZoomRegistry.shared.style(for: id) == .custom {
                // Deliberately *not* clearing `customDetailController` here. UIKit asks twice
                // for a gesture-driven pop — once from `gestureRecognizerShouldBegin:` while
                // it decides whether to arm the swipe, and again when the pop actually starts
                // — and clearing it on the first ask made the second one decline and fall back
                // to the slide. It is a weak reference, so a committed pop drops it when the
                // detail deallocates; a cancelled swipe correctly keeps it.
                let animator = CoverZoomAnimator(direction: .pop, id: id)
                runningAnimator = animator
                return animator
            }
        default:
            break
        }
#if DEBUG
        DebugUIRemote.log("COVERZOOM decline op=\(operation.rawValue) "
            + "active=\(activeCustomID ?? "nil") last=\(lastPushedCustomID ?? "nil") "
            + "pending=\(CoverZoomRegistry.shared.pendingPushID ?? "nil")")
#endif
        return forwardedAnimationController(navigationController, operation, fromVC, toVC)
    }

    func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        // Only an in-progress edge swipe makes a pop interactive. A back-button pop reaches
        // here with no live gesture and must animate straight through.
        //
        // Returning `nil` for a swipe is not neutral: UIKit refuses to *begin* the pop gesture
        // when the delegate offers a custom animator and no interaction controller. That veto
        // is the reason the swipe used to feel dead, and working around it by removing UIKit's
        // pan delegate is what stopped the delegate being consulted at all.
        let isSwipe = isSystemPanActive
#if DEBUG
        DebugUIRemote.log("COVERZOOM interactionAsk "
            + "isOurs=\(animationController is CoverZoomAnimator) "
            + "dir=\((animationController as? CoverZoomAnimator)?.direction == .pop ? "pop" : "other") "
            + "panState=\(observedPan?.state.rawValue ?? -1) "
            + "panTouches=\(observedPan?.numberOfTouches ?? -1) "
            + "isSwipe=\(isSwipe)")
#endif
        // Always vend one for our pop, without trying to judge whether a swipe is under way.
        //
        // That judgement is not decidable here: UIKit asks from `gestureRecognizerShouldBegin:`
        // while the recognizer is still `.possible` with zero translation, so any test for "is
        // the finger moving" answers no — and answering no is what makes UIKit veto the gesture
        // outright. A vetoed recognizer goes straight to `.failed` and never notifies its
        // targets, which is exactly what the device log showed: not one pan callback, ever,
        // from either pop recognizer.
        //
        // A back-button pop simply has nothing driving the controller, and the watchdog below
        // finishes it immediately — visually identical to a non-interactive pop.
        if let animator = animationController as? CoverZoomAnimator,
           animator.direction == .pop {
            let controller = CoverZoomInteractivePop()
            interactionController = controller
            isDrivingInteractionManually = false
            scheduleInteractionWatchdog(for: controller)
            return controller
        }
        if let original,
           original.responds(to: #selector(UINavigationControllerDelegate.navigationController(_:interactionControllerFor:))) {
            return original.navigationController?(navigationController, interactionControllerFor: animationController)
        }
        return nil
    }

    /// Insurance against a transition that is handed an interaction controller nobody drives.
    ///
    /// ``isSystemPanActive`` has to answer before the pop gesture reaches `.began`, so it reads
    /// the recognizer's touches and translation rather than its state. That is precise but not
    /// provably exclusive, and the failure mode if it ever mis-fires — a pop parked at 0% with
    /// the navigation stack mid-transition — is exactly the soft lock this whole screen has
    /// been fighting. If nothing has scrubbed the controller shortly after it was vended and no
    /// pan is live, let the pop finish on its own.
    /// Finishes a vended interaction controller that nothing is driving.
    ///
    /// Every pop now gets a controller (see `interactionControllerFor`), so this is what makes a
    /// back-button pop still animate straight through. Kept short so that press feels immediate;
    /// a real swipe will have moved the finger well inside this window.
    private func scheduleInteractionWatchdog(for controller: CoverZoomInteractivePop) {
        Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, let controller, self.interactionController === controller else { return }
            guard controller.percentComplete <= 0.0001 else { return }
            let panIsLive = self.observedPans.contains { $0.state == .began || $0.state == .changed || $0.numberOfTouches > 0 }
            guard !panIsLive else { return }
#if DEBUG
            DebugUIRemote.log("COVERZOOM interaction watchdog — nothing drove it, finishing")
#endif
            controller.finish(velocity: 0)
            self.interactionController = nil
            self.isDrivingInteractionManually = false
        }
    }

    private func forwardedAnimationController(
        _ navigationController: UINavigationController,
        _ operation: UINavigationController.Operation,
        _ fromVC: UIViewController,
        _ toVC: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard let original,
              original.responds(to: #selector(UINavigationControllerDelegate.navigationController(_:animationControllerFor:from:to:)))
        else { return nil }
        return original.navigationController?(navigationController, animationControllerFor: operation, from: fromVC, to: toVC)
    }

    // MARK: Forwarding

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}

// MARK: - Detail installer

/// Finds the navigation controller behind the pushed detail and installs the proxy for the
/// lifetime of that detail. Draws nothing; never takes a touch.
struct CoverZoomCustomTransitionInstaller: UIViewControllerRepresentable {
    let id: String

    func makeUIViewController(context: Context) -> Installer {
        let installer = Installer()
        installer.id = id
        installer.view.isUserInteractionEnabled = false
        return installer
    }

    func updateUIViewController(_ controller: Installer, context: Context) {
        controller.id = id
    }

    final class Installer: UIViewController {
        var id: String = ""

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let nav = parent?.navigationController ?? navigationController else { return }
            CoverZoomNavigationDelegate.install(on: nav, activeID: id)
        }

        /// Again once the push has settled — SwiftUI takes `navigationController.delegate` back
        /// during the transition, which silently disowned every subsequent pop (including the
        /// back button, which has no gesture to re-assert from).
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let nav = parent?.navigationController ?? navigationController else { return }
            CoverZoomNavigationDelegate.install(on: nav, activeID: id)
        }

        /// Diagnostic only: names the navigation controller and transition state the *pushed
        /// detail* actually sits in, independently of whichever delegate is installed. If a
        /// gesture-driven pop ever ran on a different navigation controller than the one we
        /// installed on, the ids logged here and in `COVERZOOM ask` would disagree.
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
#if DEBUG
            let nav = parent?.navigationController ?? navigationController
            DebugUIRemote.log("COVERZOOM installer willDisappear "
                + "nav=\(nav.map { UInt(bitPattern: ObjectIdentifier($0).hashValue) & 0xffff } ?? 0) "
                + "navDelegate=\(nav?.delegate.map { String(describing: type(of: $0)) } ?? "nil") "
                + "parentPreferredTransition=\(parent?.preferredTransition == nil ? "nil" : "set") "
                + "coordinator=\(nav?.transitionCoordinator != nil) "
                + "interactive=\(nav?.transitionCoordinator?.isInteractive ?? false)")
#endif
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            guard isMovingFromParent || parent?.isMovingFromParent == true,
                  let nav = parent?.navigationController ?? navigationController else { return }
            CoverZoomNavigationDelegate.clearActiveID(on: nav, id: id)
        }
    }
}

// MARK: - SwiftUI entry points

private struct CoverZoomAnchorModifier: ViewModifier {
    let id: String
    let role: CoverZoomAnchorProbe.Role
    let cornerRadius: CGFloat

    @ObservedObject private var flight = CoverZoomFlight.shared

    /// Only the *cell* copy is taken off screen. The hero is the copy that rides inside the
    /// animating card — hide it and the card flies empty, which is what "the cover doesn't
    /// move between the two views" looks like.
    private var isHiddenForFlight: Bool {
        role == .cell && flight.hiddenID == id
    }

    func body(content: Content) -> some View {
        content
            .opacity(isHiddenForFlight ? 0 : 1)
            .background(
                CoverZoomAnchorProbe(id: id, role: role, cornerRadius: cornerRadius)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    /// Marks the artwork inside a cover cell as the transition's origin rect, and takes it off
    /// screen while the transition runs so only the animating copy is ever visible.
    ///
    /// Applied to the *artwork*, not the whole cell — the animator needs the artwork's rect.
    func coverZoomCellAnchor(id: String, cornerRadius: CGFloat) -> some View {
        modifier(CoverZoomAnchorModifier(id: id, role: .cell, cornerRadius: cornerRadius))
    }

    /// Marks the detail's hero artwork as the transition's destination rect. Stays visible
    /// during the flight — it is the copy that rides inside the card.
    func coverZoomHeroAnchor(id: String, cornerRadius: CGFloat) -> some View {
        modifier(CoverZoomAnchorModifier(id: id, role: .hero, cornerRadius: cornerRadius))
    }

    /// Marks the whole tappable cell, so a touch can be resolved to the cover it belongs to.
    /// Never hidden and never interactive — it only reports geometry.
    func coverZoomRowAnchor(id: String) -> some View {
        background(
            CoverZoomAnchorProbe(id: id, role: .row, cornerRadius: 0)
                .allowsHitTesting(false)
        )
    }

    /// Installs the custom animator for a pushed detail opened from a `.custom` style cell.
    /// A no-op for `.system` ids, so this can sit unconditionally on the detail root.
    @ViewBuilder
    func coverZoomCustomTransition(id: String) -> some View {
        if CoverZoomRegistry.shared.style(for: id) == .custom {
            background(CoverZoomCustomTransitionInstaller(id: id).allowsHitTesting(false))
        } else {
            self
        }
    }
}
#else

// The package also compiles for macOS so `swift build` works on the host. There is no
// navigation controller to hang an animator off there — these keep the shared call sites
// compiling without a platform branch at every one of them.
extension View {
    func coverZoomCellAnchor(id: String, cornerRadius: CGFloat) -> some View { self }
    func coverZoomHeroAnchor(id: String, cornerRadius: CGFloat) -> some View { self }
    func coverZoomCustomTransition(id: String) -> some View { self }
    func coverZoomRowAnchor(id: String) -> some View { self }
}
#endif
