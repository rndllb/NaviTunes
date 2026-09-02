import Foundation

/// Acquisition backend for Lidarr. Album-level: Lidarr resolves the release on its
/// MusicBrainz-backed catalog, adds + monitors the album, and triggers an indexer search.
///
/// Works around Lidarr #5012 (adding an album whose artist is new unmonitors the album
/// right after, so the auto-search finds nothing): we add with `searchForNewAlbum=false`,
/// wait for the album row, force-monitor just that album, then trigger `AlbumSearch`.
struct LidarrAcquisitionPlugin: AcquisitionProviding {
    let kind: AcquisitionPluginKind = .lidarr

    /// Prefix for the native id this plugin hands back from ``enqueue(_:progress:)`` — and the
    /// same one ``activeJobs()`` stamps on a queue row once it knows which album it belongs to.
    /// Matching the two is what lets the manager follow a request into the download queue.
    static let nativeIdPrefix = "lidarr:"

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

    func enqueue(_ request: AcquisitionRequest) async throws -> String {
        guard isConfigured else { throw AcquisitionError("Configure Lidarr in Settings first.") }
        // **No progress is reported from here at all**, deliberately. This function places a
        // request — catalog lookup, add, trigger a search — and does not transfer a byte of audio,
        // so any fraction it emits is the app describing its own bookkeeping as though it were a
        // download. That is what produced first the 100% stall and then the 10% one. Everything
        // displayed for a Lidarr request now comes from `requestState(for:)`, which reads Lidarr.
        let albumTitle = request.albumTitle ?? request.trackTitle ?? ""
        let term: String
        if !albumTitle.isEmpty {
            term = "\(request.artist) \(albumTitle)"
        } else {
            term = request.artist
        }
        let candidates = try await albumLookup(term: term)
        guard let pick = pickBestAlbum(from: candidates, artist: request.artist, albumTitle: albumTitle) else {
            throw AcquisitionError("No matching album found in Lidarr for \"\(term)\".")
        }
        let foreignId = try await addOrSearchExistingAlbum(lookup: pick)
        return "\(Self.nativeIdPrefix)\(foreignId)"
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
            // nil, not 0, when Lidarr gives no size: "we don't know" and "nothing transferred yet"
            // are different facts and must not render the same.
            let progress: Double? = size > 0 ? max(0, min(1, 1 - left / size)) : nil
            let album = row["album"] as? [String: Any]
            let artist = row["artist"] as? [String: Any]
            // A queue row's `title` is the *release* name from the indexer
            // ("Daniel.Caesar-Japanese.Denim-SINGLE-WEB-2016-ENRiCH"), which matches neither what
            // the user asked for nor anything the manager can compare against. The album object —
            // present because the queue is fetched with `includeAlbum` — carries the real title
            // and, crucially, the same `foreignAlbumId` that `enqueue` returned as its native id.
            // Stamping it here is what lets a request be followed into the queue and out the other
            // side; without it the app's job never matches its own download.
            let foreignAlbumId = AcquisitionHTTP.string(album?["foreignAlbumId"])
            let albumTitle = AcquisitionHTTP.string(album?["title"])
            let releaseTitle = AcquisitionHTTP.string(row["title"]) ?? "Download"
            out.append(AcquisitionJob(
                id: "lidarr-queue:\(qid)",
                title: albumTitle ?? releaseTitle,
                artist: AcquisitionHTTP.string(artist?["artistName"]),
                albumTitle: albumTitle,
                status: Self.status(
                    fromQueue: AcquisitionHTTP.string(row["status"]) ?? "",
                    trackedState: AcquisitionHTTP.string(row["trackedDownloadState"]) ?? "",
                ),
                progress: progress,
                message: AcquisitionHTTP.string(row["errorMessage"]) ?? AcquisitionHTTP.string(row["timeleft"]),
                kind: .lidarr,
                nativeId: foreignAlbumId.map { "\(Self.nativeIdPrefix)\($0)" } ?? "lidarr-queue:\(qid)",
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
                // A running Lidarr command exposes no completion fraction, so there is none to
                // show. This used to read `0.4`, a number chosen to make the bar look busy.
                progress: nil,
                message: AcquisitionHTTP.string(cmd["message"]),
                kind: .lidarr,
                nativeId: "lidarr-cmd:\(cid)",
                source: .server
            ))
        }
        return out
    }

    /// Whether the album behind this request now has files in Lidarr.
    ///
    /// Leaving the queue is not the same as succeeding — a failed grab is removed too — so the
    /// only trustworthy answer is Lidarr's own file count for the album. `nil` when the question
    /// cannot be answered (not configured, unknown id shape, request failed), so the caller can
    /// tell "no" apart from "don't know".
    func isRequestSatisfied(nativeId: String) async -> Bool? {
        guard isConfigured, nativeId.hasPrefix(Self.nativeIdPrefix) else { return nil }
        let foreignId = String(nativeId.dropFirst(Self.nativeIdPrefix.count))
        guard let row = await libraryAlbum(foreignAlbumId: foreignId) else { return nil }
        guard let stats = row["statistics"] as? [String: Any] else { return false }
        if let files = AcquisitionHTTP.int(stats["trackFileCount"]) { return files > 0 }
        if let percent = AcquisitionHTTP.double(stats["percentOfTracks"]) { return percent > 0 }
        return false
    }

    /// The whole state of one request, derived entirely from Lidarr's own records.
    ///
    /// Read in order of authority, and every branch ends somewhere terminal so a request can never
    /// hang:
    ///
    /// 1. **Files on disk** (`statistics.trackFileCount`) — the only proof of success, and true
    ///    whether or not the app ever saw the download happen.
    /// 2. **The download queue** — real transfer fraction from `size`/`sizeleft`, and the
    ///    import-failure state from `trackedDownloadState`.
    /// 3. **The search command** — still running means still searching.
    /// 4. **History** — a completed search that grabbed nothing is `notFound`; a grab with no queue
    ///    row means the download client took it without reporting one (Soulseek and the YouTube
    ///    client both do this on server), so it is downloading with no fraction to show.
    ///
    /// Nothing here is invented: when Lidarr reports no fraction, `progress` is nil and the UI
    /// shows indeterminate rather than a made-up number.
    func requestState(for nativeId: String) async -> AcquisitionBackendState? {
        guard isConfigured, nativeId.hasPrefix(Self.nativeIdPrefix) else { return nil }
        let foreignId = String(nativeId.dropFirst(Self.nativeIdPrefix.count))
        guard let album = await libraryAlbum(foreignAlbumId: foreignId) else { return nil }

        let stats = album["statistics"] as? [String: Any]
        if let files = AcquisitionHTTP.int(stats?["trackFileCount"]), files > 0 {
            // No fraction. "Complete" is a status; attaching a manufactured 1.0 to it would be the
            // same invention this pass removes, just pointing the right way.
            return AcquisitionBackendState(phase: .completed)
        }
        guard let albumId = AcquisitionHTTP.int(album["id"]) else { return nil }

        if let row = await queueRecord(forAlbumId: albumId) {
            let size = AcquisitionHTTP.double(row["size"]) ?? 0
            let left = AcquisitionHTTP.double(row["sizeleft"]) ?? 0
            let fraction = size > 0 ? max(0, min(1, 1 - left / size)) : nil
            let tracked = (AcquisitionHTTP.string(row["trackedDownloadState"]) ?? "").lowercased()
            let status = (AcquisitionHTTP.string(row["status"]) ?? "").lowercased()
            let message = AcquisitionHTTP.string(row["errorMessage"])

            if ["importfailed", "failedpending", "failed"].contains(tracked) {
                return AcquisitionBackendState(
                    phase: .failed,
                    progress: fraction,
                    detail: message ?? "The download finished but Lidarr could not import it.",
                )
            }
            if ["importpending", "importing"].contains(tracked) || status == "completed" {
                return AcquisitionBackendState(phase: .importing, progress: fraction, detail: message)
            }
            if status == "failed" || status == "warning" {
                return AcquisitionBackendState(phase: .failed, progress: fraction, detail: message)
            }
            if status == "downloading" || status == "paused" {
                return AcquisitionBackendState(phase: .downloading, progress: fraction, detail: message)
            }
            return AcquisitionBackendState(phase: .queued, progress: fraction, detail: message)
        }

        let search = await latestAlbumSearchCommand(albumId: albumId)
        if let search, ["queued", "started", "running"].contains(
            (AcquisitionHTTP.string(search["status"]) ?? "").lowercased()
        ) {
            return AcquisitionBackendState(phase: .searching)
        }

        // Nothing queued and no files. Did the search actually grab anything? A grab with no queue
        // row is a download client that does not report one — Soulseek and the YouTube client both
        // behave this way here — so it is genuinely in flight, just invisible.
        let since = search.flatMap { AcquisitionHTTP.date($0["started"]) }
        if let grabbedAt = await lastGrab(albumId: albumId, since: since) {
            // Lidarr grabbed something, and then: no queue row, no files. Calling that
            // "downloading" would be the app asserting a transfer the backend never reported —
            // which is the whole complaint. It is reported as what it is. This is exactly the
            // "Back to Strangers" case: two grabs, nothing queued, nothing on disk.
            guard Date().timeIntervalSince(grabbedAt) < Self.grabStaleAfter else {
                return AcquisitionBackendState(
                    phase: .failed,
                    detail: "Lidarr grabbed a release but nothing ever arrived.",
                )
            }
            return AcquisitionBackendState(
                phase: .noActivity,
                detail: "Lidarr grabbed a release. Nothing is downloading and no files have arrived.",
            )
        }
        if let search {
            return AcquisitionBackendState(
                phase: .notFound,
                detail: AcquisitionHTTP.string(search["message"]),
            )
        }
        // Lidarr has the album and reports nothing against it at all.
        return AcquisitionBackendState(
            phase: .noActivity,
            detail: "Lidarr isn't reporting any activity for this.",
        )
    }

    /// The queue row for an album, across **every** page.
    ///
    /// Paging matters: 133 records and a single `pageSize=100` read misses 33
    /// of them, which is one of the ways a request could be downloading in plain sight and still
    /// look stalled to the app.
    private func queueRecord(forAlbumId albumId: Int) async -> [String: Any]? {
        for row in await allQueueRecords() {
            let nested = AcquisitionHTTP.int((row["album"] as? [String: Any])?["id"])
            if nested == albumId || AcquisitionHTTP.int(row["albumId"]) == albumId { return row }
        }
        return nil
    }

    private func latestAlbumSearchCommand(albumId: Int) async -> [String: Any]? {
        guard let data = try? await send(path: "command") else { return nil }
        let rows = (data as? [[String: Any]] ?? []).filter { cmd in
            guard (AcquisitionHTTP.string(cmd["name"]) ?? "").lowercased() == "albumsearch" else { return false }
            let ids = (cmd["body"] as? [String: Any])?["albumIds"] as? [Any] ?? []
            return ids.compactMap { AcquisitionHTTP.int($0) }.contains(albumId)
        }
        return rows.max { lhs, rhs in
            let l = AcquisitionHTTP.date(lhs["started"]) ?? .distantPast
            let r = AcquisitionHTTP.date(rhs["started"]) ?? .distantPast
            return l < r
        }
    }

    /// How long a grab with nothing to show for it still counts as "in flight".
    private static let grabStaleAfter: TimeInterval = 2 * 60 * 60

    /// When Lidarr last grabbed a release for this album, optionally only counting grabs since a
    /// given moment. `nil` when it never did.
    private func lastGrab(albumId: Int, since: Date?) async -> Date? {
        guard let data = try? await send(path: "history", query: [
            "page": "1",
            "pageSize": "20",
            "albumId": String(albumId),
        ]) else { return nil }
        let records = (data as? [String: Any])?["records"] as? [[String: Any]] ?? []
        let dates = records.compactMap { row -> Date? in
            guard (AcquisitionHTTP.string(row["eventType"]) ?? "").lowercased() == "grabbed" else { return nil }
            guard let date = AcquisitionHTTP.date(row["date"]) else { return nil }
            // A minute of slack: the grab is logged a moment after the search starts.
            if let since, date < since.addingTimeInterval(-60) { return nil }
            return date
        }
        return dates.max()
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

    /// Album search for Discover.
    ///
    /// `supportsTrackSearch` stays **false** — Lidarr has no track-search endpoint, so advertising
    /// one would only fire a request that cannot be answered. This is the album-level route to the
    /// same goal: `album/lookup` is the MusicBrainz-backed search Lidarr's own "Add New Album" uses,
    /// and it resolves a bare song title to the single that carries it. Reusing the lookup that
    /// ``enqueue(_:progress:)`` already resolves requests against is what guarantees a row surfaced
    /// here is one the enqueue path can actually act on.
    func searchAlbums(query: String) async -> [AcquisitionRelease] {
        guard isConfigured else { return [] }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let rows = (try? await albumLookup(term: term)) ?? []
        var seen = Set<String>()
        var out: [AcquisitionRelease] = []
        for row in rows {
            // An artist-less row cannot be requested (the request is keyed on artist + title) and
            // cannot be matched against the library to suppress a duplicate. Drop it.
            guard let release = mapAlbum(row, artistFallback: ""), !release.artist.isEmpty else { continue }
            guard seen.insert(release.id).inserted else { continue }
            out.append(release)
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
        await allQueueRecords()
    }

    /// Every queue record, following `totalRecords` across pages.
    ///
    /// A single `pageSize=100` read used to be the whole of it. queue holds 133, so 33
    /// records were invisible to the app — and a request sitting in that tail looked, to the UI,
    /// exactly like one that had vanished. Bounded at five pages so a pathological queue cannot
    /// turn one poll into an unbounded crawl.
    private func allQueueRecords() async -> [[String: Any]] {
        var out: [[String: Any]] = []
        for page in 1 ... 5 {
            // `includeAlbum` / `includeArtist` are what put the real album title and its
            // `foreignAlbumId` on each row — see the note in `activeJobs()`.
            guard let data = try? await send(path: "queue", query: [
                "page": String(page),
                "pageSize": "100",
                "includeAlbum": "true",
                "includeArtist": "true",
            ]) else { break }
            guard let payload = data as? [String: Any],
                  let records = payload["records"] as? [[String: Any]]
            else {
                out.append(contentsOf: data as? [[String: Any]] ?? [])
                break
            }
            out.append(contentsOf: records)
            let total = AcquisitionHTTP.int(payload["totalRecords"]) ?? out.count
            if records.isEmpty || out.count >= total { break }
        }
        return out
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

    /// Force-monitor the album, **prove it stuck**, and only then search.
    ///
    /// The original workaround for Lidarr #5012 wrote the monitor flag once with `try?` and fired
    /// the search regardless. On 2026-08-29 that failed in the field and the failure was invisible:
    /// album 76243 ("Here Comes The Rain / Back To Strangers", Rehash) came out of a request with
    /// `monitored: false`, and the app sat at a made-up 10% for ever.
    ///
    /// What actually goes wrong is a race. Adding an album whose artist is new makes Lidarr create
    /// the artist and queue a `RefreshArtist`; the artist row for that album was stamped
    /// `added: 21:04:24Z` and `RefreshArtist` completed at `21:04:24` — the same second the app was
    /// writing its monitor flag. The refresh rewrites album rows from metadata and takes the flag
    /// back out. Writing once and hoping loses that race about as often as it wins it. (Verified
    /// afterwards from this session: the identical PUT, issued with no refresh in flight, sticks
    /// first time.)
    ///
    /// An unmonitored album is not a cosmetic problem. `statistics.trackCount` reads **0** while it
    /// is unmonitored — measured: monitoring 76243 flipped it straight from 0 to 2 — so a search
    /// has nothing to work with.
    ///
    /// So: wait for any refresh of this artist to finish, then write-and-verify in a loop, and
    /// throw rather than search into the void if it will not hold.
    private func monitorAndSearch(album: [String: Any], albumId: Int) async throws {
        await waitForArtistRefresh(artistId: AcquisitionHTTP.int(album["artistId"]))
        try await ensureAlbumMonitored(albumId: albumId, fallbackBody: album)
        try await triggerAlbumSearch(albumIds: [albumId])
    }

    /// Blocks while Lidarr is refreshing this artist, so the monitor write lands after the rewrite
    /// rather than under it. Bounded — a refresh that never ends must not wedge a request.
    private func waitForArtistRefresh(artistId: Int?) async {
        guard let artistId else { return }
        for _ in 0 ..< 12 {
            guard let data = try? await send(path: "command") else { return }
            let running = (data as? [[String: Any]] ?? []).contains { cmd in
                let name = (AcquisitionHTTP.string(cmd["name"]) ?? "").lowercased()
                guard name == "refreshartist" else { return false }
                let status = (AcquisitionHTTP.string(cmd["status"]) ?? "").lowercased()
                guard status == "queued" || status == "started" || status == "running" else { return false }
                let body = cmd["body"] as? [String: Any]
                // A refresh with no artist id refreshes everything, which includes this one.
                guard let target = AcquisitionHTTP.int(body?["artistId"]) else { return true }
                return target == artistId
            }
            if !running { return }
            try? await Task.sleep(for: .milliseconds(750))
        }
    }

    /// Writes `monitored = true` and re-reads until Lidarr agrees.
    private func ensureAlbumMonitored(albumId: Int, fallbackBody: [String: Any]) async throws {
        for attempt in 0 ..< 5 {
            let current = (try? await send(path: "album/\(albumId)")) as? [String: Any]
            if (current?["monitored"] as? Bool) == true { return }
            var body = current ?? fallbackBody
            body["monitored"] = true
            _ = try? await send(path: "album/\(albumId)", method: "PUT", jsonBody: body)
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 400 : 1200))
        }
        let final = (try? await send(path: "album/\(albumId)")) as? [String: Any]
        guard (final?["monitored"] as? Bool) == true else {
            throw AcquisitionError("Lidarr would not keep this album monitored, so a search would find nothing.")
        }
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

    /// A queue row's `status` alone is not the whole story.
    ///
    /// `status` describes the *transfer*, so a download that finished and then failed to import
    /// reads `completed` — and it **stays in the queue in that state indefinitely**. Mapping that
    /// to `.importing` left such a row pinned at 100% forever with no way to tell it apart from
    /// one that is genuinely still importing, which is its own flavour of "gets to 100% and does
    /// nothing". `trackedDownloadState` is the field that distinguishes them; on the live server
    /// this was observed on 52 of 133 queued items, so it is not a rare corner.
    private static func status(fromQueue raw: String, trackedState: String = "") -> AcquisitionJobStatus {
        switch trackedState.lowercased() {
        case "importfailed", "failedpending", "failed": return .failed
        case "importpending", "importing": return .importing
        default: break
        }
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
