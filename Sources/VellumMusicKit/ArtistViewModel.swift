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

    /// Cover-zoom key for the artist *page* — the id its hero registers and the one the tiles
    /// and rows that open it mark themselves with.
    ///
    /// Derived from the name rather than an id because the entry points know a name and often
    /// nothing else, and because `.libraryArtist` and `.named` for the same artist have to land
    /// on one key or the push and the pop would disagree about which cover is in play.
    var coverZoomPageId: String { Self.coverZoomPageId(forName: displayName) }

    static func coverZoomPageId(forName name: String) -> String {
        "artist-page:" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// One row in the artist page's "Top Songs" section. Either matches a real track
/// on the user's server (`libraryTrack` non-nil, fully playable) or a scrobbled
/// title that isn't resolved locally yet.
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
/// plugin catalog album not present locally (links to BrowseAlbumDetailView for request).
struct ArtistDiscographyItem: Identifiable, Hashable {
    enum Source: Hashable {
        case libraryAlbum(AlbumSummary)
        case remote(AcquisitionRelease)
    }

    let id: String
    let title: String
    let artist: String
    let bucket: ArtistDiscographyBucket
    let releaseYear: Int?
    /// Best-effort sort date — the most precise date the source exposes
    /// (Jellyfin/Subsonic ``AlbumSummary/releaseDate`` when present, otherwise
    /// the first-of-year fallback derived from ``releaseYear``; for a plugin
    /// release, ``AcquisitionRelease/releaseDate`` when present).
    let releaseSortDate: Date?
    let artworkURL: URL?
    let source: Source

    var libraryAlbum: AlbumSummary? {
        if case .libraryAlbum(let a) = source { return a }
        return nil
    }

    var remoteAlbum: AcquisitionRelease? {
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
    @Published private(set) var pluginProfile: AcquisitionArtistProfile?
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
            || (pluginProfile?.overview?.isEmpty == false)
            || (jellyfinOverview?.isEmpty == false)
    }

    var hasRenderableBodyContent: Bool {
        !topSongs.isEmpty
            || discography.values.contains { !$0.isEmpty }
            || !similarArtists.isEmpty
    }

    var hasPlayableTracks: Bool {
        !topSongs.compactMap(\.libraryTrack).isEmpty || !serverTracks.isEmpty
    }

    /// The artist's most recent plugin/server-adjacent release, shown as a
    /// featured card under the hero. `remoteReleasesSnapshot` is newest-first.
    var latestRelease: AcquisitionRelease? {
        remoteReleasesSnapshot.first(where: { $0.releaseDate != nil }) ?? remoteReleasesSnapshot.first
    }

    /// The server album matching a remote release by title, when the user already has it.
    func serverAlbum(matching release: AcquisitionRelease) -> AlbumSummary? {
        let keys = Set(discographyTitleKeys(for: release.title))
        guard !keys.isEmpty else { return nil }
        return serverAlbums.first { !Set(discographyTitleKeys(for: $0.title)).isDisjoint(with: keys) }
    }

    var hasAboutSection: Bool {
        if let overview = pluginProfile?.overview, !overview.isEmpty { return true }
        if let overview = jellyfinOverview, !overview.isEmpty { return true }
        if let genres = pluginProfile?.genres, !genres.isEmpty { return true }
        return false
    }

    /// Hero banner URL — wide artist photo when available, then thumb, album-cover fallback, then library input art.
    /// True when this artist exists on the connected Navidrome/Jellyfin server.
    /// On-server pages use only server-provided art — no TheAudioDB / iTunes covers.
    var isOnServerArtist: Bool {
        resolvedArtistId != nil
            || input.libraryArtistId != nil
            || input.serverArtworkURL != nil
            || !serverAlbums.isEmpty
    }

    var bannerArtworkURL: URL? {
        if isOnServerArtist {
            return input.serverArtworkURL
                ?? serverAlbums.first(where: { $0.artworkURL != nil })?.artworkURL
        }
        return pluginProfile?.artworkURL
            ?? remoteReleasesSnapshot.first(where: { $0.artistArtworkURL != nil })?.artistArtworkURL
            ?? remoteReleasesSnapshot.first(where: { $0.artworkURL != nil })?.artworkURL
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
    /// then load the server catalog plus the active plugin's discography (if any).
    func load(using app: AppModel) async {
        if let cached = await ArtistEnrichmentCache.shared.load(forArtistName: input.displayName) {
            self.pluginProfile = cached.profile
            self.remoteReleasesSnapshot = cached.releases
            self.isLoadingEnrichment = false
        }

        await resolveServerArtistIdIfNeeded(using: app)

        let pluginConfigured = app.acquisitionConfigured
        async let remote: Void = {
            if pluginConfigured {
                await self.loadRemoteReleases(using: app)
            }
        }()

        await loadServerCatalog(using: app)
        rebuildTopSongs(using: app)
        applyDiscography(releases: remoteReleasesSnapshot, serverAlbums: serverAlbums)
        isLoadingDiscography = false
        isLoadingEnrichment = false

        await remote
        if pluginConfigured {
            applyDiscography(releases: remoteReleasesSnapshot, serverAlbums: serverAlbums)
            await ArtistEnrichmentCache.shared.save(
                forArtistName: input.displayName,
                profile: pluginProfile,
                releases: remoteReleasesSnapshot
            )
        }
        await loadAcquisitionRequestability(using: app)
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

    private var remoteReleasesSnapshot: [AcquisitionRelease] = []

    private func loadRemoteReleases(using app: AppModel) async {
        guard app.acquisitionConfigured else {
            remoteReleasesSnapshot = []
            pluginProfile = nil
            return
        }
        async let releasesTask = app.acquisition.artistReleases(named: input.displayName)
        async let profileTask = app.acquisition.artistProfile(named: input.displayName)
        let releases = await releasesTask
        let profile = await profileTask
        remoteReleasesSnapshot = releases
        if let profile { pluginProfile = profile }
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

    private func rebuildTopSongs(using app: AppModel) {
        topSongs = scrobbleTopSongs(using: app)
        if topSongs.isEmpty {
            topSongs = fallbackTopSongs(from: serverAlbums, tracks: serverTracks)
        }
        isLoadingTopSongs = false
    }

    private func scrobbleTopSongs(using app: AppModel) -> [ArtistTopSongRow] {
        let artistKey = LibraryTrackMatcher.normalize(input.displayName)
        guard !artistKey.isEmpty else { return [] }
        var counts: [String: (track: Track?, title: String, artist: String, count: Int)] = [:]

        func consider(trackId: String, title: String, artist: String) {
            let key = LibraryTrackMatcher.normalize(title)
            guard !key.isEmpty else { return }
            let track = app.cachedLibraryTrack(id: trackId)
                ?? serverTracks.first(where: { $0.id == trackId })
            if var existing = counts[key] {
                existing.count += 1
                if existing.track == nil { existing.track = track }
                counts[key] = existing
            } else {
                counts[key] = (track, title, artist, 1)
            }
        }

        for scrobble in app.scrobbleService.store.completed {
            let key = LibraryTrackMatcher.normalize(scrobble.artist)
            guard key == artistKey else { continue }
            consider(trackId: scrobble.trackId, title: scrobble.title, artist: scrobble.artist)
        }
        for track in app.recentlyPlayedTracks {
            let key = LibraryTrackMatcher.normalize(track.artist)
            guard key == artistKey else { continue }
            consider(trackId: track.id, title: track.title, artist: track.artist)
        }

        return counts.values
            .sorted { $0.count > $1.count }
            .prefix(10)
            .map { entry in
                if let track = entry.track {
                    return ArtistTopSongRow(
                        id: "lib-\(track.id)",
                        title: track.title,
                        artist: track.artist,
                        albumTitle: track.albumTitle.isEmpty ? nil : track.albumTitle,
                        releaseYear: track.releaseYear,
                        artworkURL: track.artworkURL,
                        libraryTrack: track,
                        playcount: entry.count
                    )
                }
                return ArtistTopSongRow(
                    id: "scrobble-\(LibraryTrackMatcher.normalize(entry.title))",
                    title: entry.title,
                    artist: entry.artist,
                    albumTitle: nil,
                    releaseYear: nil,
                    artworkURL: nil,
                    libraryTrack: nil,
                    playcount: entry.count
                )
            }
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

    /// Title keys for matching plugin rows to server albums. Exact normalize plus
    /// ``AlbumSummary.albumVersionBaseKey`` so "hate that i made you love me - EP"
    /// matches a server album tagged without the suffix.
    private func discographyTitleKeys(for title: String) -> [String] {
        AlbumSummary.discographyTitleKeys(for: title)
    }

    private func applyDiscography(releases: [AcquisitionRelease], serverAlbums: [AlbumSummary]) {
        var remoteByTitleKey: [String: AcquisitionRelease] = [:]
        for remote in releases {
            for key in discographyTitleKeys(for: remote.title) {
                if remoteByTitleKey[key] == nil { remoteByTitleKey[key] = remote }
            }
        }

        var bucketed: [ArtistDiscographyBucket: [ArtistDiscographyItem]] = [:]
        var matchedReleaseIds = Set<String>()
        for album in serverAlbums {
            let bucket: ArtistDiscographyBucket
            if let remote = discographyTitleKeys(for: album.title).lazy.compactMap({ remoteByTitleKey[$0] }).first {
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

        let serverAlbumTitleKeys = Set(serverAlbums.flatMap { discographyTitleKeys(for: $0.title) })
        let serverTrackTitles = Set(serverTracks.flatMap { discographyTitleKeys(for: $0.title) })
        for remote in releases where !matchedReleaseIds.contains(remote.id) {
            let bucket = remote.bucket
            guard bucket == .albums || bucket == .singlesAndEPs else { continue }
            let remoteKeys = discographyTitleKeys(for: remote.title)
            if remoteKeys.contains(where: { serverAlbumTitleKeys.contains($0) }) { continue }
            if bucket == .singlesAndEPs, remoteKeys.contains(where: { serverTrackTitles.contains($0) }) {
                continue
            }
            bucketed[bucket, default: []].append(ArtistDiscographyItem(
                id: "acq-\(remote.id)",
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
