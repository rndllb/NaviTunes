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

/// A discography card — either an album on the user's server (playable) or an
/// iTunes album not present locally (links to BrowseAlbumDetailView for request).
struct ArtistDiscographyItem: Identifiable, Hashable {
    enum Source: Hashable {
        case libraryAlbum(AlbumSummary)
        case remote(ITunesArtistAlbum)
    }

    let id: String
    let title: String
    let artist: String
    let bucket: ArtistDiscographyBucket
    let releaseYear: Int?
    /// Best-effort sort date — the most precise date the source exposes
    /// (Jellyfin/Subsonic ``AlbumSummary/releaseDate`` when present, otherwise
    /// the first-of-year fallback derived from ``releaseYear``; for iTunes,
    /// ``ITunesArtistAlbum/releaseDate`` when present).
    let releaseSortDate: Date?
    let artworkURL: URL?
    let source: Source

    var libraryAlbum: AlbumSummary? {
        if case .libraryAlbum(let a) = source { return a }
        return nil
    }

    var remoteAlbum: ITunesArtistAlbum? {
        if case .remote(let a) = source { return a }
        return nil
    }

    /// True when the card represents a release the user's server doesn't have —
    /// tapping should open the request flow (``BrowseAlbumDetailView`` via the request backend).
    var needsRequest: Bool {
        if case .remote = source { return true }
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
    @Published private(set) var artistProfile: ArtistProfile?
    @Published private(set) var jellyfinOverview: String?

    @Published private(set) var isLoadingServerCatalog = true
    @Published private(set) var isLoadingTopSongs = true
    @Published private(set) var isLoadingDiscography = true
    @Published private(set) var isLoadingEnrichment = true

    @Published private(set) var loadError: String?
    /// False when iTunes shows this artist but the active acquisition plugin (Lidarr) has no catalog match.
    @Published private(set) var canRequestViaAcquisition = true

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

    /// The artist's most recent release (newest dated album/EP/single from iTunes), shown as a
    /// featured card under the hero. `remoteReleasesSnapshot` is already newest-first.
    var latestRelease: ITunesArtistAlbum? {
        remoteReleasesSnapshot.first(where: { $0.releaseDate != nil }) ?? remoteReleasesSnapshot.first
    }

    /// The server album matching a remote release by title, when the user already has it.
    func serverAlbum(matching release: ITunesArtistAlbum) -> AlbumSummary? {
        let key = LibraryTrackMatcher.normalize(release.title)
        guard !key.isEmpty else { return nil }
        return serverAlbums.first { LibraryTrackMatcher.normalize($0.title) == key }
    }

    var hasAboutSection: Bool {
        if let bio = details?.biography, !bio.isEmpty { return true }
        if let overview = jellyfinOverview, !overview.isEmpty { return true }
        if let profile = artistProfile, !profile.isEmpty { return true }
        guard let d = details else { return false }
        return d.country != nil || d.formedYear != nil || d.genre != nil
    }

    /// Hero banner URL — wide artist photo when available, then thumb, album-cover fallback, then library input art.
    var bannerArtworkURL: URL? {
        details?.wideArtworkURL
            ?? details?.thumbArtworkURL
            ?? fallbackBannerArtworkURL
            ?? input.serverArtworkURL
    }

    /// Banner fallback when TheAudioDB has no artist photo: the artist's top album cover
    /// (newest full album first), so the hero shows real artwork instead of a flat gradient.
    var fallbackBannerArtworkURL: URL? {
        let order: [ArtistDiscographyBucket] = [.albums, .singlesAndEPs, .compilations, .live]
        for bucket in order {
            if let url = discography[bucket]?.first(where: { $0.artworkURL != nil })?.artworkURL {
                return url
            }
        }
        return serverAlbums.first(where: { $0.artworkURL != nil })?.artworkURL
    }

    var hasOffServerCatalogContent: Bool {
        discography.values.contains { $0.contains(where: \.needsRequest) } || !remoteReleasesSnapshot.isEmpty
    }

    var showsCannotRequestBanner: Bool {
        !canRequestViaAcquisition && hasOffServerCatalogContent
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
    /// then kick off server catalog + Last.fm + TheAudioDB + iTunes discography in parallel.
    func load(using app: AppModel) async {
        // Warm-paint from per-session cache so banner/bio/similar appear instantly
        // on return visits. Top songs + discography still rebuild from the live
        // server catalog once it loads (their row content depends on it).
        if let cached = await ArtistEnrichmentCache.shared.load(forArtistName: input.displayName) {
            self.details = cached.details
            self.similarArtists = cached.similarArtists
            self.lastFmTopTracksSnapshot = cached.topTracks
            self.remoteReleasesSnapshot = cached.releases
            self.isLoadingEnrichment = false
        }

        await resolveServerArtistIdIfNeeded(using: app)
        // Load server catalog first so dependent sections (top songs + discography)
        // can render against real album/track data. Enrichment runs concurrently.
        async let enrichment: Void = loadEnrichment()
        async let remoteDiscography: Void = loadRemoteReleases()
        await loadServerCatalog(using: app)
        _ = await (enrichment, remoteDiscography)
        rebuildTopSongs()
        applyDiscography(releases: remoteReleasesSnapshot, serverAlbums: serverAlbums)
        isLoadingDiscography = false
        await loadAcquisitionRequestability(using: app)

        await ArtistEnrichmentCache.shared.save(
            forArtistName: input.displayName,
            details: details,
            topTracks: lastFmTopTracksSnapshot,
            similarArtists: similarArtists,
            releases: remoteReleasesSnapshot
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
    private var remoteReleasesSnapshot: [ITunesArtistAlbum] = []

    private func loadEnrichment() async {
        let name = input.displayName
        async let detailsTask = TheAudioDBClient.fetchArtistDetails(name: name)
        async let topTask = LastFmClient.topTracks(artist: name, limit: 12)
        async let similarTask = LastFmClient.similarArtists(artist: name, limit: 16)
        async let profileTask = ArtistProfileClient.fetch(name: name)
        let (resolvedDetails, top, similar) = await (detailsTask, topTask, similarTask)
        let profile = await profileTask
        if let profile { self.artistProfile = profile }
        // Preserve previously-cached values when the live fetch returns nothing,
        // so a transient network failure on revisit doesn't wipe the banner/bio.
        self.details = resolvedDetails ?? self.details
        if !top.isEmpty { self.lastFmTopTracksSnapshot = top }

        // Similar artists: Last.fm when available, otherwise ListenBrainz (free, keyed by the
        // MusicBrainz id from the profile). iTunes has no related-artists endpoint. Skip the
        // (ListenBrainz + 16 iTunes avatar) work entirely when the per-session cache already
        // warm-painted them.
        if !similar.isEmpty {
            self.similarArtists = similar
        } else if self.similarArtists.isEmpty, let mbid = profile?.mbid {
            let related = await ListenBrainzClient.similarArtists(mbid: mbid, limit: 16)
            if !related.isEmpty {
                // ListenBrainz has no photos — give each a circular avatar from an iTunes album
                // cover (the same album-art-as-avatar approach the Home shelf uses).
                let art = await ITunesArtistClient.artworkURLs(forArtists: related.map(\.name))
                self.similarArtists = related.map { artist in
                    guard let url = art[LibraryTrackMatcher.normalize(artist.name)] else { return artist }
                    return LastFmSimilarArtist(name: artist.name, mbid: artist.mbid, imageURL: url, match: artist.match)
                }
            }
        }

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

    private func loadRemoteReleases() async {
        // Already warm-painted from the per-session cache — skip the iTunes discography fetch.
        guard remoteReleasesSnapshot.isEmpty else { return }
        self.remoteReleasesSnapshot = await ITunesArtistClient.discography(forArtist: input.displayName)
    }

    private func loadAcquisitionRequestability(using app: AppModel) async {
        guard app.acquisitionConfigured, app.acquisitionCapabilities.granularity == .album else {
            canRequestViaAcquisition = true
            return
        }
        guard hasOffServerCatalogContent else {
            canRequestViaAcquisition = true
            return
        }
        canRequestViaAcquisition = await app.acquisition.canRequestArtist(named: input.displayName)
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
    /// the iTunes discography, then sorting each bucket newest-first.
    ///
    /// Blending rules:
    /// - **Albums**: server albums + every iTunes album-type release
    ///   that doesn't match a server album. Missing-on-server items are tagged
    ///   `needsRequest = true` so the card renders a download glyph.
    /// - **Singles & EPs**: server albums classified as Single/EP + iTunes
    ///   Single/EP releases that aren't matched to a server album. **Strict
    ///   dedupe**: an iTunes single titled e.g. "Wake Up" is dropped when the
    ///   user already has a track titled "Wake Up" on any server album — the user
    ///   effectively already has the song, so listing it again is noise.
    /// - **Live** and **Compilations**: server-only (no iTunes blending).
    ///   Apple Music does this too — the user asked for the blend behavior on
    ///   the Albums section, with strict singles, and the other secondary
    ///   buckets stay server-faithful.
    private func applyDiscography(releases: [ITunesArtistAlbum], serverAlbums: [AlbumSummary]) {
        let remoteByNormalizedTitle: [String: ITunesArtistAlbum] = Dictionary(releases.map {
            (LibraryTrackMatcher.normalize($0.title), $0)
        }, uniquingKeysWith: { first, _ in first })

        // 1. Place each server album into a bucket. Use the iTunes album's bucket when we can
        //    match by title, otherwise fall back to a heuristic on title text and track count.
        var bucketed: [ArtistDiscographyBucket: [ArtistDiscographyItem]] = [:]
        var matchedReleaseIds = Set<String>()
        for album in serverAlbums {
            let key = LibraryTrackMatcher.normalize(album.title)
            let bucket: ArtistDiscographyBucket
            if let remote = remoteByNormalizedTitle[key] {
                matchedReleaseIds.insert(remote.id)
                bucket = remote.bucket
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

        // 2. Blend in iTunes releases that don't have a matching server album — only into
        //    Albums and Singles & EPs (per the design rule).
        let serverTrackTitles = Set(serverTracks.map { LibraryTrackMatcher.normalize($0.title) })
        for remote in releases where !matchedReleaseIds.contains(remote.id) {
            let bucket = remote.bucket
            guard bucket == .albums || bucket == .singlesAndEPs else { continue }
            if bucket == .singlesAndEPs {
                let titleKey = LibraryTrackMatcher.normalize(remote.title)
                if serverTrackTitles.contains(titleKey) { continue }
            }
            bucketed[bucket, default: []].append(ArtistDiscographyItem(
                id: "itunes-\(remote.id)",
                title: remote.title,
                artist: remote.artist.isEmpty ? input.displayName : remote.artist,
                bucket: bucket,
                releaseYear: remote.releaseYear,
                releaseSortDate: remote.releaseDate,
                artworkURL: remote.artworkURL,
                source: .remote(remote)
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
