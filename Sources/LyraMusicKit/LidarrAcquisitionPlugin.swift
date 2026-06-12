import Foundation

/// Acquisition backend for Lidarr. Album-level: resolves the request to a MusicBrainz
/// release group, adds + monitors the album, and triggers an indexer search.
///
/// Works around Lidarr #5012 (adding an album whose artist is new unmonitors the album
/// right after, so the auto-search finds nothing): we add with `searchForNewAlbum=false`,
/// wait for the album row, force-monitor just that album, then trigger `AlbumSearch`.
struct LidarrAcquisitionPlugin: AcquisitionProviding {
    let kind: AcquisitionPluginKind = .lidarr

    private var base: String { AcquisitionConfigStore.value(.lidarr, "baseURL") }
    private var apiKey: String { AcquisitionConfigStore.value(.lidarr, "apiKey") }

    var isConfigured: Bool { !base.isEmpty && !apiKey.isEmpty }

    var capabilities: AcquisitionCapabilities {
        AcquisitionCapabilities(
            displayName: "Lidarr",
            iconName: "square.stack.3d.up",
            blurb: "Album-level requests via Lidarr. Lyra resolves the album in MusicBrainz, adds and monitors it, then searches your indexers.",
            granularity: .album,
            supportsTrackSearch: false,
            configFields: [
                AcquisitionConfigField(id: "baseURL", kind: .url, label: "Server URL", placeholder: "http://192.168.1.x:8686"),
                AcquisitionConfigField(id: "apiKey", kind: .apiKey, label: "API Key", placeholder: "Settings -> General in Lidarr"),
            ]
        )
    }

    func validate() async -> Result<String, Error> {
        guard isConfigured else { return .failure(AcquisitionError("Enter your Lidarr URL and API key.")) }
        do {
            _ = try await send(path: "system/status")
            return .success("Connected to Lidarr.")
        } catch {
            return .failure(error)
        }
    }

    func enqueue(_ request: AcquisitionRequest, progress: AcquisitionProgress?) async throws -> String {
        guard isConfigured else { throw AcquisitionError("Configure Lidarr in Settings first.") }
        progress?(0.05)
        let albumTitle = request.albumTitle ?? request.trackTitle ?? ""
        let term: String
        if !albumTitle.isEmpty {
            term = "\(request.artist) \(albumTitle)"
        } else {
            term = request.artist
        }
        let candidates = try await albumLookup(term: term)
        progress?(0.3)
        guard let pick = pickBestAlbum(from: candidates, artist: request.artist, albumTitle: albumTitle) else {
            throw AcquisitionError("No matching album found in Lidarr for \"\(term)\".")
        }
        progress?(0.5)
        let foreignId = try await addOrSearchExistingAlbum(lookup: pick)
        progress?(1.0)
        return "lidarr:\(foreignId)"
    }

    func activeJobs() async -> [AcquisitionJob] {
        guard isConfigured else { return [] }
        async let queueRecords = downloadQueueRecords()
        async let commandRows = activeCommands()
        var out: [AcquisitionJob] = []
        for row in await queueRecords {
            guard let qid = AcquisitionHTTP.int(row["id"]) else { continue }
            let size = AcquisitionHTTP.double(row["size"]) ?? 0
            let left = AcquisitionHTTP.double(row["sizeleft"]) ?? 0
            let progress = size > 0 ? max(0, min(1, 1 - left / size)) : 0
            out.append(AcquisitionJob(
                id: "lidarr-queue:\(qid)",
                title: AcquisitionHTTP.string(row["title"]) ?? "Download",
                artist: nil,
                status: Self.status(fromQueue: AcquisitionHTTP.string(row["status"]) ?? ""),
                progress: progress,
                message: AcquisitionHTTP.string(row["errorMessage"]) ?? AcquisitionHTTP.string(row["timeleft"]),
                kind: .lidarr,
                nativeId: "lidarr-queue:\(qid)",
                source: .server
            ))
        }
        for cmd in await commandRows {
            guard let cid = AcquisitionHTTP.int(cmd["id"]) else { continue }
            let name = AcquisitionHTTP.string(cmd["name"]) ?? "Task"
            out.append(AcquisitionJob(
                id: "lidarr-cmd:\(cid)",
                title: Self.friendlyCommand(name),
                artist: nil,
                status: Self.status(fromCommand: AcquisitionHTTP.string(cmd["status"]) ?? ""),
                progress: 0.4,
                message: AcquisitionHTTP.string(cmd["message"]),
                kind: .lidarr,
                nativeId: "lidarr-cmd:\(cid)",
                source: .server
            ))
        }
        return out
    }

    // MARK: - REST

    @discardableResult
    private func send(
        path: String,
        query: [String: String] = [:],
        method: String = "GET",
        jsonBody: Any? = nil
    ) async throws -> Any {
        try await AcquisitionHTTP.requestJSON(
            base: base,
            path: "/api/v1/\(path)",
            query: query,
            method: method,
            headers: ["X-Api-Key": apiKey],
            jsonBody: jsonBody
        )
    }

    private func albumLookup(term: String) async throws -> [[String: Any]] {
        let data = try await send(path: "album/lookup", query: ["term": term])
        return data as? [[String: Any]] ?? []
    }

    private func libraryAlbum(foreignAlbumId: String) async -> [String: Any]? {
        let fid = foreignAlbumId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fid.count >= 36 else { return nil }
        guard let data = try? await send(path: "album", query: ["foreignAlbumId": fid]) else { return nil }
        return (data as? [[String: Any]])?.first
    }

    private func downloadQueueRecords() async -> [[String: Any]] {
        guard let data = try? await send(path: "queue", query: ["page": "1", "pageSize": "100"]) else { return [] }
        if let page = data as? [String: Any], let records = page["records"] as? [[String: Any]] { return records }
        return data as? [[String: Any]] ?? []
    }

    private func activeCommands() async -> [[String: Any]] {
        guard let data = try? await send(path: "command") else { return [] }
        let rows = data as? [[String: Any]] ?? []
        return rows.filter { cmd in
            let status = (AcquisitionHTTP.string(cmd["status"]) ?? "").lowercased()
            let name = (AcquisitionHTTP.string(cmd["name"]) ?? "").lowercased()
            let terminal = status == "completed" || status == "failed" || status == "aborted"
            let musicy = name.contains("album") || name.contains("artist") || name.contains("rss") || name.contains("search")
            return !terminal && musicy
        }
    }

    private func triggerAlbumSearch(albumIds: [Int]) async throws {
        guard !albumIds.isEmpty else { return }
        _ = try await send(path: "command", method: "POST", jsonBody: ["name": "AlbumSearch", "albumIds": albumIds])
    }

    /// Adds a new album (or re-searches an existing one), force-monitoring the album to
    /// survive Lidarr #5012, then triggers the indexer search.
    private func addOrSearchExistingAlbum(lookup: [String: Any]) async throws -> String {
        guard let foreignAlbumId = AcquisitionHTTP.string(lookup["foreignAlbumId"]), !foreignAlbumId.isEmpty else {
            throw AcquisitionError("Lidarr album lookup is missing a foreign id.")
        }
        if let existing = await libraryAlbum(foreignAlbumId: foreignAlbumId),
           let albumId = AcquisitionHTTP.int(existing["id"]) {
            try await monitorAndSearch(album: existing, albumId: albumId)
            return foreignAlbumId
        }

        let root = try await defaultRootFolderPath()
        let qualityId = try await defaultQualityProfileId()
        let metadataId = try await defaultMetadataProfileId()

        var body = lookup
        body["monitored"] = true
        body["qualityProfileId"] = qualityId
        body["metadataProfileId"] = metadataId
        body["rootFolderPath"] = root
        body["addOptions"] = ["searchForNewAlbum": false]
        if var artist = body["artist"] as? [String: Any] {
            artist["monitored"] = true
            artist["qualityProfileId"] = qualityId
            artist["metadataProfileId"] = metadataId
            artist["rootFolderPath"] = root
            artist["addOptions"] = ["monitor": "none", "monitored": true, "searchForMissingAlbums": false]
            body["artist"] = artist
        }

        do {
            _ = try await send(path: "album", method: "POST", jsonBody: body)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? ""
            let alreadyExists = msg.contains("AlbumExistsValidator") || msg.lowercased().contains("already")
            guard alreadyExists else { throw error }
        }

        let (row, albumId) = try await resolveAddedAlbum(foreignAlbumId: foreignAlbumId)
        try await monitorAndSearch(album: row, albumId: albumId)
        return foreignAlbumId
    }

    private func monitorAndSearch(album: [String: Any], albumId: Int) async throws {
        if album["monitored"] as? Bool != true {
            var body = album
            body["monitored"] = true
            _ = try? await send(path: "album/\(albumId)", method: "PUT", jsonBody: body)
        }
        try await triggerAlbumSearch(albumIds: [albumId])
    }

    private func resolveAddedAlbum(foreignAlbumId: String) async throws -> (row: [String: Any], id: Int) {
        for attempt in 0 ..< 10 {
            if let row = await libraryAlbum(foreignAlbumId: foreignAlbumId),
               let id = AcquisitionHTTP.int(row["id"]) {
                return (row, id)
            }
            try? await Task.sleep(for: .milliseconds(attempt < 2 ? 400 : 900))
        }
        throw AcquisitionError("Lidarr accepted the album but it isn't ready to search yet. Try again in a moment.")
    }

    private func defaultRootFolderPath() async throws -> String {
        let data = try await send(path: "rootfolder")
        guard let rows = data as? [[String: Any]],
              let path = rows.compactMap({ AcquisitionHTTP.string($0["path"]) }).first, !path.isEmpty
        else { throw AcquisitionError("No Lidarr root folder configured.") }
        return path
    }

    private func defaultQualityProfileId() async throws -> Int {
        let data = try await send(path: "qualityprofile")
        guard let rows = data as? [[String: Any]],
              let id = rows.compactMap({ AcquisitionHTTP.int($0["id"]) }).first
        else { throw AcquisitionError("No Lidarr quality profile found.") }
        return id
    }

    private func defaultMetadataProfileId() async throws -> Int {
        let data = try await send(path: "metadataprofile")
        guard let rows = data as? [[String: Any]],
              let id = rows.compactMap({ AcquisitionHTTP.int($0["id"]) }).first
        else { throw AcquisitionError("No Lidarr metadata profile found.") }
        return id
    }

    private func pickBestAlbum(from albums: [[String: Any]], artist: String, albumTitle: String) -> [String: Any]? {
        let a = artist.lowercased()
        let album = albumTitle.lowercased()

        func artistName(_ dict: [String: Any]) -> String {
            let nested = dict["artist"] as? [String: Any]
            return (AcquisitionHTTP.string(nested?["artistName"]) ?? AcquisitionHTTP.string(nested?["name"]) ?? "").lowercased()
        }
        func artistMatches(_ dict: [String: Any]) -> Bool {
            let name = artistName(dict)
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

    private static func status(fromQueue raw: String) -> AcquisitionJobStatus {
        switch raw.lowercased() {
        case "queued", "delay", "downloadclientunavailable": return .queued
        case "downloading", "paused": return .downloading
        case "completed": return .importing
        case "failed", "warning": return .failed
        default: return .unknown
        }
    }

    private static func status(fromCommand raw: String) -> AcquisitionJobStatus {
        switch raw.lowercased() {
        case "queued": return .queued
        case "started", "running": return .downloading
        case "completed": return .done
        case "failed", "aborted": return .failed
        default: return .unknown
        }
    }

    private static func friendlyCommand(_ name: String) -> String {
        switch name.lowercased() {
        case "albumsearch": return "Searching album"
        case "artistsearch": return "Searching artist"
        case "missingalbumsearch": return "Searching missing albums"
        case "refreshartist": return "Refreshing artist"
        case "rsssync": return "Checking indexers"
        default: return name
        }
    }
}
