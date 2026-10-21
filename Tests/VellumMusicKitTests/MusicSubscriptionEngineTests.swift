import Foundation
import Testing

@testable import VellumMusicKit

/// #18 Following: the follow-artist completeness engine, driven through its injected
/// environment with an in-memory store, so nothing touches a server or the app's own file.
@Suite("Following (#18)")
@MainActor
struct MusicSubscriptionEngineTests {
    /// A fake world: what the plugin says the artist released, what the server has, and every
    /// request the engine makes.
    @MainActor
    final class World {
        var releases: [String: [AcquisitionRelease]] = [:]
        var serverAlbums: [String: [AlbumSummary]] = [:]
        var configured = true
        var granularity: AcquisitionCapabilities.Granularity = .album
        var enqueued: [AcquisitionRequest] = []
        var releaseLookups: [String] = []
        var saved: [FollowedArtist] = []

        func environment() -> MusicSubscriptionEngine.Environment {
            .init(
                serverAlbumsForArtist: { [unowned self] name in self.serverAlbums[name] ?? [] },
                enqueue: { [unowned self] request in
                    self.enqueued.append(request)
                    return .started
                },
                isAcquisitionConfigured: { [unowned self] in self.configured },
                acquisitionGranularity: { [unowned self] in self.granularity },
                artistReleases: { [unowned self] name in
                    self.releaseLookups.append(name)
                    return self.releases[name] ?? []
                }
            )
        }

        func persistence() -> MusicSubscriptionPersistence {
            MusicSubscriptionPersistence(
                load: { [unowned self] in self.saved },
                save: { [unowned self] in self.saved = $0 }
            )
        }

        func engine() -> MusicSubscriptionEngine {
            MusicSubscriptionEngine(env: environment(), persistence: persistence())
        }
    }

    static func release(_ title: String, artist: String, type: String = "Album", tracks: Int = 10, year: Int = 2020) -> AcquisitionRelease {
        AcquisitionRelease(
            id: "rg-\(title)",
            title: title,
            artist: artist,
            releaseDate: Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 1, day: 1)),
            artworkURL: nil,
            albumType: type,
            secondaryTypes: [],
            trackCount: tracks,
            releaseGroupMBID: "rg-\(title)",
            artistMBID: "mbid-\(artist)",
            nativeAlbumId: nil,
            overview: nil,
            artistOverview: nil,
            artistArtworkURL: nil,
            monitored: false,
            wanted: false
        )
    }

    static func album(_ title: String, artist: String) -> AlbumSummary {
        AlbumSummary(id: "srv-\(title)", title: title, artist: artist, artworkURL: nil)
    }

    // MARK: Identity

    @Test("following by name and then seeing the artist's MBID is still the same follow, never a second one")
    func mbidArrivingLateIsTheSameArtist() async {
        let world = World()
        let engine = world.engine()
        await engine.follow(name: "Interpol")?.value
        // The artist page learns the MBID once the plugin answers.
        #expect(engine.isFollowing(name: "Interpol", mbid: "mbid-interpol"))
        await engine.follow(name: "Interpol", mbid: "mbid-interpol")?.value
        #expect(engine.followed.count == 1)
        #expect(engine.followed.first?.artistMBID == "mbid-interpol")
        // And unfollowing from the page that knows the MBID removes it.
        engine.toggle(name: "Interpol", mbid: "mbid-interpol")
        #expect(engine.followed.isEmpty)
        #expect(world.saved.isEmpty)
    }

    @Test("two different artists who share a name stay two follows when their MBIDs differ")
    func sameNameDifferentArtists() async {
        let world = World()
        let engine = world.engine()
        await engine.follow(name: "Nirvana", mbid: "mbid-us")?.value
        await engine.follow(name: "Nirvana", mbid: "mbid-uk")?.value
        #expect(engine.followed.count == 2)
        #expect(engine.isFollowing(name: "Nirvana", mbid: "mbid-uk"))
        #expect(!engine.isFollowing(name: "Nirvana", mbid: "mbid-other"))
    }

    // MARK: The completeness pass

    @Test("missing albums are requested once; owned ones are In Library; short EPs and live records are left alone")
    func requestsWhatIsMissingOnce() async {
        let world = World()
        world.releases["Interpol"] = [
            Self.release("Turn on the Bright Lights", artist: "Interpol", year: 2002),
            Self.release("Antics", artist: "Interpol", year: 2004),
            Self.release("Fukd ID #3", artist: "Interpol", type: "EP", tracks: 2, year: 2003),
            Self.release("Live in Astoria", artist: "Interpol", type: "Live", year: 2005),
        ]
        world.serverAlbums["Interpol"] = [Self.album("Turn On The Bright Lights", artist: "Interpol")]
        let engine = world.engine()
        await engine.follow(name: "Interpol")?.value

        let id = engine.followed[0].id
        let states = Dictionary(uniqueKeysWithValues: (engine.statusByArtist[id] ?? []).map { ($0.title, $0.state) })
        #expect(states["Turn on the Bright Lights"] == .have)
        #expect(states["Antics"] == .requested)
        #expect(states["Fukd ID #3"] == nil)
        #expect(world.enqueued.map(\.albumTitle) == ["Antics"])
        #expect(world.enqueued.first?.releaseGroupMBID == "rg-Antics")

        await engine.checkAll()
        #expect(world.enqueued.count == 1, "a second pass re-requested an album it had already asked for")
        #expect(engine.statusByArtist[id]?.first { $0.title == "Antics" }?.state == .requested)
    }

    @Test("without a request source, missing albums become a wishlist and nothing is requested")
    func wishlistWithoutPlugin() async {
        let world = World()
        world.configured = false
        world.releases["Interpol"] = [Self.release("Antics", artist: "Interpol")]
        let engine = world.engine()
        await engine.follow(name: "Interpol")?.value
        #expect(world.enqueued.isEmpty)
        #expect(engine.statusByArtist[engine.followed[0].id]?.first?.state == .pending)
    }

    @Test("a track-only source cannot fetch albums, so it wishlists them too")
    func trackPluginWishlists() async {
        let world = World()
        world.granularity = .track
        world.releases["Interpol"] = [Self.release("Antics", artist: "Interpol")]
        let engine = world.engine()
        await engine.follow(name: "Interpol")?.value
        #expect(world.enqueued.isEmpty)
        #expect(engine.statusByArtist[engine.followed[0].id]?.first?.state == .pending)
    }

    // MARK: Persistence

    @Test("the last check's results survive a relaunch, so the list does not claim 'Nothing missing' before it has looked")
    func resultsSurviveRelaunch() async {
        let world = World()
        world.configured = false
        world.releases["Interpol"] = [Self.release("Antics", artist: "Interpol")]
        let first = world.engine()
        await first.follow(name: "Interpol")?.value
        let id = first.followed[0].id

        let relaunched = world.engine()
        #expect(relaunched.followed.map(\.id) == [id])
        #expect(relaunched.statusByArtist[id]?.map(\.title) == ["Antics"])
        #expect(relaunched.statusByArtist[id]?.first?.state == .pending)
        #expect(relaunched.missingCount(for: relaunched.followed[0]) == 1)
    }

    @Test("a subscriptions file written before results were stored still loads")
    func oldFileStillDecodes() throws {
        let old = #"[{"name":"Interpol","dateFollowed":811262294.5,"requestedReleaseIds":["rg-1"],"lastChecked":811262315.2}]"#
        let decoded = try JSONDecoder().decode([FollowedArtist].self, from: Data(old.utf8))
        #expect(decoded.first?.name == "Interpol")
        #expect(decoded.first?.requestedReleaseIds == ["rg-1"])
        #expect(decoded.first?.lastStatuses == nil)
    }

    // MARK: Automatic pass

    @Test("the automatic pass checks only artists not checked recently")
    func stalePassSkipsRecentChecks() async {
        let world = World()
        world.configured = false
        let now = Date()
        world.saved = [
            FollowedArtist(name: "Fresh", lastChecked: now.addingTimeInterval(-3600)),
            FollowedArtist(name: "Stale", lastChecked: now.addingTimeInterval(-13 * 3600)),
            FollowedArtist(name: "Never"),
        ]
        let engine = world.engine()
        await engine.checkStale(olderThan: 12 * 3600, now: now)
        #expect(Set(world.releaseLookups) == ["Stale", "Never"])
        #expect(engine.followed.first { $0.name == "Stale" }?.lastChecked.map { $0 > now.addingTimeInterval(-60) } == true)
    }
}
