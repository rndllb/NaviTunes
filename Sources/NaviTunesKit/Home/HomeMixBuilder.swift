import SwiftUI

/// A personalized on-device mix for the Home → **Made for You** shelf.
struct HomeMix: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let artworkURLs: [URL]
    let tracks: [Track]

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: HomeMix, rhs: HomeMix) -> Bool {
        lhs.id == rhs.id
    }
}

extension HomeMix {
    static let libraryPlaylistIdPrefix = "__vellum_home_mix:"

    var libraryPlaylistId: String { Self.libraryPlaylistIdPrefix + id }

    static func isLibraryPlaylistId(_ id: String) -> Bool {
        id.hasPrefix(libraryPlaylistIdPrefix)
    }

    static func mixId(fromLibraryPlaylistId id: String) -> String? {
        guard id.hasPrefix(libraryPlaylistIdPrefix) else { return nil }
        return String(id.dropFirst(libraryPlaylistIdPrefix.count))
    }

    func asPlaylistSummary() -> PlaylistSummary {
        PlaylistSummary(
            id: libraryPlaylistId,
            name: title,
            songCount: tracks.count,
            artworkURL: artworkURLs.first
        )
    }

    var libraryDetailSubtitle: String {
        "\(subtitle) · Updates automatically"
    }
}

enum HomeMixBuilder {
    private static let minimumTracks = 3
    private static let maximumTracks = 30

    struct Context {
        let completedScrobbles: [CompletedScrobble]
        let trackLookup: (String) -> Track?
        let artworkURL: (Track) -> URL?
        let favoriteTrackIds: Set<String>
        let libraryAlbumIds: Set<String>
        let recentlyAddedPersonalAlbumIds: [String]
        let indexedTracks: [Track]
    }

    static func buildMixes(_ context: Context) -> [HomeMix] {
        var mixes: [HomeMix] = []
        if let mix = onRepeatMix(context) { mixes.append(mix) }
        if let mix = favoritesMix(context) { mixes.append(mix) }
        if let mix = rediscoverMix(context) { mixes.append(mix) }
        if let mix = newInLibraryMix(context) { mixes.append(mix) }
        return mixes
    }

    private static func onRepeatMix(_ context: Context) -> HomeMix? {
        guard !context.completedScrobbles.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for scrobble in context.completedScrobbles {
            counts[scrobble.trackId, default: 0] += 1
        }
        let orderedIds = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.map(\.key)
        let tracks = resolveTracks(ids: orderedIds, lookup: context.trackLookup)
        return makeMix(id: "on-repeat", title: "On Repeat", tracks: tracks, context: context)
    }

    private static func favoritesMix(_ context: Context) -> HomeMix? {
        guard !context.favoriteTrackIds.isEmpty else { return nil }
        let tracks = context.indexedTracks.filter { context.favoriteTrackIds.contains($0.id) }
        return makeMix(id: "favorites", title: "Favorites Mix", tracks: tracks, context: context)
    }

    private static func rediscoverMix(_ context: Context) -> HomeMix? {
        guard !context.libraryAlbumIds.isEmpty else { return nil }
        let playedAlbumIds = Set(
            context.completedScrobbles.compactMap { scrobble -> String? in
                context.trackLookup(scrobble.trackId)?.albumId
            }.filter { !$0.isEmpty }
        )
        let candidateAlbumIds = context.libraryAlbumIds.subtracting(playedAlbumIds)
        guard !candidateAlbumIds.isEmpty else { return nil }
        let tracksByAlbum = Dictionary(grouping: context.indexedTracks, by: \.albumId)
        var tracks: [Track] = []
        tracks.reserveCapacity(candidateAlbumIds.count)
        for albumId in candidateAlbumIds.sorted() {
            guard let albumTracks = tracksByAlbum[albumId] else { continue }
            guard let lead = albumTracks.sorted(by: trackSort).first else { continue }
            tracks.append(lead)
            if tracks.count >= maximumTracks { break }
        }
        return makeMix(id: "rediscover", title: "Rediscover", tracks: tracks, context: context)
    }

    private static func newInLibraryMix(_ context: Context) -> HomeMix? {
        guard !context.recentlyAddedPersonalAlbumIds.isEmpty else { return nil }
        let tracksByAlbum = Dictionary(grouping: context.indexedTracks, by: \.albumId)
        var tracks: [Track] = []
        for albumId in context.recentlyAddedPersonalAlbumIds {
            guard let albumTracks = tracksByAlbum[albumId] else { continue }
            guard let lead = albumTracks.sorted(by: trackSort).first else { continue }
            tracks.append(lead)
            if tracks.count >= maximumTracks { break }
        }
        return makeMix(id: "new-in-library", title: "New in Your Library", tracks: tracks, context: context)
    }

    private static func resolveTracks(ids: [String], lookup: (String) -> Track?) -> [Track] {
        var seen = Set<String>()
        var tracks: [Track] = []
        tracks.reserveCapacity(min(ids.count, maximumTracks))
        for id in ids {
            guard seen.insert(id).inserted else { continue }
            guard let track = lookup(id) else { continue }
            tracks.append(track)
            if tracks.count >= maximumTracks { break }
        }
        return tracks
    }

    private static func makeMix(id: String, title: String, tracks: [Track], context: Context) -> HomeMix? {
        guard tracks.count >= minimumTracks else { return nil }
        let limited = Array(tracks.prefix(maximumTracks))
        let artworkURLs = artworkURLs(for: limited, context: context)
        return HomeMix(
            id: id,
            title: title,
            subtitle: mixSubtitle(count: limited.count),
            artworkURLs: artworkURLs,
            tracks: limited
        )
    }

    /// Up to four unique album covers for the mix mosaic, preferring resolved server URLs.
    private static func artworkURLs(for tracks: [Track], context: Context) -> [URL] {
        var seenAlbumKeys = Set<String>()
        var urls: [URL] = []
        urls.reserveCapacity(4)
        for track in tracks {
            guard let url = context.artworkURL(track) else { continue }
            let albumKey = track.albumId.isEmpty ? url.absoluteString : track.albumId
            guard seenAlbumKeys.insert(albumKey).inserted else { continue }
            urls.append(url)
            if urls.count >= 4 { break }
        }
        return urls
    }

    private static func mixSubtitle(count: Int) -> String {
        count == 1 ? "Mix · 1 song" : "Mix · \(count) songs"
    }

    private static func trackSort(_ lhs: Track, _ rhs: Track) -> Bool {
        if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
        return lhs.indexNumber < rhs.indexNumber
    }
}

// MARK: - Mix artwork

/// 2×2 mosaic cover for Home → **Made for You** mixes (Navidrome / Apple Music–style).
struct MixCollageArtworkView: View {
    let urls: [URL]
    var fallbackSeed: String
    var cornerRadius: CGFloat = MusicDesign.heroCorner

    @Environment(\.colorScheme) private var colorScheme

    private let tileGap: CGFloat = 1

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                collageBody
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                MusicDesign.artworkSubtleBorderOverlay(
                    cornerRadius: cornerRadius,
                    colorScheme: colorScheme,
                )
            }
    }

    @ViewBuilder
    private var collageBody: some View {
        switch urls.count {
        case 0:
            RadioStationMeshArtworkView(seedKey: fallbackSeed, cornerRadius: 0)
        case 1:
            AlbumArtworkView(url: urls[0], cornerRadius: 0, showsSubtleBorder: false)
        default:
            GeometryReader { geo in
                let side = geo.size.width
                let tile = (side - tileGap) / 2
                let grid = mosaicURLs
                VStack(spacing: tileGap) {
                    HStack(spacing: tileGap) {
                        mosaicTile(url: grid[0], size: tile)
                        mosaicTile(url: grid[1], size: tile)
                    }
                    HStack(spacing: tileGap) {
                        mosaicTile(url: grid[2], size: tile)
                        mosaicTile(url: grid[3], size: tile)
                    }
                }
            }
        }
    }

    private var mosaicURLs: [URL] {
        guard !urls.isEmpty else { return [] }
        var grid = Array(urls.prefix(4))
        while grid.count < 4 {
            grid.append(urls[grid.count % urls.count])
        }
        return grid
    }

    private func mosaicTile(url: URL, size: CGFloat) -> some View {
        AlbumArtworkView(url: url, cornerRadius: 0, showsSubtleBorder: false)
            .frame(width: size, height: size)
            .clipped()
    }
}
