import Foundation

/// Terminal + in-flight states a Downtify `/api/queue` entry can report.
enum DowntifyJobStatus: String, Sendable {
    case queued
    case downloading
    case done
    case failed
    case unknown

    /// Maps Downtify's free-form status strings onto our cases.
    init(downtifyRaw raw: String) {
        switch raw.lowercased() {
        case "queued", "pending", "waiting", "enqueued": self = .queued
        case "downloading", "in_progress", "running", "processing", "active": self = .downloading
        case "done", "completed", "complete", "finished", "success", "succeeded": self = .done
        case "failed", "error", "errored", "cancelled", "canceled": self = .failed
        default: self = .unknown
        }
    }

    var isTerminal: Bool { self == .done || self == .failed }
}

/// One `/api/queue` entry. Decodes defensively because Downtify's payload keys
/// and value types vary across versions.
struct DowntifyJob: Decodable, Sendable, Identifiable, Hashable {
    /// Stable identity for SwiftUI; the submitted URL is the cross-reference key the manager uses.
    var id: String { url.isEmpty ? (filename ?? title ?? UUID().uuidString) : url }
    let url: String
    let title: String?
    let artist: String?
    let filename: String?
    let message: String?
    let status: DowntifyJobStatus
    /// Normalized to 0...1 (server may emit 0–100 or 0–1).
    let progress: Double

    private enum CodingKeys: String, CodingKey {
        case song
        case url, youtube_url, source_url, link
        case title, name, song_name
        case artist, artists, uploader
        case filename, file, output
        case message, error, status_message
        case status, state
        case progress, percent, percentage
    }

    /// Per Downtify's `/api/queue` + WebSocket payload, each entry nests track
    /// metadata under a `song` object while status/progress/message/filename
    /// stay at the top level. We descend into `song` for the metadata fields and
    /// fall back to the top-level legacy keys so older Downtify builds still parse.
    private enum SongCodingKeys: String, CodingKey {
        case song_id
        case url, youtube_url, source_url, link
        case name, song_name, title
        case artists, artist, uploader
        case album_name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let songContainer = try? c.nestedContainer(keyedBy: SongCodingKeys.self, forKey: .song)

        func firstNestedString(_ keys: [SongCodingKeys]) -> String? {
            guard let songContainer else { return nil }
            for k in keys {
                if let s = try? songContainer.decodeIfPresent(String.self, forKey: k), !s.isEmpty {
                    return s
                }
            }
            return nil
        }

        func firstTopString(_ keys: [CodingKeys]) -> String? {
            for k in keys {
                if let s = try? c.decodeIfPresent(String.self, forKey: k), !s.isEmpty { return s }
            }
            return nil
        }

        url = firstNestedString([.url, .youtube_url, .source_url, .link])
            ?? firstTopString([.url, .youtube_url, .source_url, .link])
            ?? ""
        title = firstNestedString([.name, .song_name, .title])
            ?? firstTopString([.title, .name, .song_name])
        if let arr = try? songContainer?.decodeIfPresent([String].self, forKey: .artists), !arr.isEmpty {
            artist = arr.joined(separator: ", ")
        } else if let arr = try? c.decodeIfPresent([String].self, forKey: .artists), !arr.isEmpty {
            artist = arr.joined(separator: ", ")
        } else {
            artist = firstNestedString([.artist, .uploader])
                ?? firstTopString([.artist, .uploader])
        }
        filename = firstTopString([.filename, .file, .output])
        message = firstTopString([.message, .error, .status_message])

        let rawStatus = firstTopString([.status, .state]) ?? ""
        status = DowntifyJobStatus(downtifyRaw: rawStatus)

        var rawProgress: Double = 0
        for k in [CodingKeys.progress, .percent, .percentage] {
            if let d = try? c.decodeIfPresent(Double.self, forKey: k) { rawProgress = d; break }
            if let i = try? c.decodeIfPresent(Int.self, forKey: k) { rawProgress = Double(i); break }
            if let s = try? c.decodeIfPresent(String.self, forKey: k), let d = Double(s) { rawProgress = d; break }
        }
        progress = min(1, max(0, rawProgress > 1 ? rawProgress / 100.0 : rawProgress))
    }

    init(optimisticURL: String, title: String?, artist: String?) {
        self.url = optimisticURL
        self.title = title
        self.artist = artist
        self.filename = nil
        self.message = nil
        self.status = .queued
        self.progress = 0
    }

    init(forcedURL url: String, title: String?, artist: String?, filename: String?,
         message: String?, status: DowntifyJobStatus, progress: Double) {
        self.url = url
        self.title = title
        self.artist = artist
        self.filename = filename
        self.message = message
        self.status = status
        self.progress = progress
    }
}

typealias DowntifySong = MatchableSong

/// Who to sign in to Downtify as. Downtify 3 has accounts: every API call except a few public
/// ones needs a signed-in user, and a browser-style sign-in (`POST /api/auth/login`, answered with
/// a `downtify_session` cookie) is the one a client holding a username and password can use.
/// Empty only for a server with accounts turned off (`DOWNTIFY_DISABLE_AUTH`), or an old one.
struct DowntifyCredentials: Sendable, Equatable {
    var username: String
    var password: String

    var isEmpty: Bool { username.isEmpty || password.isEmpty }
}

/// What `GET /api/server/info` says about the server, before signing in.
struct DowntifyServerInfo: Sendable, Equatable {
    var product: String
    var version: String?
    var requiresSignIn: Bool
}

enum DowntifyClient {
    /// Report approximate progress while this client talks to your Downtify server (search → enqueue).
    typealias DownloadProgressHandler = @Sendable (Double) -> Void

    /// Searches Downtify, picks the best match, and triggers a download. Returns the matched song name.
    @discardableResult
    static func download(
        artist: String,
        title: String,
        base: String,
        credentials: DowntifyCredentials,
        progress: DownloadProgressHandler? = nil
    ) async throws -> String {
        progress?(0.04)
        let songs = try await search(base: base, credentials: credentials, query: "\(artist) \(title)")
        progress?(0.52)
        guard let best = pickBest(from: songs, artist: artist, title: title) else {
            throw DowntifyError("No results found for \"\(title)\" by \(artist).")
        }

        progress?(0.62)
        try await triggerDownload(base: base, credentials: credentials, youtubeURL: best.url)
        progress?(1.0)
        return best.name
    }

    /// Enqueue a known song URL against an explicit base (used by the acquisition plugin).
    @discardableResult
    static func enqueue(base: String, credentials: DowntifyCredentials, url: String) async throws -> String {
        try await triggerDownload(base: base, credentials: credentials, youtubeURL: url)
    }

    /// Queue snapshot against an explicit base (used by the acquisition plugin). Throws when the
    /// queue cannot be read, so the caller can tell a refused read from an empty queue.
    static func queue(base: String, credentials: DowntifyCredentials) async throws -> [DowntifyJob] {
        let (data, status) = try await send(base: base, credentials: credentials, path: "/api/queue")
        guard status == 200 else { throw failure(status: status, action: "read the Downtify queue") }
        if let arr = try? JSONDecoder().decode([DowntifyJob].self, from: data) {
            return arr
        }
        struct Wrapper: Decodable {
            let queue: [DowntifyJob]?
            let items: [DowntifyJob]?
            let jobs: [DowntifyJob]?
            let songs: [DowntifyJob]?
        }
        if let w = try? JSONDecoder().decode(Wrapper.self, from: data) {
            return w.queue ?? w.items ?? w.jobs ?? w.songs ?? []
        }
        return []
    }

    static func search(base: String, credentials: DowntifyCredentials, query: String) async throws -> [DowntifySong] {
        let (data, status) = try await send(base: base, credentials: credentials, path: "/api/songs/search", query: ["query": query])
        guard status == 200 else { throw failure(status: status, action: "search Downtify") }
        return try JSONDecoder().decode([DowntifySong].self, from: data)
    }

    static func pickBest(from songs: [DowntifySong], artist: String, title: String) -> DowntifySong? {
        let t = title.lowercased()
        let a = artist.lowercased()

        let artistMatch = { (s: DowntifySong) in
            s.artists.contains { $0.lowercased().contains(a) || a.contains($0.lowercased()) }
        }

        if let s = songs.first(where: { $0.name.lowercased() == t && artistMatch($0) }) { return s }
        if let s = songs.first(where: { $0.name.lowercased().contains(t) && artistMatch($0) }) { return s }
        if let s = songs.first(where: { artistMatch($0) }) { return s }
        return songs.first
    }

    // MARK: Connection check

    /// The public `GET /api/server/info`. `nil` means the server has no such route: a Downtify
    /// from before accounts existed.
    static func serverInfo(base: String) async throws -> DowntifyServerInfo? {
        let (data, status) = try await request(base: base, path: "/api/server/info", cookie: nil)
        if status == 404 { return nil }
        guard status == 200 else { throw failure(status: status, action: "reach Downtify") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let product = AcquisitionHTTP.string(json["product"])
        else {
            throw DowntifyError("That address answered, but not as Downtify. Check the Server Address and port.")
        }
        return DowntifyServerInfo(
            product: product,
            version: AcquisitionHTTP.string(json["version"]),
            requiresSignIn: AcquisitionHTTP.bool(json["require_sign_in"]) ?? true
        )
    }

    /// Signs in and asks the server who it thinks this session is. Returns the username.
    static func verifySignIn(base: String, credentials: DowntifyCredentials) async throws -> String {
        let cookie = try await signIn(base: base, credentials: credentials)
        let (data, status) = try await request(base: base, path: "/api/auth/status", cookie: cookie)
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              AcquisitionHTTP.bool(json["signed_in"]) == true
        else {
            throw DowntifyError("Downtify accepted the sign-in but didn't keep the session. Try again.")
        }
        let user = (json["user"] as? [String: Any]).flatMap { AcquisitionHTTP.string($0["username"]) }
        return user ?? credentials.username
    }

    // MARK: Transport

    @discardableResult
    private static func triggerDownload(base: String, credentials: DowntifyCredentials, youtubeURL: String) async throws -> String {
        let (_, status) = try await send(
            base: base,
            credentials: credentials,
            path: "/api/download/url",
            query: ["url": youtubeURL, "client_id": UUID().uuidString.lowercased()],
            method: "POST"
        )
        guard (200 ..< 300).contains(status) else {
            throw failure(status: status, action: "start the download")
        }
        return youtubeURL
    }

    /// An API call as the signed-in user: reuses the session cookie, signs in when there is none
    /// yet or the server says it expired (401), and retries once.
    private static func send(
        base: String,
        credentials: DowntifyCredentials,
        path: String,
        query: [String: String] = [:],
        method: String = "GET"
    ) async throws -> (Data, Int) {
        guard !credentials.isEmpty else {
            return try await request(base: base, path: path, query: query, method: method, cookie: nil)
        }
        if let cookie = DowntifySessionCache.cookie(base: base, username: credentials.username) {
            let first = try await request(base: base, path: path, query: query, method: method, cookie: cookie)
            guard first.1 == 401 else { return first }
            DowntifySessionCache.clear(base: base, username: credentials.username)
        }
        let cookie = try await signIn(base: base, credentials: credentials)
        return try await request(base: base, path: path, query: query, method: method, cookie: cookie)
    }

    /// `POST /api/auth/login`. Returns the `Cookie` header value for the new session.
    private static func signIn(base: String, credentials: DowntifyCredentials) async throws -> String {
        guard !credentials.isEmpty else {
            throw DowntifyError("This Downtify server needs a sign-in. Enter the username and password you use for Downtify.", statusCode: 401)
        }
        let body = try JSONSerialization.data(withJSONObject: ["username": credentials.username, "password": credentials.password])
        let (_, status, response) = try await rawRequest(
            base: base, path: "/api/auth/login", query: [:], method: "POST", cookie: nil, jsonBody: body
        )
        switch status {
        case 200 ..< 300:
            break
        case 401, 403:
            throw DowntifyError("Downtify rejected the username or password.", statusCode: status)
        case 409:
            throw DowntifyError("Accounts are turned off on this Downtify server. Leave the username and password empty.", statusCode: status)
        case 429:
            throw DowntifyError("Too many failed Downtify sign-ins. Wait a few minutes and try again.", statusCode: status)
        default:
            throw failure(status: status, action: "sign in to Downtify")
        }
        let headers = (response?.allHeaderFields as? [String: String]) ?? [:]
        let url = response?.url ?? URL(string: "http://downtify.invalid")!
        guard let session = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
            .first(where: { $0.name == "downtify_session" })
        else {
            throw DowntifyError("Downtify accepted the sign-in but sent no session. Check the server version.")
        }
        let cookie = "\(session.name)=\(session.value)"
        DowntifySessionCache.store(cookie, base: base, username: credentials.username)
        return cookie
    }

    private static func request(
        base: String,
        path: String,
        query: [String: String] = [:],
        method: String = "GET",
        cookie: String?
    ) async throws -> (Data, Int) {
        let (data, status, _) = try await rawRequest(base: base, path: path, query: query, method: method, cookie: cookie, jsonBody: nil)
        return (data, status)
    }

    private static func rawRequest(
        base: String,
        path: String,
        query: [String: String],
        method: String,
        cookie: String?,
        jsonBody: Data?
    ) async throws -> (Data, Int, HTTPURLResponse?) {
        guard let normalized = AcquisitionHTTP.normalizedBase(base),
              var comps = URLComponents(string: normalized + path)
        else { throw DowntifyError("Invalid Downtify URL in Settings.") }
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw DowntifyError("Invalid URL.") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        // The session is carried by hand so it is per-server and per-account, not whatever the
        // shared cookie jar last saw.
        req.httpShouldHandleCookies = false
        if let cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = jsonBody
        }
        do {
            let (data, resp) = try await AcquisitionHTTP.session.data(for: req)
            let http = resp as? HTTPURLResponse
            return (data, http?.statusCode ?? 0, http)
        } catch {
            throw DowntifyError(AcquisitionHTTP.userFacingMessage(for: error))
        }
    }

    private static func failure(status: Int, action: String) -> DowntifyError {
        switch status {
        case 401:
            return DowntifyError("Downtify needs a sign-in to \(action). Check the username and password in Settings.", statusCode: status)
        case 403:
            return DowntifyError("Downtify refused to \(action) for this account.", statusCode: status)
        default:
            return DowntifyError("Couldn't \(action) (HTTP \(status)).", statusCode: status)
        }
    }
}

/// Downtify session cookies, keyed by (server, account). Plugins are recreated often via
/// ``AcquisitionManager/makeProvider``, so the session lives here, in memory only.
private enum DowntifySessionCache {
    private static let lock = NSLock()
    private static var cookies: [String: String] = [:]

    private static func key(base: String, username: String) -> String {
        "\(AcquisitionHTTP.normalizedBase(base) ?? base)|\(username.lowercased())"
    }

    static func cookie(base: String, username: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cookies[key(base: base, username: username)]
    }

    static func store(_ cookie: String, base: String, username: String) {
        lock.lock(); defer { lock.unlock() }
        cookies[key(base: base, username: username)] = cookie
    }

    static func clear(base: String, username: String) {
        lock.lock(); defer { lock.unlock() }
        cookies.removeValue(forKey: key(base: base, username: username))
    }
}

private struct DowntifyError: LocalizedError {
    let errorDescription: String?
    let statusCode: Int?
    init(_ msg: String, statusCode: Int? = nil) {
        errorDescription = msg
        self.statusCode = statusCode
    }
}
