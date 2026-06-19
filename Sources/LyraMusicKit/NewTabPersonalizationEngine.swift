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
    let forYouAlbums: [ChartAlbum]
    let fromYourArtists: [ChartAlbum]
    let discoverAlbums: [ChartAlbum]
    let artistHighlights: [NewTabArtistHighlight]

    var isEmpty: Bool {
        forYouAlbums.isEmpty && fromYourArtists.isEmpty && discoverAlbums.isEmpty
    }
}

/// Builds a listening-taste-aware New tab from scrobbles (Tuned In signal), favorites,
/// followed artists, and MusicBrainz release metadata.
enum NewTabPersonalizationEngine {
    private static let maxArtistFetches = 5
    private static let mbPacing: Duration = .milliseconds(1100)

    /// Non-personalised feed built from global results only — used for the fast first
    /// paint while per-artist requests are in flight.
    static func globalFallbackFeed(from globalAlbums: [ChartAlbum]) -> NewTabPersonalizedFeed {
        NewTabPersonalizedFeed(
            isPersonalized: false,
            forYouAlbums: Array(globalAlbums.prefix(20)),
            fromYourArtists: [],
            discoverAlbums: [],
            artistHighlights: [],
        )
    }

    struct Context {
        let completedScrobbles: [CompletedScrobble]
        let favoriteTrackIds: Set<String>
        let followedArtists: [FollowedArtist]
        let trackLookup: (String) -> Track?
        let indexedTracks: [Track]
        let ownsAlbum: (String, String) -> Bool
    }

    static func buildFeed(globalAlbums: [ChartAlbum], context: Context) async -> NewTabPersonalizedFeed {
        let taste = buildTasteProfile(context: context)
        let canPersonalize = taste.hasPersonalizationSignal

        let ownedFilteredGlobal = globalAlbums.filter { album in
            !context.ownsAlbum(album.artistName, album.name)
        }

        var fromYourArtists: [ChartAlbum] = []
        if canPersonalize {
            fromYourArtists = await fetchRecentFromTasteArtists(taste.artists, context: context)
        }

        let rankedGlobal = rankAlbums(ownedFilteredGlobal, taste: taste)
        let forYouPool = mergeUnique(fromYourArtists, rankedGlobal.filter { $0.score > 0 }.map(\.album))
        let forYouAlbums = Array(forYouPool.prefix(20))

        let forYouIds = Set(forYouAlbums.map(\.id))
        let fromYourIds = Set(fromYourArtists.map(\.id))
        let discoverAlbums = ownedFilteredGlobal
            .filter { !forYouIds.contains($0.id) && !fromYourIds.contains($0.id) }
            .prefix(canPersonalize ? 12 : 20)
            .map { $0 }

        let highlights = buildArtistHighlights(
            taste: taste,
            fromYourArtists: fromYourArtists,
            forYouAlbums: forYouAlbums,
        )

        if !canPersonalize {
            return NewTabPersonalizedFeed(
                isPersonalized: false,
                forYouAlbums: Array(ownedFilteredGlobal.prefix(20)),
                fromYourArtists: [],
                discoverAlbums: [],
                artistHighlights: [],
            )
        }

        return NewTabPersonalizedFeed(
            isPersonalized: true,
            forYouAlbums: forYouAlbums,
            fromYourArtists: Array(fromYourArtists.prefix(16)),
            discoverAlbums: Array(discoverAlbums),
            artistHighlights: highlights,
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

    // MARK: - MusicBrainz per-artist fetch

    private static func fetchRecentFromTasteArtists(
        _ artists: [NewTabTasteArtist],
        context: Context,
    ) async -> [ChartAlbum] {
        var collected: [ChartAlbum] = []
        var seen = Set<String>()
        let candidates = artists.prefix(maxArtistFetches)

        for (index, artist) in candidates.enumerated() {
            if index > 0 {
                try? await Task.sleep(for: mbPacing)
            }
            var mbid = artist.artistMBID
            if mbid == nil {
                mbid = await MusicBrainzArtistClient.findArtistId(name: artist.name)
            }
            guard let mbid else { continue }
            guard let albums = try? await MusicBrainzNewReleasesClient.fetchRecentAlbums(
                forArtistMBID: mbid,
                limit: 8,
            ) else { continue }

            for album in albums where !context.ownsAlbum(album.artistName, album.name) {
                guard seen.insert(album.id).inserted else { continue }
                collected.append(album)
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
}
