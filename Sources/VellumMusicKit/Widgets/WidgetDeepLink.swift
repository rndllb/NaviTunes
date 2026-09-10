import Foundation

/// What a `vellum://` deep link resolves to, before anything is looked up or presented.
///
/// Pulled out of ``AppModel/handleWidgetDeepLink(_:)`` so the routing decision can be tested
/// without standing up an `AppModel` — which starts timers, network work and keychain access on
/// init. The handler stays responsible for *doing* the thing; this decides *what* the thing is.
enum WidgetDeepLinkRoute: Equatable {
    /// The app is already showing what the link asks for. Do nothing at all — not a re-present,
    /// not a tab change, nothing observable.
    case ignore
    /// Raise the full-screen Now Playing cover.
    case openNowPlaying
    /// Open this album's detail, falling back to Home if it isn't in the catalog.
    case album(id: String)
    /// Land on Home.
    case home
}

enum WidgetDeepLink {
    /// Resolves a widget/Live Activity URL against what is currently on screen.
    ///
    /// **The already-open guard lives here rather than in a view on purpose.** Three surfaces
    /// send `vellum://nowplaying` — the home-screen widget, the Lock Screen families, and the
    /// Live Activity on the Dynamic Island — and more can be added. Guarding in the view that
    /// happens to present the cover would mean each new sender re-inherits the question of
    /// whether it is safe to ask twice. Guarding on the way in covers all of them once.
    ///
    /// `ignore` is deliberately total: no tab change either. The cover is over the whole
    /// interface, so reassigning `selectedTab` beneath it would silently change what the user
    /// finds when they dismiss — a visible side effect of a tap that was supposed to do nothing.
    static func route(for url: URL, isNowPlayingPresented: Bool) -> WidgetDeepLinkRoute {
        guard url.scheme == "vellum" else { return .ignore }
        let host = url.host ?? ""
        let itemId = url.pathComponents.dropFirst().first ?? ""

        switch host {
        case "nowplaying":
            // Already open: the tap has nothing to ask for. Re-presenting risks a second copy or
            // a dismiss-and-reopen flash, and `NowPlayingCoverZoomTransition` drives a UIKit
            // transition that has no reason to be re-entered while it is already showing.
            return isNowPlayingPresented ? .ignore : .openNowPlaying
        case "album" where !itemId.isEmpty:
            return .album(id: itemId)
        case "track" where !itemId.isEmpty:
            return .home
        default:
            return .home
        }
    }
}
