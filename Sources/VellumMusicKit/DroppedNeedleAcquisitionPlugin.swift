import Foundation

/// Acquisition backend for [DroppedNeedle](https://droppedneedle.com) — a self-hosted
/// request-to-library engine (MusicBrainz search, slskd/Usenet sourcing, fingerprint,
/// tag, import). Album requests go through ``POST /api/v1/requests/new``; the native
/// download queue is polled via ``GET /api/v1/downloads``.
///
/// Auth: the native ``/api/v1/*`` REST API accepts **session tokens** from the login
/// routes only — Connect Apps app passwords are for Subsonic/Jellyfin clients.
/// Supported sign-in paths:
///   - ``POST /api/v1/auth/login`` (local DroppedNeedle account)
///   - ``POST /api/v1/auth/jellyfin/login`` (imported Jellyfin user)
///   - ``POST /api/v1/auth/plex/pin`` + ``GET /api/v1/auth/plex/poll`` (Plex)
struct DroppedNeedleAcquisitionPlugin: AcquisitionProviding {
    let kind: AcquisitionPluginKind = .droppedNeedle

    /// Plex pin flow kickoff — opened in the browser, then polled to completion.
    struct PlexLoginStart: Sendable {
        let pinId: Int
        let authURL: URL
    }

    enum LoginMethod: String, Sendable {
        case local
        case jellyfin
        case plex
    }

    private var base: String { AcquisitionConfigStore.value(.droppedNeedle, "baseURL") }
    private var loginMethod: LoginMethod {
        LoginMethod(rawValue: AcquisitionConfigStore.value(.droppedNeedle, "loginMethod")) ?? .local
    }
    private var username: String { AcquisitionConfigStore.value(.droppedNeedle, "username") }
    private var password: String { AcquisitionConfigStore.value(.droppedNeedle, "password") }
    private var storedSessionToken: String { AcquisitionConfigStore.value(.droppedNeedle, "sessionToken") }

    private var sessionAccountKey: String {
        switch loginMethod {
        case .local: return "local:\(username.lowercased())"
        case .jellyfin: return "jellyfin:\(username.lowercased())"
        case .plex: return "plex"
        }
    }

    var isConfigured: Bool {
        guard !base.isEmpty else { return false }
        switch loginMethod {
        case .local, .jellyfin:
            return !username.isEmpty && !password.isEmpty
        case .plex:
            return !storedSessionToken.isEmpty
        }
    }

    var capabilities: AcquisitionCapabilities {
        AcquisitionCapabilities(
            displayName: "DroppedNeedle",
            iconName: "arrow.down.circle",
            blurb: "A self-hosted music request engine. Sign in with your DroppedNeedle account, an imported Jellyfin user, or Plex — then Vellum sends album requests through the native API.",
            requirementsSummary: "DroppedNeedle needs its server address and an account sign-in. No API key — app passwords from Connect Apps won't work here.",
            granularity: .album,
            supportsTrackSearch: false,
            configFields: [
                AcquisitionConfigField(
                    id: "baseURL",
                    kind: .url,
                    label: "Server Address",
                    placeholder: "http://192.168.1.10:8688",
                    helpText: "The same address you use to open DroppedNeedle in a browser, including the port."
                ),
                AcquisitionConfigField(
                    id: "loginMethod",
                    kind: .text,
                    label: "Sign-In Method",
                    placeholder: "",
                    pickerOptions: [
                        .init(id: "local", label: "DroppedNeedle Account"),
                        .init(id: "jellyfin", label: "Jellyfin"),
                        .init(id: "plex", label: "Plex"),
                    ]
                ),
                AcquisitionConfigField(
                    id: "username",
                    kind: .username,
                    label: "Username",
                    placeholder: "Account username",
                    helpText: "The account you sign in to DroppedNeedle with, not your Vellum server login."
                ),
                AcquisitionConfigField(
                    id: "password",
                    kind: .password,
                    label: "Password",
                    placeholder: "Account password"
                ),
                AcquisitionConfigField(
                    id: "sessionToken",
                    kind: .apiKey,
                    label: "Session Token",
                    placeholder: "",
                    required: false,
                ),
            ]
        )
    }

    func validate() async -> Result<String, Error> {
        guard isConfigured else {
            return .failure(AcquisitionError(missingCredentialsMessage))
        }
        do {
            let token = try await login()
            DroppedNeedleSession.store(token, base: base, accountKey: sessionAccountKey)
            _ = try await sendAuthenticated(path: "/system/health", bearer: token)
            let label = switch loginMethod {
            case .local: "DroppedNeedle"
            case .jellyfin: "Jellyfin on DroppedNeedle"
            case .plex: "Plex on DroppedNeedle"
            }
            return .success("Connected via \(label).")
        } catch {
            DroppedNeedleSession.clear(base: base, accountKey: sessionAccountKey)
            return .failure(error)
        }
    }

    func enqueue(_ request: AcquisitionRequest, progress: AcquisitionProgress?) async throws -> String {
        guard isConfigured else { throw AcquisitionError("Configure DroppedNeedle in Settings first.") }
        progress?(0.05)

        if let trackTitle = request.trackTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trackTitle.isEmpty {
            let nativeId = try await enqueueTrack(request, trackTitle: trackTitle, progress: progress)
            progress?(1.0)
            return nativeId
        }

        let mbid = try await resolveReleaseGroupMBID(for: request, progress: progress)
        progress?(0.55)
        try await submitAlbumRequest(mbid: mbid, request: request)
        progress?(1.0)
        return "droppedneedle:rg:\(mbid)"
    }

    func activeJobs() async -> [AcquisitionJob] {
        guard isConfigured else { return [] }
        guard let data = try? await send(
            path: "/downloads",
            query: ["page": "1", "page_size": "100"],
        ) else { return [] }
        guard let page = data as? [String: Any],
              let items = page["items"] as? [[String: Any]] else { return [] }
        return items.compactMap(mapDownloadTask)
    }

    func artistReleases(named name: String) async -> [AcquisitionRelease] {
        guard isConfigured else { return [] }
        let term = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let target = LibraryTrackMatcher.normalize(term)
        let rows = (try? await searchAlbums(term: term)) ?? []
        return rows.compactMap { mapSearchAlbum($0, artistFallback: name) }
            .filter { release in
                let artist = LibraryTrackMatcher.normalize(release.artist)
                // Exact, or a more-specific result that still contains the full
                // search name. Never the reverse — a short hit like "The" must
                // not match "The Rolling Stones".
                return !artist.isEmpty && (artist == target || artist.contains(target))
            }
    }

    func artistProfile(named name: String) async -> AcquisitionArtistProfile? {
        guard isConfigured else { return nil }
        let term = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        let target = LibraryTrackMatcher.normalize(term)
        let artists = (try? await searchArtists(term: term)) ?? []
        let row = artists.first(where: { artist in
            LibraryTrackMatcher.normalize(AcquisitionHTTP.string(artist["title"]) ?? "") == target
        }) ?? artists.first(where: { artist in
            let norm = LibraryTrackMatcher.normalize(AcquisitionHTTP.string(artist["title"]) ?? "")
            return !norm.isEmpty && norm.contains(target)
        })
        guard let row else { return nil }
        let display = AcquisitionHTTP.string(row["title"]) ?? name
        return AcquisitionArtistProfile(
            name: display,
            overview: nil,
            artworkURL: droppedNeedleImageURL(row),
            genres: [],
            mbid: AcquisitionHTTP.string(row["musicbrainz_id"]) ?? AcquisitionHTTP.string(row["mbid"])
        )
    }

    func searchArtists(query: String) async -> [AcquisitionArtist] {
        guard isConfigured else { return [] }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let rows = (try? await searchArtists(term: term)) ?? []
        var seen = Set<String>()
        var out: [AcquisitionArtist] = []
        for row in rows {
            let name = AcquisitionHTTP.string(row["title"]) ?? ""
            let key = LibraryTrackMatcher.normalize(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let mbid = AcquisitionHTTP.string(row["musicbrainz_id"]) ?? AcquisitionHTTP.string(row["mbid"])
            out.append(AcquisitionArtist(
                id: mbid ?? key,
                name: name,
                artworkURL: droppedNeedleImageURL(row),
                mbid: mbid
            ))
            if out.count >= 8 { break }
        }
        return out
    }

    func tracks(forRelease release: AcquisitionRelease) async -> [BrowseAlbumPreviewTrack] {
        guard isConfigured else { return [] }
        let mbid = release.releaseGroupMBID
            ?? (release.id.hasPrefix("mbid:") ? String(release.id.dropFirst(5)) : nil)
        guard let mbid, mbid.count >= 36 else { return [] }
        let rows = (try? await albumTracks(releaseGroupMBID: mbid)) ?? []
        return rows.enumerated().compactMap { index, row in
            guard let title = AcquisitionHTTP.string(row["title"]), !title.isEmpty else { return nil }
            let position = AcquisitionHTTP.int(row["position"])
                ?? AcquisitionHTTP.int(row["track_number"])
                ?? (index + 1)
            let duration: TimeInterval?
            if let ms = AcquisitionHTTP.double(row["duration_ms"]) ?? AcquisitionHTTP.double(row["duration"]) {
                duration = ms > 1000 ? ms / 1000 : ms
            } else {
                duration = nil
            }
            let tid = AcquisitionHTTP.string(row["recording_id"]) ?? "\(mbid)-\(position)"
            return BrowseAlbumPreviewTrack(id: "dn-track:\(tid)", position: position, title: title, duration: duration)
        }
        .sorted { $0.position < $1.position }
    }

    func tracks(artist: String, albumTitle: String) async -> [BrowseAlbumPreviewTrack] {
        guard isConfigured else { return [] }
        let term = [artist, albumTitle].filter { !$0.isEmpty }.joined(separator: " ")
        guard !term.isEmpty else { return [] }
        let candidates = (try? await searchAlbums(term: term)) ?? []
        guard let pick = pickBestAlbum(from: candidates, artist: artist, albumTitle: albumTitle),
              let release = mapSearchAlbum(pick, artistFallback: artist)
        else { return [] }
        return await tracks(forRelease: release)
    }

    func canRequestArtist(named name: String) async -> Bool {
        guard isConfigured else { return false }
        let term = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return false }
        guard let rows = try? await searchArtists(term: term), !rows.isEmpty else { return false }
        let target = LibraryTrackMatcher.normalize(term)
        return rows.contains { row in
            let artistName = AcquisitionHTTP.string(row["title"]) ?? ""
            let norm = LibraryTrackMatcher.normalize(artistName)
            return !norm.isEmpty && (norm == target || norm.contains(target) || target.contains(norm))
        }
    }

    // MARK: - REST

    @discardableResult
    private func send(
        path: String,
        query: [String: String] = [:],
        method: String = "GET",
        jsonBody: Any? = nil,
    ) async throws -> Any {
        let token = try await sessionToken(forceRefresh: false)
        do {
            return try await sendAuthenticated(
                path: path, query: query, method: method, jsonBody: jsonBody, bearer: token,
            )
        } catch {
            guard Self.isAuthFailure(error) else { throw error }
            DroppedNeedleSession.clear(base: base, accountKey: sessionAccountKey)
            if loginMethod == .plex {
                clearStoredSessionToken()
                throw AcquisitionError("Plex session expired. Sign in with Plex again.")
            }
            let refreshed = try await sessionToken(forceRefresh: true)
            return try await sendAuthenticated(
                path: path, query: query, method: method, jsonBody: jsonBody, bearer: refreshed,
            )
        }
    }

    @discardableResult
    private func sendAuthenticated(
        path: String,
        query: [String: String] = [:],
        method: String = "GET",
        jsonBody: Any? = nil,
        bearer: String,
    ) async throws -> Any {
        do {
            return try await AcquisitionHTTP.requestJSON(
                base: base,
                path: "/api/v1\(path)",
                query: query,
                method: method,
                headers: ["Authorization": "Bearer \(bearer)"],
                jsonBody: jsonBody,
            )
        } catch {
            throw Self.mapHTTPError(error) ?? error
        }
    }

    private func sessionToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached = DroppedNeedleSession.cached(base: base, accountKey: sessionAccountKey) {
            return cached
        }
        let token = try await login()
        DroppedNeedleSession.store(token, base: base, accountKey: sessionAccountKey)
        return token
    }

    private func login() async throws -> String {
        switch loginMethod {
        case .local:
            return try await loginPOST(path: "/auth/login", failureHint: "Invalid username or password.")
        case .jellyfin:
            return try await loginPOST(path: "/auth/jellyfin/login", failureHint: "Invalid Jellyfin credentials or Jellyfin sign-in is not enabled on this server.")
        case .plex:
            let token = storedSessionToken
            guard !token.isEmpty else {
                throw AcquisitionError("Sign in with Plex in Settings first.")
            }
            return token
        }
    }

    private func loginPOST(path: String, failureHint: String) async throws -> String {
        let response: Any
        do {
            response = try await AcquisitionHTTP.requestJSON(
                base: base,
                path: "/api/v1\(path)",
                method: "POST",
                jsonBody: ["username": username, "password": password],
            )
        } catch {
            throw Self.mapHTTPError(error) ?? AcquisitionError(failureHint)
        }
        guard let dict = response as? [String: Any],
              let token = AcquisitionHTTP.string(dict["token"]),
              !token.isEmpty
        else {
            throw AcquisitionError("Login succeeded but DroppedNeedle did not return a session token.")
        }
        return token
    }

    private var missingCredentialsMessage: String {
        switch loginMethod {
        case .local, .jellyfin:
            return "Enter your DroppedNeedle server URL, username, and password."
        case .plex:
            return "Enter your DroppedNeedle server URL and sign in with Plex."
        }
    }

    // MARK: - Plex sign-in (Settings UI)

    func startPlexLogin() async throws -> PlexLoginStart {
        guard !base.isEmpty else { throw AcquisitionError("Enter your DroppedNeedle server URL first.") }
        let response: Any
        do {
            response = try await AcquisitionHTTP.requestJSON(
                base: base,
                path: "/api/v1/auth/plex/pin",
                method: "POST",
            )
        } catch {
            throw Self.mapHTTPError(error) ?? AcquisitionError("Couldn't start Plex sign-in.")
        }
        guard let dict = response as? [String: Any],
              let pinId = AcquisitionHTTP.int(dict["pin_id"]),
              let authURLString = AcquisitionHTTP.string(dict["auth_url"]),
              let authURL = URL(string: authURLString)
        else {
            throw AcquisitionError("DroppedNeedle returned an unexpected Plex sign-in response.")
        }
        return PlexLoginStart(pinId: pinId, authURL: authURL)
    }

    /// Polls Plex sign-in progress. Returns a session token when ``completed`` is true.
    func pollPlexLogin(pinId: Int) async throws -> String? {
        let response: Any
        do {
            response = try await AcquisitionHTTP.requestJSON(
                base: base,
                path: "/api/v1/auth/plex/poll",
                query: ["pin_id": "\(pinId)"],
            )
        } catch {
            throw Self.mapHTTPError(error) ?? AcquisitionError("Plex sign-in poll failed.")
        }
        guard let dict = response as? [String: Any] else { return nil }
        let completed = (dict["completed"] as? Bool) == true
        guard completed, let token = AcquisitionHTTP.string(dict["token"]), !token.isEmpty else {
            return nil
        }
        return token
    }

    func persistSessionToken(_ token: String) {
        AcquisitionConfigStore.set(token, .droppedNeedle, "sessionToken")
        DroppedNeedleSession.store(token, base: base, accountKey: sessionAccountKey)
    }

    func clearStoredSessionToken() {
        AcquisitionConfigStore.set("", .droppedNeedle, "sessionToken")
        DroppedNeedleSession.clear(base: base, accountKey: sessionAccountKey)
    }

    static func clearAllSessions() {
        DroppedNeedleSession.clearAll()
        AcquisitionConfigStore.set("", .droppedNeedle, "sessionToken")
    }

    private static func mapHTTPError(_ error: Error) -> AcquisitionError? {
        guard let acq = error as? AcquisitionError,
              let body = acq.errorDescription,
              let friendly = friendlyMessage(fromResponseBody: body)
        else { return nil }
        return AcquisitionError(friendly)
    }

    private static func friendlyMessage(fromResponseBody body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let err = json["error"] as? [String: Any],
           let message = AcquisitionHTTP.string(err["message"]),
           !message.isEmpty {
            if message == "Invalid or expired token" {
                return "Session expired. Test the connection again to sign in."
            }
            return message
        }
        if let detail = AcquisitionHTTP.string(json["detail"]), !detail.isEmpty {
            return detail
        }
        return nil
    }

    private static func isAuthFailure(_ error: Error) -> Bool {
        guard let message = (error as? AcquisitionError)?.errorDescription?.lowercased() else { return false }
        return message.contains("unauthorized")
            || message.contains("invalid or expired token")
            || message.contains("not authenticated")
            || message.contains("session expired")
    }

    // MARK: - Enqueue helpers

    private func enqueueTrack(
        _ request: AcquisitionRequest,
        trackTitle: String,
        progress: AcquisitionProgress?,
    ) async throws -> String {
        progress?(0.2)
        let recordingMBID = try await resolveRecordingMBID(for: request, trackTitle: trackTitle)
        progress?(0.45)
        let response = try await send(
            path: "/tracks/\(recordingMBID)/request",
            method: "POST",
            jsonBody: trackRequestBody(for: request, trackTitle: trackTitle),
        )
        guard let dict = response as? [String: Any] else {
            throw AcquisitionError("DroppedNeedle returned an unexpected track response.")
        }
        let status = (AcquisitionHTTP.string(dict["status"]) ?? "").lowercased()
        if status == "already_in_library" {
            throw AcquisitionError("This track is already in your DroppedNeedle library.")
        }
        if let taskId = AcquisitionHTTP.string(dict["task_id"]), !taskId.isEmpty {
            return "droppedneedle:task:\(taskId)"
        }
        return "droppedneedle:recording:\(recordingMBID)"
    }

    private func resolveReleaseGroupMBID(
        for request: AcquisitionRequest,
        progress: AcquisitionProgress?,
    ) async throws -> String {
        if let mbid = normalizedMBID(request.releaseGroupMBID) { return mbid }
        progress?(0.15)
        let albumTitle = request.albumTitle ?? request.trackTitle ?? ""
        let term: String
        if !albumTitle.isEmpty {
            term = "\(request.artist) \(albumTitle)"
        } else {
            term = request.artist
        }
        let candidates = try await searchAlbums(term: term)
        progress?(0.35)
        guard let pick = pickBestAlbum(from: candidates, artist: request.artist, albumTitle: albumTitle),
              let mbid = AcquisitionHTTP.string(pick["musicbrainz_id"]),
              !mbid.isEmpty
        else {
            throw AcquisitionError("No matching album found in DroppedNeedle for \"\(term)\".")
        }
        return mbid
    }

    private func submitAlbumRequest(mbid: String, request: AcquisitionRequest) async throws {
        var body: [String: Any] = ["musicbrainz_id": mbid]
        if !request.artist.isEmpty { body["artist"] = request.artist }
        if let album = request.albumTitle, !album.isEmpty { body["album"] = album }
        if let artistMBID = normalizedMBID(request.artistMBID) { body["artist_mbid"] = artistMBID }
        _ = try await send(path: "/requests/new", method: "POST", jsonBody: body)
    }

    private func resolveRecordingMBID(
        for request: AcquisitionRequest,
        trackTitle: String,
    ) async throws -> String {
        let releaseGroupMBID = try await resolveReleaseGroupMBID(for: request, progress: nil)
        let tracks = try await albumTracks(releaseGroupMBID: releaseGroupMBID)
        let keys = Set(LibraryTrackMatcher.normalizedTitleKeys(from: trackTitle))
        if let match = tracks.first(where: { row in
            guard let title = AcquisitionHTTP.string(row["title"]) else { return false }
            return !Set(LibraryTrackMatcher.normalizedTitleKeys(from: title)).isDisjoint(with: keys)
        }), let recordingId = AcquisitionHTTP.string(match["recording_id"]), !recordingId.isEmpty {
            return recordingId
        }
        throw AcquisitionError("Couldn't find \"\(trackTitle)\" on the matched album in DroppedNeedle.")
    }

    private func albumTracks(releaseGroupMBID: String) async throws -> [[String: Any]] {
        let data = try await send(path: "/albums/\(releaseGroupMBID)/tracks")
        guard let dict = data as? [String: Any],
              let tracks = dict["tracks"] as? [[String: Any]] else { return [] }
        return tracks
    }

    private func searchAlbums(term: String) async throws -> [[String: Any]] {
        let data = try await send(
            path: "/search",
            query: [
                "q": term,
                "limit_artists": "0",
                "limit_albums": "20",
                "buckets": "albums",
            ],
        )
        guard let dict = data as? [String: Any],
              let albums = dict["albums"] as? [[String: Any]] else { return [] }
        return albums
    }

    private func searchArtists(term: String) async throws -> [[String: Any]] {
        let data = try await send(
            path: "/search",
            query: [
                "q": term,
                "limit_artists": "10",
                "limit_albums": "0",
                "buckets": "artists",
            ],
        )
        guard let dict = data as? [String: Any],
              let artists = dict["artists"] as? [[String: Any]] else { return [] }
        return artists
    }

    private func trackRequestBody(for request: AcquisitionRequest, trackTitle: String) -> [String: Any] {
        var body: [String: Any] = [
            "artist_name": request.artist,
            "track_title": trackTitle,
        ]
        if let album = request.albumTitle, !album.isEmpty { body["album_title"] = album }
        if let releaseGroupMBID = normalizedMBID(request.releaseGroupMBID) {
            body["release_group_mbid"] = releaseGroupMBID
        }
        if let artistMBID = normalizedMBID(request.artistMBID) { body["artist_mbid"] = artistMBID }
        return body
    }

    private func normalizedMBID(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.count >= 36 else { return nil }
        return trimmed
    }

    private func pickBestAlbum(
        from albums: [[String: Any]],
        artist: String,
        albumTitle: String,
    ) -> [String: Any]? {
        let a = artist.lowercased()
        let album = albumTitle.lowercased()

        func artistMatches(_ dict: [String: Any]) -> Bool {
            let name = (AcquisitionHTTP.string(dict["artist"]) ?? "").lowercased()
            return !name.isEmpty && (name.contains(a) || a.contains(name))
        }

        if !album.isEmpty, let exact = albums.first(where: {
            AcquisitionHTTP.string($0["title"])?.lowercased() == album && artistMatches($0)
        }) { return exact }
        if !album.isEmpty, let contains = albums.first(where: {
            (AcquisitionHTTP.string($0["title"])?.lowercased().contains(album) == true) && artistMatches($0)
        }) { return contains }
        return albums.first(where: { artistMatches($0) }) ?? albums.first
    }

    private func mapSearchAlbum(_ row: [String: Any], artistFallback: String) -> AcquisitionRelease? {
        let title = AcquisitionHTTP.string(row["title"]) ?? ""
        guard !title.isEmpty else { return nil }
        let artist = AcquisitionHTTP.string(row["artist"])
            ?? AcquisitionHTTP.string(row["artist_name"])
            ?? artistFallback
        let mbid = AcquisitionHTTP.string(row["musicbrainz_id"])
            ?? AcquisitionHTTP.string(row["mbid"])
            ?? ""
        let year = AcquisitionHTTP.int(row["year"])
        let date = AcquisitionHTTP.date(row["first_release_date"])
            ?? AcquisitionHTTP.date(row["release_date"])
            ?? year.flatMap { y -> Date? in
                var comps = DateComponents()
                comps.year = y
                comps.month = 1
                comps.day = 1
                return Calendar(identifier: .gregorian).date(from: comps)
            }
        return AcquisitionRelease(
            id: mbid.isEmpty ? "dn:\(artist)|\(title)" : mbid,
            title: title,
            artist: artist,
            releaseDate: date,
            artworkURL: droppedNeedleImageURL(row),
            albumType: AcquisitionHTTP.string(row["type"]) ?? AcquisitionHTTP.string(row["album_type"]),
            secondaryTypes: [],
            trackCount: AcquisitionHTTP.int(row["track_count"]),
            releaseGroupMBID: mbid.isEmpty ? nil : mbid,
            artistMBID: AcquisitionHTTP.string(row["artist_mbid"]),
            nativeAlbumId: nil,
            overview: nil,
            artistOverview: nil,
            artistArtworkURL: nil,
            monitored: false,
            wanted: false
        )
    }

    private func droppedNeedleImageURL(_ row: [String: Any]) -> URL? {
        let raw = AcquisitionHTTP.string(row["cover"])
            ?? AcquisitionHTTP.string(row["cover_url"])
            ?? AcquisitionHTTP.string(row["image"])
            ?? AcquisitionHTTP.string(row["image_url"])
        return raw.flatMap(URL.init(string:))
    }

    private func mapDownloadTask(_ row: [String: Any]) -> AcquisitionJob? {
        guard let taskId = AcquisitionHTTP.string(row["id"]), !taskId.isEmpty else { return nil }
        let statusRaw = AcquisitionHTTP.string(row["status"]) ?? ""
        let progressPercent = AcquisitionHTTP.int(row["progress_percent"]) ?? 0
        let progress = max(0, min(1, Double(progressPercent) / 100))
        let title = AcquisitionHTTP.string(row["track_title"])
            ?? AcquisitionHTTP.string(row["album_title"])
            ?? "Download"
        let releaseGroupMBID = AcquisitionHTTP.string(row["release_group_mbid"]) ?? ""
        let nativeId: String
        if !releaseGroupMBID.isEmpty {
            nativeId = "droppedneedle:rg:\(releaseGroupMBID)"
        } else {
            nativeId = "droppedneedle:task:\(taskId)"
        }
        return AcquisitionJob(
            id: "droppedneedle:task:\(taskId)",
            title: title,
            artist: AcquisitionHTTP.string(row["artist_name"]),
            albumTitle: AcquisitionHTTP.string(row["album_title"]),
            status: Self.status(fromDownload: statusRaw),
            progress: progress,
            message: AcquisitionHTTP.string(row["error_message"]),
            kind: .droppedNeedle,
            nativeId: nativeId,
            source: .server,
        )
    }

    private static func status(fromDownload raw: String) -> AcquisitionJobStatus {
        switch raw.lowercased() {
        case "queued", "pending", "awaiting_approval":
            return .queued
        case "searching":
            return .searching
        case "downloading":
            return .downloading
        case "processing", "importing":
            return .importing
        case "completed":
            return .done
        case "failed", "cancelled", "partial":
            return .failed
        default:
            return .unknown
        }
    }
}

// MARK: - Session cache

/// In-memory session tokens keyed by (server, account). Plugins are recreated
/// frequently via ``AcquisitionManager/makeProvider``, so tokens live here.
private enum DroppedNeedleSession {
    private static let lock = NSLock()
    private static var tokens: [String: String] = [:]

    static func cacheKey(base: String, accountKey: String) -> String {
        let normalizedBase = AcquisitionHTTP.normalizedBase(base) ?? base
        let account = accountKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedBase)|\(account)"
    }

    static func cached(base: String, accountKey: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tokens[cacheKey(base: base, accountKey: accountKey)]
    }

    static func store(_ token: String, base: String, accountKey: String) {
        lock.lock()
        defer { lock.unlock() }
        tokens[cacheKey(base: base, accountKey: accountKey)] = token
    }

    static func clear(base: String, accountKey: String) {
        lock.lock()
        defer { lock.unlock() }
        tokens.removeValue(forKey: cacheKey(base: base, accountKey: accountKey))
    }

    static func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        tokens.removeAll()
    }
}
