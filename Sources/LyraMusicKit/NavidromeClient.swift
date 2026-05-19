import Foundation

enum NavidromeClientError: LocalizedError {
    /// Navidrome registers `/api/song/{id}` read-only (`persistable: false`); Subsonic has no delete-song call.
    case libraryTrackDeleteUnsupported

    var errorDescription: String? {
        switch self {
        case .libraryTrackDeleteUnsupported:
            return "Navidrome does not expose deleting tracks through its API. Remove the file on disk and scan the library, or use the Navidrome web UI."
        }
    }
}

final class NavidromeClient: MusicLibraryProviding {
    private let baseURL: URL
    private(set) var token: String?
    private var username: String = ""
    private var password: String = ""
    /// From Subsonic ``getUser`` (`adminRole`).
    private(set) var isLibraryAdmin: Bool = false

    /// Subsonic `maxBitRate` for streaming (`0` = original / unlimited).
    var streamingMaxBitRate: Int = 0
    /// `maxBitRate` when saving offline MP3 transcodes.
    var offlineMaxBitRate: Int = 0

    var displayName: String { "Navidrome" }

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func applyRestoredSession(token: String, username: String, password: String) {
        self.token = token
        self.username = username
        self.password = password
    }

    var sessionToken: String? { token }

    func signIn(username: String, password: String) async throws {
        self.username = username
        self.password = password
        let ok = try await ping()
        guard ok else { throw URLError(.userAuthenticationRequired) }
        token = try await fetchToken()
    }

    func httpHeadersForMediaRequests() -> [String: String] { [:] }

    func albums(limit: Int) async throws -> [AlbumSummary] {
        try await fetchAlbumList2(limit: limit, listType: "alphabeticalByName")
    }

    func recentlyAdded(limit: Int) async throws -> [AlbumSummary] {
        try await fetchAlbumList2(limit: limit, listType: "newest")
    }

    func recentlyPlayed(limit: Int) async throws -> [AlbumSummary] {
        try await fetchAlbumList2(limit: limit, listType: "recent")
    }

    private func fetchAlbumList2(limit: Int, listType: String) async throws -> [AlbumSummary] {
        let items = try await subsonicRequest(path: "getAlbumList2", query: [
            "type": listType,
            "size": "\(limit)",
        ])
        guard let albumList = items["albumList2"] as? [String: Any] else {
            return []
        }
        let rawAlbums = albumList["album"]
        let albums: [[String: Any]]
        if let a = rawAlbums as? [[String: Any]] {
            albums = a
        } else if let o = rawAlbums as? [String: Any] {
            albums = [o]
        } else {
            albums = []
        }
        return albums.compactMap(parseAlbumDict)
    }

    private func parseAlbumDict(_ dict: [String: Any]) -> AlbumSummary? {
        guard let id = dict["id"] as? String, let name = dict["name"] as? String else {
            return nil
        }
        let artist = dict["artist"] as? String ?? ""
        let cover = dict["coverArt"] as? String
        let art: URL?
        if let cover {
            art = streamURLForCover(coverArt: cover)
        } else {
            art = nil
        }
        let songCount = navidromeInt(dict["songCount"]) ?? navidromeInt(dict["trackCount"])
        let added = navidromeCreatedDate(dict["created"])
        let genres: [String] = {
            guard let genreStr = navidromeCoerceString(dict["genre"]), !genreStr.isEmpty else { return [] }
            return genreStr.split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }()
        let releaseYear = navidromeInt(dict["year"]) ?? navidromeInt(dict["originalYear"])
        let releaseDate = navidromeAlbumReleaseDate(dict)
        return AlbumSummary(
            id: id,
            title: name,
            artist: artist,
            artworkURL: art,
            trackCount: songCount,
            libraryAddedDate: added,
            genres: genres,
            releaseYear: releaseYear,
            releaseDate: releaseDate,
        )
    }

    private func navidromeAlbumReleaseDate(_ dict: [String: Any]) -> Date? {
        let keys = ["originalReleaseDate", "released", "releaseDate", "originalDate"]
        for key in keys {
            guard let s = navidromeCoerceString(dict[key]) else { continue }
            if let d = Self.parseAlbumReleaseDateString(s) { return d }
        }
        return nil
    }

    private static func parseAlbumReleaseDateString(_ raw: String) -> Date? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let d = navidromeReleaseISOFrac.date(from: t) { return d }
        if let d = navidromeReleaseISODay.date(from: t) { return d }
        if let d = navidromeReleaseISOInternet.date(from: t) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        let head = String(t.prefix(10))
        if head.count == 10, let d = df.date(from: head) { return d }
        return nil
    }

    private static let navidromeReleaseISOFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let navidromeReleaseISODay: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    private static let navidromeReleaseISOInternet: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func navidromeInt(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func navidromeCreatedDate(_ value: Any?) -> Date? {
        if let n = value as? NSNumber {
            let ms = n.doubleValue
            if ms > 10_000_000_000 { return Date(timeIntervalSince1970: ms / 1000.0) }
            if ms > 1 { return Date(timeIntervalSince1970: ms) }
        }
        if let s = value as? String, let ts = Double(s) {
            if ts > 10_000_000_000 { return Date(timeIntervalSince1970: ts / 1000.0) }
            if ts > 1 { return Date(timeIntervalSince1970: ts) }
        }
        return nil
    }

    func tracks(forAlbumId albumId: String) async throws -> [Track] {
        let items = try await subsonicRequest(path: "getAlbum", query: ["id": albumId])
        guard let album = items["album"] as? [String: Any] else {
            return []
        }
        let rawSongs = album["song"]
        let songs: [[String: Any]]
        if let a = rawSongs as? [[String: Any]] {
            songs = a
        } else if let o = rawSongs as? [String: Any] {
            songs = [o]
        } else {
            songs = []
        }
        let albumCoverId = album["coverArt"] as? String
        let albumTitle = album["name"] as? String ?? ""
        let albumArtist = navidromeCoerceString(album["artist"])
        let albumGenreStr = navidromeCoerceString(album["genre"])
        let albumYear = navidromeInt(album["year"]) ?? navidromeInt(album["originalYear"])
        return songs.compactMap { dict in
            parseSongFromChildDict(
                dict,
                fallbackAlbumId: albumId,
                albumTitleFallback: albumTitle.isEmpty ? nil : albumTitle,
                albumCoverArtId: albumCoverId.flatMap { $0.isEmpty ? nil : $0 },
                fallbackAlbumArtist: albumArtist,
                albumGenreFallback: albumGenreStr,
                albumYearFallback: albumYear,
            )
        }
    }

    func allTracks(limit: Int) async throws -> [Track] {
        let cap = max(1, min(limit, 50_000))
        if let batch = try? await fetchSongsViaSearch3(cap: cap), !batch.isEmpty {
            return Array(batch.prefix(cap))
        }
        return try await allTracksByWalkingAlbums(limit: cap)
    }

    private func fetchSongsViaSearch3(cap: Int) async throws -> [Track] {
        for query in ["*", "a", ""] {
            let items = try await subsonicRequest(path: "search3", query: [
                "query": query,
                "songCount": "\(cap)",
                "albumCount": "0",
                "artistCount": "0",
            ])
            guard let result = navidromeDict(items["searchResult3"]) else { continue }
            let songs = childDictArray(from: result, key: "song")
            let parsed = songs.compactMap { parseSongFromChildDict($0) }
            if !parsed.isEmpty { return parsed }
        }
        return []
    }

    private func allTracksByWalkingAlbums(limit: Int) async throws -> [Track] {
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

    func libraryArtists(limit: Int) async throws -> [LibraryArtistSummary] {
        let items = try await subsonicRequest(path: "getArtists", query: [:])
        guard let artistsRoot = items["artists"] as? [String: Any] else {
            return []
        }
        var out: [LibraryArtistSummary] = []
        out.reserveCapacity(512)
        appendLibraryArtists(from: artistsRoot["artist"], into: &out)
        let rawIndexes = artistsRoot["index"]
        let indexes: [[String: Any]]
        if let a = rawIndexes as? [[String: Any]] {
            indexes = a
        } else if let o = rawIndexes as? [String: Any] {
            indexes = [o]
        } else {
            indexes = []
        }
        for idx in indexes {
            appendLibraryArtists(from: idx["artist"], into: &out)
        }
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let cap = max(1, min(limit, 20_000))
        return Array(out.prefix(cap))
    }

    private func appendLibraryArtists(from raw: Any?, into out: inout [LibraryArtistSummary]) {
        for dict in navidromeDictRows(raw) {
            guard let id = navidromeCoerceString(dict["id"]),
                  let name = navidromeCoerceString(dict["name"]),
                  !name.isEmpty
            else { continue }
            let art: URL?
            if let urlStr = navidromeCoerceString(dict["artistImageUrl"]),
               let u = URL(string: urlStr),
               u.scheme != nil {
                art = u
            } else if let cover = navidromeCoerceString(dict["coverArt"]) {
                art = streamURLForCover(coverArt: cover)
            } else {
                art = nil
            }
            out.append(LibraryArtistSummary(id: id, name: name, artworkURL: art))
        }
    }

    private func navidromeDictRows(_ raw: Any?) -> [[String: Any]] {
        if let a = raw as? [[String: Any]] { return a }
        if let o = raw as? [String: Any] { return [o] }
        return []
    }

    private func countArtistsInLibraryIndex() async throws -> Int {
        let items = try await subsonicRequest(path: "getArtists", query: [:])
        guard let artistsRoot = items["artists"] as? [String: Any] else {
            return 0
        }
        var count = 0
        for dict in navidromeDictRows(artistsRoot["artist"]) {
            if navidromeCoerceString(dict["id"]) != nil, navidromeCoerceString(dict["name"]) != nil {
                count += 1
            }
        }
        let rawIndexes = artistsRoot["index"]
        let indexes: [[String: Any]]
        if let a = rawIndexes as? [[String: Any]] {
            indexes = a
        } else if let o = rawIndexes as? [String: Any] {
            indexes = [o]
        } else {
            indexes = []
        }
        for idx in indexes {
            for dict in navidromeDictRows(idx["artist"]) {
                if navidromeCoerceString(dict["id"]) != nil, navidromeCoerceString(dict["name"]) != nil {
                    count += 1
                }
            }
        }
        return count
    }

    func libraryGenres(limit: Int) async throws -> [LibraryGenreSummary] {
        let items = try await subsonicRequest(path: "getGenres", query: [:])
        let rows: [[String: Any]]

        if let genresRoot = items["genres"] as? [String: Any] {
            let raw = genresRoot["genre"]
            if let a = raw as? [[String: Any]] {
                rows = a
            } else if let o = raw as? [String: Any] {
                rows = [o]
            } else {
                rows = []
            }
        } else if let arr = items["genres"] as? [[String: Any]] {
            rows = arr
        } else if let arr = items["genre"] as? [[String: Any]] {
            rows = arr
        } else if let o = items["genre"] as? [String: Any] {
            rows = [o]
        } else {
            rows = []
        }

        let cap = max(1, min(limit, 5000))
        let mapped: [LibraryGenreSummary] = rows.compactMap { dict in
            let name =
                (dict["value"] as? String)
                    ?? (dict["name"] as? String)
                    ?? (dict["genre"] as? String)
            guard let name, !name.isEmpty else { return nil }
            let albumCount = navidromeInt(dict["albumCount"])
            return LibraryGenreSummary(id: name, name: name, albumCount: albumCount)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return Array(mapped.prefix(cap))
    }

    func albums(forLibraryArtistId artistId: String, limit: Int) async throws -> [AlbumSummary] {
        let items = try await subsonicRequest(path: "getArtist", query: ["id": artistId])
        guard let artist = items["artist"] as? [String: Any] else {
            return []
        }
        let rawAlbums = artist["album"]
        let albums: [[String: Any]]
        if let a = rawAlbums as? [[String: Any]] {
            albums = a
        } else if let o = rawAlbums as? [String: Any] {
            albums = [o]
        } else {
            albums = []
        }
        let cap = max(1, min(limit, 5000))
        return albums.compactMap(parseAlbumDict).prefix(cap).map { $0 }
    }

    func albums(inGenre genre: LibraryGenreSummary, limit: Int) async throws -> [AlbumSummary] {
        let cap = max(1, min(limit, 5000))
        let items = try await subsonicRequest(path: "getAlbumList", query: [
            "type": "byGenre",
            "genre": genre.name,
            "size": "\(cap)",
        ])
        return albumsFromAlbumListResponse(items)
    }

    private func albumsFromAlbumListResponse(_ items: [String: Any]) -> [AlbumSummary] {
        guard let albumList = items["albumList"] as? [String: Any] else {
            return []
        }
        let rawAlbums = albumList["album"]
        let albums: [[String: Any]]
        if let a = rawAlbums as? [[String: Any]] {
            albums = a
        } else if let o = rawAlbums as? [String: Any] {
            albums = [o]
        } else {
            albums = []
        }
        return albums.compactMap(parseAlbumDict)
    }

    func streamURL(for track: Track) throws -> URL {
        try buildURL(path: "stream", query: ["id": track.id, "maxBitRate": "\(streamingMaxBitRate)"])
    }

    func fallbackStreamURLs(for track: Track) -> [URL] {
        var urls: [URL] = []
        if let mp3 = try? buildURL(
            path: "stream",
            query: ["id": track.id, "format": "mp3", "maxBitRate": "\(streamingMaxBitRate)"],
        ) {
            urls.append(mp3)
        }
        if let aac = try? buildURL(
            path: "stream",
            query: ["id": track.id, "format": "aac", "maxBitRate": "\(streamingMaxBitRate)"],
        ) {
            urls.append(aac)
        }
        return urls
    }

    func offlineDownloadURL(for track: Track) throws -> URL {
        // Request MP3 explicitly so the saved file is always AVPlayer-compatible,
        // regardless of the source format (OGG, Opus, etc.).
        try buildURL(path: "stream", query: ["id": track.id, "format": "mp3", "maxBitRate": "\(offlineMaxBitRate)"])
    }

    /// Approximate totals by fetching up to 50k rows per category (large libraries may plateau at the cap).
    func fetchApproximateLibraryStatistics() async throws -> LibraryStatistics {
        let cap = 50_000
        async let artists = countArtistsInLibraryIndex()
        async let albumRows = albums(limit: cap)
        async let trackRows = allTracks(limit: cap)
        let (artistCount, albumsList, tracksList) = try await (artists, albumRows, trackRows)
        return LibraryStatistics(
            artistCount: artistCount,
            albumCount: albumsList.count,
            songCount: tracksList.count,
            playlistCount: nil,
        )
    }

    func lyrics(for track: Track) async throws -> [LyricLine] {
        let items = try await subsonicRequest(path: "getLyrics", query: [
            "artist": track.artist,
            "title": track.title,
        ])
        guard let lyrics = items["lyrics"] as? [String: Any],
              let text = lyrics["value"] as? String
        else {
            return []
        }
        return NavidromeLyricsParser.parse(plain: text)
    }

    // MARK: - Starred favorites (Subsonic `star` / `getStarred2`, synced via Navidrome)

    func setFavorite(trackId: String, favorite: Bool) async throws {
        let path = favorite ? "star" : "unstar"
        _ = try await subsonicRequest(path: path, query: ["id": trackId])
    }

    func fetchFavoriteTracks(limit: Int = 15_000) async throws -> [Track] {
        let cap = max(1, min(limit, 20_000))
        let starred = try await fetchStarredContainer()
        let songRows = songDicts(fromStarredContainer: starred)
        let albumRows = albumDicts(fromStarredContainer: starred)

        var seen = Set<String>()
        var out: [Track] = []
        out.reserveCapacity(min(songRows.count + albumRows.count * 12, cap))

        for d in songRows {
            guard out.count < cap else { break }
            let track: Track?
            if let t = parseSongFromChildDict(d) {
                track = t
            } else if let sid = navidromeCoerceString(d["id"]) {
                track = try await fetchTrackViaGetSong(id: sid)
            } else {
                track = nil
            }
            guard let track else { continue }
            if seen.insert(track.id).inserted {
                out.append(track)
            }
        }

        // Navidrome "Favourites" includes starred albums; those only appear under `album`, not `song`.
        let albumIds: [String] = albumRows.compactMap { navidromeCoerceString($0["id"]) }
        if !albumIds.isEmpty {
            let expanded = await expandFavoriteAlbumTracks(albumIds: albumIds, cap: cap)
            for t in expanded {
                guard out.count < cap else { break }
                if seen.insert(t.id).inserted {
                    out.append(t)
                }
            }
        }

        return out
    }

    private func expandFavoriteAlbumTracks(albumIds: [String], cap: Int) async -> [Track] {
        var collected: [Track] = []
        collected.reserveCapacity(min(cap, albumIds.count * 8))
        let chunkSize = 6
        var index = 0
        while index < albumIds.count, collected.count < cap {
            let end = min(index + chunkSize, albumIds.count)
            let chunk = Array(albumIds[index ..< end])
            await withTaskGroup(of: [Track].self) { group in
                for albumId in chunk {
                    group.addTask {
                        (try? await self.tracks(forAlbumId: albumId)) ?? []
                    }
                }
                for await batch in group {
                    for t in batch {
                        collected.append(t)
                        if collected.count >= cap { break }
                    }
                }
            }
            index = end
        }
        return collected
    }

    func fetchFavoriteTrackIds(limit: Int = 20_000) async throws -> Set<String> {
        Set(try await fetchFavoriteTracks(limit: limit).map(\.id))
    }

    /// Payload from ``getStarred2`` / ``getStarred``: starred songs, albums, and artists (Navidrome UI: Favourites).
    private func fetchStarredContainer() async throws -> [String: Any] {
        if let items2 = try? await subsonicRequest(path: "getStarred2", query: [:]),
           let starred = navidromeDict(items2["starred2"]) {
            return starred
        }
        let items1 = try await subsonicRequest(path: "getStarred", query: [:])
        return navidromeDict(items1["starred"]) ?? [:]
    }

    private func songDicts(fromStarredContainer starred: [String: Any]) -> [[String: Any]] {
        childDictArray(from: starred, key: "song")
    }

    private func albumDicts(fromStarredContainer starred: [String: Any]) -> [[String: Any]] {
        childDictArray(from: starred, key: "album")
    }

    /// Bridges JSONSerialization / NSDictionary payloads into Swift dictionaries (nested ``starred2`` / ``Child`` rows).
    private func navidromeDict(_ value: Any?) -> [String: Any]? {
        switch value {
        case let d as [String: Any]:
            return d
        case let d as NSDictionary:
            return d as? [String: Any]
        default:
            return nil
        }
    }

    /// Normalizes Subsonic ``song`` / ``album`` arrays (single object, mixed ``Any``, or ``NSDictionary`` rows).
    private func childDictArray(from container: [String: Any], key: String) -> [[String: Any]] {
        guard let raw = container[key] else { return [] }
        if let a = raw as? [[String: Any]] { return a }
        if let o = raw as? [String: Any] { return [o] }
        if let anyArr = raw as? [Any] {
            return anyArr.compactMap { navidromeDict($0) }
        }
        return []
    }

    /// Subsonic JSON sometimes uses strings vs numbers; minimal clients may omit album fields (handled via ``fetchTrackViaGetSong``).
    private func navidromeCoerceString(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case let n as NSNumber:
            return n.stringValue
        case let i as Int:
            return "\(i)"
        default:
            return nil
        }
    }

    private func fetchTrackViaGetSong(id: String) async throws -> Track? {
        let items = try await subsonicRequest(path: "getSong", query: ["id": id])
        guard let song = navidromeDict(items["song"]) else { return nil }
        return parseSongFromChildDict(song)
    }

    /// Parses a Subsonic ``Child`` / song JSON object into a ``Track`` (library & starred responses).
    private func parseSongFromChildDict(
        _ dict: [String: Any],
        fallbackAlbumId: String? = nil,
        albumTitleFallback: String? = nil,
        albumCoverArtId: String? = nil,
        fallbackAlbumArtist: String? = nil,
        albumGenreFallback: String? = nil,
        albumYearFallback: Int? = nil,
    ) -> Track? {
        guard let id = navidromeCoerceString(dict["id"]) else { return nil }
        let rawTitle =
            navidromeCoerceString(dict["title"])
            ?? navidromeCoerceString(dict["name"])
        let title =
            (rawTitle.flatMap { $0.isEmpty ? nil : $0 })
            ?? titleFromPath(dict["path"])
            ?? "Unknown title"

        let albumId =
            navidromeCoerceString(dict["albumId"])
            ?? navidromeCoerceString(dict["parent"])
            ?? fallbackAlbumId.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard let albumIdFinal = albumId, !albumIdFinal.isEmpty else { return nil }

        let albumTitle =
            navidromeCoerceString(dict["album"])
            ?? albumTitleFallback.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? ""

        let artist =
            navidromeCoerceString(dict["artist"])
            ?? navidromeCoerceString(dict["displayArtist"])
            ?? navidromeCoerceString(dict["displayAlbumArtist"])
            ?? fallbackAlbumArtist.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? ""

        let duration: Double = {
            if let n = dict["duration"] as? NSNumber { return Double(truncating: n) }
            if let s = dict["duration"] as? String { return Double(s) ?? 0 }
            return 0
        }()
        let disc = intFromNavidrome(dict["discNumber"]) ?? 1
        let index = intFromNavidrome(dict["track"]) ?? 0
        let coverId =
            navidromeCoerceString(dict["coverArt"])
            ?? albumCoverArtId.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let art = coverId.flatMap { streamURLForCover(coverArt: $0) }
        let added = navidromeCreatedDate(dict["created"])

        let songGenre = navidromeCoerceString(dict["genre"])
        let genres: [String] = {
            if let songGenre, !songGenre.isEmpty { return [songGenre] }
            if let albumGenreFallback, !albumGenreFallback.isEmpty { return [albumGenreFallback] }
            return []
        }()
        let releaseYear = intFromNavidrome(dict["year"]) ?? albumYearFallback

        let suffixRaw = navidromeCoerceString(dict["suffix"])?.lowercased() ?? ""
        let codecFromSuffix: String = suffixRaw.replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let audioCodec: String? = codecFromSuffix.isEmpty ? nil : codecFromSuffix

        let bitRate = navidromeInt(dict["bitRate"])

        return Track(
            id: id,
            title: title,
            albumId: albumIdFinal,
            albumTitle: albumTitle,
            artist: artist,
            duration: duration,
            discNumber: disc,
            indexNumber: index,
            artworkURL: art,
            libraryAddedDate: added,
            genres: genres,
            releaseYear: releaseYear,
            sampleRateHz: nil,
            audioChannels: nil,
            audioCodec: audioCodec,
            audioBitDepth: nil,
            audioBitRateKbps: bitRate,
        )
    }

    private func titleFromPath(_ value: Any?) -> String? {
        guard let path = navidromeCoerceString(value) else { return nil }
        let last = (path as NSString).lastPathComponent
        let base = (last as NSString).deletingPathExtension
        let t = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func intFromNavidrome(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func streamURLForCover(coverArt: String) -> URL? {
        try? buildURL(path: "getCoverArt", query: ["id": coverArt, "size": "400"])
    }

    // MARK: - Playlists (Subsonic)

    func fetchPlaylistSummaries(limit: Int = 500) async throws -> [PlaylistSummary] {
        let items = try await subsonicRequest(path: "getPlaylists", query: [:])
        guard let root = navidromeDict(items["playlists"]) else { return [] }
        let rows = childDictArray(from: root, key: "playlist")
        let cap = max(1, min(limit, 2000))
        return rows.prefix(cap).compactMap(parsePlaylistDictSummary)
    }

    func fetchPlaylistRows(playlistId: String) async throws -> [PlaylistRowItem] {
        let items = try await subsonicRequest(path: "getPlaylist", query: ["id": playlistId])
        guard let pl = navidromeDict(items["playlist"]) else { return [] }
        let entries = childDictArray(from: pl, key: "entry")
        var out: [PlaylistRowItem] = []
        out.reserveCapacity(entries.count)
        for (idx, dict) in entries.enumerated() {
            let track: Track?
            if let t = parseSongFromChildDict(dict) {
                track = t
            } else if let sid = navidromeCoerceString(dict["id"]) {
                track = try await fetchTrackViaGetSong(id: sid)
            } else {
                track = nil
            }
            guard let track else { continue }
            let rowId = "\(playlistId)-\(idx)-\(track.id)"
            out.append(
                PlaylistRowItem(
                    rowId: rowId,
                    track: track,
                    jellyfinEntryId: nil,
                    navidromeIndex: idx,
                ),
            )
        }
        return out
    }

    func createPlaylist(name: String, trackIds: [String]) async throws -> PlaylistSummary {
        let repeated = trackIds.map { ("songId", $0) }
        let items = try await subsonicRequest(path: "createPlaylist", query: ["name": name], repeatedQuery: repeated)
        if let pl = navidromeDict(items["playlist"]),
           let summary = parsePlaylistDictSummary(pl) {
            return summary
        }
        let all = try await fetchPlaylistSummaries(limit: 500)
        if let match = all.first(where: { $0.name == name }) {
            return match
        }
        throw URLError(.cannotParseResponse)
    }

    func addTracksToPlaylist(playlistId: String, trackIds: [String]) async throws {
        guard !trackIds.isEmpty else { return }
        let repeated = trackIds.map { ("songIdToAdd", $0) }
        _ = try await subsonicRequest(path: "updatePlaylist", query: ["playlistId": playlistId], repeatedQuery: repeated)
    }

    func removeTracksFromPlaylist(playlistId: String, indexes: [Int]) async throws {
        guard !indexes.isEmpty else { return }
        for idx in indexes.sorted(by: >) {
            _ = try await subsonicRequest(path: "updatePlaylist", query: [
                "playlistId": playlistId,
                "songIndexToRemove": "\(idx)",
            ])
        }
    }

    func renamePlaylist(playlistId: String, name: String) async throws {
        _ = try await subsonicRequest(path: "updatePlaylist", query: [
            "playlistId": playlistId,
            "name": name,
        ])
    }

    func deletePlaylist(playlistId: String) async throws {
        _ = try await subsonicRequest(path: "deletePlaylist", query: ["id": playlistId])
    }

    func deleteTrackFromLibrary(trackId: String) async throws {
        _ = trackId
        throw NavidromeClientError.libraryTrackDeleteUnsupported
    }

    private func parsePlaylistDictSummary(_ dict: [String: Any]) -> PlaylistSummary? {
        guard let id = navidromeCoerceString(dict["id"]),
              let name = navidromeCoerceString(dict["name"]),
              !name.isEmpty
        else {
            return nil
        }
        let count = navidromeInt(dict["songCount"])
        let coverId = navidromeCoerceString(dict["coverArt"])
        let art = coverId.flatMap { streamURLForCover(coverArt: $0) }
        let created = navidromeCreatedDate(dict["created"])
        return PlaylistSummary(id: id, name: name, songCount: count, artworkURL: art, libraryAddedDate: created)
    }

    /// Subsonic ``getAvatar`` for the signed-in user (toolbar profile image).
    func accountAvatarURL(username: String? = nil) -> URL? {
        guard !self.username.isEmpty || username != nil else { return nil }
        guard token != nil || !password.isEmpty else { return nil }
        var query: [String: String] = [:]
        let name = (username ?? self.username).trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            query["username"] = name
        }
        return try? buildURL(path: "getAvatar", query: query)
    }

    func verifyServerReachable() async throws {
        guard try await ping() else {
            throw URLError(.cannotConnectToHost)
        }
    }

    private func ping() async throws -> Bool {
        let items = try await subsonicRequest(path: "ping", query: [:])
        if let status = items["status"] as? String { return status == "ok" }
        return false
    }

    private func fetchToken() async throws -> String? {
        let items: [String: Any]
        if let withUser = try? await subsonicRequest(path: "getUser", query: ["username": username]),
           withUser["user"] != nil {
            items = withUser
        } else {
            items = try await subsonicRequest(path: "getUser", query: [:])
        }
        guard let user = items["user"] as? [String: Any] else { return nil }
        isLibraryAdmin = navidromeCoerceBool(user["adminRole"]) || navidromeCoerceBool(user["admin"])
        return navidromeCoerceString(user["token"])
    }

    private func navidromeCoerceBool(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t == "true" || t == "1" || t == "yes"
        }
        return false
    }

    private func subsonicRequest(path: String, query: [String: String] = [:], repeatedQuery: [(String, String)] = []) async throws -> [String: Any] {
        let url = try buildURL(path: path, query: query, repeatedQuery: repeatedQuery)
        let (data, res) = try await URLSession.shared.data(from: url)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let sub = json?["subsonic-response"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        if let err = sub["error"] as? [String: Any],
           let message = err["message"] as? String {
            throw NSError(domain: "Navidrome", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return sub
    }

    private func buildURL(path: String, query: [String: String] = [:], repeatedQuery: [(String, String)] = []) throws -> URL {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("rest/\(path)"),
            resolvingAgainstBaseURL: false,
        )!
        // Client id must not match Navidrome `Subsonic.MinimalClients`: minimal payloads omit `albumId`, which breaks favorites.
        var items: [URLQueryItem] = [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "LyraMusicKit"),
            URLQueryItem(name: "f", value: "json"),
        ]
        if let token {
            items.append(URLQueryItem(name: "s", value: token))
        } else {
            items.append(URLQueryItem(name: "p", value: password))
        }
        for (k, v) in query {
            items.append(URLQueryItem(name: k, value: v))
        }
        for pair in repeatedQuery {
            items.append(URLQueryItem(name: pair.0, value: pair.1))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw URLError(.badURL) }
        return url
    }
}

enum NavidromeLyricsParser {
    static func parse(plain: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let pattern = #"\[(\d+):(\d+)\.(\d+)\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return lines
        }
        for row in plain.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(row)
            let range = NSRange(s.startIndex..., in: s)
            guard let m = regex.firstMatch(in: s, range: range), m.numberOfRanges >= 5 else {
                if !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append(LyricLine(start: lines.last.map { $0.start + 5 } ?? 0, text: s))
                }
                continue
            }
            let min = Int((s as NSString).substring(with: m.range(at: 1))) ?? 0
            let sec = Int((s as NSString).substring(with: m.range(at: 2))) ?? 0
            let cs = Int((s as NSString).substring(with: m.range(at: 3))) ?? 0
            let text = (s as NSString).substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
            let start = TimeInterval(min * 60 + sec) + TimeInterval(cs) / 100.0
            lines.append(LyricLine(start: start, text: text))
        }
        return lines.sorted { $0.start < $1.start }
    }
}
