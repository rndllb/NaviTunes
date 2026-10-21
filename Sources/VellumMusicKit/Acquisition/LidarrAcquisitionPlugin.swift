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
        await LidarrSearchCommandLog.shared.reset()
    }

    var capabilities: AcquisitionCapabilities {
        AcquisitionCapabilities(
            displayName: "Lidarr",
            iconName: "square.stack.3d.up",
            blurb: "A music collection manager. Vellum sends album requests to Lidarr, which adds them to your collection and keeps them monitored and complete.",
            requirementsSummary: "Use the address you open Lidarr with, including the port. The API key is in Lidarr under Settings → General → Security.",
            granularity: .album,
            supportsTrackSearch: false,
            supportsReleaseCatalog: true,
            configFields: [
                AcquisitionConfigField(
                    id: "baseURL",
                    kind: .url,
                    label: "Server",
                    placeholder: "192.168.1.10:8686"
                ),
                AcquisitionConfigField(
                    id: "apiKey",
                    kind: .apiKey,
                    label: "API Key",
                    placeholder: "32-character key"
                ),
            ]
        )
    }

    /// Test Connection. An authenticated read of `system/status`, which Lidarr refuses without a
    /// valid key, and which must come back **as Lidarr**: any web server at the wrong port answers
    /// 200 with an HTML page, and that used to read as "Connected" because an unparseable body
    /// decoded to an empty object.
    func validate() async -> Result<String, Error> {
        guard isConfigured else { return .failure(AcquisitionError("Enter your Lidarr URL and API key.")) }
        do {
            let status = try await send(path: "system/status")
            guard let dict = status as? [String: Any],
                  let appName = AcquisitionHTTP.string(dict["appName"]),
                  appName.caseInsensitiveCompare("Lidarr") == .orderedSame
            else {
                return .failure(AcquisitionError("That address answered, but not as Lidarr. Check the Server Address and port."))
            }
            if let version = AcquisitionHTTP.string(dict["version"]), !version.isEmpty {
                return .success("Connected to Lidarr \(version).")
            }
            return .success("Connected to Lidarr.")
        } catch let error as AcquisitionError where error.isCredentialRejection {
            return .failure(AcquisitionError(
                "Lidarr rejected the API key. Copy it again from Lidarr → Settings → General → Security.",
                statusCode: error.statusCode
            ))
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

        // Ask by MusicBrainz id when the row carried one.
        //
        // Lidarr resolves `term=lidarr:<mbid>` as an exact catalog lookup, while a plain text term
        // goes through its metadata proxy's *search*, which is a different code path and a fallible
        // one: for some albums it answers with a SkyHookException rather than a result, so a
        // request for a release that plainly exists fails on a title the user can see on screen.
        // The id is exact, so where it exists it is the better question to ask — and the row that
        // was tapped already knows it, because the discography it came from is keyed by it.
        if let releaseGroupMBID = request.releaseGroupMBID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !releaseGroupMBID.isEmpty {
            if let pick = try? await albumLookup(term: "lidarr:\(releaseGroupMBID)").first {
                let foreignId = try await addOrSearchExistingAlbum(lookup: pick)
                return "\(Self.nativeIdPrefix)\(foreignId)"
            }
            // Lidarr did not recognise the id. That is a real possibility — its metadata mirror
            // lags MusicBrainz, so a release group new enough or obscure enough can be unknown to
            // it — and it is not a reason to give up while a second way to ask still exists.
            // Fall through to the text path rather than failing here.
        }

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

    func activeJobs() async throws -> [AcquisitionJob] {
        guard isConfigured else { return [] }
        async let queueRecords = downloadQueueRecords()
        async let commandRows = activeCommands()
        var out: [AcquisitionJob] = []
        for row in try await queueRecords {
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

        let search = await albumSearchCommand(albumId: albumId)
        if let search {
            let status = (AcquisitionHTTP.string(search["status"]) ?? "").lowercased()
            if status == "failed" || status == "aborted" {
                return AcquisitionBackendState(
                    phase: .failed,
                    detail: AcquisitionHTTP.string(search["message"]) ?? "Lidarr's search for this failed.",
                )
            }
            if ["queued", "started", "running"].contains(status) {
                // "Accepted but not started" is a real and common state on a busy server — the
                // Bambi request sat in it for over two hours — and it is not the same thing as
                // searching. Reporting them identically is what let a stalled request look fine.
                let started = AcquisitionHTTP.date(search["started"]) != nil
                guard started else {
                    return AcquisitionBackendState(
                        phase: .queued,
                        detail: "Lidarr has this search queued behind its other work.",
                    )
                }
                return AcquisitionBackendState(phase: .searching)
            }
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
        for row in (try? await allQueueRecords()) ?? [] {
            let nested = AcquisitionHTTP.int((row["album"] as? [String: Any])?["id"])
            if nested == albumId || AcquisitionHTTP.int(row["albumId"]) == albumId { return row }
        }
        return nil
    }

    /// The `AlbumSearch` command for this album — the one **we** fired where we know it, otherwise
    /// the most recent matching row.
    private func albumSearchCommand(albumId: Int) async -> [String: Any]? {
        if let ours = await LidarrSearchCommandLog.shared.commandId(forAlbumId: albumId),
           let row = (try? await send(path: "command/\(ours)")) as? [String: Any] {
            return row
        }
        return await latestAlbumSearchCommand(albumId: albumId)
    }

    private func latestAlbumSearchCommand(albumId: Int) async -> [String: Any]? {
        guard let data = try? await send(path: "command") else { return nil }
        let rows = (data as? [[String: Any]] ?? []).filter { cmd in
            guard (AcquisitionHTTP.string(cmd["name"]) ?? "").lowercased() == "albumsearch" else { return false }
            let ids = (cmd["body"] as? [String: Any])?["albumIds"] as? [Any] ?? []
            return ids.compactMap { AcquisitionHTTP.int($0) }.contains(albumId)
        }
        // Order by when Lidarr *took* the command, not when it started running it: a command that
        // has never started has `started: null`, so sorting on `started` alone sank exactly the
        // rows this function exists to find — the stalled ones — to `.distantPast`.
        func ordering(_ cmd: [String: Any]) -> Date {
            AcquisitionHTTP.date(cmd["started"])
                ?? AcquisitionHTTP.date(cmd["queued"])
                ?? .distantPast
        }
        return rows.max { ordering($0) < ordering($1) }
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
            // Same rule as `artistNameMatches`, and for the same reason: this list becomes the
            // "Request Missing" plan, so a loose match here adds another artist's records.
            LibraryTrackMatcher.normalize(release.artist) == target
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
        let foreignId: String? = {
            let candidate = release.releaseGroupMBID
                ?? release.id.replacingOccurrences(of: "mbid:", with: "")
            return candidate.count >= 36 ? candidate : nil
        }()

        // A published release's track list does not change, so a cached one is served without
        // asking again — see ``AcquisitionTrackListCache`` for why this is not on a freshness timer.
        let cacheKey = foreignId.map {
            AcquisitionTrackListCache.key(pluginKind: Self.nativeIdPrefix, releaseGroupMBID: $0)
        }
        if let cacheKey, let cached = await AcquisitionTrackListCache.loadAsync(cacheKey) {
            return cached.rows.map(BrowseAlbumPreviewTrack.init(cached:))
        }

        var albumId = release.nativeAlbumId.flatMap(Int.init)
        if albumId == nil, let foreignId, let row = await libraryAlbum(foreignAlbumId: foreignId) {
            albumId = AcquisitionHTTP.int(row["id"])
        }

        guard let albumId else {
            // Not in the backend's *library* — which is the ordinary case for a release the user
            // has not requested yet, and the reason this used to give up and show no track list at
            // all. The library is not the catalog: ask the catalog by id.
            //
            // By id, and never by title. The text form of this lookup is the call whose metadata
            // proxy fails, so retrying the same question in words would reproduce the original
            // failure. The id is exact and the row it returns carries the pressings inline.
            guard let foreignId,
                  let row = try? await albumLookup(term: "\(Self.nativeIdPrefix)\(foreignId)").first
            else { return [] }
            let tracks = parseEmbeddedTracks(from: row, albumTitle: release.title)
            if let cacheKey, !tracks.isEmpty {
                await AcquisitionTrackListCache.saveAsync(
                    key: cacheKey,
                    rows: tracks.map(\.cacheRow),
                    releaseNote: Self.preferredRelease(
                        from: row["releases"] as? [[String: Any]] ?? [],
                        albumRow: row
                    ).flatMap { AcquisitionHTTP.string($0["title"]) }
                )
            }
            return tracks
        }
        let rows = (try? await send(path: "track", query: ["albumId": String(albumId)])) as? [[String: Any]] ?? []
        let tracks = rows.enumerated().compactMap { index, row -> BrowseAlbumPreviewTrack? in
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
        if let cacheKey, !tracks.isEmpty {
            await AcquisitionTrackListCache.saveAsync(
                key: cacheKey,
                rows: tracks.map(\.cacheRow),
                releaseNote: "from the backend library album \(albumId)"
            )
        }
        return tracks
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

    private func downloadQueueRecords() async throws -> [[String: Any]] {
        try await allQueueRecords()
    }

    /// Every queue record, following `totalRecords` across pages.
    ///
    /// A single `pageSize=100` read used to be the whole of it. queue holds 133, so 33
    /// records were invisible to the app — and a request sitting in that tail looked, to the UI,
    /// exactly like one that had vanished. Bounded at five pages so a pathological queue cannot
    /// turn one poll into an unbounded crawl.
    ///
    /// The first page throws: if Lidarr cannot be read at all, the caller has to know that rather
    /// than see an empty queue. A later page failing keeps what was already read.
    private func allQueueRecords() async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for page in 1 ... 5 {
            // `includeAlbum` / `includeArtist` are what put the real album title and its
            // `foreignAlbumId` on each row — see the note in `activeJobs()`.
            let query = [
                "page": String(page),
                "pageSize": "100",
                "includeAlbum": "true",
                "includeArtist": "true",
            ]
            let data: Any
            if page == 1 {
                data = try await send(path: "queue", query: query)
            } else {
                guard let next = try? await send(path: "queue", query: query) else { break }
                data = next
            }
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

    /// Fires the indexer search and **keeps the command Lidarr hands back**.
    ///
    /// This used to be `_ = try await send(...)`. Lidarr answers an `AlbumSearch` POST with the
    /// command object — an `id`, a `status` and a `trigger` — and throwing that away is what made
    /// a search that never ran indistinguishable from one that worked. It is not a hypothetical:
    /// on this server, command **676277** (`AlbumSearch`, `trigger: manual`, the Bambi request)
    /// was `queued: 2026-09-04T02:31:27Z`, `started: null`, and still queued unstarted more than
    /// two hours later, behind three long-running searches left over from a Wanted-page
    /// "Search All Missing". Vellum reported nothing wrong for the whole two hours.
    ///
    /// So the id is captured and recorded against the album. `requestState(for:)` then asks about
    /// **this** command rather than scanning `/command` and guessing which row is ours, which is
    /// what lets the UI separate "Lidarr is searching" from "Lidarr accepted this and has not
    /// started it yet". A queue that is backed up is an ordinary condition here, not an error —
    /// it just has to be reported as itself.
    @discardableResult
    private func triggerAlbumSearch(albumIds: [Int]) async throws -> Int? {
        guard !albumIds.isEmpty else { return nil }
        let response = try await send(
            path: "command",
            method: "POST",
            jsonBody: ["name": "AlbumSearch", "albumIds": albumIds]
        )
        guard let command = response as? [String: Any],
              let commandId = AcquisitionHTTP.int(command["id"])
        else {
            // A 2xx that is not a command object means Lidarr did not take the search. Failing
            // here is the point: the caller has just proven the album is monitored, so silently
            // returning would strand a request that is ready to run.
            throw AcquisitionError("Lidarr accepted the album but would not start a search for it.")
        }
        if (AcquisitionHTTP.string(command["status"]) ?? "").lowercased() == "failed" {
            throw AcquisitionError(
                AcquisitionHTTP.string(command["message"]) ?? "Lidarr's search command failed immediately."
            )
        }
        for albumId in albumIds {
            await LidarrSearchCommandLog.shared.record(commandId: commandId, albumId: albumId)
        }
        return commandId
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
            // No `monitor` key. Sending `monitor: "none"` here is what unmonitored every artist
            // Vellum has ever added — Lidarr's `AddArtistService.SetPropertiesAndValidate` ends
            // with `if (AddOptions != null && AddOptions.Monitor == MonitorTypes.None)
            // { Monitored = false; }`, so it is written *after* our `artist["monitored"] = true`
            // and wins. Measured on the live server, one key the only difference between them:
            // Codeine (id 5360, key present) came back `monitored: false`; Bedhead (id 5361, key
            // absent) came back `monitored: true`.
            //
            // Leaving it out sets `MonitoringOptions.Monitor` to its default `Unknown`, which
            // `AlbumMonitoredService` returns early on — so no album is mass-monitored on the way
            // in, and the resulting artist is identical to one added by hand in Lidarr's own UI
            // (checked against the 20 artists added that way on 2026-08-28: all
            // `monitored: true, monitorNewItems: "all"`).
            //
            // This matters beyond tidiness: an unmonitored artist takes no part in RSS or missing
            // sweeps, so the single `AlbumSearch` fired below was the only chance a request ever
            // got. When that command was dropped, nothing ever retried it.
            artist["addOptions"] = ["monitored": true, "searchForMissingAlbums": false]
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

    /// Picks the release a **text** lookup meant, or nothing.
    ///
    /// This is the fallback path: `enqueue` prefers `lidarr:<mbid>`, and only lands here when the
    /// row carried no release-group id or Lidarr's metadata mirror did not recognise the one it
    /// carried. Matching by name is therefore unavoidable here — but it used to end
    /// `?? albums.first`, which is not a match at all. It hands back the first row of a text search
    /// whatever it is, so a request could bind to an album by an entirely different artist and
    /// **add that artist to the user's Lidarr**. Two ways in, both reachable:
    ///
    /// - `artistMatches` compared with two-way `contains`, and `String.contains("")` is `true` for
    ///   every string. `ServerPlaylistViews` builds its request as `albumOrNil?.artist ?? ""`, so a
    ///   preview row with no resolved album asks with an empty artist and matches the first row.
    /// - Short names are substrings of longer ones. Requesting "Citizen" contains-matched
    ///   "Citizen Cope"; requesting "Rocket" matched "Rocket Juice & the Moon".
    ///
    /// Adding to someone's music server is not a place to guess, so the artist must now match on
    /// normalized equality — same normalizer the rest of the app matches names with — and a lookup
    /// that matches no artist returns `nil` so `enqueue` throws its "no matching album" error
    /// instead of quietly fetching the wrong record.
    ///
    /// The artist-only last resort stays, because a track-level row on this album-level plugin
    /// (chart song rows) has a track title where an album title would go and cannot match one. It
    /// is now reached only when the artist is a strict match, which is the part that was missing.
    private func pickBestAlbum(from albums: [[String: Any]], artist: String, albumTitle: String) -> [String: Any]? {
        let wantArtist = LibraryTrackMatcher.normalize(artist)
        // An empty requested artist can only match by accident. Refuse rather than pick.
        guard !wantArtist.isEmpty else { return nil }
        let wantTitle = LibraryTrackMatcher.normalize(albumTitle)

        func artistMatches(_ dict: [String: Any]) -> Bool {
            let nested = dict["artist"] as? [String: Any]
            let raw = AcquisitionHTTP.string(nested?["artistName"])
                ?? AcquisitionHTTP.string(nested?["name"])
                ?? ""
            let name = LibraryTrackMatcher.normalize(raw)
            return !name.isEmpty && name == wantArtist
        }
        let byArtist = albums.filter(artistMatches)
        guard !byArtist.isEmpty else { return nil }

        func title(_ dict: [String: Any]) -> String {
            LibraryTrackMatcher.normalize(AcquisitionHTTP.string(dict["title"]) ?? "")
        }
        if !wantTitle.isEmpty {
            if let exact = byArtist.first(where: { title($0) == wantTitle }) { return exact }
            if let contains = byArtist.first(where: { title($0).contains(wantTitle) }) { return contains }
        }
        return byArtist.first
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

    /// Does this Lidarr artist row *are* the artist we asked for — not merely resemble them.
    ///
    /// This used to accept containment in **both** directions, which meant any short name in the
    /// library shadowed every longer name containing it. Measured against the live library
    /// (2,041 artists) on 2026-09-04:
    ///
    /// - target `nothing more` matched `NOT`, `Nothing`, `$NOT`, `OT` and `Nothing More`, and
    ///   ``libraryArtist(matching:)`` takes `.first`, so the **Nothing More** artist page resolved
    ///   to `NOT` (id 3923) — `"nothing more".contains("not")`.
    /// - target `rocket` resolved to `K` (id 3894) — `"rocket".contains("k")`. A one-letter artist
    ///   is a substring of nearly every name in the library.
    ///
    /// This is not a display-only concern. ``artistReleases(named:)`` lists the resolved artist's
    /// albums, `ArtistViewModel.makeDiscographyRequestPlan` turns those rows into the plan behind
    /// "Request Missing (N)", and `startBulkAcquisition` sends them — so a mis-resolve requested a
    /// **different artist's** discography, each row carrying a perfectly valid release-group id for
    /// the wrong record. No id-based check downstream can catch that, because by then the ids are
    /// internally consistent; the error is already baked in here.
    ///
    /// So: normalized equality. The normalizer already folds diacritics, case, punctuation and
    /// `&`/`and`, which covers the real spelling drift between a server's tags and Lidarr's
    /// metadata. Anything looser is guessing about whose music to add.
    private func artistNameMatches(_ row: [String: Any], target: String) -> Bool {
        let artistName = AcquisitionHTTP.string(row["artistName"])
            ?? AcquisitionHTTP.string(row["name"])
            ?? ""
        let norm = LibraryTrackMatcher.normalize(artistName)
        return !norm.isEmpty && norm == target
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
    /// Picks which pressing in a release group supplies the displayed track list.
    ///
    /// Ordered by how closely each signal ties the list to what the user will actually receive:
    ///
    /// 1. **The monitored release.** That is the pressing the backend will fetch, so its track
    ///    list is the one that will arrive. Nothing beats matching reality.
    /// 2. **The release whose track count equals the album's own.** The album-level count
    ///    describes the release group's canonical shape, so a pressing that agrees with it is the
    ///    standard edition.
    /// 3. **The shortest single-disc release.** Deliberately not the longest: a preview that
    ///    over-promises is worse than one that under-promises, because bonus tracks that never
    ///    arrive read as a failed download rather than as a different edition.
    /// 4. **A stable tie-break** on foreign id, so the same album shows the same list on every
    ///    open instead of flipping as the backend reorders its response.
    ///
    /// Note what this deliberately does not do: it never unions track lists across pressings.
    /// That is the tempting fix and the worst one — it manufactures a track list that no edition
    /// actually has, and presents it with more authority than any real one.
    static func preferredRelease(from releases: [[String: Any]], albumRow: [String: Any]) -> [String: Any]? {
        let withTracks = releases.filter { release in
            (release["media"] as? [[String: Any]] ?? []).contains { medium in
                !((medium["tracks"] as? [[String: Any]]) ?? []).isEmpty
            }
        }
        guard !withTracks.isEmpty else { return nil }

        if let monitored = withTracks.first(where: { ($0["monitored"] as? Bool) == true }) {
            return monitored
        }

        let albumTrackCount = AcquisitionHTTP.int(albumRow["trackCount"])
            ?? AcquisitionHTTP.int((albumRow["statistics"] as? [String: Any])?["trackCount"])
        if let albumTrackCount, albumTrackCount > 0,
           let exact = withTracks.first(where: { AcquisitionHTTP.int($0["trackCount"]) == albumTrackCount }) {
            return exact
        }

        func trackCount(_ r: [String: Any]) -> Int {
            AcquisitionHTTP.int(r["trackCount"])
                ?? (r["media"] as? [[String: Any]] ?? []).reduce(0) {
                    $0 + ((($1["tracks"] as? [[String: Any]]) ?? []).count)
                }
        }
        func mediumCount(_ r: [String: Any]) -> Int {
            AcquisitionHTTP.int(r["mediumCount"]) ?? (r["media"] as? [[String: Any]] ?? []).count
        }
        func tieBreak(_ r: [String: Any]) -> String {
            AcquisitionHTTP.string(r["foreignReleaseId"]) ?? AcquisitionHTTP.string(r["title"]) ?? ""
        }

        return withTracks.min { a, b in
            let (ma, mb) = (mediumCount(a) <= 1 ? 0 : 1, mediumCount(b) <= 1 ? 0 : 1)
            if ma != mb { return ma < mb }
            let (ta, tb) = (trackCount(a), trackCount(b))
            if ta != tb { return ta < tb }
            return tieBreak(a) < tieBreak(b)
        }
    }

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
            // Which pressing's track list to show is a real choice, and taking whichever came
            // back first was not making it. A release group holds many releases — an original, a
            // remaster, a deluxe, regional pressings — and their track lists differ.
            if let chosen = Self.preferredRelease(from: releases, albumRow: row) {
                for medium in (chosen["media"] as? [[String: Any]] ?? []) {
                    if let tracks = medium["tracks"] as? [[String: Any]] {
                        rawTracks.append(contentsOf: tracks)
                    }
                }
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

/// Which `AlbumSearch` command Vellum fired for which album, this session.
///
/// `requestState(for:)` otherwise has to scan `/command` and pick the row whose `body.albumIds`
/// contains the album — workable, but it cannot tell *our* manual search apart from a batch the
/// user started from Lidarr's own Wanted page, and it sorts on `started`, which is `null` for a
/// command that has not run. Recording the id at the moment we fire it removes the guesswork.
///
/// Session-scoped on purpose: it is an optimisation over the scan, never a source of truth, so
/// losing it on relaunch costs nothing and the scan still answers.
private actor LidarrSearchCommandLog {
    static let shared = LidarrSearchCommandLog()

    private var commandIdByAlbumId: [Int: Int] = [:]

    func record(commandId: Int, albumId: Int) {
        commandIdByAlbumId[albumId] = commandId
    }

    func commandId(forAlbumId albumId: Int) -> Int? {
        commandIdByAlbumId[albumId]
    }

    func reset() {
        commandIdByAlbumId.removeAll()
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
