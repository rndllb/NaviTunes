import Foundation

// There is deliberately no progress callback in this file.
//
// Plugins used to be handed a `(Double) -> Void` to call during `enqueue`, and all three used it
// the same way: to report how far through *placing the request* they were — 0.05 after validating
// config, 0.5 after picking a release, 1.0 once the server accepted it. None of that measures a
// transfer, and all of it reached the screen as a download percentage. Removing the channel is
// what makes an invented figure unrepresentable rather than merely discouraged: the only way a
// fraction can now reach `AcquisitionJob.progress` is by being read from a server response.

/// The selectable acquisition backends. Only one is active at a time
/// (`AcquisitionManager.activePlugin`); every request flows through the active one.
enum AcquisitionPluginKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case lidarr
    case downtify
    case droppedNeedle

    var id: String { rawValue }
}

/// Where a displayed job came from: a request this app issued, or the plugin's
/// own server-side queue (so Settings can surface activity started elsewhere).
/// Raw-valued so it survives a round trip through the persisted job store by name rather than by
/// declaration order.
enum AcquisitionJobSource: String, Sendable, Codable {
    case app
    case server
}

/// Normalized lifecycle for a request across every plugin.
enum AcquisitionJobStatus: String, Sendable, Codable {
    case queued
    case searching
    case downloading
    case importing
    case done
    case failed
    /// The backend looked and came back empty-handed. **Terminal**, and distinct from `failed`:
    /// nothing went wrong, there is simply nothing to fetch. Without this the UI had no way to
    /// stop waiting, so a search that found nothing looked identical to one still running — the
    /// request sat at "searching" for ever.
    case notFound
    /// The backend has the request but reports **nothing happening**: not queued, not searching,
    /// no files. Ethan's "Back to Strangers" case — Lidarr grabbed twice and the job never entered
    /// the download queue.
    ///
    /// Not terminal, because it can still start moving on its own, but never shown as a spinner or
    /// a percentage: silence dressed up as progress is the exact defect this pass exists to remove.
    case stalled
    case unknown

    var isTerminal: Bool { self == .done || self == .failed || self == .notFound }

    /// One wording for a state, everywhere it is shown.
    var displayTitle: String {
        switch self {
        case .queued: return "Queued"
        case .searching: return "Searching"
        case .downloading: return "Downloading"
        case .importing: return "Importing"
        case .done: return "Complete"
        case .failed: return "Failed"
        case .notFound: return "Not found"
        case .stalled: return "Nothing happening"
        case .unknown: return "In progress"
        }
    }
}

/// What the backend says about one request, sampled fresh.
///
/// The point of this type is that **the app does not get a vote**. Every phase and every fraction
/// below is read from a field the server owns; when the server reports no fraction, `progress` is
/// `nil` and the UI shows indeterminate rather than inventing a number. Returning `nil` from
/// ``AcquisitionProviding/requestState(for:)`` means "this plugin cannot say", which is different
/// from any of these phases and leaves the existing state alone.
struct AcquisitionBackendState: Sendable {
    enum Phase: Sendable {
        /// A search is running on the server right now.
        case searching
        /// Accepted into the download queue, transfer not started.
        case queued
        /// Transferring. `progress` carries the fraction only if the server reports one.
        case downloading
        /// Transferred; the server is moving it into the library.
        case importing
        /// Files exist in the library. Terminal.
        case completed
        /// The search finished and grabbed nothing. Terminal.
        case notFound
        /// The backend knows about the request and reports no activity against it at all.
        case noActivity
        /// Something went wrong, with the server's own words in `detail`. Terminal.
        case failed
    }

    let phase: Phase
    /// 0–1, and **only** when the backend reports a real fraction. `nil` = indeterminate.
    let progress: Double?
    /// Server-supplied explanation, shown as-is.
    let detail: String?

    init(phase: Phase, progress: Double? = nil, detail: String? = nil) {
        self.phase = phase
        self.progress = progress
        self.detail = detail
    }

    var status: AcquisitionJobStatus {
        switch phase {
        case .searching: return .searching
        case .queued: return .queued
        case .downloading: return .downloading
        case .importing: return .importing
        case .completed: return .done
        case .notFound: return .notFound
        case .noActivity: return .stalled
        case .failed: return .failed
        }
    }
}

/// The single unified request type. Every UI call site builds one of these and
/// hands it to ``AcquisitionManager/enqueue(_:)`` regardless of the active plugin.
///
/// `requestKey` is a backend-agnostic stable identity (normalized artist|title|album)
/// used for job tracking, so a request stays trackable no matter what native id the
/// plugin uses internally (the request backend URL, Lidarr foreignAlbumId, …).
struct AcquisitionRequest: Hashable, Sendable {
    var artist: String
    var trackTitle: String?
    var albumTitle: String?
    var artistMBID: String?
    var releaseGroupMBID: String?
    var coverURL: URL?
    /// Optional direct handle a plugin can act on immediately (e.g. an acquisition song
    /// URL) when it's already known.
    var sourceURL: String?
    var requestKey: String

    init(
        artist: String,
        trackTitle: String? = nil,
        albumTitle: String? = nil,
        artistMBID: String? = nil,
        releaseGroupMBID: String? = nil,
        coverURL: URL? = nil,
        sourceURL: String? = nil,
        requestKey: String? = nil
    ) {
        self.artist = artist
        self.trackTitle = trackTitle
        self.albumTitle = albumTitle
        self.artistMBID = artistMBID
        self.releaseGroupMBID = releaseGroupMBID
        self.coverURL = coverURL
        self.sourceURL = sourceURL
        self.requestKey = requestKey ?? AcquisitionRequest.key(artist: artist, title: trackTitle, album: albumTitle)
    }

    /// Backend-agnostic identity. Uses the same normalization as library matching so a
    /// request lines up with optimistic rows and server queue entries.
    static func key(artist: String, title: String?, album: String?) -> String {
        let a = LibraryTrackMatcher.normalize(artist)
        let t = LibraryTrackMatcher.normalize(title ?? "")
        let al = LibraryTrackMatcher.normalize(album ?? "")
        return "\(a)|\(t)|\(al)"
    }

    /// Best human-readable title for jobs/toasts.
    var displayTitle: String {
        if let t = trackTitle, !t.isEmpty { return t }
        if let a = albumTitle, !a.isEmpty { return a }
        return artist
    }

    /// Search term plugins use against their catalogs.
    var searchTerm: String {
        let pieces = [artist, trackTitle ?? albumTitle ?? ""].filter { !$0.isEmpty }
        return pieces.joined(separator: " ")
    }
}

/// A concrete, enqueue-able item returned by track-search plugins (the request backend).
/// Carries the ``AcquisitionRequest`` needed to download it, so the UI never touches
/// plugin internals.
struct AcquisitionResult: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artists: [String]
    let albumName: String
    let coverURL: URL?
    let year: Int?
    let explicit: Bool
    /// Optional secondary line (format/quality/source hint), rendered verbatim.
    let subtitle: String?
    /// "Single" / "EP" / "Album" — the *kind* on its own, without the artist appended.
    ///
    /// Kept apart from ``subtitle`` so a row can lay the second line out itself and make the
    /// artist a separate tap target. Baked into one string, the artist could not be tapped.
    let kindLabel: String?
    let request: AcquisitionRequest

    init(
        id: String,
        title: String,
        artists: [String],
        albumName: String,
        coverURL: URL?,
        year: Int?,
        explicit: Bool,
        subtitle: String?,
        kindLabel: String? = nil,
        request: AcquisitionRequest
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.albumName = albumName
        self.coverURL = coverURL
        self.year = year
        self.explicit = explicit
        self.subtitle = subtitle
        self.kindLabel = kindLabel
        self.request = request
    }

    var artistLine: String { artists.joined(separator: ", ") }
}

/// Per-file progress inside a multi-file acquisition.
struct AcquisitionFileProgress: Identifiable, Hashable, Sendable, Codable {
    var id: String
    let title: String
    let status: AcquisitionJobStatus
    /// Same contract as ``AcquisitionJob/progress``: a fraction the backend reported, or **nil**
    /// because it reported none.
    ///
    /// Nothing constructs one of these today, so this changes no behaviour. It is optional anyway
    /// because the guarantee is supposed to hold **by type**, not by the absence of callers — a
    /// non-optional `Double` here would quietly hand the first plugin that adopts per-file
    /// reporting the same footgun the rest of this file was just cleared of, and it would arrive
    /// looking reasonable.
    let progress: Double?
    /// Optional secondary line (bytes, speed, queue position).
    let detail: String?
}

/// One row in the unified queue/activity surface.
struct AcquisitionJob: Identifiable, Hashable, Sendable, Codable {
    var id: String
    let title: String?
    let artist: String?
    let albumTitle: String?
    let status: AcquisitionJobStatus
    /// How far along the backend says this is, 0–1 — or **nil, meaning the backend did not say**.
    ///
    /// Optional on purpose, and the optionality is the feature. While this was a plain `Double`
    /// every construction site had to put *something* in it, and what went in were numbers nobody
    /// measured: `0.05` on enqueue, a floor of `0.4`, `1.0` the moment a request was accepted. Each
    /// of those reached the screen as a percentage and each was fiction — the 100% stall and then
    /// the 10% stall were both exactly this.
    ///
    /// There is no longer anywhere to put a made-up number: a caller with no backend figure has to
    /// write `nil`, and `nil` renders as an explicit "no progress reported" state rather than a
    /// bar. The only values that can appear here are ones a plugin read from its server.
    let progress: Double?
    let message: String?
    let kind: AcquisitionPluginKind
    let nativeId: String?
    let source: AcquisitionJobSource
    /// Optional per-file breakdown for multi-file downloads.
    let files: [AcquisitionFileProgress]?

    init(
        id: String,
        title: String?,
        artist: String?,
        albumTitle: String? = nil,
        status: AcquisitionJobStatus,
        progress: Double?,
        message: String? = nil,
        kind: AcquisitionPluginKind,
        nativeId: String? = nil,
        source: AcquisitionJobSource = .app,
        files: [AcquisitionFileProgress]? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.status = status
        self.progress = progress
        self.message = message
        self.kind = kind
        self.nativeId = nativeId
        self.source = source
        self.files = files
    }
}

/// A user-entered configuration field, rendered generically by Settings.
struct AcquisitionConfigField: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        case url
        case apiKey
        case username
        case password
        case text
    }

    struct PickerOption: Hashable, Sendable {
        let id: String
        let label: String
    }

    /// Storage suffix (unique within a plugin).
    let id: String
    let kind: Kind
    let label: String
    let placeholder: String
    /// Whether ``AcquisitionProviding/isConfigured`` requires this field.
    let required: Bool
    /// When set, Settings renders a picker instead of a free-text field.
    let pickerOptions: [PickerOption]?

    init(
        id: String,
        kind: Kind,
        label: String,
        placeholder: String,
        required: Bool = true,
        pickerOptions: [PickerOption]? = nil,
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.placeholder = placeholder
        self.required = required
        self.pickerOptions = pickerOptions
    }
}

/// Static description of what a plugin can do, driving UI affordances.
struct AcquisitionCapabilities: Sendable {
    enum Granularity: Sendable {
        case track
        case album
    }

    let displayName: String
    let iconName: String
    let blurb: String
    let granularity: Granularity
    /// True when the plugin can return concrete ``AcquisitionResult`` rows for a query.
    let supportsTrackSearch: Bool
    /// True when the plugin exposes its own calendar / wanted / library catalog
    /// (Lidarr). DroppedNeedle search is request-only and stays false.
    let supportsReleaseCatalog: Bool
    let configFields: [AcquisitionConfigField]

    init(
        displayName: String,
        iconName: String,
        blurb: String,
        granularity: Granularity,
        supportsTrackSearch: Bool,
        supportsReleaseCatalog: Bool = false,
        configFields: [AcquisitionConfigField]
    ) {
        self.displayName = displayName
        self.iconName = iconName
        self.blurb = blurb
        self.granularity = granularity
        self.supportsTrackSearch = supportsTrackSearch
        self.supportsReleaseCatalog = supportsReleaseCatalog
        self.configFields = configFields
    }
}

/// One release from the active acquisition plugin (Lidarr library/calendar, or
/// DroppedNeedle search). Feature code never sees plugin-specific JSON.
struct AcquisitionRelease: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let releaseDate: Date?
    let artworkURL: URL?
    let albumType: String?
    let secondaryTypes: [String]
    let trackCount: Int?
    let releaseGroupMBID: String?
    let artistMBID: String?
    /// Plugin-native album id (Lidarr integer) for track-list fetches.
    let nativeAlbumId: String?
    let overview: String?
    let artistOverview: String?
    let artistArtworkURL: URL?
    let monitored: Bool
    let wanted: Bool

    var releaseYear: Int? {
        guard let releaseDate else { return nil }
        return Calendar(identifier: .gregorian).component(.year, from: releaseDate)
    }

    /// Id passed through ``BrowseAlbumDetailSource`` so the plugin can reload tracks.
    var trackLookupId: String {
        if let nativeAlbumId, !nativeAlbumId.isEmpty { return "native:\(nativeAlbumId)" }
        if let releaseGroupMBID, !releaseGroupMBID.isEmpty { return "mbid:\(releaseGroupMBID)" }
        return id
    }

    var bucket: ArtistDiscographyBucket {
        let type = (albumType ?? "").lowercased()
        let secondary = secondaryTypes.map { $0.lowercased() }
        if secondary.contains(where: { $0.contains("live") }) || type.contains("live") {
            return .live
        }
        if secondary.contains(where: { $0.contains("compilation") })
            || type.contains("compilation")
            || type.contains("broadcast") {
            return .compilations
        }
        if type.contains("ep") || type.contains("single") {
            return .singlesAndEPs
        }
        let title = title.lowercased()
        if title.range(of: #"\blive\b"#, options: .regularExpression) != nil { return .live }
        if title.range(of: #"\bcompilation\b|\bgreatest hits\b|\bbest of\b|\banthology\b"#, options: .regularExpression) != nil {
            return .compilations
        }
        if title.hasSuffix("- single") || title.hasSuffix("- ep") { return .singlesAndEPs }
        if let n = trackCount, n <= 6 { return .singlesAndEPs }
        return .albums
    }

    var acquisitionRequest: AcquisitionRequest {
        AcquisitionRequest(
            artist: artist,
            albumTitle: title,
            artistMBID: artistMBID,
            releaseGroupMBID: releaseGroupMBID,
            coverURL: artworkURL
        )
    }

    /// The release-kind word a search row leads its subtitle with.
    ///
    /// Deliberately not ``bucket``, which folds singles and EPs into one case for discography
    /// grouping. A row that says "Single" is the whole point here: it is what tells the user the
    /// title they searched exists as its own release and can be requested.
    var releaseKindLabel: String {
        switch (albumType ?? "").lowercased() {
        case "single": return "Single"
        case "ep": return "EP"
        default: return "Album"
        }
    }

    /// This release as a requestable Discover search row.
    ///
    /// `albumName` is left empty on purpose: for a release row the album *is* the title, and
    /// ``AcquireResultDetailView``'s metadata line would otherwise print it again directly under
    /// itself. The request is ``acquisitionRequest``, so tapping the row enqueues exactly the
    /// release the row describes.
    var asSearchResult: AcquisitionResult {
        AcquisitionResult(
            id: id,
            title: title,
            artists: artist.isEmpty ? [] : [artist],
            albumName: "",
            coverURL: artworkURL,
            year: releaseYear,
            explicit: false,
            // `subtitle` stays nil and the kind travels separately, so the row can render
            // "Single · <artist>" with the artist as its own tap target.
            subtitle: nil,
            kindLabel: releaseKindLabel,
            request: acquisitionRequest
        )
    }
}

/// Artist metadata the plugin already has (Lidarr overview / images).
struct AcquisitionArtistProfile: Hashable, Sendable {
    let name: String
    let overview: String?
    let artworkURL: URL?
    let genres: [String]
    let mbid: String?
}

/// Off-server artist row from a plugin search (Discover).
struct AcquisitionArtist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let artworkURL: URL?
    let mbid: String?
}

/// The one protocol every acquisition backend implements. Feature code only ever
/// talks to the active provider via ``AcquisitionManager``; concrete plugins are
/// never referenced directly outside of construction.
protocol AcquisitionProviding: Sendable {
    var kind: AcquisitionPluginKind { get }
    var capabilities: AcquisitionCapabilities { get }
    var isConfigured: Bool { get }

    /// Connectivity / auth check. Returns a short success message or an error.
    func validate() async -> Result<String, Error>

    /// Track-search plugins only (gated by ``capabilities``). Default: empty.
    func search(query: String) async throws -> [AcquisitionResult]

    /// Release search for Discover. Album-granularity plugins only. Default: empty.
    ///
    /// The album-level counterpart to ``search(query:)``, which returns *track* rows and is gated
    /// on ``AcquisitionCapabilities/supportsTrackSearch``. Lidarr is album-granularity and has no
    /// track-search endpoint at all, so before this a song-title query could reach nothing but
    /// ``searchArtists(query:)`` — searching a single by its title returned artists and no way to
    /// request the single itself. Plugins with no album catalog inherit the empty default and are
    /// unaffected.
    func searchAlbums(query: String) async -> [AcquisitionRelease]

    /// Kicks off acquisition. Returns the plugin's native id for the new job.
    func enqueue(_ request: AcquisitionRequest) async throws -> String

    /// Snapshot of the plugin's server-side queue/activity, including items started
    /// outside this app. Default: empty.
    func activeJobs() async -> [AcquisitionJob]

    /// Did this request actually land — files on disk, not merely gone from the queue?
    ///
    /// A finished download **disappears** from the queue, and so does a failed one, so vanishing
    /// on its own says nothing. This is the plugin's chance to answer authoritatively for the
    /// native id it handed back from ``enqueue(_:progress:)``. `nil` means "no opinion", which is
    /// the default and leaves the manager to assume the optimistic case.
    func isRequestSatisfied(nativeId: String) async -> Bool?

    /// The whole state of one request, straight from the backend.
    ///
    /// This is the contract that makes the request UI a shell. The manager renders what comes back
    /// and derives nothing of its own; a plugin that returns `nil` keeps the old behaviour, where
    /// state was inferred from the queue snapshot.
    ///
    /// Watching the queue alone is not enough, which is the lesson that produced this method: a
    /// download can finish between two polls, sit beyond the first page of a long queue, or be
    /// handed to a client that never reports a queue row at all — and in each case the request
    /// froze mid-progress for ever, because the app had no other way to ask.
    func requestState(for nativeId: String) async -> AcquisitionBackendState?

    /// Albums the plugin already knows for this artist (Lidarr library, or DN search).
    func artistReleases(named name: String) async -> [AcquisitionRelease]

    /// Calendar + wanted/missing window. Empty when the plugin has no catalog.
    func upcomingAndWanted(since: Date, until: Date) async -> [AcquisitionRelease]

    /// Overview / art the plugin already stores for this artist.
    func artistProfile(named name: String) async -> AcquisitionArtistProfile?

    /// Artist search for Discover (not iTunes).
    func searchArtists(query: String) async -> [AcquisitionArtist]

    /// Tracklist for an off-server release the plugin listed.
    func tracks(forRelease release: AcquisitionRelease) async -> [BrowseAlbumPreviewTrack]

    /// Resolve a tracklist by artist + album title (library album "complete album" rows).
    func tracks(artist: String, albumTitle: String) async -> [BrowseAlbumPreviewTrack]
}

extension AcquisitionProviding {
    func search(query: String) async throws -> [AcquisitionResult] { [] }
    func searchAlbums(query: String) async -> [AcquisitionRelease] { [] }
    func activeJobs() async -> [AcquisitionJob] { [] }
    func isRequestSatisfied(nativeId: String) async -> Bool? { nil }
    func requestState(for nativeId: String) async -> AcquisitionBackendState? { nil }
    /// Whether the active plugin's catalog (Lidarr → MusicBrainz) knows this artist.
    func canRequestArtist(named name: String) async -> Bool { true }
    func artistReleases(named name: String) async -> [AcquisitionRelease] { [] }
    func upcomingAndWanted(since: Date, until: Date) async -> [AcquisitionRelease] { [] }
    func artistProfile(named name: String) async -> AcquisitionArtistProfile? { nil }
    func searchArtists(query: String) async -> [AcquisitionArtist] { [] }
    func tracks(forRelease release: AcquisitionRelease) async -> [BrowseAlbumPreviewTrack] { [] }
    func tracks(artist: String, albumTitle: String) async -> [BrowseAlbumPreviewTrack] { [] }
}

/// Generic LocalizedError carrying a user-facing message.
struct AcquisitionError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Config storage

/// Per-plugin credential storage in `UserDefaults`, keyed so switching the active
/// plugin and back preserves what the user entered.
enum AcquisitionConfigStore {
    private static func key(_ kind: AcquisitionPluginKind, _ fieldId: String) -> String {
        "acquisition.\(kind.rawValue).\(fieldId)"
    }

    static func value(_ kind: AcquisitionPluginKind, _ fieldId: String) -> String {
        let raw = UserDefaults.standard.string(forKey: key(kind, fieldId)) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func set(_ value: String, _ kind: AcquisitionPluginKind, _ fieldId: String) {
        UserDefaults.standard.set(
            value.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: key(kind, fieldId)
        )
    }

    static func clear(_ kind: AcquisitionPluginKind, fields: [AcquisitionConfigField]) {
        for field in fields {
            UserDefaults.standard.removeObject(forKey: key(kind, field.id))
        }
    }
}

// MARK: - Shared HTTP helpers for REST plugins (Lidarr, …)

enum AcquisitionHTTP {
    /// Normalizes a user-entered base URL: adds `http://` when no scheme, drops a trailing slash.
    static func normalizedBase(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        return withScheme.hasSuffix("/") ? String(withScheme.dropLast()) : withScheme
    }

    /// Performs a request and returns the decoded JSON object plus status code.
    /// Throws ``AcquisitionError`` for transport failures and non-2xx responses.
    @discardableResult
    static func requestJSON(
        base: String,
        path: String,
        query: [String: String] = [:],
        method: String = "GET",
        headers: [String: String] = [:],
        jsonBody: Any? = nil
    ) async throws -> Any {
        guard let normalized = normalizedBase(base),
              var comps = URLComponents(string: normalized + path)
        else { throw AcquisitionError("Invalid server URL.") }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw AcquisitionError("Invalid request URL.") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.vellum.data(for: req)
        } catch {
            throw AcquisitionError(userFacingMessage(for: error))
        }
        guard let http = resp as? HTTPURLResponse else { throw AcquisitionError("Invalid response.") }
        guard (200 ..< 300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw AcquisitionError(snippet.isEmpty ? "Request failed (HTTP \(http.statusCode))." : snippet)
        }
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    static func userFacingMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "Can't reach the server. Use a URL that resolves on this device (LAN IP, Tailscale, etc.)."
            case NSURLErrorCannotConnectToHost:
                return "Connection refused. Check the server is running and the port is correct."
            case NSURLErrorTimedOut:
                return "The server timed out. Check your network or server load."
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate:
                return "HTTPS certificate problem. Try http:// on your LAN or trust the cert on device."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let d = value as? Date { return d }
        guard let raw = string(value), !raw.isEmpty else { return nil }
        if let iso = iso8601.date(from: raw) { return iso }
        if let isoFrac = iso8601Fractional.date(from: raw) { return isoFrac }
        if raw.count >= 10 {
            let day = String(raw.prefix(10))
            return ymd.date(from: day)
        }
        return nil
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
