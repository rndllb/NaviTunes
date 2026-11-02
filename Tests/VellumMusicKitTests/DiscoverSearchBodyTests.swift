import Testing

@testable import VellumMusicKit

/// #8: Discover search no longer opens on a category (genre tile) list; with no query it shows
/// what you searched recently, whether or not the field is focused.
@Suite("Discover search body (#8)")
struct DiscoverSearchBodyTests {
    @Test("no query, field not focused: recently searched, not categories")
    func idleShowsRecent() {
        #expect(DiscoverSearchBody.state(sessionActive: false, query: "") == .recentlySearched)
        #expect(DiscoverSearchBody.state(sessionActive: false, query: "   ") == .recentlySearched)
    }

    @Test("no query, field focused: recently searched")
    func focusedShowsRecent() {
        #expect(DiscoverSearchBody.state(sessionActive: true, query: "") == .recentlySearched)
    }

    @Test("a query shows results, focused or not")
    func queryShowsResults() {
        #expect(DiscoverSearchBody.state(sessionActive: true, query: "interpol") == .results)
        #expect(DiscoverSearchBody.state(sessionActive: false, query: "interpol") == .results)
    }
}
