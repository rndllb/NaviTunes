import Foundation

/// Acquisition backend for Lidarr. Album-level: Lidarr resolves the release on its
/// MusicBrainz-backed catalog, adds + monitors the album, and triggers an indexer search.
///
/// Works around Lidarr #5012 (adding an album whose artist is new unmonitors the album
/// right after, so the auto-search finds nothing): we add with `searchForNewAlbum=false`,
/// wait for the album row, force-monitor just that album, then trigger `AlbumSearch`.
struct LidarrAcquisitionPlugin: AcquisitionProviding {
    let kind: AcquisitionPluginKind = .lidarr

    private var base: String { AcquisitionConfigStore.value(.lidarr, "baseURL") }
    private var apiKey: String { AcquisitionConfigStore.value(.lidarr, "apiKey") }

    var isConfigured: Bool { !base.isEmpty && !apiKey.isEmpty }

    static func resetSessionCaches() async {
        await LidarrArtistListCache.shared.reset()
    }

    var capabilities: AcquisitionCapabilities {
        AcquisitionCapabilities(
            displayName: "Lidarr",
            iconName: "square.stack.3d.up",
            blurb: "A music collection manager. Vellum sends album requests to Lidarr, which adds them to your collection and keeps them monitored and complete.",
            requirementsSummary: "Lidarr needs its server address and an API key.",
            granularity: .album,
            supportsTrackSearch: false,
            supportsReleaseCatalog: true,
            configFields: [
                AcquisitionConfigField(
                    id: "baseURL",
                    kind: .url,
                    label: "Server Address",
                    placeholder: "http://192.168.1.10:8686",
                    helpText: "The same address you use to open Lidarr in a browser, including the port."
                ),
                AcquisitionConfigField(
                    id: "apiKey",
                    kind: .apiKey,
                    label: "API Key",
                    placeholder: "32-character key",
                    helpText: "In Lidarr, go to Settings → General → Security and copy the API Key."
                ),
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

    func canRequestArtist(named name: String) async -> Bool {
        guard isConfigured else { return false }
        let term = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return false }
        guard let rows = try? await artistLookup(term: term), !rows.isEmpty else { return false }
        let target = LibraryTrackMatcher.normalize(term)
        return rows.contains { artistNameMatches($0, target: target) }
    }

    func artistReleases(named name: String) async -> [AcquisitionRelease] {
        guard isConfigured else { return [] }
        let target = LibraryTrackMatcher.normalize(name)
        guard !target.isEmpty else { return [] }
        let match = await resolvedArtist(named: name, target: target)
        let overview = match.flatMap { AcquisitionHTTP.string($0["overview"]) }
        let art = match.flatMap { imageURL(from: $0, preferred: ["poster", "fanart", "banner", "cover"]) }
        let artistMBID = match.flatMap { AcquisitionHTTP.string($0["foreignArtistId"]) }

        // Already in the user's Lidarr library — list exactly what Lidarr shows.
        if let match, let artistId = AcquisitionHTTP.int(match["id"]) {
            let rows = (try? await send(path: "album", query: ["artistId": String(artistId)])) as? [[String: Any]] ?? []
            let mapped = rows.compactMap {
                mapAlbum(
                    $0,
                    artistFallback: name,
                    artistMBID: artistMBID,
                    artistOverview: overview,
                    artistArt: art
                )
            }
            if !mapped.isEmpty { return mapped }
        }

        // Not in Lidarr yet (or library list was empty): same album search Lidarr's
        // UI uses, so an off-server artist page can still request releases.
        let lookups = (try? await albumLookup(term: name)) ?? []
        return lookups.compactMap {
            mapAlbum(
                $0,
                artistFallback: name,
                artistMBID: artistMBID,
                artistOverview: overview,
                artistArt: art
            )
        }
        .filter { release in
            let key = LibraryTrackMatcher.normalize(release.artist)
            return key == target || key.contains(target) || target.contains(key)
        }
    }

    func upcomingAndWanted(since: Date, until: Date) async -> [AcquisitionRelease] {
        guard isConfigured else { return [] }
        let start = Self.ymd.string(from: since)
        let end = Self.ymd.string(from: until)
        async let calendarTask = send(
            path: "calendar",
            query: ["start": start, "end": end, "includeArtist": "true", "unmonitored": "false"]
        )
        async let wantedTask = send(
            path: "wanted/missing",
            query: [
                "page": "1",
                "pageSize": "100",
                "sortKey": "releaseDate",
                "sortDirection": "descending",
            ]
        )
        var out: [AcquisitionRelease] = []
        var seen = Set<String>()
        if let rows = try? await calendarTask as? [[String: Any]] {
            for row in rows {
                guard let release = mapAlbum(row, artistFallback: "", wanted: false),
                      seen.insert(release.id).inserted
                else { continue }
                out.append(release)
            }
        }
        if let page = try? await wantedTask as? [String: Any],
           let records = page["records"] as? [[String: Any]] {
            for row in records {
                guard let release = mapAlbum(row, artistFallback: "", wanted: true),
                      seen.insert(release.id).inserted
                else { continue }
                out.append(release)
            }
        }
        return out
    }

    func artistProfile(named name: String) async -> AcquisitionArtistProfile? {
        guard isConfigured else { return nil }
        let target = LibraryTrackMatcher.normalize(name)
        guard !target.isEmpty else { return nil }
        guard let row = await resolvedArtist(named: name, target: target) else { return nil }
        let display = AcquisitionHTTP.string(row["artistName"])
            ?? AcquisitionHTTP.string(row["name"])
            ?? name
        let genres = (row["genres"] as? [String]) ?? []
        return AcquisitionArtistProfile(
            name: display,
            overview: AcquisitionHTTP.string(row["overview"]),
            artworkURL: imageURL(from: row, preferred: ["poster", "fanart", "banner", "cover"]),
            genres: genres,
            mbid: AcquisitionHTTP.string(row["foreignArtistId"])
        )
    }

    func searchArtists(query: String) async -> [AcquisitionArtist] {
        guard isConfigured else { return [] }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let rows = (try? await artistLookup(term: term)) ?? []
        var seen = Set<String>()
        var out: [AcquisitionArtist] = []
        for row in rows {
            let name = AcquisitionHTTP.string(row["artistName"])
                ?? AcquisitionHTTP.string(row["name"])
                ?? ""
            let key = LibraryTrackMatcher.normalize(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let mbid = AcquisitionHTTP.string(row["foreignArtistId"])
            out.append(AcquisitionArtist(
                id: mbid ?? key,
                name: name,
                artworkURL: imageURL(from: row, preferred: ["poster", "fanart", "banner", "cover"]),
                mbid: mbid
            ))
            if out.count >= 8 { break }
        }
        return out
    }

    func tracks(forRelease release: AcquisitionRelease) async -> [BrowseAlbumPreviewTrack] {
        guard isConfigured else { return [] }
        var albumId = release.nativeAlbumId.flatMap(Int.init)
        if albumId == nil {
            let foreign = release.releaseGroupMBID
                ?? release.id.replacingOccurrences(of: "mbid:", with: "")
            if foreign.count >= 36, let row = await libraryAlbum(foreignAlbumId: foreign) {
                albumId = AcquisitionHTTP.int(row["id"])
            }
        }
        guard let albumId else { return [] }
        let rows = (try? await send(path: "track", query: ["albumId": String(albumId)])) as? [[String: Any]] ?? []
        return rows.enumerated().compactMap { index, row in
            guard let title = AcquisitionHTTP.string(row["title"]), !title.isEmpty else { return nil }
            let position = AcquisitionHTTP.int(row["trackNumber"]) ?? (index + 1)
            let duration: TimeInterval?
            if let ms = AcquisitionHTTP.double(row["duration"]) {
                duration = ms > 1000 ? ms / 1000 : ms
            } else {
                duration = nil
            }
            let tid = AcquisitionHTTP.int(row["id"]).map(String.init) ?? "\(albumId)-\(position)"
            return BrowseAlbumPreviewTrack(id: "lidarr-track:\(tid)", position: position, title: title, duration: duration)
        }
        .sorted { $0.position < $1.position }
    }

    func tracks(artist: String, albumTitle: String) async -> [BrowseAlbumPreviewTrack] {
        guard isConfigured else { return [] }
        let term = [artist, albumTitle].filter { !$0.isEmpty }.joined(separator: " ")
        guard !term.isEmpty else { return [] }
        let candidates = (try? await albumLookup(term: term)) ?? []
        guard let pick = pickBestAlbum(from: candidates, artist: artist, albumTitle: albumTitle) else { return [] }
        if let release = mapAlbum(pick, artistFallback: artist) {
            let fromLibrary = await tracks(forRelease: release)
            if !fromLibrary.isEmpty { return fromLibrary }
        }
        return parseEmbeddedTracks(from: pick, albumTitle: albumTitle)
    }

    private func artistLookup(term: String) async throws -> [[String: Any]] {
        let data = try await send(path: "artist/lookup", query: ["term": term])
        return data as? [[String: Any]] ?? []
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

    // MARK: - Catalog mapping

    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func libraryArtist(matching target: String) async -> [String: Any]? {
        let rows = await libraryArtists()
        return rows.first { artistNameMatches($0, target: target) }
    }

    private func libraryArtists() async -> [[String: Any]] {
        let currentBase = base
        let currentKey = apiKey
        return (try? await LidarrArtistListCache.shared.artists(base: currentBase) {
            let data = try await AcquisitionHTTP.requestJSON(
                base: currentBase,
                path: "/api/v1/artist",
                headers: ["X-Api-Key": currentKey]
            )
            return data as? [[String: Any]] ?? []
        }) ?? []
    }

    private func resolvedArtist(named name: String, target: String) async -> [String: Any]? {
        if let match = await libraryArtist(matching: target) { return match }
        return (try? await artistLookup(term: name))?.first { artistNameMatches($0, target: target) }
    }

    private func artistNameMatches(_ row: [String: Any], target: String) -> Bool {
        let artistName = AcquisitionHTTP.string(row["artistName"])
            ?? AcquisitionHTTP.string(row["name"])
            ?? ""
        let norm = LibraryTrackMatcher.normalize(artistName)
        return !norm.isEmpty && (norm == target || norm.contains(target) || target.contains(norm))
    }

    private func mapAlbum(
        _ row: [String: Any],
        artistFallback: String,
        artistMBID: String? = nil,
        artistOverview: String? = nil,
        artistArt: URL? = nil,
        wanted: Bool = false
    ) -> AcquisitionRelease? {
        let title = AcquisitionHTTP.string(row["title"]) ?? ""
        guard !title.isEmpty else { return nil }
        let nested = row["artist"] as? [String: Any]
        let artist = AcquisitionHTTP.string(nested?["artistName"])
            ?? AcquisitionHTTP.string(nested?["name"])
            ?? artistFallback
        let foreignId = AcquisitionHTTP.string(row["foreignAlbumId"]) ?? ""
        let nativeId = AcquisitionHTTP.int(row["id"]).map(String.init)
        let id = foreignId.isEmpty ? (nativeId.map { "lidarr:\($0)" } ?? "lidarr:\(artist)|\(title)") : foreignId
        let secondary = (row["secondaryTypes"] as? [String]) ?? []
        let nestedMBID = AcquisitionHTTP.string(nested?["foreignArtistId"])
        return AcquisitionRelease(
            id: id,
            title: title,
            artist: artist,
            releaseDate: AcquisitionHTTP.date(row["releaseDate"]),
            artworkURL: imageURL(from: row, preferred: ["cover", "poster"]),
            albumType: AcquisitionHTTP.string(row["albumType"]),
            secondaryTypes: secondary,
            trackCount: statisticsTrackCount(row),
            releaseGroupMBID: foreignId.isEmpty ? nil : foreignId,
            artistMBID: artistMBID ?? nestedMBID,
            nativeAlbumId: nativeId,
            overview: AcquisitionHTTP.string(row["overview"]),
            artistOverview: artistOverview ?? AcquisitionHTTP.string(nested?["overview"]),
            artistArtworkURL: artistArt ?? imageURL(from: nested ?? [:], preferred: ["poster", "fanart", "banner", "cover"]),
            monitored: AcquisitionHTTP.bool(row["monitored"]) ?? false,
            wanted: wanted
        )
    }

    private func statisticsTrackCount(_ row: [String: Any]) -> Int? {
        if let stats = row["statistics"] as? [String: Any] {
            return AcquisitionHTTP.int(stats["trackCount"]) ?? AcquisitionHTTP.int(stats["totalTrackCount"])
        }
        return nil
    }

    private func imageURL(from row: [String: Any], preferred: [String]) -> URL? {
        guard let images = row["images"] as? [[String: Any]], !images.isEmpty else { return nil }
        func url(from image: [String: Any]) -> URL? {
            if let remote = AcquisitionHTTP.string(image["remoteUrl"]), let url = URL(string: remote) {
                return url
            }
            guard let raw = AcquisitionHTTP.string(image["url"]), !raw.isEmpty else { return nil }
            if raw.hasPrefix("http"), let url = URL(string: raw) { return url }
            guard let base = AcquisitionHTTP.normalizedBase(base) else { return nil }
            let path = raw.hasPrefix("/") ? raw : "/\(raw)"
            var comps = URLComponents(string: base + path)
            var items = comps?.queryItems ?? []
            if !items.contains(where: { $0.name.lowercased() == "apikey" }) {
                items.append(URLQueryItem(name: "apikey", value: apiKey))
            }
            comps?.queryItems = items
            return comps?.url
        }
        for type in preferred {
            if let image = images.first(where: {
                (AcquisitionHTTP.string($0["coverType"]) ?? "").lowercased() == type
            }), let url = url(from: image) {
                return url
            }
        }
        return images.lazy.compactMap(url).first
    }

    /// Lookup payloads sometimes embed media/tracks before the album is in Lidarr.
    private func parseEmbeddedTracks(from row: [String: Any], albumTitle: String) -> [BrowseAlbumPreviewTrack] {
        var rawTracks: [[String: Any]] = []
        if let media = row["media"] as? [[String: Any]] {
            for medium in media {
                if let tracks = medium["tracks"] as? [[String: Any]] {
                    rawTracks.append(contentsOf: tracks)
                }
            }
        }
        if rawTracks.isEmpty, let releases = row["releases"] as? [[String: Any]] {
            for release in releases {
                if let media = release["media"] as? [[String: Any]] {
                    for medium in media {
                        if let tracks = medium["tracks"] as? [[String: Any]] {
                            rawTracks.append(contentsOf: tracks)
                        }
                    }
                }
                if !rawTracks.isEmpty { break }
            }
        }
        if rawTracks.isEmpty, let tracks = row["tracks"] as? [[String: Any]] {
            rawTracks = tracks
        }
        return rawTracks.enumerated().compactMap { index, track in
            guard let title = AcquisitionHTTP.string(track["title"])
                ?? AcquisitionHTTP.string(track["trackName"]),
                  !title.isEmpty
            else { return nil }
            let position = AcquisitionHTTP.int(track["trackNumber"])
                ?? AcquisitionHTTP.int(track["absoluteTrackNumber"])
                ?? (index + 1)
            let duration: TimeInterval?
            if let ms = AcquisitionHTTP.double(track["duration"]) {
                duration = ms > 1000 ? ms / 1000 : ms
            } else {
                duration = nil
            }
            return BrowseAlbumPreviewTrack(
                id: "lidarr-lookup:\(albumTitle):\(position):\(title)",
                position: position,
                title: title,
                duration: duration
            )
        }
        .sorted { $0.position < $1.position }
    }
}

/// Session cache for `GET /api/v1/artist` so artist page + profile + Following
/// don't each download the full Lidarr library.
private actor LidarrArtistListCache {
    static let shared = LidarrArtistListCache()

    private var rows: [[String: Any]] = []
    private var base = ""
    private var savedAt = Date.distantPast
    private var inFlight: Task<[[String: Any]], Error>?
    private let ttl: TimeInterval = 5 * 60

    func artists(
        base: String,
        fetch: @Sendable @escaping () async throws -> [[String: Any]]
    ) async throws -> [[String: Any]] {
        if self.base == base, Date().timeIntervalSince(savedAt) < ttl, !rows.isEmpty {
            return rows
        }
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await fetch() }
        inFlight = task
        defer { inFlight = nil }
        let fresh = try await task.value
        self.rows = fresh
        self.base = base
        self.savedAt = Date()
        return fresh
    }

    func reset() {
        inFlight?.cancel()
        inFlight = nil
        rows = []
        base = ""
        savedAt = Date.distantPast
    }
}
