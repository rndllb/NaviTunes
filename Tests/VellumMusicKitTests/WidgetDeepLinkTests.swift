import Foundation
import Testing

@testable import VellumMusicKit

/// Routing for `vellum://` links from the widget, the Lock Screen families and the Live Activity.
///
/// The already-open guard is the reason this is a separate type: three surfaces send
/// `vellum://nowplaying`, so the question "is it safe to ask twice" has to be answered on the way
/// in rather than by each presenter.
@Suite("WidgetDeepLink routing")
struct WidgetDeepLinkTests {
    private static func route(_ string: String, presented: Bool) -> WidgetDeepLinkRoute {
        WidgetDeepLink.route(for: URL(string: string)!, isNowPlayingPresented: presented)
    }

    // MARK: - The guard (c9)

    @Test("a now-playing link is ignored while the player is already open")
    func ignoredWhenPresented() {
        #expect(Self.route("vellum://nowplaying", presented: true) == .ignore)
    }

    /// Every surface that sends this URL, routed through the same call.
    @Test(
        "the guard covers every sender of the now-playing link",
        arguments: [
            "vellum://nowplaying",      // home-screen + Lock Screen widget families
            "vellum://nowplaying/",     // trailing slash
        ],
    )
    func guardCoversEverySender(link: String) {
        #expect(Self.route(link, presented: true) == .ignore)
        #expect(Self.route(link, presented: false) == .openNowPlaying)
    }

    /// `ignore` has to be total. Falling through to a tab change would silently alter what the
    /// user finds underneath when they dismiss the cover — a visible effect from a tap that was
    /// supposed to do nothing.
    @Test("ignoring is total — it is not a disguised home route")
    func ignoreIsNotHome() {
        let ignored = Self.route("vellum://nowplaying", presented: true)
        #expect(ignored != .home)
        #expect(ignored != .openNowPlaying)
        #expect(ignored == .ignore)
    }

    // MARK: - The branch that must keep working (c10)

    @Test("a now-playing link still opens the player when it is not already open")
    func opensWhenNotPresented() {
        #expect(Self.route("vellum://nowplaying", presented: false) == .openNowPlaying)
    }

    /// Repeated taps while closed each resolve to open — the guard keys on what is on screen,
    /// not on having seen the URL before.
    @Test("the guard is stateless across taps")
    func statelessAcrossTaps() {
        #expect(Self.route("vellum://nowplaying", presented: false) == .openNowPlaying)
        #expect(Self.route("vellum://nowplaying", presented: false) == .openNowPlaying)
    }

    // MARK: - Everything else must be unchanged

    /// The guard is specific to the now-playing link. An album tap while the player is open is
    /// still a real request — it targets a different screen.
    @Test("album links are unaffected by the player being open")
    func albumUnaffected() {
        #expect(Self.route("vellum://album/abc123", presented: true) == .album(id: "abc123"))
        #expect(Self.route("vellum://album/abc123", presented: false) == .album(id: "abc123"))
    }

    @Test(
        "the remaining routes are unchanged",
        arguments: [
            ("vellum://home", WidgetDeepLinkRoute.home),
            ("vellum://track/xyz", .home),
            ("vellum://album", .home),          // no id
            ("vellum://unknown", .home),
        ],
    )
    func otherRoutes(link: String, expected: WidgetDeepLinkRoute) {
        #expect(Self.route(link, presented: false) == expected)
    }

    /// A URL from somewhere else is not ours to act on.
    @Test("a foreign scheme is ignored", arguments: ["https://example.com/nowplaying", "music://nowplaying"])
    func foreignScheme(link: String) {
        #expect(Self.route(link, presented: false) == .ignore)
    }
}
