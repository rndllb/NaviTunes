import Foundation

/// Artist the user has affinity for — derived from scrobbles, favorites, and follows.
struct NewTabTasteArtist: Identifiable, Hashable {
    var id: String { normalizedKey }
    let name: String
    let normalizedKey: String
    let score: Double
    let artistMBID: String?

    var hasStrongSignal: Bool { score >= 1 }
}

/// A followed artist surfaced on the New tab with fresh releases.
struct NewTabArtistHighlight: Identifiable {
    let id: String
    let name: String
    let imageURL: URL?
    let newReleaseCount: Int
    let topAlbum: ChartAlbum?
}

/// Personalized shelves for the **New** tab.
struct NewTabPersonalizedFeed {
    let isPersonalized: Bool
    /// Charting / taste-ranked **songs** for the hero + Best New Songs shelves.
    let forYouTracks: [ChartTrack]
    let forYouAlbums: [ChartAlbum]
    let fromYourArtists: [ChartAlbum]
    let discoverAlbums: [ChartAlbum]
    let artistHighlights: [NewTabArtistHighlight]
    /// Every recent release connected to the user's listening taste (releases by the
    /// artists they play/follow/favorite, plus affinity-ranked new music), ordered
    /// newest-first. The New tab splits this by recency into "New This Week" and
    /// "Recent Releases" so both shelves are taste-driven and never identical.
    let recentTasteReleases: [ChartAlbum]

    var isEmpty: Bool {
        forYouTracks.isEmpty && forYouAlbums.isEmpty && fromYourArtists.isEmpty && discoverAlbums.isEmpty
    }
}

/// Builds a listening-taste-aware New tab from scrobbles (Made for You / home-mix signal), favorites,
/// followed artists, and the user's top genres — sourced entirely from Apple's free iTunes
/// feeds (`ITunesNewReleasesClient`). All requests run concurrently with no rate-limit pacing,
/// so the personalized feed is ready in ~1–2 s.
enum NewTabPersonalizationEngine {
    private static let maxArtistFetches = 5

    struct Context {
        let completedScrobbles: [CompletedScrobble]
        let favoriteTrackIds: Set<String>
        let followedArtists: [FollowedArtist]
        let trackLookup: (String) -> Track?
        let indexedTracks: [Track]
        let ownsAlbum: (String, String) -> Bool
        let ownsTrack: (String, String) -> Bool
        /// The user's top genres (canonicalised, most-listened first). Computed by `AppModel`
        /// from reliably-loaded data — recently played, favorites, and library albums — so it
        /// doesn't depend on the sparse discovery-track index.
        let topGenres: [String]
    }

    static func buildFeed(context: Context) async -> NewTabPersonalizedFeed {
        let taste = buildTasteProfile(context: context)
        let canPersonalize = taste.hasPersonalizationSignal
        let topGenres = context.topGenres

        // Genre chart songs + per-artist recent singles, fetched concurrently from iTunes.
        async let genreSongsTask = ITunesNewReleasesClient.topSongsForGenres(topGenres, perGenre: 20)
        async let genreReleasesTask = ITunesNewReleasesClient.newReleasesForGenres(topGenres, perGenre: 20)
        let artistReleases = canPersonalize
            ? await fetchRecentFromTasteArtists(taste.artists)
            : []
        let artistSingles = canPersonalize
            ? await fetchRecentSinglesFromTasteArtists(taste.artists)
            : []
        let genreReleases = await genreReleasesTask
        let genreSongs = await genreSongsTask

        let notOwnedAlbum: (ChartAlbum) -> Bool = { !context.ownsAlbum($0.artistName, $0.name) }
        let notOwnedTrack: (ChartTrack) -> Bool = { !context.ownsTrack($0.artistName, $0.name) }
        let fromYourArtists = artistReleases.filter(notOwnedAlbum)
        var genrePool = genreReleases.filter(notOwnedAlbum)
        var songPool = genreSongs.filter(notOwnedTrack)

        // No personal signal at all → fall back to the global charts.
        if genrePool.isEmpty, fromYourArtists.isEmpty {
            genrePool = (await ITunesNewReleasesClient.topAlbums(genreId: nil, limit: 30)).filter(notOwnedAlbum)
        }
        if songPool.isEmpty, artistSingles.isEmpty {
            songPool = (await ITunesNewReleasesClient.topSongs(genreId: nil, limit: 30)).filter(notOwnedTrack)
        }

        let isPersonalized = canPersonalize || !topGenres.isEmpty

        // Taste-rank pools, then put the user's own artists' releases first.
        let rankedGenre = rankAlbums(genrePool, taste: taste).map(\.album)
        let forYouPool = mergeUnique(fromYourArtists, rankedGenre)

        let forYouAlbums = Array(forYouPool.prefix(20))
        let rankedSongs = rankTracks(songPool, taste: taste).map(\.track)
        let forYouTrackPool = mergeUniqueTracks(artistSingles, rankedSongs)
        let forYouTracks = diversifyTracks(forYouTrackPool, maxPerArtist: 2, totalLimit: 20)
        // Newest-first pool the New tab splits into "New This Week" / "Recent Releases".
        let recentTasteReleases = forYouPool.sorted {
            ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast)
        }

        let forYouIds = Set(forYouAlbums.map(\.id))
        let fromYourIds = Set(fromYourArtists.map(\.id))
        let discoverAlbums = genrePool
            .filter { !forYouIds.contains($0.id) && !fromYourIds.contains($0.id) }
            .prefix(12)
            .map { $0 }

        let highlights = buildArtistHighlights(
            taste: taste,
            fromYourArtists: fromYourArtists,
            forYouAlbums: forYouAlbums,
        )

        return NewTabPersonalizedFeed(
            isPersonalized: isPersonalized,
            forYouTracks: forYouTracks,
            forYouAlbums: forYouAlbums,
            fromYourArtists: Array(fromYourArtists.prefix(16)),
            discoverAlbums: Array(discoverAlbums),
            artistHighlights: highlights,
            recentTasteReleases: recentTasteReleases,
        )
    }

    // MARK: - Taste profile

    private struct TasteProfile {
        let artists: [NewTabTasteArtist]
        let affinityByKey: [String: Double]

        var hasPersonalizationSignal: Bool { !artists.isEmpty }
    }

    private struct ScoredAlbum {
        let album: ChartAlbum
        let score: Double
    }

    private struct ScoredTrack {
        let track: ChartTrack
        let score: Double
    }

    private static func buildTasteProfile(context: Context) -> TasteProfile {
        var scores: [String: (name: String, score: Double, mbid: String?)] = [:]

        let now = Date()
        for scrobble in context.completedScrobbles {
            let artist = scrobble.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty else { continue }
            let key = LibraryTrackMatcher.normalize(artist)
            guard !key.isEmpty else { continue }
            let age = now.timeIntervalSince(scrobble.timestamp)
            let recency = max(0.35, 1.0 - age / (90 * 86_400))
            if var existing = scores[key] {
                existing.score += recency
                scores[key] = existing
            } else {
                scores[key] = (artist, recency, nil)
            }
        }

        for followed in context.followedArtists {
            let key = LibraryTrackMatcher.normalize(followed.name)
            guard !key.isEmpty else { continue }
            if var existing = scores[key] {
                existing.score += 6
                existing.mbid = existing.mbid ?? followed.artistMBID
                scores[key] = existing
            } else {
                scores[key] = (followed.name, 6, followed.artistMBID)
            }
        }

        var favoriteArtistCounts: [String: (name: String, count: Int)] = [:]
        for trackId in context.favoriteTrackIds {
            let track = context.trackLookup(trackId)
                ?? context.indexedTracks.first(where: { $0.id == trackId })
            guard let track else { continue }
            let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty else { continue }
            let key = LibraryTrackMatcher.normalize(artist)
            guard !key.isEmpty else { continue }
            if var existing = favoriteArtistCounts[key] {
                existing.count += 1
                favoriteArtistCounts[key] = existing
            } else {
                favoriteArtistCounts[key] = (artist, 1)
            }
        }
        for (key, entry) in favoriteArtistCounts {
            let boost = Double(entry.count) * 1.5
            if var existing = scores[key] {
                existing.score += boost
                scores[key] = existing
            } else {
                scores[key] = (entry.name, boost, nil)
            }
        }

        let artists = scores
            .map { key, value in
                NewTabTasteArtist(
                    name: value.name,
                    normalizedKey: key,
                    score: value.score,
                    artistMBID: value.mbid,
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        let affinity = Dictionary(uniqueKeysWithValues: artists.map { ($0.normalizedKey, $0.score) })
        return TasteProfile(artists: artists, affinityByKey: affinity)
    }

    // MARK: - iTunes per-artist fetch

    /// Recent albums from the user's top taste artists via iTunes, fetched concurrently and
    /// biased toward the last few years so "From Artists You Play" feels current.
    private static func fetchRecentFromTasteArtists(_ artists: [NewTabTasteArtist]) async -> [ChartAlbum] {
        let candidates = Array(artists.prefix(maxArtistFetches))
        guard !candidates.isEmpty else { return [] }

        var collected: [ChartAlbum] = []
        var seen = Set<String>()
        await withTaskGroup(of: [ChartAlbum].self) { group in
            for artist in candidates {
                group.addTask { await ITunesNewReleasesClient.recentAlbums(forArtist: artist.name, limit: 6) }
            }
            for await albums in group {
                for album in albums where seen.insert(album.id).inserted {
                    collected.append(album)
                }
            }
        }

        let cutoff = Calendar.current.date(byAdding: .year, value: -3, to: Date()) ?? .distantPast
        let recent = collected.filter { ($0.releaseDate ?? .distantPast) >= cutoff }
        return (recent.isEmpty ? collected : recent).sorted {
            ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast)
        }
    }

    /// Recent official singles from the user's top taste artists (iTunes discography, not Search).
    private static func fetchRecentSinglesFromTasteArtists(_ artists: [NewTabTasteArtist]) async -> [ChartTrack] {
        let candidates = Array(artists.prefix(maxArtistFetches))
        guard !candidates.isEmpty else { return [] }

        var collected: [ChartTrack] = []
        var seen = Set<String>()
        await withTaskGroup(of: [ChartTrack].self) { group in
            for artist in candidates {
                group.addTask { await ITunesNewReleasesClient.recentSingles(forArtist: artist.name, limit: 4) }
            }
            for await singles in group {
                for track in singles where seen.insert(track.id).inserted {
                    collected.append(track)
                }
            }
        }
        return collected
    }

    // MARK: - Ranking

    private static func rankAlbums(_ albums: [ChartAlbum], taste: TasteProfile) -> [ScoredAlbum] {
        albums
            .map { album in
                ScoredAlbum(album: album, score: affinityScore(for: album.artistName, taste: taste))
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.album.name.localizedCaseInsensitiveCompare(rhs.album.name) == .orderedAscending
            }
    }

    private static func rankTracks(_ tracks: [ChartTrack], taste: TasteProfile) -> [ScoredTrack] {
        tracks
            .map { track in
                ScoredTrack(track: track, score: affinityScore(for: track.artistName, taste: taste))
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.track.name.localizedCaseInsensitiveCompare(rhs.track.name) == .orderedAscending
            }
    }

    private static func affinityScore(for artistLine: String, taste: TasteProfile) -> Double {
        let wholeKey = LibraryTrackMatcher.normalize(artistLine)
        var score = taste.affinityByKey[wholeKey] ?? 0

        let parts = artistLine
            .split(separator: ",")
            .map { LibraryTrackMatcher.normalize(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }

        for part in parts where part != wholeKey {
            score += (taste.affinityByKey[part] ?? 0) * 0.85
        }

        if score == 0, !wholeKey.isEmpty {
            for (key, value) in taste.affinityByKey where key.count >= 4 {
                if wholeKey.contains(key) || key.contains(wholeKey) {
                    score += value * 0.45
                }
            }
        }
        return score
    }

    private static func buildArtistHighlights(
        taste: TasteProfile,
        fromYourArtists: [ChartAlbum],
        forYouAlbums: [ChartAlbum],
    ) -> [NewTabArtistHighlight] {
        var releaseCounts: [String: Int] = [:]
        var topAlbumByKey: [String: ChartAlbum] = [:]

        for album in fromYourArtists + forYouAlbums {
            let key = LibraryTrackMatcher.normalize(album.artistName)
            guard !key.isEmpty else { continue }
            releaseCounts[key, default: 0] += 1
            if topAlbumByKey[key] == nil {
                topAlbumByKey[key] = album
            }
        }

        return taste.artists
            .filter { releaseCounts[$0.normalizedKey, default: 0] > 0 }
            .prefix(10)
            .map { artist in
                let count = releaseCounts[artist.normalizedKey, default: 0]
                let album = topAlbumByKey[artist.normalizedKey]
                return NewTabArtistHighlight(
                    id: artist.normalizedKey,
                    name: artist.name,
                    imageURL: album?.imageURL ?? nil,
                    newReleaseCount: count,
                    topAlbum: album,
                )
            }
    }

    private static func mergeUnique(_ primary: [ChartAlbum], _ secondary: [ChartAlbum]) -> [ChartAlbum] {
        var seen = Set<String>()
        var merged: [ChartAlbum] = []
        for album in primary + secondary {
            guard seen.insert(album.id).inserted else { continue }
            merged.append(album)
        }
        return merged
    }

    private static func mergeUniqueTracks(_ primary: [ChartTrack], _ secondary: [ChartTrack]) -> [ChartTrack] {
        var seen = Set<String>()
        var merged: [ChartTrack] = []
        for track in primary + secondary {
            guard seen.insert(track.id).inserted else { continue }
            merged.append(track)
        }
        return merged
    }

    /// Prevent one artist from flooding the Best New Songs shelf (common with posthumous catalogs).
    private static func diversifyTracks(
        _ tracks: [ChartTrack],
        maxPerArtist: Int,
        totalLimit: Int,
    ) -> [ChartTrack] {
        var perArtist = [String: Int]()
        var result: [ChartTrack] = []
        for track in tracks {
            let key = LibraryTrackMatcher.normalize(track.artistName)
            guard perArtist[key, default: 0] < maxPerArtist else { continue }
            perArtist[key] = perArtist[key, default: 0] + 1
            result.append(track)
            if result.count >= totalLimit { break }
        }
        return result
    }

    // MARK: - Server catalog (Home Top Picks)

    /// Ranks server ``AlbumSummary`` rows by taste; falls back to input order when there is no signal.
    static func tasteRankedAlbumSummaries(
        _ albums: [AlbumSummary],
        context: Context,
        limit: Int,
        recentlyAddedOrder: [String: Int] = [:],
    ) -> [AlbumSummary] {
        guard !albums.isEmpty else { return [] }
        let taste = buildTasteProfile(context: context)
        let topGenres = context.topGenres.map { $0.lowercased() }
        let hasTasteSignal = taste.hasPersonalizationSignal || !topGenres.isEmpty

        let scored: [(album: AlbumSummary, score: Double)] = albums.map { album in
            var score = affinityScore(for: album.artist, taste: taste)

            for (idx, genre) in topGenres.prefix(10).enumerated() {
                let weight = max(0.35, 1.0 - Double(idx) / 10.0)
                for raw in album.genres {
                    if GenreCanonicalizer.canonical(for: raw).lowercased() == genre {
                        score += weight * 2.2
                        break
                    }
                }
            }

            if let idx = recentlyAddedOrder[album.id] {
                score += max(0.25, 1.4 - Double(idx) / 35.0)
            }
            if let date = album.libraryAddedDate {
                let age = Date().timeIntervalSince(date)
                score += max(0, 0.8 - age / (120 * 86_400))
            }

            return (album, score)
        }

        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.album.title.localizedCaseInsensitiveCompare(rhs.album.title) == .orderedAscending
        }

        if !hasTasteSignal || sorted.allSatisfy({ $0.score <= 0.01 }) {
            return dedupedAlbumSummaries(from: albums, limit: limit)
        }

        return dedupedAlbumSummaries(from: sorted.map(\.album), limit: limit)
    }

    private static func dedupedAlbumSummaries(from albums: [AlbumSummary], limit: Int) -> [AlbumSummary] {
        var seenIDs = Set<String>()
        var seenReleases = Set<String>()
        var result: [AlbumSummary] = []
        for album in albums {
            guard seenIDs.insert(album.id).inserted else { continue }
            guard seenReleases.insert(album.catalogReleaseIdentityKey).inserted else { continue }
            result.append(album)
            if result.count >= limit { break }
        }
        return result
    }
}
