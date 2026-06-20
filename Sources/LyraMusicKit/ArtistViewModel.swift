import Combine
import Foundation
import SwiftUI

/// Selector for what the artist page should load. We accept either a resolved
/// server artist id (`LibraryArtistSummary`) or a free-form name string (Now Playing
/// "Go to Artist" only carries a name, as do album-hero artist taps).
enum ArtistPageInput: Hashable {
    case libraryArtist(LibraryArtistSummary)
    case named(String)

    var displayName: String {
        switch self {
        case .libraryArtist(let a): return a.name
        case .named(let n): return n
        }
    }

    var serverArtworkURL: URL? {
        switch self {
        case .libraryArtist(let a): return a.artworkURL
        case .named: return nil
        }
    }

    var libraryArtistId: String? {
        if case .libraryArtist(let a) = self { return a.id }
        return nil
    }
}

/// One row in the artist page's "Top Songs" section. Either matches a real track
/// on the user's server (`libraryTrack` non-nil, fully playable) or surfaces a
/// Last.fm-ranked title that isn't on the server yet (greyed row + request CTA).
struct ArtistTopSongRow: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let albumTitle: String?
    let releaseYear: Int?
    let artworkURL: URL?
    let libraryTrack: Track?
    let playcount: Int
}

/// Bucketing of a release for the artist page's discography sections.
enum ArtistDiscographyBucket: Hashable {
    case albums
    case singlesAndEPs
    case live
    case compilations
}

/// A discography card — either an album on the user's server (playable) or a
/// MusicBrainz release-group not present locally (links to BrowseAlbumDetailView).
struct ArtistDiscographyItem: Identifiable, Hashable {
    enum Source: Hashable {
        case libraryAlbum(AlbumSummary)
        case musicBrainz(MusicBrainzArtistRelease)
    }

    let id: String
    let title: String
    let artist: String
    let bucket: ArtistDiscographyBucket
    let releaseYear: Int?
    /// Best-effort sort date — the most precise date the source exposes
    /// (Jellyfin/Subsonic ``AlbumSummary/releaseDate`` when present, otherwise
    /// the first-of-year fallback derived from ``releaseYear``; for MusicBrainz,
    /// ``MusicBrainzArtistRelease/firstReleaseDate`` parsed liberally).
    let releaseSortDate: Date?
    let artworkURL: URL?
    let source: Source

    var libraryAlbum: AlbumSummary? {
        if case .libraryAlbum(let a) = source { return a }
        return nil
    }

    var musicBrainzRelease: MusicBrainzArtistRelease? {
        if case .musicBrainz(let r) = source { return r }
        return nil
    }

    /// True when the card represents a release the user's server doesn't have —
    /// tapping should open the request flow (``BrowseAlbumDetailView`` via the request backend).
    var needsRequest: Bool {
        if case .musicBrainz = source { return true }
        return false
    }
}

/// View state for ``ArtistPageView``. Loads server data + enrichment in parallel
/// and publishes each slice independently so the matching section can render the
/// moment its data arrives. Empty/failed slices leave their section hidden.
@MainActor
final class ArtistViewModel: ObservableObject {
    let input: ArtistPageInput

    @Published private(set) var resolvedArtistId: String?
    @Published private(set) var serverAlbums: [AlbumSummary] = []
    @Published private(set) var serverTracks: [Track] = []
    @Published private(set) var topSongs: [ArtistTopSongRow] = []
    @Published private(set) var discography: [ArtistDiscographyBucket: [ArtistDiscographyItem]] = [:]
    @Published private(set) var similarArtists: [LastFmSimilarArtist] = []
    @Published private(set) var details: TheAudioDBClient.ArtistDetails?
    @Published private(set) var jellyfinOverview: String?

    @Published private(set) var isLoadingServerCatalog = true
    @Published private(set) var isLoadingTopSongs = true
    @Published private(set) var isLoadingDiscography = true
    @Published private(set) var isLoadingEnrichment = true

    @Published private(set) var loadError: String?

    init(input: ArtistPageInput) {
        self.input = input
        if case .libraryArtist(let a) = input {
            self.resolvedArtistId = a.id
        }
    }

    var displayName: String { input.displayName }

    var hasAnyContent: Bool {
        !serverAlbums.isEmpty
            || !serverTracks.isEmpty
            || !topSongs.isEmpty
            || !discography.isEmpty
            || !similarArtists.isEmpty
            || (details?.biography?.isEmpty == false)
            || (jellyfinOverview?.isEmpty == false)
    }

    var hasPlayableTracks: Bool {
        !topSongs.compactMap(\.libraryTrack).isEmpty || !serverTracks.isEmpty
    }

    func playbackTracks(for mode: ArtistPlayMode) -> [Track] {
        switch mode {
        case .topSongs:
            let fromTop = topSongs.compactMap(\.libraryTrack)
            if !fromTop.isEmpty { return fromTop }
            return sortedServerTracks()
        case .fullCatalog:
            return sortedServerTracks()
        }
    }

    private func sortedServerTracks() -> [Track] {
        serverTracks.sorted { lhs, rhs in
            if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
            if lhs.indexNumber != rhs.indexNumber { return lhs.indexNumber < rhs.indexNumber }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// Drives the whole page: resolve the server artist id (when input was a bare name),
    /// then kick off server catalog + Last.fm + TheAudioDB + MusicBrainz in parallel.
    func load(using app: AppModel) async {
        // Warm-paint from per-session cache so banner/bio/similar appear instantly
        // on return visits. Top songs + discography still rebuild from the live
        // server catalog once it loads (their row content depends on it).
        if let cached = await ArtistEnrichmentCache.shared.load(forArtistName: input.displayName) {
            self.details = cached.details
            self.similarArtists = cached.similarArtists
            self.lastFmTopTracksSnapshot = cached.topTracks
            self.musicBrainzReleasesSnapshot = cached.releases
            self.isLoadingEnrichment = false
        }

        await resolveServerArtistIdIfNeeded(using: app)
        // Load server catalog first so dependent sections (top songs + discography)
        // can render against real album/track data. Enrichment runs concurrently.
        async let enrichment: Void = loadEnrichment()
        async let mbDiscography: Void = loadMusicBrainzReleases()
        await loadServerCatalog(using: app)
        _ = await (enrichment, mbDiscography)
        rebuildTopSongs()
        applyDiscography(releases: musicBrainzReleasesSnapshot, serverAlbums: serverAlbums)
        isLoadingDiscography = false

        await ArtistEnrichmentCache.shared.save(
            forArtistName: input.displayName,
            details: details,
            topTracks: lastFmTopTracksSnapshot,
            similarArtists: similarArtists,
            releases: musicBrainzReleasesSnapshot
        )
    }

    // MARK: - Subloads

    private func resolveServerArtistIdIfNeeded(using app: AppModel) async {
        if resolvedArtistId != nil { return }
        guard let lib = app.activeLibrary else { return }
        do {
            let artists = try await lib.libraryArtists(limit: 12_000)
            let target = LibraryTrackMatcher.normalize(input.displayName)
            if !target.isEmpty,
               let match = artists.first(where: { LibraryTrackMatcher.normalize($0.name) == target })
            {
                self.resolvedArtistId = match.id
            }
        } catch {
            // Non-fatal — page still renders enrichment-only.
        }
    }

    private func loadServerCatalog(using app: AppModel) async {
        guard let lib = app.activeLibrary, let id = resolvedArtistId else {
            isLoadingServerCatalog = false
            return
        }
        do {
            async let albumsTask = lib.albums(forLibraryArtistId: id, limit: 4000)
            async let tracksTask = lib.tracks(forLibraryArtistId: id, limit: 8000)
            let (albums, tracks) = try await (albumsTask, tracksTask)
            self.serverAlbums = albums.sorted { lhs, rhs in
                let l = lhs.releaseDate ?? lhs.releaseYearAsDate
                let r = rhs.releaseDate ?? rhs.releaseYearAsDate
                if let l, let r, l != r { return l > r }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            self.serverTracks = tracks
        } catch {
            self.loadError = error.localizedDescription
        }
        isLoadingServerCatalog = false
    }

    private var lastFmTopTracksSnapshot: [LastFmTopTrack] = []
    private var musicBrainzReleasesSnapshot: [MusicBrainzArtistRelease] = []

    private func loadEnrichment() async {
        let name = input.displayName
        async let detailsTask = TheAudioDBClient.fetchArtistDetails(name: name)
        async let topTask = LastFmClient.topTracks(artist: name, limit: 12)
        async let similarTask = LastFmClient.similarArtists(artist: name, limit: 16)
        let (resolvedDetails, top, similar) = await (detailsTask, topTask, similarTask)
        // Preserve previously-cached values when the live fetch returns nothing,
        // so a transient network failure on revisit doesn't wipe the banner/bio.
        self.details = resolvedDetails ?? self.details
        if !top.isEmpty { self.lastFmTopTracksSnapshot = top }
        if !similar.isEmpty { self.similarArtists = similar }

        // English-bio fallback: TheAudioDB often lacks `strBiographyEN` for niche
        // artists; if so, ask Last.fm (always English). Run sequentially after
        // TheAudioDB resolves so we don't waste the request when EN is present.
        if self.details?.biography == nil || self.details?.biography?.isEmpty == true {
            if let englishBio = await LastFmClient.artistBio(artist: name) {
                self.details = mergeBioIntoDetails(details: self.details, bio: englishBio, fallbackName: name)
            }
        }

        isLoadingEnrichment = false
    }

    /// Returns a new `ArtistDetails` with `biography` set to `bio`. If we never
    /// got a TheAudioDB payload, synthesize a minimal one so the About section
    /// can still render the Last.fm bio.
    private func mergeBioIntoDetails(
        details: TheAudioDBClient.ArtistDetails?,
        bio: String,
        fallbackName: String
    ) -> TheAudioDBClient.ArtistDetails {
        guard let d = details else {
            return TheAudioDBClient.ArtistDetails(
                name: fallbackName,
                wideArtworkURL: nil,
                thumbArtworkURL: nil,
                biography: bio,
                country: nil,
                formedYear: nil,
                genre: nil
            )
        }
        return TheAudioDBClient.ArtistDetails(
            name: d.name,
            wideArtworkURL: d.wideArtworkURL,
            thumbArtworkURL: d.thumbArtworkURL,
            biography: bio,
            country: d.country,
            formedYear: d.formedYear,
            genre: d.genre
        )
    }

    private func loadMusicBrainzReleases() async {
        let name = input.displayName
        let releases: [MusicBrainzArtistRelease]
        if let mbid = await MusicBrainzArtistClient.findArtistId(name: name) {
            releases = await MusicBrainzArtistClient.releaseGroups(artistId: mbid)
        } else {
            releases = []
        }
        self.musicBrainzReleasesSnapshot = releases
    }

    // MARK: - Section composition

    private func rebuildTopSongs() {
        topSongs = mergeTopSongs(lastFm: lastFmTopTracksSnapshot, tracks: serverTracks)
        if topSongs.isEmpty {
            topSongs = fallbackTopSongs(from: serverAlbums, tracks: serverTracks)
        }
        isLoadingTopSongs = false
    }

    private func mergeTopSongs(lastFm: [LastFmTopTrack], tracks: [Track]) -> [ArtistTopSongRow] {
        guard !lastFm.isEmpty else { return [] }
        let titleIndex = Dictionary(grouping: tracks) { LibraryTrackMatcher.normalize($0.title) }
        var rows: [ArtistTopSongRow] = []
        rows.reserveCapacity(min(lastFm.count, 10))
        for top in lastFm {
            let keys = LibraryTrackMatcher.normalizedTitleKeys(from: top.title)
            let match = keys.lazy.compactMap { titleIndex[$0]?.first }.first
            if let match {
                rows.append(ArtistTopSongRow(
                    id: "lib-\(match.id)",
                    title: match.title,
                    artist: match.artist,
                    albumTitle: match.albumTitle.isEmpty ? nil : match.albumTitle,
                    releaseYear: match.releaseYear,
                    artworkURL: match.artworkURL,
                    libraryTrack: match,
                    playcount: top.playcount
                ))
            } else {
                rows.append(ArtistTopSongRow(
                    id: "lfm-\(top.id)",
                    title: top.title,
                    artist: input.displayName,
                    albumTitle: nil,
                    releaseYear: nil,
                    artworkURL: nil,
                    libraryTrack: nil,
                    playcount: top.playcount
                ))
            }
            if rows.count >= 10 { break }
        }
        return rows
    }

    private func fallbackTopSongs(from albums: [AlbumSummary], tracks: [Track]) -> [ArtistTopSongRow] {
        let groups = Dictionary(grouping: tracks) { $0.albumId }
        var rows: [ArtistTopSongRow] = []
        for album in albums {
            guard let albumTracks = groups[album.id] else { continue }
            let leadoff = albumTracks
                .sorted { lhs, rhs in
                    if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
                    return lhs.indexNumber < rhs.indexNumber
                }
                .first
            guard let leadoff else { continue }
            rows.append(ArtistTopSongRow(
                id: "fallback-\(leadoff.id)",
                title: leadoff.title,
                artist: leadoff.artist,
                albumTitle: album.title,
                releaseYear: album.releaseYear,
                artworkURL: album.artworkURL ?? leadoff.artworkURL,
                libraryTrack: leadoff,
                playcount: 0
            ))
            if rows.count >= 10 { break }
        }
        return rows
    }

    /// Build the four discography buckets by blending the user's server catalog with
    /// MusicBrainz release-groups, then sorting each bucket newest-first.
    ///
    /// Blending rules:
    /// - **Albums**: server albums + every MusicBrainz `primary-type=Album` release
    ///   that doesn't match a server album. Missing-on-server items are tagged
    ///   `needsRequest = true` so the card renders a download glyph.
    /// - **Singles & EPs**: server albums classified as Single/EP + MusicBrainz
    ///   Single/EP releases that aren't matched to a server album. **Strict
    ///   dedupe**: a MusicBrainz single titled e.g. "Wake Up" is dropped when the
    ///   user already has a track titled "Wake Up" on any server album — the user
    ///   effectively already has the song, so listing it again is noise.
    /// - **Live** and **Compilations**: server-only (no MusicBrainz blending).
    ///   Apple Music does this too — the user asked for the blend behavior on
    ///   the Albums section, with strict singles, and the other secondary
    ///   buckets stay server-faithful.
    private func applyDiscography(releases: [MusicBrainzArtistRelease], serverAlbums: [AlbumSummary]) {
        let mbByNormalizedTitle: [String: MusicBrainzArtistRelease] = Dictionary(releases.map {
            (LibraryTrackMatcher.normalize($0.title), $0)
        }, uniquingKeysWith: { first, _ in first })

        // 1. Place each server album into a bucket. Use the MusicBrainz primary/
        //    secondary-type when we can match by title, otherwise fall back to
        //    a heuristic on title text and track count.
        var bucketed: [ArtistDiscographyBucket: [ArtistDiscographyItem]] = [:]
        var matchedReleaseIds = Set<String>()
        for album in serverAlbums {
            let key = LibraryTrackMatcher.normalize(album.title)
            let bucket: ArtistDiscographyBucket
            if let mb = mbByNormalizedTitle[key] {
                matchedReleaseIds.insert(mb.id)
                bucket = bucketFor(mb)
            } else {
                bucket = heuristicBucket(for: album)
            }
            bucketed[bucket, default: []].append(ArtistDiscographyItem(
                id: "lib-\(album.id)",
                title: album.title,
                artist: album.artist,
                bucket: bucket,
                releaseYear: album.releaseYear,
                releaseSortDate: album.releaseDate ?? album.releaseYearAsDate,
                artworkURL: album.artworkURL,
                source: .libraryAlbum(album)
            ))
        }

        // 2. Blend in MusicBrainz releases that don't have a matching server
        //    album — only into Albums and Singles & EPs (per the design rule).
        let serverTrackTitles = Set(serverTracks.map { LibraryTrackMatcher.normalize($0.title) })
        for mb in releases where !matchedReleaseIds.contains(mb.id) {
            let bucket = bucketFor(mb)
            guard bucket == .albums || bucket == .singlesAndEPs else { continue }
            if bucket == .singlesAndEPs {
                let titleKey = LibraryTrackMatcher.normalize(mb.title)
                if serverTrackTitles.contains(titleKey) { continue }
            }
            bucketed[bucket, default: []].append(ArtistDiscographyItem(
                id: "mb-\(mb.id)",
                title: mb.title,
                artist: mb.artistCredit.isEmpty ? input.displayName : mb.artistCredit,
                bucket: bucket,
                releaseYear: mb.releaseYear,
                releaseSortDate: Self.parseMusicBrainzDate(mb.firstReleaseDate),
                artworkURL: mb.coverArtURL,
                source: .musicBrainz(mb)
            ))
        }

        // 3. Sort every bucket newest-first. Items with no date sink to the end
        //    (sorted alphabetically among themselves) so a complete discography
        //    with a few undated re-releases still surfaces the recents at the top.
        for key in bucketed.keys {
            bucketed[key]?.sort { lhs, rhs in
                switch (lhs.releaseSortDate, rhs.releaseSortDate) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }
        }

        self.discography = bucketed
    }

    private func bucketFor(_ release: MusicBrainzArtistRelease) -> ArtistDiscographyBucket {
        switch release.kind {
        case .album: return .albums
        case .single, .ep: return .singlesAndEPs
        case .live: return .live
        case .compilation: return .compilations
        case .other: return .albums
        }
    }

    private func heuristicBucket(for album: AlbumSummary) -> ArtistDiscographyBucket {
        let title = album.title.lowercased()
        if title.range(of: #"\blive\b"#, options: .regularExpression) != nil { return .live }
        if title.range(of: #"\bcompilation\b|\bgreatest hits\b|\bbest of\b|\banthology\b"#, options: .regularExpression) != nil {
            return .compilations
        }
        if let n = album.trackCount {
            if n <= 3 { return .singlesAndEPs }
            if n <= 6 { return .singlesAndEPs }
        }
        return .albums
    }

    /// Parse MusicBrainz `first-release-date` (which can be `yyyy`, `yyyy-MM`, or
    /// `yyyy-MM-dd`) into a comparable `Date` for newest-first sort.
    private static func parseMusicBrainzDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        var comps = DateComponents()
        let parts = raw.split(separator: "-")
        guard let y = Int(parts.first ?? "") else { return nil }
        comps.year = y
        if parts.count >= 2, let m = Int(parts[1]) { comps.month = m } else { comps.month = 1 }
        if parts.count >= 3, let d = Int(parts[2]) { comps.day = d } else { comps.day = 1 }
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}

private extension AlbumSummary {
    /// Fallback sort key: a Date from the year alone so albums with year-only metadata still sort.
    var releaseYearAsDate: Date? {
        guard let y = releaseYear else { return nil }
        var comps = DateComponents()
        comps.year = y
        comps.month = 1
        comps.day = 1
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}
