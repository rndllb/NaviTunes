import Foundation

enum JellyfinClientError: LocalizedError {
    case badResponse(status: Int, message: String)
    case unexpectedPayload

    var errorDescription: String? {
        switch self {
        case .badResponse(let status, let message):
            return "Jellyfin request failed (HTTP \(status)): \(message)"
        case .unexpectedPayload:
            return "Jellyfin returned an unexpected response (missing token or user)."
        }
    }
}

final class JellyfinMusicClient: MusicLibraryProviding {
    private static let clientName = "LyraMusic"
    private static let deviceName = "LyraMusic"
    private static let version = "0.1"
    private static let deviceIdDefaultsKey = "com.randll.lyra.jellyfin.deviceId"

    private static let jellyfinISOFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let jellyfinISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Genres and release year are omitted unless `Fields` asks for them.
    private static let jellyfinAlbumListFields =
        "Genres,GenreItems,Genre,ProductionYear,PremiereDate,ChildCount,DateCreated,ImageTags,Name"

    /// Sample rate / codec / channels for album hero subtitles.
    private static let jellyfinAudioItemFields =
        "MediaStreams,Genres,GenreItems,Genre,ProductionYear,PremiereDate,AlbumArtist,Album,ArtistItems,ImageTags,RunTimeTicks,ParentIndexNumber,IndexNumber,Name,DateCreated,AlbumId,ParentId"

    private(set) var baseURL: URL
    private var accessToken: String = ""
    private var userId: String = ""
    /// From authenticate response; improves caching when requesting ``accountPrimaryImageURL()``.
    private var primaryImageTag: String?
    /// From ``User.Policy`` in the authenticate response (`IsAdministrator`).
    private(set) var isLibraryAdmin: Bool = false
    /// From ``User.Policy``: Jellyfin allows ``DELETE /Items/{id}`` only when `EnableContentDeletion` is true or a folder allow-list is set — **not** implied by ``IsAdministrator``.
    private(set) var canDeleteLibraryMedia: Bool = false

    /// Optional cap (bits/sec) applied to progressive streams when ``AppModel`` chooses a capped tier; nil = leave server defaults (original).
    var streamingBitrateCapBps: Int?
    /// Optional cap for offline save URLs (transcoded MP3 / FLAC paths).
    var offlineBitrateCapBps: Int?
    /// User-selected streaming format; nil container means follow track codec.
    var streamingFormat: StreamFormatOption = .raw
    var offlineFormat: DownloadFormatOption = .mp3

    var displayName: String { "Jellyfin" }

    /// Stable per-install id (Jellyfin ties sessions to DeviceId).
    private static var stableDeviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdDefaultsKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIdDefaultsKey)
        return id
    }

    /// Jellyfin 10.10+ expects the **Authorization** `MediaBrowser` scheme (not legacy
    /// `X-Emby-Authorization: Emby …`), otherwise the server throws `request.App` null → HTTP 400.
    /// See: https://gist.githubusercontent.com/nielsvanvelzen/ea047d9028f676185832e51ffaf12a6f/raw
    private static func authorizationClientOnly() -> String {
        let d = stableDeviceId.replacingOccurrences(of: "\"", with: "")
        return
            "MediaBrowser Client=\"\(clientName)\", Device=\"\(deviceName)\", DeviceId=\"\(d)\", Version=\"\(version)\""
    }

    private static func authorizationWithToken(_ token: String) -> String {
        let d = stableDeviceId.replacingOccurrences(of: "\"", with: "")
        return
            "MediaBrowser Token=\"\(token)\", Client=\"\(clientName)\", Device=\"\(deviceName)\", DeviceId=\"\(d)\", Version=\"\(version)\""
    }

    init(baseURL: URL) {
        self.baseURL = Self.normalizeBaseURL(baseURL)
    }

    func updateBaseURL(_ url: URL) {
        baseURL = Self.normalizeBaseURL(url)
    }

    /// Restores a prior sign-in from the keychain so the app can browse cached library offline.
    func applyRestoredSession(accessToken: String, userId: String) {
        self.accessToken = accessToken
        self.userId = userId
    }

    var sessionAccessToken: String { accessToken }
    var sessionUserId: String { userId }

    /// Users often paste the web UI URL (`…/web` or `…/web/`). Jellyfin API lives one segment above `/web`.
    private static func normalizeBaseURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var path = components.path
        while path.hasSuffix("/"), path.count > 1 {
            path.removeLast()
        }
        if path.hasSuffix("/web") {
            path.removeLast(4)
        }
        while path.hasSuffix("/"), path.count > 1 {
            path.removeLast()
        }
        if path.isEmpty { path = "/" }
        components.path = path
        return components.url ?? url
    }

    /// Jellyfin paths must be built one component at a time. A single
    /// `appendingPathComponent("Users/AuthenticateByName")` encodes `/` as `%2F`
    /// and breaks routing (often HTTP 400).
    private func apiURL(_ components: String...) -> URL {
        components.reduce(baseURL) { $0.appendingPathComponent($1) }
    }

    func signIn(username: String, password: String) async throws {
        let authURL = apiURL("Users", "AuthenticateByName")
        var comps = URLComponents(url: authURL, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "format", value: "json"))
        comps?.queryItems = items
        guard let url = comps?.url else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.authorizationClientOnly(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "Username": username,
            "Pw": password,
        ])

        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode != 200 {
            let snippet = Self.humanReadableError(from: data) ?? String(data: data, encoding: .utf8) ?? ""
            let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = trimmed.isEmpty ? "(empty body)" : trimmed
            throw JellyfinClientError.badResponse(status: http.statusCode, message: message)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard
            let token =
                (json?["AccessToken"] as? String)
                ?? (json?["accessToken"] as? String),
            let user =
                (json?["User"] as? [String: Any])
                ?? (json?["user"] as? [String: Any]),
            let id =
                (user["Id"] as? String)
                ?? (user["id"] as? String)
        else {
            throw JellyfinClientError.unexpectedPayload
        }
        accessToken = token
        userId = id
        primaryImageTag =
            (user["PrimaryImageTag"] as? String)
            ?? (user["primaryImageTag"] as? String)
        applyPolicy(fromUserDict: user)
        await refreshLibraryDeletionCapabilityFromUserEndpoint()
    }

    /// Lightweight reachability check (session GET or public ping).
    func verifyServerReachable() async throws {
        if !userId.isEmpty, !accessToken.isEmpty {
            let url = apiURL("Users", userId)
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            applyAuth(&req)
            let (_, res) = try await URLSession.lyra.data(for: req)
            guard let http = res as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                throw URLError(.cannotConnectToHost)
            }
            return
        }
        let url = apiURL("System", "Ping")
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.cannotConnectToHost)
        }
    }

    /// Distinguishes "token rejected" (401/403) from "server unreachable".
    /// Used at cold launch so we can avoid re-POSTing the password when the restored
    /// session is still healthy. When there is no restored token, returns `.authRejected`
    /// to force sign-in.
    func probeAuthStatus() async -> ServerReachabilityProbe {
        guard !userId.isEmpty, !accessToken.isEmpty else { return .authRejected }
        let url = apiURL("Users", userId)
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        applyAuth(&req)
        do {
            let (_, res) = try await URLSession.lyra.data(for: req)
            guard let http = res as? HTTPURLResponse else { return .unreachable }
            if http.statusCode == 401 || http.statusCode == 403 { return .authRejected }
            return (200 ..< 300).contains(http.statusCode) ? .ok : .unreachable
        } catch {
            return .unreachable
        }
    }

    /// Re-reads ``UserDto/Policy`` from ``GET /Users/{userId}`` (same source as the dashboard).
    private func refreshLibraryDeletionCapabilityFromUserEndpoint() async {
        guard !userId.isEmpty, !accessToken.isEmpty else { return }
        let url = apiURL("Users", userId)
        var req = URLRequest(url: url)
        applyAuth(&req)
        do {
            let (data, res) = try await URLSession.lyra.data(for: req)
            guard let http = res as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let remote = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            applyPolicy(fromUserDict: remote)
        } catch {}
    }

    private func applyPolicy(fromUserDict user: [String: Any]) {
        guard let policy = Self.policyDict(fromUser: user) else {
            isLibraryAdmin = false
            canDeleteLibraryMedia = false
            return
        }
        isLibraryAdmin =
            Self.jellyfinBool(policy["IsAdministrator"]) || Self.jellyfinBool(policy["isAdministrator"])
        canDeleteLibraryMedia = Self.policyAllowsDeletingLibraryMedia(policy)
    }

    private static func policyDict(fromUser user: [String: Any]) -> [String: Any]? {
        if let p = user["Policy"] as? [String: Any] { return p }
        if let p = user["policy"] as? [String: Any] { return p }
        return nil
    }

    private static func jellyfinBool(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t == "true" || t == "1" || t == "yes"
        }
        return false
    }

    /// Mirrors Jellyfin ``BaseItem.CanDelete(User)`` authorization (global flag or per-folder GUID allow-list).
    private static func policyAllowsDeletingLibraryMedia(_ policy: [String: Any]) -> Bool {
        if jellyfinBool(policy["EnableContentDeletion"]) || jellyfinBool(policy["enableContentDeletion"]) {
            return true
        }
        let folders =
            (policy["EnableContentDeletionFromFolders"] as? [Any])
            ?? (policy["enableContentDeletionFromFolders"] as? [Any])
        guard let folders else {
            return false
        }
        return folders.contains { entry in
            let raw: String? =
                (entry as? String)
                ?? (entry as? NSNumber).map { $0.stringValue }
            guard let raw else { return false }
            return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Signed-in user profile picture (``ApiKey`` query auth for ``AsyncImage``). Nil when not signed in.
    func accountPrimaryImageURL(maxWidth: Int = 192) -> URL? {
        guard !userId.isEmpty, !accessToken.isEmpty else { return nil }
        let base = apiURL("Users", userId, "Images", "Primary")
        var extras: [URLQueryItem] = [
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)"),
            URLQueryItem(name: "quality", value: "88"),
        ]
        if let tag = primaryImageTag, !tag.isEmpty {
            extras.append(URLQueryItem(name: "tag", value: tag))
        }
        return mediaURLWithQueryAuth(base, extraQuery: extras)
    }

    private static func humanReadableError(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let msg = obj["Message"] as? String { return msg }
        if let title = obj["title"] as? String { return title }
        if let detail = obj["detail"] as? String { return detail }
        if let err = obj["error"] as? String { return err }
        return nil
    }

    func httpHeadersForMediaRequests() -> [String: String] {
        [
            "Authorization": Self.authorizationWithToken(accessToken),
            "User-Agent": "LyraMusic/0.1",
        ]
    }

    func albums(limit: Int) async throws -> [AlbumSummary] {
        try await fetchAlbumSummaries(limit: limit, sortBy: "SortName", sortDescending: false)
    }

    func recentlyAdded(limit: Int) async throws -> [AlbumSummary] {
        try await fetchAlbumSummaries(limit: limit, sortBy: "DateCreated", sortDescending: true)
    }

    func recentlyPlayed(limit: Int) async throws -> [AlbumSummary] {
        try await fetchAlbumSummaries(limit: limit, sortBy: "DatePlayed", sortDescending: true)
    }

    private func fetchAlbumSummaries(limit: Int, sortBy: String, sortDescending: Bool) async throws -> [AlbumSummary] {
        let itemsURL = apiURL("Users", userId, "Items")
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortDescending ? "Descending" : "Ascending"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.jellyfinAlbumListFields),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, _) = try await URLSession.lyra.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        return items.compactMap(parseAlbum)
    }

    func libraryArtists(limit: Int) async throws -> [LibraryArtistSummary] {
        let cap = max(1, min(limit, 15_000))
        guard !userId.isEmpty, !accessToken.isEmpty else {
            throw JellyfinClientError.unexpectedPayload
        }
        var comps = URLComponents(url: apiURL("Artists", "AlbumArtists"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Limit", value: "\(cap)"),
            URLQueryItem(name: "Fields", value: "ImageTags"),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = json?["Items"] as? [[String: Any]] ?? []
        return rows.compactMap(parseLibraryArtist)
    }

    func libraryGenres(limit: Int) async throws -> [LibraryGenreSummary] {
        let cap = max(1, min(limit, 5000))
        guard !userId.isEmpty, !accessToken.isEmpty else {
            throw JellyfinClientError.unexpectedPayload
        }
        let derived = try await libraryGenresDerivedFromAlbumTags(limitAlbums: min(15_000, max(cap * 80, 500)))
            .filter(\.hasAlbums)
        if !derived.isEmpty {
            return Array(derived.prefix(cap))
        }
        if let fromAPI = try await jellyfinMusicGenresFromAPI(limit: cap), !fromAPI.isEmpty {
            return fromAPI
        }
        return try await libraryGenresDerivedFromAlbumTags(limitAlbums: min(10_000, max(cap * 60, 500)))
            .filter(\.hasAlbums)
            .prefix(cap)
            .map { $0 }
    }

    func browseGenreCategories(limit: Int) async throws -> [LibraryGenreSummary] {
        let cap = max(1, min(limit, 500))
        guard !userId.isEmpty, !accessToken.isEmpty else {
            throw JellyfinClientError.unexpectedPayload
        }
        if let fromAPI = try await jellyfinMusicGenresFromAPI(limit: cap), !fromAPI.isEmpty {
            return fromAPI
        }
        let derived = try await libraryGenresDerivedFromAlbumTags(limitAlbums: min(600, max(cap * 8, 200)))
            .filter(\.hasAlbums)
        return Array(derived.prefix(cap))
    }

    private func jellyfinMusicGenresFromAPI(limit: Int) async throws -> [LibraryGenreSummary]? {
        var comps = URLComponents(url: apiURL("Genres"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = json?["Items"] as? [[String: Any]] ?? []
        let parsed = rows.compactMap(parseLibraryGenre).filter(\.hasAlbums)
        guard !parsed.isEmpty else { return nil }
        return Array(parsed.prefix(limit))
    }

    func albums(forLibraryArtistId artistId: String, limit: Int) async throws -> [AlbumSummary] {
        let cap = max(1, min(limit, 5000))
        let itemsURL = apiURL("Users", userId, "Items")
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "ArtistIds", value: artistId),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Limit", value: "\(cap)"),
            URLQueryItem(name: "Fields", value: Self.jellyfinAlbumListFields),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, _) = try await URLSession.lyra.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        return items.compactMap(parseAlbum)
    }

    func tracks(forLibraryArtistId artistId: String, limit: Int) async throws -> [Track] {
        let cap = max(1, min(limit, 15_000))
        let itemsURL = apiURL("Users", userId, "Items")
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "ArtistIds", value: artistId),
            URLQueryItem(name: "SortBy", value: "AlbumArtist,Album,ParentIndexNumber,IndexNumber"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Limit", value: "\(cap)"),
            URLQueryItem(name: "Fields", value: Self.jellyfinAudioItemFields),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, _) = try await URLSession.lyra.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        return items.compactMap { dict -> Track? in
            let albumId =
                (dict["AlbumId"] as? String)
                    ?? (dict["ParentId"] as? String)
                    ?? ""
            guard !albumId.isEmpty else { return nil }
            return parseTrack(dict: dict, albumId: albumId)
        }
    }

    func albums(inGenre genre: LibraryGenreSummary, limit: Int) async throws -> [AlbumSummary] {
        let cap = max(1, min(limit, 5000))
        let itemsURL = apiURL("Users", userId, "Items")
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Limit", value: "\(cap)"),
            URLQueryItem(name: "Fields", value: Self.jellyfinAlbumListFields),
        ]
        if Self.isLikelyJellyfinUUID(genre.id) {
            queryItems.append(URLQueryItem(name: "GenreIds", value: genre.id))
        } else {
            queryItems.append(URLQueryItem(name: "Genres", value: genre.name))
        }
        comps.queryItems = queryItems
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, _) = try await URLSession.lyra.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        return items.compactMap(parseAlbum)
    }

    func tracks(forAlbumId albumId: String) async throws -> [Track] {
        let itemsURL = apiURL("Users", userId, "Items")
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "ParentId", value: albumId),
            // Albums may nest tracks under disc folders; non-recursive ParentId queries return empty.
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber"),
            URLQueryItem(name: "Fields", value: Self.jellyfinAudioItemFields),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, _) = try await URLSession.lyra.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        return items.compactMap { parseTrack(dict: $0, albumId: albumId) }
    }

    func allTracks(limit: Int) async throws -> [Track] {
        let cap = max(1, min(limit, 50_000))
        var collected: [Track] = []
        collected.reserveCapacity(min(cap, 4_096))
        let pageSize = 1_000
        var startIndex = 0
        while collected.count < cap {
            let pageLimit = min(pageSize, cap - collected.count)
            let page = try await fetchAudioItemsPage(startIndex: startIndex, limit: pageLimit)
            if page.isEmpty { break }
            collected.append(contentsOf: page)
            if page.count < pageLimit { break }
            startIndex += page.count
        }
        return collected
    }

    private func fetchAudioItemsPage(startIndex: Int, limit: Int) async throws -> [Track] {
        try await fetchAudioItemsPage(startIndex: startIndex, limit: limit, sortBy: "SortName", sortOrder: "Ascending")
    }

    private func fetchAudioItemsPage(startIndex: Int, limit: Int, sortBy: String, sortOrder: String) async throws -> [Track] {
        let itemsURL = apiURL("Users", userId, "Items")
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
            URLQueryItem(name: "Limit", value: "\(max(1, limit))"),
            URLQueryItem(name: "Fields", value: Self.jellyfinAudioItemFields),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, _) = try await URLSession.lyra.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        return items.compactMap { dict -> Track? in
            let albumId =
                (dict["AlbumId"] as? String)
                    ?? (dict["ParentId"] as? String)
                    ?? ""
            guard !albumId.isEmpty else { return nil }
            return parseTrack(dict: dict, albumId: albumId)
        }
    }

    /// Paged track listing (newest-added first) for scroll pagination in Library → Songs.
    func tracksPage(offset: Int, limit: Int) async throws -> [Track] {
        try await fetchAudioItemsPage(
            startIndex: max(0, offset),
            limit: max(1, min(limit, 2_000)),
            sortBy: "DateCreated",
            sortOrder: "Descending",
        )
    }

    private enum BitrateApplication {
        case streaming
        case offline
    }

    private func bitrateQueryItems(for mode: BitrateApplication) -> [URLQueryItem] {
        let cap: Int?
        switch mode {
        case .streaming: cap = streamingBitrateCapBps
        case .offline: cap = offlineBitrateCapBps
        }
        guard let cap else { return [] }
        return [
            URLQueryItem(name: "audioBitRate", value: "\(cap)"),
            URLQueryItem(name: "maxStreamingBitrate", value: "\(cap)"),
        ]
    }

    private func baseStreamQueryItems(mode: BitrateApplication, allowStaticDirect: Bool = false) -> [URLQueryItem] {
        let deviceId = Self.stableDeviceId.replacingOccurrences(of: "\"", with: "")
        var extras: [URLQueryItem] = [
            URLQueryItem(name: "deviceId", value: deviceId),
        ]
        if !userId.isEmpty {
            extras.append(URLQueryItem(name: "userId", value: userId))
        }
        extras.append(contentsOf: bitrateQueryItems(for: mode))
        if allowStaticDirect, streamingBitrateCapBps == nil {
            extras.append(URLQueryItem(name: "Static", value: "true"))
        }
        return extras
    }

    private func progressiveStreamURL(trackId: String, container: String, mode: BitrateApplication, staticDirect: Bool = false) -> URL {
        let base = apiURL("Audio", trackId, "stream.\(container)")
        return mediaURLWithQueryAuth(base, extraQuery: baseStreamQueryItems(mode: mode, allowStaticDirect: staticDirect))
    }

    private func universalAudioStreamURL(trackId: String, transcodingContainer: String, audioCodec: String, mode: BitrateApplication) -> URL {
        let base = apiURL("Audio", trackId, "universal")
        var extras = baseStreamQueryItems(mode: mode, allowStaticDirect: false)
        extras.append(contentsOf: [
            URLQueryItem(name: "transcodingContainer", value: transcodingContainer),
            URLQueryItem(name: "audioCodec", value: audioCodec),
            URLQueryItem(name: "transcodingProtocol", value: "Http"),
        ])
        return mediaURLWithQueryAuth(base, extraQuery: extras)
    }

    private static func preferredStreamContainer(for track: Track) -> String {
        let codec = track.audioCodec?.lowercased() ?? ""
        switch codec {
        case "mp3", "mpeg": return "mp3"
        case "flac": return "flac"
        case "aac", "m4a", "alac": return "m4a"
        case "ogg", "vorbis", "opus": return "mp3"
        case "wma": return "wma"
        case "wav", "pcm": return "wav"
        default: return "mp3"
        }
    }

    private func orderedStreamingURLs(for track: Track) -> [URL] {
        let userContainer = streamingFormat.jellyfinPrimaryContainer
        let primaryContainer = userContainer ?? Self.preferredStreamContainer(for: track)
        let allowStatic = streamingBitrateCapBps == nil && userContainer == nil
        var urls: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let key = url.absoluteString
            guard !seen.contains(key) else { return }
            seen.insert(key)
            urls.append(url)
        }

        append(progressiveStreamURL(trackId: track.id, container: primaryContainer, mode: .streaming, staticDirect: allowStatic))
        if primaryContainer != "mp3" {
            append(progressiveStreamURL(trackId: track.id, container: "mp3", mode: .streaming, staticDirect: false))
        }
        append(universalAudioStreamURL(trackId: track.id, transcodingContainer: "mp3", audioCodec: "mp3", mode: .streaming))
        if primaryContainer != "m4a" {
            append(progressiveStreamURL(trackId: track.id, container: "m4a", mode: .streaming, staticDirect: false))
        }
        append(progressiveStreamURL(trackId: track.id, container: "aac", mode: .streaming, staticDirect: false))
        append(universalAudioStreamURL(trackId: track.id, transcodingContainer: "aac", audioCodec: "aac", mode: .streaming))
        append(universalAudioStreamURL(trackId: track.id, transcodingContainer: "m4a", audioCodec: "aac", mode: .streaming))
        let codec = track.audioCodec?.lowercased() ?? ""
        if codec == "flac", primaryContainer != "flac" {
            append(progressiveStreamURL(trackId: track.id, container: "flac", mode: .streaming, staticDirect: allowStatic))
            append(universalAudioStreamURL(trackId: track.id, transcodingContainer: "flac", audioCodec: "flac", mode: .streaming))
        }
        return urls
    }

    /// Full Jellyfin candidate list for playback (primary + fallbacks, deduped).
    func allStreamingURLs(for track: Track) -> [URL] {
        orderedStreamingURLs(for: track)
    }

    func streamURL(for track: Track) throws -> URL {
        guard let first = orderedStreamingURLs(for: track).first else {
            throw JellyfinClientError.unexpectedPayload
        }
        return first
    }

    func offlineDownloadURL(for track: Track) throws -> URL {
        let container = offlineFormat.jellyfinContainer
        let staticDirect = container == "flac" && offlineFormat == .raw
        return progressiveStreamURL(trackId: track.id, container: container, mode: .offline, staticDirect: staticDirect)
    }

    func reportNowPlaying(trackId: String) async throws {
        try await reportPlaybackSession(trackId: trackId, event: "play", positionSeconds: 0)
    }

    func submitScrobble(trackId: String, timestamp: Date) async throws {
        try await reportPlaybackSession(trackId: trackId, event: "stop", positionSeconds: nil, playedAt: timestamp)
    }

    private func reportPlaybackSession(
        trackId: String,
        event: String,
        positionSeconds: TimeInterval?,
        playedAt: Date? = nil
    ) async throws {
        guard !userId.isEmpty, !accessToken.isEmpty else { return }
        let url = apiURL("Sessions", "Playing")
        var body: [String: Any] = [
            "ItemId": trackId,
            "CanSeek": true,
            "IsPaused": false,
            "IsMuted": false,
            "PlayMethod": "DirectStream",
            "EventName": event,
        ]
        if let positionSeconds {
            body["PositionTicks"] = Int64(positionSeconds * 10_000_000)
        }
        if let playedAt {
            body["PlayedAt"] = Self.jellyfinISOFrac.string(from: playedAt)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func fallbackStreamURLs(for track: Track) -> [URL] {
        let all = orderedStreamingURLs(for: track)
        guard all.count > 1 else { return [] }
        return Array(all.dropFirst())
    }

    /// Item totals via ``TotalRecordCount`` (accurate; does not fetch full libraries).
    func fetchLibraryStatistics() async throws -> LibraryStatistics {
        guard !userId.isEmpty else {
            throw JellyfinClientError.unexpectedPayload
        }
        async let artists = fetchAlbumArtistTotalCount()
        async let albums = fetchTotalRecordCount(includeItemTypes: "MusicAlbum")
        async let songs = fetchTotalRecordCount(includeItemTypes: "Audio")
        let (a, al, s) = try await (artists, albums, songs)
        return LibraryStatistics(artistCount: a, albumCount: al, songCount: s, playlistCount: nil)
    }

    /// Album artists (matches ``libraryArtists`` / Jellyfin music libraries — `MusicArtist` items are often empty).
    private func fetchAlbumArtistTotalCount() async throws -> Int {
        guard !userId.isEmpty, !accessToken.isEmpty else {
            throw JellyfinClientError.unexpectedPayload
        }
        var comps = URLComponents(url: apiURL("Artists", "AlbumArtists"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "1"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "true"),
        ]
        guard let url = comps.url else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let total = json?["TotalRecordCount"] as? Int {
            return total
        }
        if let totalNum = json?["totalRecordCount"] as? NSNumber {
            return totalNum.intValue
        }
        throw JellyfinClientError.unexpectedPayload
    }

    private func fetchTotalRecordCount(includeItemTypes: String) async throws -> Int {
        let itemsURL = apiURL("Users", userId, "Items")
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: includeItemTypes),
            URLQueryItem(name: "Limit", value: "1"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "true"),
        ]
        guard let url = comps.url else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let total = json?["TotalRecordCount"] as? Int {
            return total
        }
        if let totalNum = json?["totalRecordCount"] as? NSNumber {
            return totalNum.intValue
        }
        throw JellyfinClientError.unexpectedPayload
    }

    /// Build a media URL **without** placing the bearer token in the query string.
    /// Callers must inject `Authorization: MediaBrowser Token=...` via headers — see
    /// `httpHeadersForMediaRequests()` (for `AVURLAssetHTTPHeaderFieldsKey` / `URLRequest`)
    /// and `MediaAuthHeaderRegistry` (for artwork loaders behind `URLSession.lyra`).
    ///
    /// Putting `ApiKey=` in URLs leaks the full user access token into:
    ///   - Jellyfin's HTTP access log (`$request_uri`)
    ///   - every reverse proxy in front of it (NGINX/Caddy/Cloudflare/Tailscale)
    ///   - `URLSession`'s on-disk URL cache (`Cache.db`)
    ///   - any `Referer` header that travels with follow-on requests
    /// Token disclosure = full account compromise.
    private func mediaURLWithQueryAuth(_ base: URL, extraQuery: [URLQueryItem]) -> URL {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        var items = comps.queryItems ?? []
        for extra in extraQuery {
            items.removeAll { $0.name == extra.name }
            items.append(extra)
        }
        // Strip any stale ApiKey/api_key that may have been appended by older code paths
        // (defense-in-depth; the bearer goes in the Authorization header).
        items.removeAll { $0.name == "ApiKey" || $0.name == "api_key" }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url ?? base
    }

    func lyrics(for track: Track) async throws -> [LyricLine] {
        let url = apiURL("Audio", track.id, "Lyrics")
        var req = URLRequest(url: url)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse else { return [] }
        if http.statusCode == 404 { return [] }
        guard http.statusCode == 200 else {
            throw JellyfinClientError.badResponse(status: http.statusCode, message: "Could not load lyrics.")
        }
        return JellyfinLyricsParser.parse(data: data)
    }

    // MARK: - Favorites (syncs with other Jellyfin clients for this user)

    /// Marks or clears the favorite flag for an audio item (`POST` / `DELETE` ``Users/{id}/FavoriteItems/{itemId}``).
    func setFavorite(trackId: String, favorite: Bool) async throws {
        guard !userId.isEmpty, !accessToken.isEmpty else {
            throw JellyfinClientError.unexpectedPayload
        }
        let url = apiURL("Users", userId, "FavoriteItems", trackId)
        var req = URLRequest(url: url)
        req.httpMethod = favorite ? "POST" : "DELETE"
        applyAuth(&req)
        let (_, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let message = favorite ? "Could not favorite this track." : "Could not remove favorite."
            throw JellyfinClientError.badResponse(status: http.statusCode, message: message)
        }
    }

    /// All library audio the user has marked as favorite on the server.
    func fetchFavoriteTracks(limit: Int = 15_000) async throws -> [Track] {
        guard !userId.isEmpty, !accessToken.isEmpty else {
            throw JellyfinClientError.unexpectedPayload
        }
        let cap = max(1, min(limit, 20_000))
        let itemsURL = apiURL("Users", userId, "Items")
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Filters", value: "IsFavorite"),
            URLQueryItem(name: "SortBy", value: "AlbumArtist,Album,ParentIndexNumber,IndexNumber"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Limit", value: "\(cap)"),
            URLQueryItem(name: "Fields", value: Self.jellyfinAudioItemFields),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode != 200 {
            let snippet = Self.humanReadableError(from: data) ?? String(data: data, encoding: .utf8) ?? ""
            let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            throw JellyfinClientError.badResponse(
                status: http.statusCode,
                message: trimmed.isEmpty ? "Could not load favorites." : trimmed,
            )
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        return items.compactMap { dict -> Track? in
            let albumId =
                (dict["AlbumId"] as? String)
                    ?? (dict["ParentId"] as? String)
                    ?? ""
            guard !albumId.isEmpty else { return nil }
            return parseTrack(dict: dict, albumId: albumId)
        }
    }

    func fetchFavoriteTrackIds(limit: Int = 20_000) async throws -> Set<String> {
        Set(try await fetchFavoriteTracks(limit: limit).map(\.id))
    }

    // MARK: - Playlists

    func fetchPlaylistSummaries(limit: Int = 500) async throws -> [PlaylistSummary] {
        try requireSignedInUser()
        let cap = max(1, min(limit, 2000))
        let itemsURL = apiURL("Users", userId, "Items")
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Limit", value: "\(cap)"),
            URLQueryItem(name: "Fields", value: "ChildCount,IsPublic,DateCreated,DateModified,ImageTags"),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        return items.compactMap(parsePlaylistSummary)
    }

    func fetchPlaylistRows(playlistId: String) async throws -> [PlaylistRowItem] {
        try requireSignedInUser()
        let itemsURL = apiURL("Users", userId, "Items")
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "ParentId", value: playlistId),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Fields", value: "PlaylistItemId,ParentId,AlbumId,AlbumArtist,Album,ArtistItems,ImageTags,RunTimeTicks,ParentIndexNumber,IndexNumber,Name,DateCreated,PremiereDate,MediaStreams,Genres,GenreItems,Genre,ProductionYear"),
            URLQueryItem(name: "Limit", value: "5000"),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        return items.enumerated().compactMap { idx, dict in
            parsePlaylistRow(dict: dict, playlistId: playlistId, index: idx)
        }
    }

    func createPlaylist(name: String, trackIds: [String], isPublic: Bool = false) async throws -> PlaylistSummary {
        try requireSignedInUser()
        let url = apiURL("Playlists")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "Name": name,
            "MediaType": "Audio",
            "UserId": userId,
            "Ids": trackIds,
            "IsPublic": isPublic,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = Self.humanReadableError(from: data) ?? ""
            throw JellyfinClientError.badResponse(status: http.statusCode, message: snippet.isEmpty ? "Could not create playlist." : snippet)
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["Id"] as? String {
            if let summary = parsePlaylistSummary(json) {
                return summary
            }
            return PlaylistSummary(id: id, name: name, songCount: trackIds.count, artworkURL: nil, isPublic: isPublic)
        }
        let summaries = try await fetchPlaylistSummaries(limit: 200)
        if let match = summaries.first(where: { $0.name == name }) {
            return match
        }
        throw JellyfinClientError.unexpectedPayload
    }

    func addTracksToPlaylist(playlistId: String, trackIds: [String]) async throws {
        try requireSignedInUser()
        guard !trackIds.isEmpty else { return }
        var comps = URLComponents(url: apiURL("Playlists", playlistId, "Items"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "Ids", value: trackIds.joined(separator: ",")),
            URLQueryItem(name: "UserId", value: userId),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        applyAuth(&req)
        let (_, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw JellyfinClientError.badResponse(status: (res as? HTTPURLResponse)?.statusCode ?? -1, message: "Could not add to playlist.")
        }
    }

    func removeTracksFromPlaylist(playlistId: String, entryIds: [String]) async throws {
        try requireSignedInUser()
        guard !entryIds.isEmpty else { return }
        var comps = URLComponents(url: apiURL("Playlists", playlistId, "Items"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "EntryIds", value: entryIds.joined(separator: ",")),
            URLQueryItem(name: "UserId", value: userId),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "DELETE"
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 204 else {
            let snippet = Self.humanReadableError(from: data) ?? ""
            throw JellyfinClientError.badResponse(
                status: (res as? HTTPURLResponse)?.statusCode ?? -1,
                message: snippet.isEmpty ? "Could not remove from playlist." : snippet,
            )
        }
    }

    func renamePlaylist(playlistId: String, name: String, isPublic: Bool? = nil) async throws {
        try requireSignedInUser()
        let url = apiURL("Playlists", playlistId)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["Name": name]
        if let isPublic {
            body["IsPublic"] = isPublic
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 204 else {
            let snippet = Self.humanReadableError(from: data) ?? ""
            throw JellyfinClientError.badResponse(
                status: (res as? HTTPURLResponse)?.statusCode ?? -1,
                message: snippet.isEmpty ? "Could not rename playlist." : snippet,
            )
        }
    }

    func deletePlaylist(playlistId: String) async throws {
        try requireSignedInUser()
        var comps = URLComponents(url: apiURL("Items", playlistId), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "UserId", value: userId)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "DELETE"
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 204 else {
            let snippet = Self.humanReadableError(from: data) ?? ""
            throw JellyfinClientError.badResponse(
                status: (res as? HTTPURLResponse)?.statusCode ?? -1,
                message: snippet.isEmpty ? "Could not delete playlist." : snippet,
            )
        }
    }

    /// Uploads a new Primary image for a playlist (`POST /Items/{id}/Images/Primary`).
    func uploadPlaylistImage(playlistId: String, imageData: Data, contentType: String) async throws {
        try requireSignedInUser()
        guard !imageData.isEmpty else {
            throw NSError(
                domain: "LyraMusic",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Image data is empty."],
            )
        }
        let url = apiURL("Items", playlistId, "Images", "Primary")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuth(&req)
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = imageData
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 204 else {
            let snippet = Self.humanReadableError(from: data) ?? ""
            throw JellyfinClientError.badResponse(
                status: (res as? HTTPURLResponse)?.statusCode ?? -1,
                message: snippet.isEmpty ? "Could not upload playlist cover." : snippet,
            )
        }
    }

    func fetchPlaylistSummary(playlistId: String) async throws -> PlaylistSummary? {
        let dict = try await fetchPlaylistMetadata(playlistId: playlistId)
        return parsePlaylistSummary(dict)
    }

    func deleteTrackFromLibrary(trackId: String) async throws {
        try requireSignedInUser()
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw JellyfinClientError.unexpectedPayload
        }
        var comps = URLComponents(url: apiURL("Items", trimmed), resolvingAgainstBaseURL: false)!
        comps.queryItems = []
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "DELETE"
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 204 else {
            let snippet = Self.humanReadableError(from: data) ?? ""
            throw JellyfinClientError.badResponse(
                status: (res as? HTTPURLResponse)?.statusCode ?? -1,
                message: snippet.isEmpty ? "Could not delete track from library." : snippet,
            )
        }
    }

    private func requireSignedInUser() throws {
        guard !userId.isEmpty, !accessToken.isEmpty else {
            throw JellyfinClientError.unexpectedPayload
        }
    }

    /// `POST Library/Refresh`. Tells Jellyfin to walk every media library so the
    /// audio file the request backend just wrote becomes visible. Fire-and-forget; callers
    /// poll `searchCatalog` for the new item afterwards.
    func triggerLibraryScan() async throws {
        try requireSignedInUser()
        let url = apiURL("Library", "Refresh")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        applyAuth(&req)
        let (_, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 204 else {
            throw JellyfinClientError.badResponse(
                status: (res as? HTTPURLResponse)?.statusCode ?? -1,
                message: "Could not start library scan.",
            )
        }
    }

    func searchCatalog(query: String, limit: Int) async throws -> CatalogSearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .empty }
        try requireSignedInUser()
        let cap = max(1, min(limit, 100))

        async let songsTask = searchAudioItems(query: q, limit: cap)
        async let albumsTask = searchAlbumItems(query: q, limit: cap)
        async let artistsTask = searchArtistItems(query: q, limit: cap)

        let songs = (try? await songsTask) ?? []
        let albums = (try? await albumsTask) ?? []
        let artists = (try? await artistsTask) ?? []
        return CatalogSearchResults(songs: songs, albums: albums, artists: artists)
    }

    func similarTracks(to track: Track, limit: Int) async throws -> [Track] {
        let cap = max(1, min(limit, 100))
        // Real Jellyfin similarity: GET /Items/{id}/Similar. Falls back to artist-based
        // shuffle when the server returns nothing (sparse music similarity is common).
        var comps = URLComponents(url: apiURL("Items", track.id, "Similar"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: "\(cap)"),
            URLQueryItem(name: "Fields", value: Self.jellyfinAudioItemFields),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        if let (data, res) = try? await URLSession.lyra.data(for: req),
           let http = res as? HTTPURLResponse, http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let items = json["Items"] as? [[String: Any]] ?? []
            let tracks = items.compactMap { dict -> Track? in
                let albumId = (dict["AlbumId"] as? String) ?? (dict["ParentId"] as? String) ?? ""
                guard !albumId.isEmpty else { return nil }
                return parseTrack(dict: dict, albumId: albumId)
            }.filter { $0.id != track.id }
            if !tracks.isEmpty { return Array(tracks.prefix(cap)) }
        }
        return try await artistBasedSimilarTracks(to: track, limit: cap)
    }

    /// Legacy fallback: songs by the same artist, shuffled. Used when Jellyfin's
    /// `/Items/{id}/Similar` returns no usable results.
    private func artistBasedSimilarTracks(to track: Track, limit: Int) async throws -> [Track] {
        let cap = max(1, min(limit, 100))
        let artistQuery = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artistQuery.isEmpty else { return [] }
        let results = try await searchCatalog(query: artistQuery, limit: cap + 8)
        return results.songs
            .filter { $0.id != track.id }
            .shuffled()
            .prefix(cap)
            .map { $0 }
    }

    func randomTracks(limit: Int, genre: String?) async throws -> [Track] {
        let cap = max(1, min(limit, 100))
        let albumsList = try await albums(limit: min(120, cap * 3))
        var out: [Track] = []
        for album in albumsList.shuffled() {
            let tracks = try await tracks(forAlbumId: album.id)
            if let genre {
                let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                out.append(contentsOf: tracks.filter {
                    $0.genres.contains(where: { $0.lowercased() == trimmed })
                        || album.genres.contains(where: { $0.lowercased() == trimmed })
                })
            } else {
                out.append(contentsOf: tracks)
            }
            if out.count >= cap { break }
        }
        if out.isEmpty, genre != nil {
            return try await randomTracks(limit: limit, genre: nil)
        }
        return Array(out.shuffled().prefix(cap))
    }

    private func searchAudioItems(query: String, limit: Int) async throws -> [Track] {
        var comps = URLComponents(url: apiURL("Users", userId, "Items"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "SearchTerm", value: query),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.jellyfinAudioItemFields),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        return items.compactMap { dict -> Track? in
            let albumId =
                (dict["AlbumId"] as? String)
                    ?? (dict["ParentId"] as? String)
                    ?? ""
            guard !albumId.isEmpty else { return nil }
            return parseTrack(dict: dict, albumId: albumId)
        }
    }

    private func searchAlbumItems(query: String, limit: Int) async throws -> [AlbumSummary] {
        var comps = URLComponents(url: apiURL("Users", userId, "Items"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "SearchTerm", value: query),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.jellyfinAlbumListFields),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        return items.compactMap(parseAlbum)
    }

    private func searchArtistItems(query: String, limit: Int) async throws -> [LibraryArtistSummary] {
        var comps = URLComponents(url: apiURL("Artists", "AlbumArtists"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SearchTerm", value: query),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: "ImageTags"),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        return items.compactMap(parseLibraryArtist)
    }

    /// One-off summary fetch for a single album id. Used to fill in albums that the
    /// user added to their library but which fell outside the paged `albums(limit:)`
    /// catalog (large libraries past the alphabetical cap).
    func albumSummary(forId id: String) async throws -> AlbumSummary? {
        try requireSignedInUser()
        let itemsURL = apiURL("Users", userId, "Items", id)
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "Fields", value: Self.jellyfinAlbumListFields)]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseAlbum(dict)
    }

    // MARK: - Library magic playlist

    /// Full contents of a single playlist for library-membership bookkeeping. Mirror of
    /// the Navidrome equivalent so ``AppModel`` can route through one shape.
    struct LibraryPlaylistFetch {
        let id: String
        let name: String
        let trackIds: [String]
        /// Playlist `Overview` — Jellyfin's counterpart to Subsonic `comment`.
        let comment: String?
    }

    /// Finds a playlist by exact name. Used to bind the Lyra magic playlist by
    /// deterministic name across devices.
    func findPlaylistByName(_ name: String) async throws -> PlaylistSummary? {
        try requireSignedInUser()
        let itemsURL = apiURL("Users", userId, "Items")
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SearchTerm", value: name),
            URLQueryItem(name: "Limit", value: "50"),
            URLQueryItem(name: "Fields", value: "ChildCount,IsPublic,DateCreated,DateModified,ImageTags"),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        let matches = items.compactMap { parsePlaylistSummary($0) }.filter { $0.name == name }
        // Duplicate playlists can share the magic name (multi-device race). Server order isn't
        // stable, so returning the first match made membership sync flap between duplicates and
        // the Library shelf flicker. Deterministically pick the richest (most songs; tiebreak by id).
        return matches.max { lhs, rhs in
            let l = lhs.songCount ?? 0, r = rhs.songCount ?? 0
            return l != r ? l < r : lhs.id > rhs.id
        }
    }

    /// Creates an empty, private playlist with the given name. Returns the new id.
    func createEmptyPrivatePlaylist(name: String) async throws -> String {
        let summary = try await createPlaylist(name: name, trackIds: [], isPublic: false)
        return summary.id
    }

    /// One round-trip combination of `getItem` (for Overview) and `fetchPlaylistRows`
    /// (for track ids). Used on sign-in to seed library state.
    func fetchLibraryPlaylist(playlistId: String) async throws -> LibraryPlaylistFetch {
        try requireSignedInUser()
        async let metaTask = fetchPlaylistMetadata(playlistId: playlistId)
        async let rowsTask = fetchPlaylistRows(playlistId: playlistId)
        let (meta, rows) = try await (metaTask, rowsTask)
        let name = (meta["Name"] as? String) ?? ""
        let overview = (meta["Overview"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return LibraryPlaylistFetch(
            id: playlistId,
            name: name,
            trackIds: rows.map(\.track.id),
            comment: overview,
        )
    }

    /// Updates the playlist's Overview field. Jellyfin's metadata endpoint requires the
    /// full BaseItemDto, so this does a read-mutate-write.
    func setPlaylistOverview(playlistId: String, overview: String) async throws {
        try requireSignedInUser()
        var meta = try await fetchPlaylistMetadata(playlistId: playlistId)
        meta["Overview"] = overview
        let url = apiURL("Items", playlistId)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: meta)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 204 else {
            let snippet = Self.humanReadableError(from: data) ?? ""
            throw JellyfinClientError.badResponse(
                status: (res as? HTTPURLResponse)?.statusCode ?? -1,
                message: snippet.isEmpty ? "Could not update playlist metadata." : snippet,
            )
        }
    }

    private func fetchPlaylistMetadata(playlistId: String) async throws -> [String: Any] {
        let url = apiURL("Users", userId, "Items", playlistId)
        var req = URLRequest(url: url)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func parsePlaylistSummary(_ dict: [String: Any]) -> PlaylistSummary? {
        guard let id = dict["Id"] as? String, let name = dict["Name"] as? String else {
            return nil
        }
        let childCount = (dict["ChildCount"] as? NSNumber)?.intValue ?? dict["ChildCount"] as? Int
        let isPublic = Self.parseOptionalBool(dict["IsPublic"])
        let added = jellyfinDate(dict["DateCreated"])
        let updated = jellyfinDate(dict["DateModified"])
        var art: URL?
        if let tag = dict["ImageTags"] as? [String: Any],
           let primary = tag["Primary"] as? String,
           var comps = URLComponents(
               url: apiURL("Items", id, "Images", "Primary"),
               resolvingAgainstBaseURL: false,
           ) {
            comps.queryItems = [URLQueryItem(name: "tag", value: primary)]
            art = mediaURLWithQueryAuth(comps.url!, extraQuery: [])
        }
        if art == nil {
            art = mediaURLWithQueryAuth(apiURL("Items", id, "Images", "Primary"), extraQuery: [])
        }
        return PlaylistSummary(
            id: id,
            name: name,
            songCount: childCount,
            artworkURL: art,
            isPublic: isPublic,
            libraryAddedDate: added,
            serverUpdatedDate: updated
        )
    }

    private static func parseOptionalBool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    private func parsePlaylistRow(dict: [String: Any], playlistId: String, index: Int) -> PlaylistRowItem? {
        guard let mediaId = dict["Id"] as? String else { return nil }
        let entryId =
            (dict["PlaylistItemId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? mediaId
        let albumId =
            (dict["AlbumId"] as? String)
                ?? (dict["ParentId"] as? String)
                ?? ""
        guard !albumId.isEmpty, let track = parseTrack(dict: dict, albumId: albumId) else {
            return nil
        }
        let rowId = "\(playlistId)-\(entryId)-\(index)-\(mediaId)"
        return PlaylistRowItem(rowId: rowId, track: track, jellyfinEntryId: entryId, navidromeIndex: nil)
    }

    private func fetchLibraryItemRows(
        includeTypes: String,
        limit: Int,
        sortBy: String,
        sortDescending: Bool,
        extraQuery: [URLQueryItem],
    ) async throws -> [[String: Any]] {
        guard !userId.isEmpty, !accessToken.isEmpty else {
            throw JellyfinClientError.unexpectedPayload
        }
        let itemsURL = apiURL("Users", userId, "Items")
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        var q: [URLQueryItem] = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: includeTypes),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortDescending ? "Descending" : "Ascending"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
        ]
        q.append(contentsOf: extraQuery)
        comps.queryItems = q
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["Items"] as? [[String: Any]] ?? []
    }

    private func parseLibraryArtist(_ dict: [String: Any]) -> LibraryArtistSummary? {
        guard let id = dict["Id"] as? String, let name = dict["Name"] as? String else {
            return nil
        }
        var art: URL?
        if let tag = dict["ImageTags"] as? [String: Any],
           let primary = tag["Primary"] as? String,
           var comps = URLComponents(
               url: apiURL("Items", id, "Images", "Primary"),
               resolvingAgainstBaseURL: false,
           ) {
            comps.queryItems = [URLQueryItem(name: "tag", value: primary)]
            art = mediaURLWithQueryAuth(comps.url!, extraQuery: [])
        }
        return LibraryArtistSummary(id: id, name: name, artworkURL: art)
    }

    private func parseLibraryGenre(_ dict: [String: Any]) -> LibraryGenreSummary? {
        let id = (dict["Id"] as? String) ?? (dict["id"] as? String)
        let name = (dict["Name"] as? String) ?? (dict["name"] as? String)
        guard let id, let name, !id.isEmpty, !name.isEmpty else { return nil }
        let albumCount = (dict["ChildCount"] as? NSNumber)?.intValue ?? (dict["ChildCount"] as? Int)
        return LibraryGenreSummary(id: id, name: name, albumCount: albumCount)
    }

    /// Jellyfin often has genres only as strings on albums (no `MusicGenre` items).
    private func libraryGenresDerivedFromAlbumTags(limitAlbums: Int) async throws -> [LibraryGenreSummary] {
        guard !userId.isEmpty, !accessToken.isEmpty else {
            throw JellyfinClientError.unexpectedPayload
        }
        let sample = max(200, min(limitAlbums, 15_000))
        let itemsURL = apiURL("Users", userId, "Items")
        var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Limit", value: "\(sample)"),
            /// Without this, Jellyfin often omits genre tags from album payloads and derived genres stay empty.
            URLQueryItem(name: "Fields", value: "Genres,GenreItems,Genre"),
        ]
        var req = URLRequest(url: comps.url!)
        applyAuth(&req)
        let (data, res) = try await URLSession.lyra.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        var counts: [String: Int] = [:]
        for dict in items {
            for g in Self.genreNamesFromAlbum(dict) {
                let trimmed = g.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                counts[trimmed, default: 0] += 1
            }
        }
        return counts.map { LibraryGenreSummary(id: $0.key, name: $0.key, albumCount: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func genreNamesFromAlbum(_ dict: [String: Any]) -> [String] {
        if let arr = dict["Genres"] as? [Any], !arr.isEmpty {
            let mapped = arr.compactMap { el -> String? in
                if let s = el as? String { return s }
                if let o = el as? [String: Any] {
                    return (o["Name"] as? String) ?? (o["name"] as? String)
                }
                return nil
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            if !mapped.isEmpty { return mapped }
        }
        if let items = dict["GenreItems"] as? [[String: Any]] {
            let mapped = items.compactMap { ($0["Name"] as? String) ?? ($0["name"] as? String) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !mapped.isEmpty { return mapped }
        }
        if let s = dict["Genre"] as? String {
            let parts = s.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts }
        }
        return []
    }

    private static func isLikelyJellyfinUUID(_ s: String) -> Bool {
        let pattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    private static func yearFromPremiereDateString(_ string: String?) -> Int? {
        guard let string, string.count >= 4 else { return nil }
        guard let y = Int(string.prefix(4)), (1000...9999).contains(y) else { return nil }
        return y
    }

    private static func primaryAudioStreamFields(_ dict: [String: Any]) -> (Int?, Int?, String?, Int?) {
        guard let streams = dict["MediaStreams"] as? [[String: Any]] else {
            return (nil, nil, nil, nil)
        }
        func isAudio(_ s: [String: Any]) -> Bool {
            if let t = s["Type"] as? String {
                return t.caseInsensitiveCompare("audio") == .orderedSame
            }
            if let n = s["Type"] as? NSNumber {
                return n.intValue == 0
            }
            return false
        }
        let audio = streams.first(where: isAudio)
            ?? streams.first { row in
                let codec = (row["Codec"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !codec.isEmpty && (row["SampleRate"] != nil || row["Channels"] != nil)
            }
        guard let s = audio else { return (nil, nil, nil, nil) }
        let sr = (s["SampleRate"] as? NSNumber)?.intValue ?? (s["SampleRate"] as? Int)
        let ch = (s["Channels"] as? NSNumber)?.intValue ?? (s["Channels"] as? Int)
        let rawCodec = (s["Codec"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let codec = rawCodec.isEmpty ? nil : rawCodec
        let bd = (s["BitDepth"] as? NSNumber)?.intValue ?? (s["BitDepth"] as? Int)
        return (sr, ch, codec, bd)
    }

    private func applyAuth(_ req: inout URLRequest) {
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(Self.authorizationWithToken(accessToken), forHTTPHeaderField: "Authorization")
    }

    private func parseAlbum(_ dict: [String: Any]) -> AlbumSummary? {
        guard let id = dict["Id"] as? String, let name = dict["Name"] as? String else {
            return nil
        }
        let artists = (dict["AlbumArtists"] as? [[String: Any]])?.compactMap { $0["Name"] as? String } ?? []
        let artist = artists.first ?? (dict["AlbumArtist"] as? String) ?? ""
        var art: URL?
        if let tag = dict["ImageTags"] as? [String: Any],
           let primary = tag["Primary"] as? String,
           var comps = URLComponents(
               url: apiURL("Items", id, "Images", "Primary"),
               resolvingAgainstBaseURL: false,
           ) {
            comps.queryItems = [URLQueryItem(name: "tag", value: primary)]
            art = mediaURLWithQueryAuth(comps.url!, extraQuery: [])
        }
        let childCount = (dict["ChildCount"] as? NSNumber)?.intValue ?? dict["ChildCount"] as? Int
        let libraryAddedDate = jellyfinDate(dict["DateCreated"])
        let releaseDate = jellyfinDate(dict["PremiereDate"])
        let genres = Self.genreNamesFromAlbum(dict)
        let releaseYear =
            (dict["ProductionYear"] as? NSNumber)?.intValue
            ?? (dict["ProductionYear"] as? Int)
            ?? Self.yearFromPremiereDateString(dict["PremiereDate"] as? String)
        return AlbumSummary(
            id: id,
            title: name,
            artist: artist,
            artworkURL: art ?? albumPrimaryImageURL(albumId: id),
            trackCount: childCount,
            libraryAddedDate: libraryAddedDate,
            genres: genres,
            releaseYear: releaseYear,
            releaseDate: releaseDate,
        )
    }

    private func jellyfinDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return Self.jellyfinISOFrac.date(from: s) ?? Self.jellyfinISO.date(from: s)
    }

    private func parseTrack(dict: [String: Any], albumId: String) -> Track? {
        guard let id = dict["Id"] as? String, let title = dict["Name"] as? String else {
            return nil
        }
        let run = (dict["RunTimeTicks"] as? NSNumber)?.doubleValue ?? 0
        let seconds = run > 0 ? run / 10_000_000.0 : 0
        let performerNames = (dict["ArtistItems"] as? [[String: Any]])?.compactMap { $0["Name"] as? String }.filter { !$0.isEmpty } ?? []
        let albumArtist = (dict["AlbumArtist"] as? String) ?? ""
        let artist = performerNames.first ?? albumArtist
        let albumTitle = (dict["Album"] as? String) ?? ""
        let disc = (dict["ParentIndexNumber"] as? NSNumber)?.intValue ?? 1
        let index = (dict["IndexNumber"] as? NSNumber)?.intValue ?? 0
        let art = artworkURLForTrackOrAlbum(dict: dict, trackId: id, albumId: albumId)
        let added = jellyfinDate(dict["DateCreated"])
        let genres = Self.genreNamesFromAlbum(dict)
        let releaseYear =
            (dict["ProductionYear"] as? NSNumber)?.intValue
            ?? (dict["ProductionYear"] as? Int)
            ?? Self.yearFromPremiereDateString(dict["PremiereDate"] as? String)
        let (sampleRate, channels, codec, bitDepth) = Self.primaryAudioStreamFields(dict)
        return Track(
            id: id,
            title: title,
            albumId: albumId,
            albumTitle: albumTitle,
            artist: artist,
            duration: seconds,
            discNumber: disc,
            indexNumber: index,
            artworkURL: art,
            libraryAddedDate: added,
            genres: genres,
            releaseYear: releaseYear,
            sampleRateHz: sampleRate,
            audioChannels: channels,
            audioCodec: codec,
            audioBitDepth: bitDepth,
            audioBitRateKbps: nil,
        )
    }

    func albumPrimaryImageURL(albumId: String) -> URL? {
        mediaURLWithQueryAuth(apiURL("Items", albumId, "Images", "Primary"), extraQuery: [])
    }

    private func artworkURLForTrackOrAlbum(dict: [String: Any], trackId: String, albumId: String) -> URL? {
        if let tag = dict["ImageTags"] as? [String: Any],
           let primary = tag["Primary"] as? String,
           var comps = URLComponents(
               url: apiURL("Items", trackId, "Images", "Primary"),
               resolvingAgainstBaseURL: false,
           ) {
            comps.queryItems = [URLQueryItem(name: "tag", value: primary)]
            return mediaURLWithQueryAuth(comps.url!, extraQuery: [])
        }
        return mediaURLWithQueryAuth(apiURL("Items", albumId, "Images", "Primary"), extraQuery: [])
    }
}

enum JellyfinLyricsParser {
    static func parse(data: Data) -> [LyricLine] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let lyrics = root["Lyrics"] as? [[String: Any]]
        else {
            return []
        }
        return lyrics.compactMap { row in
            guard let text = row["Text"] as? String else { return nil }
            let startTicks = (row["Start"] as? NSNumber)?.doubleValue ?? 0
            let start = startTicks / 10_000_000.0
            return LyricLine(start: start, text: text)
        }
        .sorted { $0.start < $1.start }
    }
}
