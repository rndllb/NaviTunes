import Foundation

/// Result of a lightweight reachability probe that distinguishes
/// "server says your token is bad" from "server is unreachable".
/// Used so cold-launch restore can decide whether to re-POST the
/// user's password (only when explicitly auth-rejected).
enum ServerReachabilityProbe {
    case ok
    case authRejected
    case unreachable
}

/// Process-wide host → auth headers registry. Lets media-asset / artwork loaders inject
/// per-backend `Authorization` headers without leaking bearer tokens into URLs (which
/// would otherwise appear in server access logs, reverse-proxy logs, and URL caches).
///
/// `AppModel` registers the active Jellyfin host's headers on sign-in / Keychain restore;
/// `RemoteArtworkLoad`, `AccountAvatarCache`, and `ArtworkDynamicGradient` consult the
/// registry before their `URLSession` requests.
actor MediaAuthHeaderRegistry {
    static let shared = MediaAuthHeaderRegistry()

    private var headersByHost: [String: [String: String]] = [:]

    func register(host: String, headers: [String: String]) {
        let key = host.lowercased()
        if headers.isEmpty {
            headersByHost.removeValue(forKey: key)
        } else {
            headersByHost[key] = headers
        }
    }

    func unregister(host: String) {
        headersByHost.removeValue(forKey: host.lowercased())
    }

    func clear() {
        headersByHost.removeAll()
    }

    func headers(for url: URL) -> [String: String] {
        guard let host = url.host?.lowercased() else { return [:] }
        return headersByHost[host] ?? [:]
    }
}

struct AlbumSummary: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
    /// Track count when the backend reports it (optional surfacing in Library / grids).
    let trackCount: Int?
    /// When the album was added to the library (Jellyfin DateCreated, etc.), when known.
    let libraryAddedDate: Date?
    /// Album genres when the server tags them (Jellyfin / Navidrome).
    let genres: [String]
    /// Original release year when reported (`ProductionYear`, Subsonic `year`, etc.).
    let releaseYear: Int?
    /// Original release calendar date when the server exposes it (`PremiereDate`, Subsonic `originalReleaseDate`, etc.).
    let releaseDate: Date?

    init(
        id: String,
        title: String,
        artist: String,
        artworkURL: URL?,
        trackCount: Int? = nil,
        libraryAddedDate: Date? = nil,
        genres: [String] = [],
        releaseYear: Int? = nil,
        releaseDate: Date? = nil,
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.trackCount = trackCount
        self.libraryAddedDate = libraryAddedDate
        self.genres = genres
        self.releaseYear = releaseYear
        self.releaseDate = releaseDate
    }
}

extension AlbumSummary {
    /// Album footer: long-style release date, or release year when only a year is known.
    var releaseFooterDisplayString: String? {
        if let d = releaseDate {
            return d.formatted(date: .long, time: .omitted)
        }
        guard let y = releaseYear else { return nil }
        let current = Calendar.current.component(.year, from: Date())
        guard y >= 1900 && y <= current + 2 else { return nil }
        return String(y)
    }
}

// MARK: - Album hero subtitle (genre · year · technical)

/// Subtitle under the album title on library / browse hero surfaces (`Genre · Year · Sample rate · Channels`).
enum AlbumHeroMetadataLine {
    private static let sep = " \u{00B7} "

    static func compose(album: AlbumSummary, tracks: [Track]) -> String {
        var parts: [String] = []

        if let g = primaryGenre(album: album, tracks: tracks), !g.isEmpty {
            parts.append(g)
        }
        if let y = releaseYear(album: album, tracks: tracks) {
            parts.append("\(y)")
        }
        if let hz = representativeSampleRateHz(tracks: tracks), hz > 0 {
            parts.append(formatKhz(hz))
        }
        if let ch = representativeChannelLabel(tracks: tracks), !ch.isEmpty {
            parts.append(ch)
        }

        if parts.isEmpty {
            return fallbackLine(album: album, tracks: tracks)
        }
        return parts.joined(separator: sep)
    }

    private static func fallbackLine(album: AlbumSummary, tracks: [Track]) -> String {
        if let y = album.releaseYear, isPlausibleReleaseYear(y) {
            return "\(y)"
        }
        let n = album.trackCount ?? (tracks.isEmpty ? nil : tracks.count)
        if let n, n > 0 {
            return n == 1 ? "1 song" : "\(n) songs"
        }
        return ""
    }

    private static func primaryGenre(album: AlbumSummary, tracks: [Track]) -> String? {
        for raw in album.genres {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPlausibleGenreLabel(t) else { continue }
            return t
        }
        for t in tracks {
            for raw in t.genres {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isPlausibleGenreLabel(trimmed) else { continue }
                return trimmed
            }
        }
        return nil
    }

    private static func releaseYear(album: AlbumSummary, tracks: [Track]) -> Int? {
        if let y = album.releaseYear, isPlausibleReleaseYear(y) { return y }
        return tracks.compactMap(\.releaseYear).first(where: { isPlausibleReleaseYear($0) })
    }

    private static func isPlausibleGenreLabel(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        // Subsonic sometimes exposes `genre` as a number (e.g. `1`) — coerce becomes `"1"`.
        if trimmed.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return false
        }
        return true
    }

    private static func isPlausibleReleaseYear(_ y: Int) -> Bool {
        let current = Calendar.current.component(.year, from: Date())
        return y >= 1900 && y <= current + 2
    }

    private static func representativeSampleRateHz(tracks: [Track]) -> Int? {
        for t in tracks {
            if let hz = t.sampleRateHz, hz > 0 { return hz }
        }
        return nil
    }

    private static func representativeChannelLabel(tracks: [Track]) -> String? {
        for t in tracks {
            if let label = channelLabel(t.audioChannels) { return label }
        }
        return nil
    }

    private static func channelLabel(_ n: Int?) -> String? {
        guard let n, n > 0 else { return nil }
        switch n {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(n) channels"
        }
    }

    private static func formatKhz(_ hz: Int) -> String {
        let whole = hz / 1000
        let frac = hz % 1000
        if frac == 0 {
            return "\(whole) kHz"
        }
        let k = Double(hz) / 1000.0
        return String(format: "%.1f kHz", k)
    }
}

struct Track: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let albumId: String
    /// Album display name from the server when available (Now Playing menus, etc.).
    let albumTitle: String
    let artist: String
    let duration: TimeInterval
    let discNumber: Int
    let indexNumber: Int
    /// Per-track or album artwork when the server exposes it (mini player / Now Playing).
    let artworkURL: URL?
    /// Server “added / created” time when known (Library Songs sorting).
    let libraryAddedDate: Date?
    let genres: [String]
    let releaseYear: Int?
    let sampleRateHz: Int?
    let audioChannels: Int?
    /// Normalized codec id when known (e.g. flac, aac, mp3).
    let audioCodec: String?
    let audioBitDepth: Int?
    /// Reported bitrate in kbps (Subsonic `bitRate`); Jellyfin often omits on Child items.
    let audioBitRateKbps: Int?
    /// Direct stream URL for internet radio (bypasses Subsonic ``stream`` for this item).
    let streamOverrideURL: URL?

    init(
        id: String,
        title: String,
        albumId: String,
        albumTitle: String,
        artist: String,
        duration: TimeInterval,
        discNumber: Int,
        indexNumber: Int,
        artworkURL: URL?,
        libraryAddedDate: Date? = nil,
        genres: [String] = [],
        releaseYear: Int? = nil,
        sampleRateHz: Int? = nil,
        audioChannels: Int? = nil,
        audioCodec: String? = nil,
        audioBitDepth: Int? = nil,
        audioBitRateKbps: Int? = nil,
        streamOverrideURL: URL? = nil,
    ) {
        self.id = id
        self.title = title
        self.albumId = albumId
        self.albumTitle = albumTitle
        self.artist = artist
        self.duration = duration
        self.discNumber = discNumber
        self.indexNumber = indexNumber
        self.artworkURL = artworkURL
        self.libraryAddedDate = libraryAddedDate
        self.genres = genres
        self.releaseYear = releaseYear
        self.sampleRateHz = sampleRateHz
        self.audioChannels = audioChannels
        self.audioCodec = audioCodec
        self.audioBitDepth = audioBitDepth
        self.audioBitRateKbps = audioBitRateKbps
        self.streamOverrideURL = streamOverrideURL
    }

    var isInternetRadioStream: Bool { streamOverrideURL != nil }

    func withDuration(_ newDuration: TimeInterval) -> Track {
        Track(
            id: id,
            title: title,
            albumId: albumId,
            albumTitle: albumTitle,
            artist: artist,
            duration: newDuration,
            discNumber: discNumber,
            indexNumber: indexNumber,
            artworkURL: artworkURL,
            libraryAddedDate: libraryAddedDate,
            genres: genres,
            releaseYear: releaseYear,
            sampleRateHz: sampleRateHz,
            audioChannels: audioChannels,
            audioCodec: audioCodec,
            audioBitDepth: audioBitDepth,
            audioBitRateKbps: audioBitRateKbps,
            streamOverrideURL: streamOverrideURL,
        )
    }
}

struct LyricLine: Identifiable, Hashable {
    var id: String { "\(start)-\(text)" }
    let start: TimeInterval
    let text: String
}

/// Artist folder / performer entry for Library → Artists (server-backed id).
struct LibraryArtistSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let artworkURL: URL?
}

/// Genre entry for Library → Genres (`id` is Jellyfin item id or Navidrome stable key — use ``albums(inGenre:limit:)``).
struct LibraryGenreSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let albumCount: Int?
}

/// Server-wide catalog search results. Songs / albums / artists across the entire
/// connected Navidrome / Jellyfin instance — **not** scoped to the user's personal
/// library. Use this for "find anything on the server"; use ``AppModel`` personal-
/// library state to scope to "what I've added".
struct CatalogSearchResults {
    var songs: [Track]
    var albums: [AlbumSummary]
    var artists: [LibraryArtistSummary]

    static let empty = CatalogSearchResults(songs: [], albums: [], artists: [])
    var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty }
}

protocol MusicLibraryProviding: AnyObject {
    var displayName: String { get }
    func albums(limit: Int) async throws -> [AlbumSummary]
    func recentlyAdded(limit: Int) async throws -> [AlbumSummary]
    func recentlyPlayed(limit: Int) async throws -> [AlbumSummary]
    func tracks(forAlbumId albumId: String) async throws -> [Track]
    /// All playable audio in the library (up to `limit`). Jellyfin uses one recursive query; other backends walk albums.
    func allTracks(limit: Int) async throws -> [Track]
    /// Page of library tracks (newest-added first when the backend supports server-side sort).
    /// Used by ``LibrarySongsView`` for scroll-driven pagination on large libraries.
    func tracksPage(offset: Int, limit: Int) async throws -> [Track]
    func streamURL(for track: Track) throws -> URL
    /// Progressive URLs to try if ``streamURL(for:)`` does not become playable (transcoding / codec mismatches).
    func fallbackStreamURLs(for track: Track) -> [URL]
    /// URL used when saving a track for offline playback. Must resolve to an AVPlayer-compatible format
    /// (MP3, AAC/M4A, FLAC, WAV). Defaults to ``streamURL(for:)`` — backends should override to
    /// explicitly request a supported container rather than relying on whatever the server returns.
    func offlineDownloadURL(for track: Track) throws -> URL
    func httpHeadersForMediaRequests() -> [String: String]
    func lyrics(for track: Track) async throws -> [LyricLine]

    /// Library sidebar — Artists (sorted by name).
    func libraryArtists(limit: Int) async throws -> [LibraryArtistSummary]
    /// Library sidebar — Genres.
    func libraryGenres(limit: Int) async throws -> [LibraryGenreSummary]
    /// Albums credited to this library artist id.
    func albums(forLibraryArtistId artistId: String, limit: Int) async throws -> [AlbumSummary]
    /// Tracks attributed to this artist (album tracks by default; Jellyfin uses a single Audio query).
    func tracks(forLibraryArtistId artistId: String, limit: Int) async throws -> [Track]
    /// Albums tagged with this genre (Jellyfin uses ``LibraryGenreSummary/id``; Navidrome uses ``LibraryGenreSummary/name`` for `byGenre`).
    func albums(inGenre genre: LibraryGenreSummary, limit: Int) async throws -> [AlbumSummary]

    /// Permanently removes a library audio item on the server (supported backends only).
    func deleteTrackFromLibrary(trackId: String) async throws

    /// Server-wide catalog search. Returns songs / albums / artists matching `query`,
    /// **not** scoped to the user's personal library. Caps each kind at `limit`.
    /// Used by the Discovery → Downtify hybrid tab to surface "already on the server,
    /// just not in your library yet" candidates alongside Downtify download results.
    func searchCatalog(query: String, limit: Int) async throws -> CatalogSearchResults
}

extension MusicLibraryProviding {
    func lyrics(for track: Track) async throws -> [LyricLine] { [] }

    /// Default no-op so backends without server-side search compile.
    func searchCatalog(query: String, limit: Int) async throws -> CatalogSearchResults {
        .empty
    }

    func fallbackStreamURLs(for track: Track) -> [URL] { [] }
    func offlineDownloadURL(for track: Track) throws -> URL { try streamURL(for: track) }

    func allTracks(limit: Int) async throws -> [Track] {
        let cap = max(1, min(limit, 50_000))
        let albumBudget = min(2_000, max(400, cap))
        let albumsList = try await albums(limit: albumBudget)
        var out: [Track] = []
        out.reserveCapacity(min(cap, 6_000))
        for album in albumsList {
            let ts = try await tracks(forAlbumId: album.id)
            out.append(contentsOf: ts)
            if out.count >= cap { break }
        }
        return Array(out.prefix(cap))
    }

    /// Fallback paginated track listing for backends that don't override. Walks `allTracks`,
    /// which loads everything up to `offset + limit` and slices — not ideal, but correct.
    func tracksPage(offset: Int, limit: Int) async throws -> [Track] {
        let safeOffset = max(0, offset)
        let safeLimit = max(1, limit)
        let needed = safeOffset + safeLimit
        let all = try await allTracks(limit: needed)
        guard safeOffset < all.count else { return [] }
        return Array(all[safeOffset..<min(all.count, safeOffset + safeLimit)])
    }

    func tracks(forLibraryArtistId artistId: String, limit: Int) async throws -> [Track] {
        let cap = max(1, min(limit, 12_000))
        let albumBudget = min(600, max(48, cap / 10))
        let albumsList = try await albums(forLibraryArtistId: artistId, limit: albumBudget)
        var out: [Track] = []
        out.reserveCapacity(min(cap, 2500))
        for album in albumsList {
            let ts = try await tracks(forAlbumId: album.id)
            out.append(contentsOf: ts)
            if out.count >= cap { break }
        }
        out.sort { lhs, rhs in
            if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
            if lhs.indexNumber != rhs.indexNumber { return lhs.indexNumber < rhs.indexNumber }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return Array(out.prefix(cap))
    }
}
