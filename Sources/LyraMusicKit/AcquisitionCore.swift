import Foundation

/// Progress callback shared by every acquisition plugin (0...1).
typealias AcquisitionProgress = @Sendable (Double) -> Void

/// The selectable acquisition backends. Only one is active at a time
/// (`AcquisitionManager.activePlugin`); every request flows through the active one.
enum AcquisitionPluginKind: String, CaseIterable, Identifiable, Sendable {
    case lidarr

    var id: String { rawValue }
}

/// Where a displayed job came from: a request this app issued, or the plugin's
/// own server-side queue (so Settings can surface activity started elsewhere).
enum AcquisitionJobSource: Sendable {
    case app
    case server
}

/// Normalized lifecycle for a request across every plugin.
enum AcquisitionJobStatus: String, Sendable {
    case queued
    case searching
    case downloading
    case importing
    case done
    case failed
    case unknown

    var isTerminal: Bool { self == .done || self == .failed }
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
    /// Optional secondary line (format/quality/source hint).
    let subtitle: String?
    let request: AcquisitionRequest

    var artistLine: String { artists.joined(separator: ", ") }
}

/// Per-file progress inside a multi-file acquisition.
struct AcquisitionFileProgress: Identifiable, Hashable, Sendable {
    var id: String
    let title: String
    let status: AcquisitionJobStatus
    let progress: Double
    /// Optional secondary line (bytes, speed, queue position).
    let detail: String?
}

/// One row in the unified queue/activity surface.
struct AcquisitionJob: Identifiable, Hashable, Sendable {
    var id: String
    let title: String?
    let artist: String?
    let albumTitle: String?
    let status: AcquisitionJobStatus
    let progress: Double
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
        progress: Double,
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

    /// Storage suffix (unique within a plugin).
    let id: String
    let kind: Kind
    let label: String
    let placeholder: String
    /// Whether ``AcquisitionProviding/isConfigured`` requires this field.
    let required: Bool

    init(id: String, kind: Kind, label: String, placeholder: String, required: Bool = true) {
        self.id = id
        self.kind = kind
        self.label = label
        self.placeholder = placeholder
        self.required = required
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
    let configFields: [AcquisitionConfigField]
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

    /// Kicks off acquisition. Returns the plugin's native id for the new job.
    func enqueue(_ request: AcquisitionRequest, progress: AcquisitionProgress?) async throws -> String

    /// Snapshot of the plugin's server-side queue/activity, including items started
    /// outside this app. Default: empty.
    func activeJobs() async -> [AcquisitionJob]
}

extension AcquisitionProviding {
    func search(query: String) async throws -> [AcquisitionResult] { [] }
    func activeJobs() async -> [AcquisitionJob] { [] }
    /// Whether the active plugin's catalog (Lidarr → MusicBrainz) knows this artist.
    func canRequestArtist(named name: String) async -> Bool { true }
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
            (data, resp) = try await URLSession.lyra.data(for: req)
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
}
