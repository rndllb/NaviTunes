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

/// Builds a listening-taste-aware New tab from scrobbles, favorites, followed
/// artists, and the user's top genres. Candidate albums come from the connected
/// server catalog plus (when configured) the active plugin's calendar/wanted list.
enum NewTabPersonalizationEngine {
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
        /// Server albums to present as New (recently added + taste-artist catalog).
        let serverAlbums: [AlbumSummary]
        let recentlyPlayedTracks: [Track]
        /// Lidarr calendar / wanted rows. Empty when no catalog plugin is connected.
        let catalogReleases: [AcquisitionRelease]
    }

    static func serverCandidateAlbums(
        recentlyAdded: [AlbumSummary],
        libraryAlbums: [AlbumSummary],
        tasteArtistNames: [String]
    ) -> [AlbumSummary] {
        var pool: [AlbumSummary] = []
        var seen = Set<String>()
        func append(_ albums: [AlbumSummary]) {
            for album in albums {
                guard seen.insert(album.id).inserted else { continue }
                pool.append(album)
            }
        }
        append(recentlyAdded)
        let tasteArtists = Set(
            tasteArtistNames
                .map { LibraryTrackMatcher.normalize($0) }
                .filter { !$0.isEmpty }
        )
        if !tasteArtists.isEmpty {
            append(libraryAlbums.filter { tasteArtists.contains(LibraryTrackMatcher.normalize($0.artist)) })
        }
        if pool.isEmpty {
            append(libraryAlbums)
        }
        return pool
    }

    static func buildFeed(context: Context) -> NewTabPersonalizedFeed {
        let taste = buildTasteProfile(context: context)
        let canPersonalize = taste.hasPersonalizationSignal
        let topGenres = context.topGenres
        let tasteKeys = Set(taste.artists.map(\.normalizedKey))

        let notOwnedAlbum: (ChartAlbum) -> Bool = { !context.ownsAlbum($0.artistName, $0.name) }

        let serverCharts = uniqueAlbums(context.serverAlbums.map { ChartAlbum(serverAlbum: $0) })
        let catalogCharts = uniqueAlbums(
            context.catalogReleases.map { ChartAlbum(release: $0) }.filter(notOwnedAlbum)
        )

        func isTasteArtist(_ artist: String) -> Bool {
            let key = LibraryTrackMatcher.normalize(artist)
            if key.isEmpty { return false }
            if tasteKeys.contains(key) { return true }
            return taste.artists.contains { artist in
                key.contains(artist.normalizedKey) || artist.normalizedKey.contains(key)
            }
        }

        let fromYourArtists = uniqueAlbums(
            (catalogCharts + serverCharts).filter { isTasteArtist($0.artistName) }
        )
        // Server + Lidarr calendar/wanted share one pool so shelves stay populated
        // when the server catalog is sparse or taste artists have no new rows.
        var genrePool = uniqueAlbums(serverCharts + catalogCharts)
        if genrePool.isEmpty {
            genrePool = catalogCharts
        }

        let isPersonalized = canPersonalize || !topGenres.isEmpty

        let rankedGenre = rankAlbums(genrePool, taste: taste).map(\.album)
        let forYouPool = mergeUnique(fromYourArtists, rankedGenre)
        let forYouAlbums = Array(forYouPool.prefix(20))

        let songPool = listeningTracks(context: context)
        let forYouTracks = diversifyTracks(
            rankTracks(songPool, taste: taste).map(\.track),
            maxPerArtist: 2,
            totalLimit: 20
        )
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

    private static func listeningTracks(context: Context) -> [ChartTrack] {
        var seen = Set<String>()
        var tracks: [ChartTrack] = []
        func append(_ track: ChartTrack) {
            guard seen.insert(track.id).inserted else { return }
            tracks.append(track)
        }
        for track in context.recentlyPlayedTracks {
            append(ChartTrack(track: track))
        }
        for scrobble in context.completedScrobbles.sorted(by: { $0.timestamp > $1.timestamp }) {
            if let track = context.trackLookup(scrobble.trackId)
                ?? context.indexedTracks.first(where: { $0.id == scrobble.trackId }) {
                append(ChartTrack(track: track, playcount: 1))
            } else {
                append(ChartTrack(
                    id: scrobble.trackId,
                    name: scrobble.title,
                    artistName: scrobble.artist,
                    imageURL: nil,
                    playcount: 1
                ))
            }
        }
        return tracks
    }

    private static func uniqueAlbums(_ albums: [ChartAlbum]) -> [ChartAlbum] {
        var seenIDs = Set<String>()
        var seenReleases = Set<String>()
        var out: [ChartAlbum] = []
        for album in albums {
            let key = "\(LibraryTrackMatcher.normalize(album.artistName))|\(LibraryTrackMatcher.normalize(album.name))"
            guard seenIDs.insert(album.id).inserted, seenReleases.insert(key).inserted else { continue }
            out.append(album)
        }
        return out
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
