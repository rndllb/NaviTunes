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

/// Published into the environment by `coverZoomSource(id:style: .custom)` so the artwork inside
/// the cell can register itself as the transition's origin without the call site having to
/// find it. `AlbumArtworkView` reads this; a cell whose cover is something else marks it by hand
/// with `coverZoomCellAnchor(id:cornerRadius:)`.
struct CoverZoomCellAnchorRequest: Equatable {
    let id: String
    /// Overrides the artwork's own corner radius — for covers whose visible rounding belongs to
    /// a clipping container rather than to the artwork view itself (Home Top Picks).
    let cornerRadius: CGFloat?
}

private struct CoverZoomCellAnchorRequestKey: EnvironmentKey {
    static let defaultValue: CoverZoomCellAnchorRequest? = nil
}

extension EnvironmentValues {
    var coverZoomCellAnchorRequest: CoverZoomCellAnchorRequest? {
        get { self[CoverZoomCellAnchorRequestKey.self] }
        set { self[CoverZoomCellAnchorRequestKey.self] = newValue }
    }
}

extension View {
    /// Registers this view as the cover-zoom origin when an enclosing `.custom` cell asked for
    /// one, and otherwise does nothing. Applied inside `AlbumArtworkView`.
    @ViewBuilder
    func coverZoomCellAnchorIfRequested(_ request: CoverZoomCellAnchorRequest?, ownCornerRadius: CGFloat) -> some View {
        if let request {
            coverZoomCellAnchor(id: request.id, cornerRadius: request.cornerRadius ?? ownCornerRadius)
        } else {
            self
        }
    }
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

    /// Fraction of a dismiss that runs before a card with no cover to carry starts dissolving
    /// onto the row's artwork.
    ///
    /// Only reached when the detail was scrolled past its hero, so there is nothing at the
    /// cover's position inside the card to land with. Kept late: the shrink should read as the
    /// motion, with the hand-over happening as the card arrives. Expressed as a
    /// `UIViewPropertyAnimator` delay factor so an interactive swipe scrubs it too.
    static let dissolveDelayFactor: CGFloat = 0.55

    /// How much of its size the page gives up per screen-width of drag while the finger is down.
    /// 0.55 ⇒ a full-width drag leaves the page at 45% size. The position is the finger's; only
    /// the size is a function of distance.
    static let dragShrinkPerWidth: CGFloat = 0.55
    /// Smallest the page may get under the finger, as a fraction of full size.
    static let dragMinScale: CGFloat = 0.35
    /// Fly-home after the finger lifts on a committed swipe: from wherever the card is into the
    /// row. Separate from `popDuration` so the two can be tuned apart.
    static let dragReleaseDuration: TimeInterval = 0.50
    /// Return to full screen after a cancelled swipe.
    static let dragCancelDuration: TimeInterval = 0.35

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
    ///
    /// Keyed by destination *kind* (`heroKind(for:)`): the playlist/album detail, the browse
    /// album detail and Favorite Songs each have their own layout, and one global answer would
    /// aim a first push at the wrong rect whenever the kinds differ. (Today all three happen to
    /// share `min(max(w − 52, 260), 320)` at radius 14 — keying costs nothing and means the next
    /// destination with a different hero does not regress every first push.)
    private var lastHeroWindowRects: [String: CGRect] = [:]
    private var lastHeroCornerRadii: [String: CGFloat] = [:]

    private static let heroRectDefaultsKey = "coverZoom.lastHeroWindowRect"
    private static let heroRadiusDefaultsKey = "coverZoom.lastHeroCornerRadius"

    /// Which hero layout a cover id lands on. Derived from the id so the *source* side never
    /// has to know the destination type.
    static func heroKind(for id: String) -> String {
        if id == "__favorite_songs__" { return "favorites" }
        // The mini player's destination is the full player, whose hero is larger and higher
        // than a detail cover. Its own kind, so measuring it never overwrites the album
        // detail's cached rect (and vice versa).
        if id == "__now_playing__" { return "player" }
        if id.hasPrefix("chart-browse:") { return "browse" }
        // The artist page's hero is a full-bleed stretchy banner, not a square cover — the one
        // destination whose geometry genuinely differs, and the reason this cache is keyed at
        // all. Borrowing the album detail's 320×320 rect would aim every first artist push at
        // a square in the middle of the screen.
        if id.hasPrefix("artist-page:") { return "artist" }
        return "detail"
    }

    private init() {
        for kind in ["detail", "browse", "favorites", "artist", "player"] {
            // The un-suffixed key is the pre-keyed cache, which only ever held the detail hero.
            let suffix = kind == "detail" ? "" : ".\(kind)"
            if let stored = UserDefaults.standard.string(forKey: Self.heroRectDefaultsKey + suffix) {
                let rect = NSCoder.cgRect(for: stored)
                if rect.width > 1, rect.height > 1 { lastHeroWindowRects[kind] = rect }
            }
            let radius = UserDefaults.standard.double(forKey: Self.heroRadiusDefaultsKey + suffix)
            if radius > 0 { lastHeroCornerRadii[kind] = radius }
        }
    }

    // MARK: Style

    func setStyle(_ style: CoverZoomStyle, for id: String) {
        styles[id] = style
    }

    /// An id nobody registered answers `.custom`, not `.system`.
    ///
    /// A style is recorded by the *source cell's* `onAppear`, so an id whose cell has never
    /// been on screen has none — which is every deep link: "Go to Album" / "Go to Playlist"
    /// from the player, a notification tap, `DebugUIRemote`. Answering `.system` there made
    /// the pushed detail arm `navigationTransition(.zoom(sourceID:))` against a source id
    /// nothing had claimed. Two things followed, and both were reported as bugs: no zoom ran
    /// (there was nothing to zoom from), and SwiftUI's zoom took over dismissal, so the page
    /// could not be swiped back from the left edge the way every other pushed page can.
    ///
    /// `.custom` is the honest answer for an unknown id. Our own delegate declines a push it
    /// has no `pendingPushID` for and a pop with no cell to fly to, which lands the detail on
    /// UIKit's ordinary slide — with its ordinary edge-swipe pop. Every live call site passes
    /// `.custom` anyway; `.system` now only ever comes from a cell that asked for it.
    func style(for id: String) -> CoverZoomStyle {
        styles[id] ?? .custom
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

    /// Whether the source cover is still in a window.
    ///
    /// It is regularly `false` while a detail is open: `List` rows and lazy-stack cells are
    /// released once something covers them, so on most surfaces the cover the user tapped is
    /// simply not there any more by the time they come back.
    func cellIsOnScreen(for id: String) -> Bool {
        guard let view = cells[id]?.view, view.window != nil else { return false }
        return view.bounds.width > 1 && view.bounds.height > 1
    }

    /// Where this cover was, in **window** coordinates, when its detail was pushed.
    ///
    /// The pop's target when the live cell is gone (see ``cellIsOnScreen``). Without it the
    /// pop had no rect at all, and the two ways of handling that were both wrong on device:
    /// the cross-fade fallback stranded the navigation stack, and declining the pop handed it
    /// to UIKit's parallax — the swipe "immediately cutting out and doing the right-hand
    /// transition instead". The push's own measurement is the correct answer anyway: it is
    /// exactly where the artwork was when the user tapped it, and the row comes back into the
    /// same place as the list is revealed. Once the live cell does resolve again, the
    /// per-frame retarget takes over from this seed.
    private var lastCellWindowRects: [String: (rect: CGRect, cornerRadius: CGFloat)] = [:]

    func rememberCell(_ resolved: (rect: CGRect, cornerRadius: CGFloat), for id: String, in container: UIView) {
        let windowRect = container.convert(resolved.rect, to: nil)
        guard windowRect.width > 1, windowRect.height > 1 else { return }
        lastCellWindowRects[id] = (windowRect, resolved.cornerRadius)
    }

    func rememberedCellRect(for id: String, in container: UIView) -> (rect: CGRect, cornerRadius: CGFloat)? {
        guard let stored = lastCellWindowRects[id] else { return nil }
        let rect = container.convert(stored.rect, from: nil)
        guard rect.width > 1, rect.height > 1 else { return nil }
        return (rect, stored.cornerRadius)
    }

    /// Whether a pop has anywhere to fly to — a live cell, or a remembered one.
    ///
    /// Needs no container, so it can be answered in `animationControllerFor`, which runs before
    /// there is a transition context and is the only place a pop can still be declined cleanly.
    func hasCellTarget(for id: String) -> Bool {
        cellIsOnScreen(for: id) || lastCellWindowRects[id] != nil
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
        recordHero(resolved, kind: Self.heroKind(for: id), in: container)
        return resolved
    }

    /// Whether the hero artwork is (almost entirely) inside the visible area right now.
    ///
    /// A detail scrolled past its cover still has a live probe — the hero is part of a scroll
    /// view's content, not a lazy row — so it keeps resolving to a rect above the top of the
    /// screen. The rect is truthful and the animator's arithmetic stays correct, but the pixels
    /// are clipped away by the scroll view, so the card flies home empty. The pop needs to know
    /// that and dissolve onto the row instead of pretending it is carrying a cover.
    ///
    /// `false` also when the probe is gone entirely. On a *pop* the detail is on screen, so a
    /// missing probe means the hero is not there to fly.
    func heroIsOnScreen(for id: String, in container: UIView) -> Bool {
        guard let resolved = resolve(heroes[id], in: container) else { return false }
        let visible = resolved.rect.intersection(container.bounds)
        guard !visible.isNull else { return false }
        let area = resolved.rect.width * resolved.rect.height
        guard area > 0 else { return false }
        return (visible.width * visible.height) / area > 0.92
    }

    /// The hero rect to animate to, falling back to the last measurement when this detail has
    /// not built its body yet. See ``lastHeroWindowRect``.
    func heroRect(for id: String, in container: UIView) -> (rect: CGRect, cornerRadius: CGFloat)? {
        if let measured = measuredHeroRect(for: id, in: container) { return measured }
        let kind = Self.heroKind(for: id)
        // A kind never measured yet borrows the detail's answer: the album, browse and
        // favourites heroes all share `min(max(w − 52, 260), 320)` at radius 14, so a
        // slightly-off first push beats a cross-fade. The artist banner does **not** share it
        // — borrowing there would fly the card at a square in the middle of a page whose hero
        // is a full-width band at the top — so its first push cross-fades and every one after
        // it uses the real measurement.
        let borrowed = kind == "artist" ? nil : lastHeroWindowRects["detail"]
        guard let windowRect = lastHeroWindowRects[kind] ?? borrowed else { return nil }
        let rect = container.convert(windowRect, from: nil)
        guard rect.width > 1, rect.height > 1 else { return nil }
        return (rect, lastHeroCornerRadii[kind] ?? (kind == "artist" ? 0 : lastHeroCornerRadii["detail"] ?? 14))
    }

    private func recordHero(_ resolved: (rect: CGRect, cornerRadius: CGFloat), kind: String, in container: UIView) {
        let windowRect = container.convert(resolved.rect, to: nil)
        guard windowRect.width > 1, windowRect.height > 1 else { return }
        // Only a hero that is actually on screen is a valid predictor of where the *next*
        // detail's hero will be. Without this guard a detail scrolled past its cover reports a
        // rect above the top of the screen and that gets persisted — device log:
        //   COVERZOOM run push=false hero=(-97.3, 77.3, 320.0, 320.3)
        // — after which every first push of the session aims at a rect off the top of the
        // display. The measurement is still *used* for that transition; it just never becomes
        // the cached answer.
        guard container.bounds.insetBy(dx: -1, dy: -1).contains(resolved.rect) else { return }
        guard windowRect != lastHeroWindowRects[kind] || resolved.cornerRadius != lastHeroCornerRadii[kind] else { return }
        lastHeroWindowRects[kind] = windowRect
        lastHeroCornerRadii[kind] = resolved.cornerRadius
        let suffix = kind == "detail" ? "" : ".\(kind)"
        UserDefaults.standard.set(NSCoder.string(for: windowRect), forKey: Self.heroRectDefaultsKey + suffix)
        UserDefaults.standard.set(resolved.cornerRadius, forKey: Self.heroRadiusDefaultsKey + suffix)
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
            if isCell {
                if let nav = Self.enclosingNavigationController(of: self) {
                    CoverZoomNavigationDelegate.installIfNeeded(on: nav)
                } else {
#if DEBUG
                    DebugUIRemote.log("COVERZOOM cell \(registeredID) found no navigation controller — push will be SwiftUI's")
#endif
                }
            }
        }

        /// The navigation controller this view is ultimately presented in.
        ///
        /// Walks the *whole* responder chain rather than stopping at the first view controller.
        /// That first controller is not always the screen: `List` and collection-view rows are
        /// hosted by their own cell controllers (`CellHostingView`), whose `navigationController`
        /// is nil — stopping there meant every cell on Home, Search and the New tab installed
        /// nothing, SwiftUI's delegate ran the push as a plain slide, and ours only arrived with
        /// the detail, in time for the pop alone. Library's cells sit in a plain `ScrollView`,
        /// which is why it was the one tab that worked.
        static func enclosingNavigationController(of view: UIView) -> UINavigationController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let nav = current as? UINavigationController { return nav }
                if let controller = current as? UIViewController, let nav = controller.navigationController {
                    return nav
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

    // MARK: Navigation-bar fade state
    //
    // Deliberately *not* on `Session`: `animationEnded` clears that, and the one thing this
    // must never do is leave a bar button stuck at alpha 0 because the restore path could not
    // find its own state. See `startBarItemFadeIn`.
    private weak var fadingIncomingItem: UINavigationItem?
    private weak var fadingBar: UINavigationBar?
    private var fadingIncludesChevron = false
    private var barFadeReleased = false
    private var barFadeLink: CADisplayLink?
    private var barFadeStart: CFTimeInterval = 0
    private var barFadeHoldUntil: TimeInterval = 0

    /// Set the moment `prepare` gives up on the geometry and hands the transition to
    /// ``crossFade``. A cross-fade owns the context from then on — it will call
    /// `completeTransition` when its own animation ends — so `prepare` must never run a second
    /// one for the same transition.
    ///
    /// It could, before this: on the swipe path `prepare` is called twice, once from
    /// `beginDrag` and again from `interruptibleAnimator`, and with no `Session` to short it
    /// out both calls fell through to the fallback. Two cross-fades meant two
    /// `completeTransition` calls on one context, which leaves the navigation controller
    /// holding its transition coordinator forever — every later push and pop silently refused,
    /// the whole app apparently frozen with the UI still drawing. Device log, Search:
    ///
    ///     fallback id=7a0x… push=false cell=nil hero=(60,124,320,320)
    ///     fallback id=7a0x… push=false cell=nil hero=(60,124,320,320)
    ///     touchDown … coordinator=true depth=1     ← and still true seconds later
    private var didCrossFade = false
    /// Guards `finishOwnedInteractiveContext` — the cross-fade path can reach it from both the
    /// drag's early return and its own completion.
    private var didFinishInteractiveContext = false

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
        /// True when the card has no cover to carry — the detail is scrolled past its hero, so
        /// the artwork's pixels are clipped away by the scroll view. The card then dissolves
        /// onto the row's own artwork instead of landing on it. See `prepare`.
        var dissolvesOntoCell = false
        /// The navigation item of the screen being *revealed*. Its buttons are held at zero and
        /// faded in as the transition settles — see `startBarItemFadeIn`.
        weak var incomingItem: UINavigationItem?
        /// The system back chevron only arrives with a push; on a pop the one in the bar still
        /// belongs to the screen going away and is already being faded out by
        /// `CoverZoomTransition`'s `setBarItemAlpha`.
        var fadesBackChevron = false
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
        // Scrolled past the cover: the card is carrying the *page*, not an artwork, so it has to
        // hand over to the row rather than land on it. Full opacity for most of the travel — the
        // shrink is the motion — then a dissolve onto the row's own cover, which is deliberately
        // left on screen for this case (see `prepare`). A second animation block rather than an
        // alpha in `applyState` because that runs exactly twice: `UIViewPropertyAnimator`
        // interpolates between the two values it is given, so an alpha written there would fade
        // across the whole transition instead of the tail of it.
        if let session, session.dissolvesOntoCell {
            session.clip.alpha = 1
            animator.addAnimations(
                { session.clip.alpha = 0 },
                delayFactor: CoverZoomTuning.dissolveDelayFactor
            )
        }
        animator.addCompletion { [weak self] position in
            guard let self else { return }
            // `.start` means the interactive pop was cancelled and ran backwards.
            finish(committed: position == .end)
        }
        propertyAnimator = animator
        if let session {
            startRetargetWatch(session)
            startBarItemFadeIn(session)
        }
        scheduleCompletionWatchdog(nominal: transitionDuration(using: context))
        return animator
    }

    func animationEnded(_ transitionCompleted: Bool) {
        // Belt and braces: never leave the list deaf, a display link running, or a navigation
        // item's buttons invisible, even if `finish` was bypassed.
        session?.retargetLink?.invalidate()
        session?.suspendedList?.isUserInteractionEnabled = true
        releaseBarItemFade(animated: true)
        session = nil
        propertyAnimator = nil
    }

    // MARK: Setup

    /// Builds the card and measures both ends. Returns `nil` when the geometry cannot be
    /// resolved, having already run a plain cross-fade in its place.
    @discardableResult
    func prepare(context: UIViewControllerContextTransitioning) -> Session? {
        if let session { return session }
        // The cross-fade already has this transition. See `didCrossFade`.
        if didCrossFade { return nil }

        let isPush = direction == .push
        let container = context.containerView
        let detailKey: UITransitionContextViewControllerKey = isPush ? .to : .from
        let listKey: UITransitionContextViewControllerKey = isPush ? .from : .to

        guard let detailController = context.viewController(forKey: detailKey),
              let detailView = detailController.view else {
            didCrossFade = true
            crossFade(context: context)
            return nil
        }

        // The list stays at full size and full opacity for the whole transition — measured:
        // Apple Music never scales or dims it. On a pop it has to be *added*; on a push it is
        // already in the container.
        var suspendedList: UIView?
        if !isPush, let listController = context.viewController(forKey: listKey),
           let listView = listController.view {
            // `finalFrame(for:)` is documented to return `.zero` when UIKit does not consider
            // the controller's view part of the transition — a zero-sized list is invisible and
            // untouchable, which reads exactly like "the list is dead during the dismiss".
            let finalFrame = context.finalFrame(for: listController)
            listView.frame = finalFrame.width > 1 && finalFrame.height > 1 ? finalFrame : container.bounds
            // The list must be usable the whole way back. A push that fell through to the
            // cross-fade used to leave it switched off for good (see the `guard` below), and
            // anything that reaches this point with a stale `false` would silently swallow every
            // tap on the revealed list.
            listView.isUserInteractionEnabled = true
            listView.isHidden = false
            listView.alpha = 1
            listView.transform = .identity
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

        guard let cell = capturedCell
                ?? CoverZoomRegistry.shared.cellRect(for: id, in: container)
                // The row was released while the detail covered it. Fly back to where the push
                // came from — see `rememberedCellRect`.
                ?? CoverZoomRegistry.shared.rememberedCellRect(for: id, in: container),
              let hero = CoverZoomRegistry.shared.heroRect(for: id, in: container),
              hero.rect.width > 1 else {
#if DEBUG
            DebugUIRemote.log("COVERZOOM fallback id=\(id) push=\(isPush) "
                + "cell=\(CoverZoomRegistry.shared.cellRect(for: id, in: container)?.rect.debugDescription ?? "nil") "
                + "hero=\(CoverZoomRegistry.shared.heroRect(for: id, in: container)?.rect.debugDescription ?? "nil")")
#endif
            // The list was switched off a few lines above and there is no `Session` to switch it
            // back on: `finish` and `animationEnded` both key off one. Every cross-faded push
            // therefore used to leave the playlists list permanently deaf — the app looked
            // completely normal and ignored every tap. Device log has 21 of these.
            suspendedList?.isUserInteractionEnabled = true
            detailView.transform = .identity
            detailView.frame = full
            container.addSubview(detailView)
            clip.removeFromSuperview()
            didCrossFade = true
            crossFade(context: context, detailView: detailView)
            return nil
        }

        // A dismiss from a page scrolled past its cover has no cover to fly: the hero's pixels
        // are clipped away by the detail's own scroll view, so the card would arrive at the row
        // empty. Detected here, handled in `applyState` by dissolving the card over the last
        // stretch — and the row's artwork is deliberately left *visible* for that case, because
        // it is what the card is dissolving onto. A push always predicts its hero from the
        // cache (the detail has not built its body yet), so this only ever applies to a pop.
        let heroIsOnScreen = isPush || CoverZoomRegistry.shared.heroIsOnScreen(for: id, in: container)

        // Recorded on the push, spent on the pop when the row has been released underneath.
        if isPush { CoverZoomRegistry.shared.rememberCell(cell, for: id, in: container) }

#if DEBUG
        DebugUIRemote.log("COVERZOOM run id=\(id) push=\(isPush) cell=\(cell.rect) hero=\(hero.rect) "
            + "heroOnScreen=\(heroIsOnScreen)")
#endif

        if heroIsOnScreen {
            CoverZoomFlight.shared.beginFlight(id: id)
        }

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
        built.dissolvesOntoCell = !heroIsOnScreen
        // The screen being revealed: the detail on a push, the list on a pop.
        built.incomingItem = isPush
            ? detailController.navigationItem
            : context.viewController(forKey: listKey)?.navigationItem
        built.fadesBackChevron = isPush
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
            var lastFraction: CGFloat = -1
            // Extended, not fixed. A swipe the user is still dragging legitimately outlives the
            // nominal duration, and tearing the screen away mid-gesture is worse than the stall
            // this guards against — so a transition that is still *moving* gets another window.
            // Three of them, then it is wedged whatever it looks like.
            for round in 0..<12 {
                try? await Task.sleep(for: .seconds(nominal * 2 + 0.3))
                guard let self, let session, !session.didComplete else { return }
                let fraction = propertyAnimator?.fractionComplete ?? 0
                guard abs(fraction - lastFraction) <= 0.001 else {
                    lastFraction = fraction
                    continue
                }
                // A finger holding a swipe still is not a stall: a scrubbed animator is
                // `.active` but not running. Keep waiting — within reason — while that is so.
                if round < 6, isDragging { continue }
                if round < 3, session.context.isInteractive,
                   let animator = propertyAnimator, animator.state == .active, !animator.isRunning {
                    continue
                }
#if DEBUG
                DebugUIRemote.log("COVERZOOM watchdog — transition never completed, forcing it")
#endif
                session.retargetLink?.invalidate()
                session.retargetLink = nil
                completeImmediately()
                if let session = self.session, !session.didComplete {
                    finish(committed: true)
                }
                return
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

    /// Fades the *incoming* screen's bar buttons in as the transition settles.
    ///
    /// The outgoing side already leaves early — `setBarItemAlpha` in `CoverZoomTransition.swift`
    /// fades the departing screen's item groups and the system back chevron at
    /// `viewWillDisappear`. The arriving side had nothing: UIKit swaps the bar's content the
    /// instant the transition starts, so a full set of buttons appeared over a card that was
    /// still the size of a playlist row. That snap is what the reference footage does not do.
    ///
    /// **Never fade `UINavigationController.navigationBar` itself to achieve this.** That bar is
    /// shared by every screen on the stack, so it takes the *list's* own header buttons with it,
    /// and any transition that does not reach `finish` leaves them invisible and untappable — a
    /// soft lock, and far worse than a late fade. This works on one `UINavigationItem`'s hosted
    /// item views, plus the back chevron `UINavigationBar` owns privately.
    ///
    /// Held at zero on a display link rather than set once, because UIKit installs the incoming
    /// item's views partway through the transition — the same reason `applyMorphPassthrough` in
    /// `CoverZoomTransition.swift` re-applies each frame. Every path out of here restores alpha
    /// (see `releaseBarItemFade`), and a watchdog restores it even if none of them runs.
    @MainActor
    private func startBarItemFadeIn(_ session: Session) {
        guard let item = session.incomingItem else { return }
        fadingIncomingItem = item
        fadingBar = session.navigationBar
        fadingIncludesChevron = session.fadesBackChevron
        barFadeReleased = false

        let views = incomingBarViews()
        guard !views.isEmpty || fadingIncludesChevron else { return }
        views.forEach { $0.alpha = 0 }

        let total = transitionDuration(using: session.context)
        // Start early enough that the fade is over before the pushed detail's `viewDidAppear`
        // sets its own items back to full alpha — that call is not animated and would otherwise
        // cut the fade off at its brightest point.
        barFadeHoldUntil = max(0, total - CoverZoomTuning.barFadeIn - 0.06)
        // Under a finger the clock is meaningless — hold until the swipe is released and the
        // transition finishes (`finish` releases the fade). The watchdog below still bounds it.
        if session.context.isInteractive { barFadeHoldUntil = 4 }
        barFadeStart = CACurrentMediaTime()
        barFadeLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(barFadeTick))
        link.add(to: .main, forMode: .common)
        barFadeLink = link

        // Unconditional restore. Nothing about a navigation bar may depend on a transition
        // reaching its completion handler — a bar button left at alpha 0 is invisible *and*
        // untappable (UIKit's hit test skips near-transparent views), which is the soft lock an
        // earlier attempt at this shipped. The zeroed views are captured strongly as well as
        // going through `releaseBarItemFade`, so this holds even if the animator is gone.
        Task { @MainActor [weak self, held = views] in
            try? await Task.sleep(for: .seconds(max(total, barFadeHoldUntil) + 0.6))
            self?.releaseBarItemFade(animated: false)
            held.forEach { if $0.alpha < 1 { $0.alpha = 1 } }
        }
    }

    /// The incoming screen's own bar-button views. SwiftUI toolbar content lives in the
    /// navigation item's leading/trailing *groups* (`rightBarButtonItems` stays empty), hosted as
    /// `customView`s — alpha on those is the one knob `UINavigationBar` leaves alone while it
    /// animates the item containers itself.
    private func incomingBarViews() -> [UIView] {
        guard let item = fadingIncomingItem else { return [] }
        var views = (item.leadingItemGroups + item.trailingItemGroups)
            .flatMap(\.barButtonItems)
            .compactMap(\.customView)
        if fadingIncludesChevron, let bar = fadingBar {
            views += Self.backChevronViews(in: bar)
        }
        return views
    }

    /// The system back chevron, which is owned by `UINavigationBar` rather than by any
    /// navigation item — so the item-level walk above structurally cannot reach it.
    private static func backChevronViews(in bar: UIView) -> [UIView] {
        var found: [UIView] = []
        func walk(_ view: UIView) {
            let name = String(describing: type(of: view))
            if name.contains("BackButton") || name.contains("BackIndicator") {
                found.append(view)
                return
            }
            view.subviews.forEach(walk)
        }
        walk(bar)
        return found
    }

    @objc private func barFadeTick() {
        guard !barFadeReleased else { return }
        if CACurrentMediaTime() - barFadeStart < barFadeHoldUntil {
            for view in incomingBarViews() where view.alpha != 0 { view.alpha = 0 }
        } else {
            releaseBarItemFade(animated: true)
        }
    }

    @MainActor
    private func releaseBarItemFade(animated: Bool) {
        guard !barFadeReleased else { return }
        barFadeReleased = true
        barFadeLink?.invalidate()
        barFadeLink = nil
        let views = incomingBarViews()
        guard !views.isEmpty else { return }
        if animated {
            UIView.animate(withDuration: CoverZoomTuning.barFadeIn, delay: 0, options: [.curveEaseIn]) {
                views.forEach { $0.alpha = 1 }
            }
        } else {
            views.forEach { $0.alpha = 1 }
        }
    }

    // MARK: Interruption

    /// True while this animator still owns an un-torn-down transition — its clip may still be
    /// on screen even if nothing is animating.
    var hasLiveSession: Bool {
        guard let session else { return false }
        return !session.didComplete
    }

    /// True while this animator's transition is still running — including while a finger is
    /// holding the card mid-drag, when there is no property animator at all.
    var isRunning: Bool {
        if isDragging { return true }
        guard let propertyAnimator else { return false }
        return propertyAnimator.state == .active || propertyAnimator.isRunning
    }

    // MARK: Finger-driven drag

    /// True between `beginDrag` and the release animation starting.
    private(set) var isDragging = false
    /// True when *we* own the interactive context (our edge pan), so `finish` must tell UIKit
    /// the interaction finished or cancelled before completing. A percent-driven controller
    /// does that itself.
    private var ownsInteractiveContext = false
    /// The card's geometry at the moment of release, so the fly-home can start from it.
    private var dragScale: CGFloat = 1
    private var dragFrame: CGRect = .zero

    /// Puts the page under the finger. Called once when the swipe's pop is set up.
    ///
    /// Two phases, split at finger-up. While the finger is down the page is a plain uniform
    /// shrink that follows the finger — the point that was under the fingertip stays under it,
    /// in any direction — and its size is a function of how far the finger has travelled. Only
    /// when the finger lifts does the card fly home into the row (`flyHome`) or spring back to
    /// full screen (`flyBack`). Nothing is percent-driven: the geometry is written directly on
    /// every pan update, so it cannot drift onto the cell-bound path.
    func beginDrag(context: UIViewControllerContextTransitioning) {
        guard let session = prepare(context: context) else {
            // Geometry unavailable; `prepare` already ran a cross-fade that will complete.
            //
            // But this is *our* interactive context — UIKit will not act on
            // `completeTransition` until it has been told the interaction is over, and a
            // percent-driven controller is not in play here to do that for us. Without this
            // line the cross-fade finishes, the screen looks right, and the navigation
            // controller keeps its transition coordinator forever: every later push and pop is
            // refused and the app appears frozen. Committed rather than cancelled — the
            // cross-fade is already running the pop through to its end.
            finishOwnedInteractiveContext(context)
            return
        }
        isDragging = true
        ownsInteractiveContext = true
        applyState(progress: 1)
        session.clip.alpha = 1
        dragScale = 1
        dragFrame = session.full
        startBarItemFadeIn(session)
        scheduleCompletionWatchdog(nominal: transitionDuration(using: context))
    }

    /// Places the page for the current finger position. `start` is where the finger was when
    /// the swipe began, `finger` where it is now — both in container coordinates.
    func updateDrag(start: CGPoint, finger: CGPoint) {
        guard isDragging, let session else { return }
        let full = session.full
        let width = max(full.width, 1)
        let distance = hypot(finger.x - start.x, finger.y - start.y)
        let travelled = min(1, distance / width)
        let scale = max(CoverZoomTuning.dragMinScale, 1 - CoverZoomTuning.dragShrinkPerWidth * travelled)

        // Anchor on the fingertip: the page point under the finger at touch-down, (start − full
        // origin), stays under the finger after scaling.
        let origin = CGPoint(
            x: finger.x - (start.x - full.minX) * scale,
            y: finger.y - (start.y - full.minY) * scale
        )
        let frame = CGRect(x: origin.x, y: origin.y, width: full.width * scale, height: full.height * scale)

        session.clip.frame = frame
        session.clip.layer.cornerRadius = max(session.cellCornerRadius, CoverZoomTuning.screenCornerRadius * scale)
        session.detail.transform = CGAffineTransform(scaleX: scale, y: scale)
        session.detail.center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        dragScale = scale
        dragFrame = frame
        // Keep UIKit's own bookkeeping (navigation bar, coordinator observers) roughly in step.
        session.context.updateInteractiveTransition(travelled)
    }

    /// Finger lifted on a committed swipe: from wherever the card is, into the row.
    func flyHome() {
        guard isDragging, let session else { return }
        isDragging = false
        let animator = UIViewPropertyAnimator(
            duration: CoverZoomTuning.dragReleaseDuration,
            timingParameters: CoverZoomTuning.easeOutQuint
        )
        animator.addAnimations { [weak self] in
            self?.applyState(progress: 0)
        }
        if session.dissolvesOntoCell {
            animator.addAnimations({ session.clip.alpha = 0 }, delayFactor: CoverZoomTuning.dissolveDelayFactor)
        }
        animator.addCompletion { [weak self] _ in
            self?.finish(committed: true)
        }
        propertyAnimator = animator
        startRetargetWatch(session)
        animator.startAnimation()
    }

    /// Finger lifted early: back to full screen, page stays.
    func flyBack() {
        guard isDragging, let session else { return }
        isDragging = false
        let animator = UIViewPropertyAnimator(
            duration: CoverZoomTuning.dragCancelDuration,
            timingParameters: CoverZoomTuning.easeOutQuint
        )
        animator.addAnimations { [weak self] in
            self?.applyState(progress: 1)
            session.clip.alpha = 1
        }
        animator.addCompletion { [weak self] _ in
            self?.finish(committed: false)
        }
        propertyAnimator = animator
        animator.startAnimation()
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
        isDragging = false
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
        releaseBarItemFade(animated: true)
        // A cancelled dissolve leaves the card part-transparent; it is about to be handed back
        // to the container as the live screen.
        session.clip.alpha = 1

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

        // When our own edge pan owns the interaction, UIKit has not been told how it ended —
        // a percent-driven controller does this itself; we have to.
        if ownsInteractiveContext {
            ownsInteractiveContext = false
            if committed {
                session.context.finishInteractiveTransition()
            } else {
                session.context.cancelInteractiveTransition()
            }
        }
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
           let listView = listController.view {
            if listView.superview == nil {
                // `finalFrame(for:)` is documented to return `.zero` when UIKit does not
                // consider the controller part of the transition, and a zero-sized list is
                // invisible *and* untouchable — which reads exactly like the app having
                // frozen. Same guard the main path already carries.
                let final = context.finalFrame(for: listController)
                listView.frame = final.isEmpty ? container.bounds : final
                container.insertSubview(listView, at: 0)
            }
            listView.isUserInteractionEnabled = true
            listView.alpha = 1
            listView.isHidden = false
        }
        view?.alpha = isPush ? 0 : 1

        var completed = false
        let complete = { [weak self] in
            guard !completed else { return }
            completed = true
            view?.alpha = 1
            self?.finishOwnedInteractiveContext(context)
            context.completeTransition(!context.transitionWasCancelled)
        }

        UIView.animate(withDuration: transitionDuration(using: context)) {
            view?.alpha = isPush ? 1 : 0
        } completion: { _ in
            complete()
        }
        // The completion block of `UIView.animate` is not guaranteed to run if the animation is
        // removed out from under it, and a cross-fade that never calls `completeTransition`
        // leaves the navigation controller holding its transition coordinator forever: every
        // later push and pop silently refused while the UI still draws. Cheap insurance.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(transitionDuration(using: context) * 1000) + 250))
            complete()
        }
    }

    /// Tells UIKit an interaction we own has ended, so `completeTransition` can actually tear
    /// the transition down. A `UIPercentDrivenInteractiveTransition` does this itself; our
    /// finger-driven `CoverZoomDragInteraction` does not, and skipping it is what strands the
    /// stack. Safe to call on a non-interactive transition — it is then a no-op.
    private func finishOwnedInteractiveContext(_ context: UIViewControllerContextTransitioning) {
        guard context.isInteractive, !didFinishInteractiveContext else { return }
        didFinishInteractiveContext = true
        if context.transitionWasCancelled {
            context.cancelInteractiveTransition()
        } else {
            context.finishInteractiveTransition()
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

/// The interaction controller for our own edge swipe. Not percent-driven on purpose: UIKit's
/// percent scrubbing walks the fly-home path in step with the drag, which is exactly the "it
/// slides along a line instead of following my finger" complaint. This object hands the context
/// to the animator and then the pan drives the geometry directly (`updateDrag`); on release the
/// animator runs its own fly-home or fly-back and completes the transition.
@MainActor
final class CoverZoomDragInteraction: NSObject, UIViewControllerInteractiveTransitioning {
    private weak var animator: CoverZoomAnimator?
    /// Finger position when the swipe began, in the navigation view's coordinates.
    private let start: CGPoint
    private var hasStarted = false
    private var pendingFinger: CGPoint?

    init(animator: CoverZoomAnimator, start: CGPoint) {
        self.animator = animator
        self.start = start
    }

    nonisolated var wantsInteractiveStart: Bool { true }

    nonisolated func startInteractiveTransition(_ transitionContext: UIViewControllerContextTransitioning) {
        MainActor.assumeIsolated {
            hasStarted = true
            animator?.beginDrag(context: transitionContext)
            if let pendingFinger { update(finger: pendingFinger) }
        }
    }

    func update(finger: CGPoint) {
        guard hasStarted else { pendingFinger = finger; return }
        animator?.updateDrag(start: start, finger: finger)
    }

    func commit() {
        animator?.flyHome()
    }

    func cancel() {
        animator?.flyBack()
    }
}

/// A recognizer that only ever watches. It reports the first touch of every sequence and then
/// immediately fails, so it never competes with, delays, or starves another recognizer.
///
/// This replaces a zero-duration `UILongPressGestureRecognizer`, which recognizes on touch-down
/// and holds until lift — on device that stopped `_UIParallaxTransitionPanGestureRecognizer`
/// receiving the swipe at all (the log showed our pan target never firing once, and UIKit never
/// even asking whether the gesture should begin).
#if DEBUG
/// Watches UIKit's answer to `gestureRecognizerShouldBegin:` on the pop recognizers **without
/// taking the job over**.
///
/// The one thing 4.1 turns on is whether UIKit vetoes the swipe. A vetoed recognizer goes
/// straight to `.failed` and never notifies its targets, so silence from our pan target cannot
/// tell "UIKit said no" apart from "the recognizer never saw the touch" — and the two have
/// nothing in common as fixes.
///
/// Replacing that delegate has been tried twice and broke the pop both times: the object sitting
/// there is `_UINavigationInteractiveTransitionBase`, the only thing that consults
/// `UINavigationControllerDelegate` on a gesture pop and the only thing that arms it. So this
/// forwards *everything* to it — including the `shouldBegin` call itself, whose answer it merely
/// reads on the way past. Compiled out of Release.
final class CoverZoomPanDelegateSpy: NSObject, UIGestureRecognizerDelegate {
    /// Launch with `VELLUM_DEBUG_PAN_SPY=1` to install. See `syncGestures` for why it is off.
    static let isEnabled = ProcessInfo.processInfo.environment["VELLUM_DEBUG_PAN_SPY"] != nil

    private let original: UIGestureRecognizerDelegate
    private static var associationKey: UInt8 = 0

    private init(original: UIGestureRecognizerDelegate) {
        self.original = original
    }

    /// Installs on `recognizer` once. No-op when there is nothing to forward to, or when the
    /// delegate in place is already one of ours.
    @MainActor
    static func installIfNeeded(on recognizer: UIGestureRecognizer) {
        guard let current = recognizer.delegate, !(current is CoverZoomPanDelegateSpy) else { return }
        let spy = CoverZoomPanDelegateSpy(original: current)
        // The recognizer holds `delegate` weakly; keep the proxy alive alongside it.
        objc_setAssociatedObject(recognizer, &associationKey, spy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        recognizer.delegate = spy
    }

    nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated {
            let answer = original.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
            let pan = gestureRecognizer as? UIPanGestureRecognizer
            let translation = pan.map { $0.translation(in: $0.view) } ?? .zero
            DebugUIRemote.log("COVERZOOM shouldBegin \(type(of: gestureRecognizer)) "
                + "answer=\(answer) state=\(gestureRecognizer.state.rawValue) "
                + "touches=\(gestureRecognizer.numberOfTouches) "
                + "dx=\(String(format: "%.1f", translation.x)) dy=\(String(format: "%.1f", translation.y))")
            return answer
        }
    }

    /// The gate that turned out to matter. Device log, three real edge swipes on the build that
    /// added `edgeSample`: both pop recognizers sat at `st=0 n=0` for 420ms with the finger down
    /// and `shouldBegin` was never called — UIKit refused to *deliver* the touch, which happens
    /// here, one step before `shouldBegin`.
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            let answer = original.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) ?? true
            let point = touch.location(in: gestureRecognizer.view)
            if point.x < 60 {
                DebugUIRemote.log("COVERZOOM shouldReceiveTouch \(type(of: gestureRecognizer)) answer=\(answer) "
                    + "x=\(String(format: "%.1f", point.x)) "
                    + "delegateResponds=\(original.responds(to: Self.shouldReceiveTouchSelector))")
            }
            return answer
        }
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        MainActor.assumeIsolated {
            let answer = original.gestureRecognizer?(gestureRecognizer, shouldReceive: event) ?? true
            if !answer {
                DebugUIRemote.log("COVERZOOM shouldReceiveEvent \(type(of: gestureRecognizer)) answer=false")
            }
            return answer
        }
    }

    // `#selector` cannot disambiguate the two `shouldReceive:` overloads; name them directly.
    private static let shouldReceiveTouchSelector = NSSelectorFromString("gestureRecognizer:shouldReceiveTouch:")
    private static let shouldReceiveEventSelector = NSSelectorFromString("gestureRecognizer:shouldReceiveEvent:")

    // Everything else is UIKit's business.
    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(UIGestureRecognizerDelegate.gestureRecognizerShouldBegin(_:)) { return true }
        if aSelector == Self.shouldReceiveTouchSelector { return true }
        if aSelector == Self.shouldReceiveEventSelector { return true }
        if super.responds(to: aSelector) { return true }
        return original.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}
#endif

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

// MARK: - Non-animated push fix

/// Forces `animated: true` on a push that is about to open a `.custom` cover.
///
/// **Why this is not optional.** UIKit asks `animationControllerFor:` only for an *animated*
/// push; a `pushViewController(_:animated: false)` runs with no animator, no transition
/// coordinator, and no delegate call of any kind. On the Home tab SwiftUI pushes exactly that
/// way, every time, and it is the whole reason the cover zoom never appeared there. Measured on
/// device across one run, same build, same code:
///
///     COVERZOOM willShow animated=true  nav=49467 depth=2   ← Library  → ask op=1 → run push=true
///     COVERZOOM willShow animated=true  nav=6864  depth=2   ← Search   → ask op=1 → run push=true
///     COVERZOOM willShow animated=false nav=16064 depth=2   ← Home     → nothing, ever
///
/// Two stock-SwiftUI shapes were tried on Home first and both still measured `animated=false`:
/// a destination-closure `NavigationLink`, and the New tab's `Button` +
/// `navigationDestination(item:)` (which animates correctly on the New tab itself). So this is
/// not a call-site style that can be written differently — SwiftUI decides, and on that stack it
/// decides not to animate.
///
/// **Scope.** The swizzle is global but the *behaviour change* is not: it fires only when the
/// navigation controller carries our proxy **and** `pendingPushID` names a `.custom` cover —
/// which is written only by the touch spy hit-testing a registered cover row, and cleared as
/// soon as a push consumes it. Every other push in the app keeps the flag it was given. And the
/// change it makes is to animate a push, which is the ordinary case everywhere else.
@MainActor
enum CoverZoomPushAnimationFix {
    private static var installed = false

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        guard let original = class_getInstanceMethod(
                UINavigationController.self,
                #selector(UINavigationController.pushViewController(_:animated:))),
              let replacement = class_getInstanceMethod(
                UINavigationController.self,
                #selector(UINavigationController.coverZoomForcedAnimatedPush(_:animated:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }
}

extension UINavigationController {
    /// Swapped with `pushViewController(_:animated:)` by ``CoverZoomPushAnimationFix``, so the
    /// recursive-looking call at the end is the original implementation.
    @objc fileprivate func coverZoomForcedAnimatedPush(_ viewController: UIViewController, animated: Bool) {
        var animated = animated
        MainActor.assumeIsolated {
            guard !animated,
                  CoverZoomNavigationDelegate.isInstalled(on: self),
                  let id = CoverZoomRegistry.shared.pendingPushID,
                  CoverZoomRegistry.shared.style(for: id) == .custom
            else { return }
            animated = true
#if DEBUG
            DebugUIRemote.log("COVERZOOM forced animated push id=\(id) "
                + "nav=\(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xffff)")
#endif
        }
        coverZoomForcedAnimatedPush(viewController, animated: animated)
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
    /// The finger-driven interaction for our own edge swipe; nil outside one.
    private var dragInteraction: CoverZoomDragInteraction?
    /// Where the swipe's finger was when it began, in the navigation view's coordinates. Read
    /// by `interactionControllerFor`, which runs synchronously inside `popViewController`.
    private var edgePanStart: CGPoint = .zero
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
    /// Our own edge swipe. See `installEdgePan`.
    private var edgePan: UIScreenEdgePanGestureRecognizer?
    /// True from the moment `handleEdgePan` raises a pop until that pop's gesture ends, so the
    /// delegate knows the interaction controller it is vending has a driver.
    private var edgePanPopInFlight = false
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
    /// Whether this navigation controller is one of ours. Read by the push-animation fix, which
    /// must not touch any other stack.
    static func isInstalled(on navigationController: UINavigationController) -> Bool {
        objc_getAssociatedObject(navigationController, &associationKey) is CoverZoomNavigationDelegate
    }

    static func installIfNeeded(on navigationController: UINavigationController) -> CoverZoomNavigationDelegate {
        CoverZoomPushAnimationFix.installIfNeeded()
        let existing = objc_getAssociatedObject(navigationController, &associationKey) as? CoverZoomNavigationDelegate
        let proxy = existing ?? CoverZoomNavigationDelegate(navigationController: navigationController)
        if existing == nil {
            objc_setAssociatedObject(
                navigationController,
                &associationKey,
                proxy,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
#if DEBUG
            // Once per navigation controller — i.e. once per tab that has a `.custom` cover on
            // it. Compare `nav=` here with the same field on `COVERZOOM ask` / `installer
            // willAppear`: if a tab's pushes report a navigation controller that never appears
            // in one of these lines, the cells installed on the wrong object.
            DebugUIRemote.log("COVERZOOM proxy installed "
                + "nav=\(UInt(bitPattern: ObjectIdentifier(navigationController).hashValue) & 0xffff) "
                + "wasDelegate=\(navigationController.delegate.map { String(describing: type(of: $0)) } ?? "nil") "
                + "root=\(navigationController.viewControllers.first.map { String(describing: type(of: $0)) } ?? "nil") "
                + "depth=\(navigationController.viewControllers.count)")
#endif
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

    /// Keeps UIKit's own pop gesture observed, and **switched off while our detail is on top**.
    ///
    /// Why it is off: the built-in edge gesture does not drive custom animators. That is
    /// UIKit's design, not a bug — once the navigation delegate answers `animationControllerFor`
    /// with its own object for a pop, the built-in recognizer is not used for that pop, and it
    /// declines the touch *without consulting anyone* (device log: both recognizers at
    /// `st=0 n=0` for 420ms with the finger down, and neither `shouldReceiveTouch` nor
    /// `shouldBegin` ever called, with UIKit's pristine delegate in place). The contract is the
    /// one from the original custom-transitions session: custom animator ⇒ supply your own
    /// gesture and drive the interaction controller yourself. That is `installEdgePan`.
    ///
    /// It stays observed anyway, so that `wantsInteractiveStart` and the touch-down settling
    /// logic keep working on the screens where it *is* in charge (the playlists list).
    private func syncGestures() {
        guard let navigationController else { return }
        guard let systemPan = navigationController.interactivePopGestureRecognizer else { return }
        // Off only while the custom-zoomed detail is on top; an ordinary slide screen keeps it.
        let customOnTop = customDetailController != nil
            && navigationController.topViewController === customDetailController
        systemPan.isEnabled = !customOnTop

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
        // Every built-in pop recognizer follows the same on/off rule as `interactivePopGestureRecognizer`.
        for recognizer in observedPans where recognizer.isEnabled == customOnTop {
            recognizer.isEnabled = !customOnTop
        }
        installEdgePan(on: navigationController)
#if DEBUG
        // Off by default. With the spy in front of UIKit's delegate, device logs showed the pop
        // recognizers refusing every edge touch *without consulting the delegate protocol at all*
        // — no `shouldReceiveTouch`, no `shouldBegin`, `n=0` for 420ms. That is the signature of
        // the recognizer testing its delegate's identity or class privately, which a proxy fails.
        // Every measured failing swipe had the spy installed, so the pristine delegate plus the
        // always-non-nil interaction controller has to be measured on its own first.
        if CoverZoomPanDelegateSpy.isEnabled {
            candidates.forEach(CoverZoomPanDelegateSpy.installIfNeeded(on:))
        }
#endif
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

    // MARK: Edge swipe

    /// Our own left-edge pan, which starts and drives the interactive pop for custom-zoomed
    /// details. The built-in gesture will not do this for a custom animator — see `syncGestures`.
    ///
    /// An earlier version of this idea was abandoned because `popViewController` from our own
    /// recognizer "desynced `NavigationLink`" — tapping the same playlist again did nothing. The
    /// back button is *also* a UIKit-initiated `popViewController`, and it has always kept
    /// SwiftUI in sync through `navigationController(_:didShow:)`, which this proxy forwards. So
    /// the pop itself cannot have been the cause; a transition that never reached
    /// `completeTransition` (so `didShow` never fired) was. Every exit from the animator now
    /// completes the transition, and every exit from this gesture finishes or cancels the
    /// interaction controller.
    private func installEdgePan(on navigationController: UINavigationController) {
        guard edgePan == nil else { return }
        let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        pan.edges = .left
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        navigationController.view.addGestureRecognizer(pan)
        edgePan = pan
    }

    /// True only when a swipe-back would be ours to animate: our detail is on top, with
    /// something under it, and nothing else is mid-transition.
    private var edgePanMayBegin: Bool {
        guard let navigationController, let detail = customDetailController else { return false }
        guard navigationController.viewControllers.count > 1,
              navigationController.topViewController === detail,
              navigationController.transitionCoordinator == nil else { return false }
        guard let id = activeCustomID ?? lastPushedCustomID,
              CoverZoomRegistry.shared.style(for: id) == .custom else { return false }
        return true
    }

    @objc private func handleEdgePan(_ pan: UIScreenEdgePanGestureRecognizer) {
        guard let navigationController, let view = navigationController.view else { return }
        let width = max(view.bounds.width, 1)
        let translation = pan.translation(in: view).x
        let fraction = max(0, min(1, translation / width))
        let velocity = pan.velocity(in: view).x

#if DEBUG
        if pan.state != .changed || Int(fraction * 20) % 4 == 0 {
            DebugUIRemote.log("COVERZOOM edgePan state=\(pan.state.rawValue) "
                + "frac=\(String(format: "%.2f", fraction)) v=\(String(format: "%.0f", velocity)) "
                + "inFlight=\(edgePanPopInFlight) interaction=\(interactionController != nil) "
                + "pct=\(String(format: "%.2f", interactionController?.percentComplete ?? -1)) "
                + "coordinator=\(navigationController.transitionCoordinator != nil) "
                + "interactiveCoordinator=\(navigationController.transitionCoordinator?.isInteractive ?? false)")
        }
#endif

        switch pan.state {
        case .began:
            guard edgePanMayBegin else {
#if DEBUG
                DebugUIRemote.log("COVERZOOM edgePan began but may not pop — depth=\(navigationController.viewControllers.count) "
                    + "topIsDetail=\(navigationController.topViewController === customDetailController) "
                    + "coordinator=\(navigationController.transitionCoordinator != nil)")
#endif
                return
            }
            // Anything still settling is finished first — a pop cannot start over a live
            // transition, and UIKit would silently drop the request.
            if let running = runningAnimator, running.isRunning {
                running.completeImmediately()
                runningAnimator = nil
            }
            if navigationController.delegate !== self {
                navigationController.delegate = self
            }
            // Raising the flag first: `popViewController` asks for the animator and the
            // interaction controller synchronously, and `interactionControllerFor` reads it.
            edgePanPopInFlight = true
            // `.began` fires once the pan has cleared its threshold; the finger's true origin is
            // the current location minus what it has already travelled.
            let location = pan.location(in: view)
            edgePanStart = CGPoint(x: location.x - translation, y: location.y - pan.translation(in: view).y)
            navigationController.popViewController(animated: true)
            if dragInteraction == nil {
#if DEBUG
                DebugUIRemote.log("COVERZOOM edgePan popped but no interaction controller was vended")
#endif
                edgePanPopInFlight = false
            } else {
                dragInteraction?.update(finger: location)
            }
        case .changed:
            guard edgePanPopInFlight, let drag = dragInteraction else { return }
            drag.update(finger: pan.location(in: view))
        case .ended:
            guard edgePanPopInFlight else { return }
            defer { edgePanPopInFlight = false; dragInteraction = nil }
            guard let drag = dragInteraction else { return }
            let commits = fraction > CoverZoomTuning.popCommitFraction
                || velocity > CoverZoomTuning.popCommitVelocity
            if commits {
                drag.commit()
            } else {
                drag.cancel()
            }
        case .cancelled, .failed:
            guard edgePanPopInFlight else { return }
            defer { edgePanPopInFlight = false; dragInteraction = nil }
            dragInteraction?.cancel()
        default:
            break
        }
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
            + "nav=\(UInt(bitPattern: ObjectIdentifier(navigationController).hashValue) & 0xffff) "
            + "navDelegate=\(navigationController.delegate.map { String(describing: type(of: $0)) } ?? "nil") "
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

        // A dismiss still in flight is the other half of the same problem, and the one that
        // actually wedges the stack: a tap on the list during a close raises a *push* while the
        // pop's transition is still live, so two transitions are stacked and the pop that should
        // follow is never even requested — the back button is visible and nothing reaches
        // `animationControllerFor` at all. Device log:
        //
        //   touchDown x=125 y=208  coordinator=true depth=1   ← tap landed inside the close
        //   PHASE didDisappear popped=true
        //   ask op=1 → run push=true                          ← push started inside the pop
        //   touchDown x=109 y=203  coordinator=true depth=2   ← and another inside that
        //
        // Settling the dismiss *here* fixes it without deafening the list: touches are delivered
        // before the tap's action fires, so by the time SwiftUI activates the link the stack has
        // already settled and the push is an ordinary one. Skipped while a pop gesture is
        // genuinely being dragged — that transition has a driver and must not be cut short.
        let panDragging = edgePanPopInFlight
            || observedPans.contains { $0.state == .began || $0.state == .changed }
        var settledTransition = false
        if !panDragging, let running = runningAnimator, running.isRunning, running.direction == .pop {
#if DEBUG
            DebugUIRemote.log("COVERZOOM touch during dismiss — settling it now")
#endif
            running.completeImmediately()
            runningAnimator = nil
            settledTransition = true
        }

        if let running = runningPushAnimator, running.isRunning {
#if DEBUG
            DebugUIRemote.log("COVERZOOM touch during push — completing it now")
#endif
            running.completeImmediately()
            runningPushAnimator = nil
            settledTransition = true
        }

        if settledTransition {
            // Settling frees the stack, but this touch's own button action has already been
            // rejected by UIKit — which is why the first back tap did nothing and a second was
            // needed. If the touch was on the back button and nothing popped by the next runloop
            // turn, perform the pop ourselves.
            if isBackButtonRegion(point, in: view) {
                let depthBefore = navigationController.viewControllers.count
                Task { @MainActor [weak self, weak navigationController] in
                    guard let self, let navigationController else { return }
                    guard navigationController.viewControllers.count == depthBefore,
                          depthBefore > 1,
                          navigationController.transitionCoordinator == nil,
                          navigationController.topViewController === self.customDetailController
                    else { return }
#if DEBUG
                    DebugUIRemote.log("COVERZOOM back tap was swallowed by the transition — popping")
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
            // Walk the whole chain the touch actually travels — from the hit-test view up to the
            // window — rather than the two views we happened to guess at. A recognizer deeper in
            // the SwiftUI content that claims the touch would only ever show up here.
            var lines: [String] = []
            var node: UIView? = navigationController.view.hitTest(point, with: nil)
            while let current = node {
                let owned = (current.gestureRecognizers ?? []).map {
                    "\(type(of: $0))/en=\($0.isEnabled)/st=\($0.state.rawValue)"
                }
                if !owned.isEmpty {
                    lines.append("\(type(of: current)){\(owned.joined(separator: "|"))}")
                }
                node = current.superview
            }
            // Everything `_UINavigationInteractiveTransition`'s receive-touch gate is known to
            // consult, so a refusal can be matched to its cause in one read.
            let top = navigationController.topViewController
            let item = top?.navigationItem
            let navState = "barHidden=\(navigationController.isNavigationBarHidden) "
                + "hidesBack=\(item?.hidesBackButton ?? false) "
                + "leftItems=\(item?.leftBarButtonItems?.count ?? 0) "
                + "leftSupplement=\(item?.leftItemsSupplementBackButton ?? false) "
                + "leadingGroups=\(item?.leadingItemGroups.count ?? 0) "
                + "backMode=\(item?.backButtonDisplayMode.rawValue ?? -1) "
                + "backItem=\(item?.backBarButtonItem == nil ? "nil" : "set") "
                + "coordinator=\(navigationController.transitionCoordinator != nil) "
                + "modal=\(top?.presentedViewController == nil ? "nil" : "set") "
                + "panDelegate=\(pan?.delegate.map { String(describing: type(of: $0)) } ?? "nil") "
                + "topModalInPresentation=\(top?.isModalInPresentation ?? false)"
            DebugUIRemote.log("COVERZOOM edgeTouch x=\(String(format: "%.1f", point.x)) "
                + "y=\(String(format: "%.0f", point.y)) depth=\(navigationController.viewControllers.count) "
                + "panEnabled=\(pan?.isEnabled ?? false) panState=\(pan?.state.rawValue ?? -1) "
                + "panView=\(pan?.view.map { String(describing: type(of: $0)) } ?? "nil") "
                + navState + " "
                + "recognizers=[\(lines.joined(separator: ", "))]")

            // The one question 4.1 still turns on: does either pop recognizer ever leave
            // `.possible`? A vetoed recognizer goes straight to `.failed` and never notifies its
            // targets, so silence from `handleSystemPan` cannot distinguish "vetoed" from "never
            // saw the touch". Sampling the states a few frames into the swipe can.
            let observed = observedPans
            Task { @MainActor in
                for delay in [120, 260, 420] {
                    try? await Task.sleep(for: .milliseconds(delay == 120 ? 120 : 140))
                    let states = observed.map { "\(type(of: $0))/st=\($0.state.rawValue)/n=\($0.numberOfTouches)" }
                    DebugUIRemote.log("COVERZOOM edgeSample +\(delay)ms [\(states.joined(separator: ", "))]")
                }
            }
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
            // A controller vended for a pop that has already finished is not ours to scrub —
            // `wantsInteractiveStart == false` pops leave one behind until the next ask.
            guard navigationController?.transitionCoordinator != nil else { return }
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
        MainActor.assumeIsolated {
            if gestureRecognizer === edgePan {
                let allowed = edgePanMayBegin
#if DEBUG
                DebugUIRemote.log("COVERZOOM edgePan shouldBegin=\(allowed)")
#endif
                return allowed
            }
            return true
        }
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

    /// The detail's track list is a scroll view whose pan would otherwise race our edge pan
    /// for the same touch. Make every other recognizer wait for the edge pan to fail — which it
    /// does immediately for any touch that did not start at the edge, so scrolling is not
    /// delayed anywhere else.
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        MainActor.assumeIsolated {
            gestureRecognizer === edgePan && other !== touchObserver
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
               CoverZoomRegistry.shared.style(for: id) == .custom,
               // Nothing to fly home to at all — see `hasCellTarget`. Declining hands the pop
               // to SwiftUI's slide, which is the right answer and, unlike the cross-fade
               // fallback, cannot strand the stack. This should now be rare: a cover that was
               // pushed from is remembered, so the usual "the row was released while the
               // detail covered it" case still animates.
               CoverZoomRegistry.shared.hasCellTarget(for: id) {
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

    /// Diagnostic only, and the one callback UIKit makes for **every** push and pop —
    /// animated or not, delegate-driven or not. `animationControllerFor` is skipped entirely
    /// for a non-animated push, so its absence cannot distinguish "UIKit never asked us" from
    /// "UIKit never asked anyone"; this line can, because `animated:` is UIKit's own flag for
    /// the transition it is about to run.
    ///
    /// Forwarded by hand: implementing the selector takes it out of `forwardingTarget(for:)`'s
    /// reach, and SwiftUI's coordinator relies on these callbacks to keep its path in sync.
    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
#if DEBUG
        DebugUIRemote.log("COVERZOOM willShow animated=\(animated) "
            + "nav=\(UInt(bitPattern: ObjectIdentifier(navigationController).hashValue) & 0xffff) "
            + "depth=\(navigationController.viewControllers.count) "
            + "coordinator=\(navigationController.transitionCoordinator != nil) "
            + "isUs=\(navigationController.delegate === self) "
            + "vcPreferredTransition=\(viewController.preferredTransition == nil ? "nil" : "set") "
            + "pending=\(CoverZoomRegistry.shared.pendingPushID ?? "nil")")
#endif
        if let original,
           original.responds(to: #selector(UINavigationControllerDelegate.navigationController(_:willShow:animated:))) {
            original.navigationController?(navigationController, willShow: viewController, animated: animated)
        }
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
#if DEBUG
        DebugUIRemote.log("COVERZOOM didShow animated=\(animated) "
            + "nav=\(UInt(bitPattern: ObjectIdentifier(navigationController).hashValue) & 0xffff) "
            + "depth=\(navigationController.viewControllers.count)")
#endif
        if let original,
           original.responds(to: #selector(UINavigationControllerDelegate.navigationController(_:didShow:animated:))) {
            original.navigationController?(navigationController, didShow: viewController, animated: animated)
        }
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
            + "anyPanTouches=\(observedPans.map { $0.numberOfTouches }.max() ?? -1) "
            + "observed=\(observedPans.count) "
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
            // `wantsInteractiveStart` is the part that *can* be decided here, and it is the
            // difference between the two kinds of pop:
            //
            //  - Edge swipe: UIKit asks from `gestureRecognizerShouldBegin:` with the finger
            //    down, so a pop recognizer is holding touches. The transition starts paused at
            //    0% and UIKit scrubs it with the gesture.
            //  - Back button: the pop is raised on touch *up* — device log shows `panTouches=0`
            //    at exactly this moment. Starting paused there stalled every single back-button
            //    pop for the length of `scheduleInteractionWatchdog`, which the log confirms
            //    fired on all of them ("nothing drove it, finishing"). Starting non-interactive
            //    runs it straight through, and a gesture can still take it over later.
            //
            // Translation is deliberately not consulted: at `shouldBegin` time it is zero, and
            // testing for it is what used to make this return `nil` — which UIKit reads as "no
            // interactive pop available" and answers by vetoing the gesture outright.
            // Our own edge swipe: a finger-driven interaction, not a percent-driven one. The
            // page follows the finger while it is down and only flies home on release.
            if edgePanPopInFlight {
                let drag = CoverZoomDragInteraction(animator: animator, start: edgePanStart)
                dragInteraction = drag
                interactionController = nil
                isDrivingInteractionManually = false
                return drag
            }
            let fingerDown = observedPans.contains { $0.numberOfTouches > 0 }
            controller.wantsInteractiveStart = fingerDown
            interactionController = controller
            isDrivingInteractionManually = false
            if fingerDown { scheduleInteractionWatchdog(for: controller) }
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
            let panIsLive = self.edgePanPopInFlight
                || self.observedPans.contains { $0.state == .began || $0.state == .changed || $0.numberOfTouches > 0 }
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
#if DEBUG
            // The push's own post-mortem. On Home / Search / New the device log showed the
            // detail arriving with no `COVERZOOM ask op=1` line at all, which leaves exactly
            // three explanations, and this line separates them in one read:
            //
            //   navDelegate != CoverZoomNavigationDelegate  → SwiftUI held the property when
            //       UIKit asked, so the question never reached us.
            //   preferredTransition = set                   → UIKit used the controller's own
            //       transition and skips the delegate entirely.
            //   animated=false                              → there was no transition to ask
            //       an animator for.
            //
            // `nav` is logged so it can be compared with the id in `COVERZOOM ask` /
            // `COVERZOOM syncGestures`: a mismatch means the push ran on a navigation
            // controller the cells never installed on.
            let debugNav = parent?.navigationController ?? navigationController
            DebugUIRemote.log("COVERZOOM installer willAppear id=\(id) animated=\(animated) "
                + "nav=\(debugNav.map { UInt(bitPattern: ObjectIdentifier($0).hashValue) & 0xffff } ?? 0) "
                + "navDelegate=\(debugNav?.delegate.map { String(describing: type(of: $0)) } ?? "nil") "
                + "parentPreferredTransition=\(parent?.preferredTransition == nil ? "nil" : "set") "
                + "selfPreferredTransition=\(preferredTransition == nil ? "nil" : "set") "
                + "topPreferredTransition=\(debugNav?.topViewController?.preferredTransition == nil ? "nil" : "set") "
                + "parent=\(parent.map { String(describing: type(of: $0)) } ?? "nil") "
                + "depth=\(debugNav?.viewControllers.count ?? -1) "
                + "coordinator=\(debugNav?.transitionCoordinator != nil) "
                + "style=\(CoverZoomRegistry.shared.style(for: id) == .custom ? "custom" : "system") "
                + "pending=\(CoverZoomRegistry.shared.pendingPushID ?? "nil")")
#endif
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
