import CryptoKit
import Foundation
import Security

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

/// Parsed Subsonic ``getUser`` payload for the signed-in account.
struct NavidromeUserMetadata: Equatable {
    var username: String
    var email: String?
    var scrobblingEnabled: Bool
    var maxBitRate: Int?
    var avatarLastChanged: Date?
    var allowedFolderIds: [String]

    var adminRole: Bool
    var settingsRole: Bool
    var streamRole: Bool
    var downloadRole: Bool
    var uploadRole: Bool
    var playlistRole: Bool
    var coverArtRole: Bool
    var commentRole: Bool
    var podcastRole: Bool
    var jukeboxRole: Bool
    var shareRole: Bool
    var videoConversionRole: Bool
}

final class NavidromeClient: MusicLibraryProviding {
    private(set) var baseURL: URL
    private(set) var token: String?
    private var username: String = ""
    private var password: String = ""
    /// From Subsonic ``getUser`` (`adminRole`).
    private(set) var isLibraryAdmin: Bool = false
    /// Full Subsonic ``getUser`` payload for the signed-in account. Populated on sign-in
    /// and refreshable via ``refreshUserMetadata()``.
    private(set) var currentUserMetadata: NavidromeUserMetadata?
    /// JWT for Navidrome's native (non-Subsonic) REST API at ``/api/...``. Lazily obtained
    /// the first time we need to call a native endpoint (e.g. detecting custom playlist art).
    private var nativeAuthToken: String?

    /// Subsonic `maxBitRate` for streaming (`0` = original / unlimited).
    var streamingMaxBitRate: Int = 0
    /// Subsonic stream format preset.
    var streamingFormat: StreamFormatOption = .raw
    /// `maxBitRate` when saving offline transcodes.
    var offlineMaxBitRate: Int = 0
    /// Offline download format preset.
    var offlineFormat: DownloadFormatOption = .mp3

    var displayName: String { "Navidrome" }

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func updateBaseURL(_ url: URL) {
        baseURL = url
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
        try await refreshUserMetadata()
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
        let cover = navidromeCoerceString(dict["coverArt"]) ?? id
        let art = streamURLForCover(coverArt: cover)
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
            coverArtId: cover,
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

    private func navidromeBool(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t == "true" || t == "1" || t == "yes"
        }
        return false
    }

    private func navidromeOptionalDate(_ value: Any?) -> Date? {
        if let date = navidromeCreatedDate(value) { return date }
        if let s = value as? String {
            if let d = Self.navidromeReleaseISOFrac.date(from: s) { return d }
            if let d = Self.navidromeReleaseISOInternet.date(from: s) { return d }
            if let d = Self.navidromeReleaseISODay.date(from: s) { return d }
        }
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

    /// Paged track listing for scroll pagination. Subsonic `search3` has no sort param,
    /// so order is the server's natural order — the UI applies its own sort to what it
    /// has loaded. Returns `[]` when the server has no more rows past `offset`.
    func tracksPage(offset: Int, limit: Int) async throws -> [Track] {
        let safeOffset = max(0, offset)
        let safeLimit = max(1, min(limit, 2_000))
        for query in ["*", "a", ""] {
            let items = try await subsonicRequest(path: "search3", query: [
                "query": query,
                "songCount": "\(safeLimit)",
                "songOffset": "\(safeOffset)",
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
        let chunkSize = 8
        var index = 0
        while index < albumsList.count, out.count < cap {
            let end = min(index + chunkSize, albumsList.count)
            let chunk = Array(albumsList[index ..< end])
            await withTaskGroup(of: [Track].self) { group in
                for album in chunk {
                    group.addTask {
                        (try? await self.tracks(forAlbumId: album.id)) ?? []
                    }
                }
                for await batch in group {
                    out.append(contentsOf: batch)
                    if out.count >= cap { break }
                }
            }
            index = end
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
        try buildStreamURL(trackId: track.id, format: streamingFormat, maxBitRate: streamingMaxBitRate)
    }

    func fallbackStreamURLs(for track: Track) -> [URL] {
        var formats: [StreamFormatOption] = []
        if streamingFormat != .mp3 { formats.append(.mp3) }
        if streamingFormat != .aac { formats.append(.aac) }
        if streamingFormat != .raw { formats.append(.raw) }
        var urls: [URL] = []
        var seen = Set<String>()
        for format in formats {
            let rate = StreamBitRateOption.kbps320.navidromeMaxBitRate(for: format)
            if let url = try? buildStreamURL(trackId: track.id, format: format, maxBitRate: rate),
               !seen.contains(url.absoluteString) {
                seen.insert(url.absoluteString)
                urls.append(url)
            }
        }
        return urls
    }

    func offlineDownloadURL(for track: Track) throws -> URL {
        try buildStreamURL(trackId: track.id, format: offlineFormat.asStreamFormat, maxBitRate: offlineMaxBitRate)
    }

    func reportNowPlaying(trackId: String) async throws {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        _ = try await subsonicRequest(path: "scrobble", query: [
            "id": trackId,
            "time": "\(ms)",
            "submission": "false",
        ])
    }

    func submitScrobble(trackId: String, timestamp: Date) async throws {
        let ms = Int64(timestamp.timeIntervalSince1970 * 1000)
        _ = try await subsonicRequest(path: "scrobble", query: [
            "id": trackId,
            "time": "\(ms)",
            "submission": "true",
        ])
    }

    private func buildStreamURL(trackId: String, format: StreamFormatOption, maxBitRate: Int) throws -> URL {
        var query: [String: String] = ["id": trackId]
        if let formatParam = format.navidromeFormatParam {
            query["format"] = formatParam
        }
        if maxBitRate > 0, !format.isLossless {
            query["maxBitRate"] = "\(maxBitRate)"
        }
        return try buildMediaURL(path: "stream", query: query)
    }

    /// Approximate totals via ``getArtists`` + ``getAlbumList2`` (song count sums album ``trackCount`` — no full-track fetch).
    func fetchApproximateLibraryStatistics() async throws -> LibraryStatistics {
        let cap = 50_000
        async let artistCount = countArtistsInLibraryIndex()
        async let albumRows = albums(limit: cap)
        let (artists, albumsList) = try await (artistCount, albumRows)
        let summedTracks = albumsList.reduce(0) { partial, album in
            partial + max(0, album.trackCount ?? 0)
        }
        return LibraryStatistics(
            artistCount: artists,
            albumCount: albumsList.count,
            songCount: summedTracks > 0 ? summedTracks : nil,
            playlistCount: nil,
        )
    }

    func lyrics(for track: Track) async throws -> [LyricLine] {
        var candidates: [[LyricLine]] = []
        if let structured = try? await fetchStructuredLyrics(trackId: track.id), !structured.isEmpty {
            candidates.append(structured)
        }
        if let plain = try? await fetchPlainLyricsText(track: track) {
            let parsed = NavidromeLyricsParser.parse(plain: plain)
            if !parsed.isEmpty {
                candidates.append(parsed)
            }
        }
        return candidates.max(by: { Self.structuredLyricsScore($0) < Self.structuredLyricsScore($1) }) ?? []
    }

    private func fetchPlainLyricsText(track: Track) async throws -> String? {
        let items = try await subsonicRequest(path: "getLyrics", query: [
            "artist": track.artist,
            "title": track.title,
        ])
        guard let lyrics = items["lyrics"] as? [String: Any],
              let text = lyrics["value"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return text
    }

    /// OpenSubsonic ``getLyricsBySongId`` — synced lines carry millisecond ``start`` values.
    private func fetchStructuredLyrics(trackId: String) async throws -> [LyricLine] {
        let sub = try await subsonicRequest(path: "getLyricsBySongId", query: ["id": trackId])
        guard let lyricsList = sub["lyricsList"] as? [String: Any] else { return [] }
        let blocks = Self.dictArray(lyricsList["structuredLyrics"])
        return Self.parseStructuredLyricsBlocks(blocks)
    }

    private static func parseStructuredLyricsBlocks(_ blocks: [[String: Any]]) -> [LyricLine] {
        guard !blocks.isEmpty else { return [] }
        let candidates = blocks.compactMap { parseStructuredLyricsBlock($0) }
        guard !candidates.isEmpty else { return [] }
        return candidates.max(by: { structuredLyricsScore($0) < structuredLyricsScore($1) }) ?? []
    }

    private static func structuredLyricsScore(_ lines: [LyricLine]) -> Int {
        var score = lines.count
        if lines.lyricsAppearSynced { score += 100_000 }
        score += Int((lines.map(\.start).max() ?? 0) * 10)
        return score
    }

    private static func parseStructuredLyricsBlock(_ block: [String: Any]) -> [LyricLine] {
        let isSyncedBlock = (block["synced"] as? Bool) == true
        let offsetMs = (block["offset"] as? NSNumber)?.doubleValue ?? 0
        let rows = dictArray(block["line"])
        let rawStarts = rows.compactMap { ($0["start"] as? NSNumber)?.doubleValue }
        let startUnit = structuredStartUnitScale(
            maxRawStart: rawStarts.max() ?? 0,
            isSyncedBlock: isSyncedBlock,
            lineCount: rows.count
        )

        var lines: [LyricLine] = rows.compactMap { row in
            guard let text = row["value"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let startMs = (row["start"] as? NSNumber)?.doubleValue {
                let start = NavidromeLyricsParser.structuredLineStart(
                    lineStartMs: startMs * startUnit,
                    offsetMs: offsetMs
                )
                let display = NavidromeLyricsParser.displayText(trimmed)
                guard !display.isEmpty else { return nil }
                return LyricLine(start: start, text: display)
            }
            if let parsed = NavidromeLyricsParser.parseTimedLine(trimmed) {
                let start = NavidromeLyricsParser.structuredLineStart(
                    lineStartMs: parsed.start * 1000,
                    offsetMs: offsetMs
                )
                return LyricLine(start: start, text: parsed.text)
            }
            guard !isSyncedBlock else { return nil }
            let display = NavidromeLyricsParser.displayText(trimmed)
            guard !display.isEmpty else { return nil }
            return LyricLine(
                start: NavidromeLyricsParser.structuredLineStart(lineStartMs: 0, offsetMs: offsetMs),
                text: display
            )
        }

        if !lines.lyricsAppearSynced {
            let reparsed = reparsedLRCFromRowValues(rows, offsetMs: offsetMs)
            if reparsed.lyricsAppearSynced {
                lines = reparsed
            }
        }

        return lines.sorted { $0.start < $1.start }
    }

    /// Navidrome stores LRC ``start`` in ms, but some sources use seconds when under ~10 min.
    private static func structuredStartUnitScale(maxRawStart: Double, isSyncedBlock: Bool, lineCount: Int) -> Double {
        guard isSyncedBlock, maxRawStart > 0, lineCount >= 2, maxRawStart <= 600 else { return 1 }
        return 1000
    }

    /// Reconstruct embedded LRC timestamps when the server only returned plain ``value`` rows.
    private static func reparsedLRCFromRowValues(_ rows: [[String: Any]], offsetMs: Double) -> [LyricLine] {
        let text = rows.compactMap { $0["value"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else { return [] }
        let parsed = NavidromeLyricsParser.parse(plain: text)
        guard parsed.lyricsAppearSynced else { return parsed }
        let applyBlockOffset = offsetMs != 0 && !text.localizedCaseInsensitiveContains("[offset:")
        guard applyBlockOffset else { return parsed }
        return parsed.map { line in
            LyricLine(
                start: NavidromeLyricsParser.structuredLineStart(
                    lineStartMs: line.start * 1000,
                    offsetMs: offsetMs
                ),
                text: line.text
            )
        }
    }

    private static func dictArray(_ value: Any?) -> [[String: Any]] {
        if let arr = value as? [[String: Any]] { return arr }
        if let one = value as? [String: Any] { return [one] }
        return []
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

        var pendingSongIds: [String] = []
        for d in songRows {
            guard out.count + pendingSongIds.count < cap else { break }
            if let t = parseSongFromChildDict(d) {
                if seen.insert(t.id).inserted {
                    out.append(t)
                }
            } else if let sid = navidromeCoerceString(d["id"]), seen.insert(sid).inserted {
                pendingSongIds.append(sid)
            }
        }
        if !pendingSongIds.isEmpty {
            let fetched = try await fetchTracksViaGetSongParallel(ids: pendingSongIds)
            for track in fetched {
                guard out.count < cap else { break }
                if seen.insert(track.id).inserted {
                    out.append(track)
                }
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

    /// Batches `getSong` lookups so playlist/favorites loading doesn't devolve into one
    /// sequential round-trip per track when Subsonic returns minimal child payloads.
    private func fetchTracksViaGetSongParallel(ids: [String], concurrency: Int = 16) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        let limit = max(1, min(concurrency, 24))
        var tracks: [Track] = []
        tracks.reserveCapacity(ids.count)
        for chunkStart in stride(from: 0, to: ids.count, by: limit) {
            let chunk = Array(ids[chunkStart ..< min(chunkStart + limit, ids.count)])
            try await withThrowingTaskGroup(of: Track?.self) { group in
                for id in chunk {
                    group.addTask { try await self.fetchTrackViaGetSong(id: id) }
                }
                for try await track in group {
                    if let track { tracks.append(track) }
                }
            }
        }
        return tracks
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
            ?? navidromeCoerceString(dict["album_id"])
            ?? navidromeCoerceString(dict["parent"])
            ?? fallbackAlbumId.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard let albumIdFinal = albumId, !albumIdFinal.isEmpty else { return nil }

        let albumTitle =
            navidromeCoerceString(dict["album"])
            ?? albumTitleFallback.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? ""

        let artist =
            navidromeCoerceString(dict["artist"])
            ?? navidromeCoerceString(dict["albumArtist"])
            ?? navidromeCoerceString(dict["displayArtist"])
            ?? navidromeCoerceString(dict["displayAlbumArtist"])
            ?? fallbackAlbumArtist.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? ""

        let duration: Double = {
            if let n = dict["duration"] as? NSNumber { return Double(truncating: n) }
            if let s = dict["duration"] as? String { return Double(s) ?? 0 }
            return 0
        }()
        let disc = intFromNavidrome(dict["discNumber"]) ?? intFromNavidrome(dict["disc_number"]) ?? 1
        let index = intFromNavidrome(dict["track"]) ?? intFromNavidrome(dict["trackNumber"]) ?? 0
        let coverId =
            navidromeCoerceString(dict["coverArt"])
            ?? albumCoverArtId.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? albumIdFinal
        let art = streamURLForCover(coverArt: coverId)
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
        try? buildMediaURL(path: "getCoverArt", query: ["id": coverArt, "size": "400"])
    }

    /// Public Subsonic `getCoverArt` URL for a given cover-art id (e.g. a playlist id).
    /// Mirrors ``streamURLForCover(coverArt:)`` but is exposed so callers can render the
    /// magic playlist's cover as the user's profile picture.
    func coverArtURL(forId coverArtId: String, size: Int? = 400) -> URL? {
        var query = ["id": coverArtId]
        if let size, size > 0 { query["size"] = "\(size)" }
        return try? buildMediaURL(path: "getCoverArt", query: query)
    }

    // MARK: - Native (non-Subsonic) API

    /// Logs in against Navidrome's native `/auth/login` endpoint and caches the JWT.
    /// Re-runs if a previous request was rejected (401) so callers can simply retry.
    @discardableResult
    private func nativeAuthenticate(force: Bool = false) async throws -> String {
        if !force, let token = nativeAuthToken, !token.isEmpty { return token }
        guard !username.isEmpty, !password.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        let url = baseURL.appendingPathComponent("auth/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["username": username, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.lyra.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty
        else {
            throw URLError(.cannotParseResponse)
        }
        nativeAuthToken = token
        return token
    }

    /// Returns `true` when the playlist has a user-uploaded image or an external image URL set —
    /// i.e. Navidrome is NOT falling back to its auto-generated 4-up mosaic. Uses the native
    /// `/api/playlist/<id>` endpoint and the `uploadedImage` / `externalImageUrl` fields.
    func playlistHasCustomCover(playlistId: String) async throws -> Bool {
        let dict = try await fetchNativePlaylist(id: playlistId)
        let uploaded = (dict["uploadedImage"] as? String) ?? ""
        let external = (dict["externalImageUrl"] as? String) ?? ""
        return !uploaded.isEmpty || !external.isEmpty
    }

    /// Uploads an image as the cover of a playlist via Navidrome's native API. The server
    /// detects the format from the bytes (PNG/JPEG/GIF/WebP). On 403, Navidrome's
    /// `EnableArtworkUpload` is off and the caller isn't admin.
    func uploadPlaylistImage(playlistId: String, imageData: Data, filename: String = "avatar.jpg") async throws {
        do {
            try await uploadPlaylistImageRequest(playlistId: playlistId, imageData: imageData, filename: filename)
        } catch let urlError as URLError where urlError.code == .userAuthenticationRequired {
            nativeAuthToken = nil
            try await uploadPlaylistImageRequest(playlistId: playlistId, imageData: imageData, filename: filename)
        }
    }

    private func uploadPlaylistImageRequest(playlistId: String, imageData: Data, filename: String) async throws {
        let token = try await nativeAuthenticate()
        let url = baseURL.appendingPathComponent("api/playlist/\(playlistId)/image")
        let boundary = "LyraMusicBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "X-ND-Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let crlf = "\r\n"
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(imageData)
        body.append("\(crlf)--\(boundary)--\(crlf)".data(using: .utf8)!)
        request.httpBody = body

        let (_, response) = try await URLSession.lyra.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 { throw URLError(.userAuthenticationRequired) }
        if http.statusCode == 403 {
            throw NSError(
                domain: "Navidrome",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Artwork upload is disabled for this account. Ask your Navidrome admin to enable EnableArtworkUpload or grant admin role."],
            )
        }
        guard (200 ..< 300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
    }

    private func fetchNativePlaylist(id: String) async throws -> [String: Any] {
        do {
            return try await nativeRequest(path: "api/playlist/\(id)")
        } catch let urlError as URLError where urlError.code == .userAuthenticationRequired {
            // Token may have expired — re-login once and retry.
            nativeAuthToken = nil
            return try await nativeRequest(path: "api/playlist/\(id)")
        }
    }

    private func nativeRequest(path: String) async throws -> [String: Any] {
        let token = try await nativeAuthenticate()
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "X-ND-Authorization")
        let (data, response) = try await URLSession.lyra.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw URLError(.userAuthenticationRequired)
        }
        guard (200 ..< 300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return json
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
        if let native = try? await fetchPlaylistRowsViaNativeAPI(playlistId: playlistId), !native.isEmpty {
            return native
        }
        let items = try await subsonicRequest(path: "getPlaylist", query: ["id": playlistId])
        guard let pl = navidromeDict(items["playlist"]) else { return [] }
        let entries = childDictArray(from: pl, key: "entry")
        let playlistCoverId = navidromeCoerceString(pl["coverArt"])
        let playlistArtist = navidromeCoerceString(pl["owner"])
        var resolved: [(idx: Int, track: Track)] = []
        resolved.reserveCapacity(entries.count)
        var pending: [(idx: Int, id: String)] = []
        for (idx, dict) in entries.enumerated() {
            if let track = parseSongFromChildDict(
                dict,
                albumCoverArtId: playlistCoverId,
                fallbackAlbumArtist: playlistArtist,
            ) {
                resolved.append((idx, track))
            } else if let sid = navidromeCoerceString(dict["id"]) {
                pending.append((idx, sid))
            }
        }
        if !pending.isEmpty {
            let fetched = try await fetchTracksViaGetSongParallel(ids: pending.map(\.id))
            let byId = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (idx, sid) in pending {
                if let track = byId[sid] {
                    resolved.append((idx, track))
                }
            }
        }
        return resolved.sorted { $0.idx < $1.idx }.map { pair in
            PlaylistRowItem(
                rowId: "\(playlistId)-\(pair.idx)-\(pair.track.id)",
                track: pair.track,
                jellyfinEntryId: nil,
                navidromeIndex: pair.idx,
            )
        }
    }

    /// Navidrome's native `/api/playlist/{id}/tracks` returns full ``MediaFile`` rows in
    /// one round-trip — avoids Subsonic minimal child payloads that force N× ``getSong``.
    private func fetchPlaylistRowsViaNativeAPI(playlistId: String) async throws -> [PlaylistRowItem] {
        let rows: [[String: Any]]
        do {
            rows = try await fetchNativePlaylistTrackDicts(playlistId: playlistId)
        } catch let urlError as URLError where urlError.code == .userAuthenticationRequired {
            nativeAuthToken = nil
            rows = try await fetchNativePlaylistTrackDicts(playlistId: playlistId)
        }
        guard !rows.isEmpty else { return [] }
        var out: [PlaylistRowItem] = []
        out.reserveCapacity(rows.count)
        for (idx, dict) in rows.enumerated() {
            guard let track = parseNativePlaylistTrackDict(dict) else { continue }
            out.append(
                PlaylistRowItem(
                    rowId: "\(playlistId)-\(idx)-\(track.id)",
                    track: track,
                    jellyfinEntryId: nil,
                    navidromeIndex: idx,
                ),
            )
        }
        return out
    }

    private func fetchNativePlaylistTrackDicts(playlistId: String) async throws -> [[String: Any]] {
        let pageSize = 2_000
        var start = 0
        var all: [[String: Any]] = []
        while true {
            let path = "api/playlist/\(playlistId)/tracks?_start=\(start)&_end=\(start + pageSize)&_sort=id&_order=ASC"
            let batch = try await fetchNativeJSONArray(path: path)
            guard !batch.isEmpty else { break }
            all.append(contentsOf: batch)
            if batch.count < pageSize { break }
            start += batch.count
        }
        return all
    }

    private func fetchNativeJSONArray(path: String) async throws -> [[String: Any]] {
        let token = try await nativeAuthenticate()
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "X-ND-Authorization")
        let (data, response) = try await URLSession.lyra.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 || http.statusCode == 403 { throw URLError(.userAuthenticationRequired) }
        guard (200 ..< 300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let json = try JSONSerialization.jsonObject(with: data)
        if let arr = json as? [[String: Any]] { return arr }
        if let arr = json as? [Any] {
            return arr.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    /// Parses a native playlist-track or media-file JSON object into a ``Track``.
    private func parseNativePlaylistTrackDict(_ dict: [String: Any]) -> Track? {
        if let nested = navidromeDict(dict["mediaFile"]) {
            var merged = nested
            if let mediaFileId = navidromeCoerceString(dict["mediaFileId"]), !mediaFileId.isEmpty {
                merged["id"] = mediaFileId
            }
            return parseSongFromChildDict(merged)
        }
        var normalized = dict
        if let mediaFileId = navidromeCoerceString(dict["mediaFileId"]), !mediaFileId.isEmpty {
            normalized["id"] = mediaFileId
        }
        return parseSongFromChildDict(normalized)
    }

    func createPlaylist(name: String, trackIds: [String], isPublic: Bool = false) async throws -> PlaylistSummary {
        let repeated = trackIds.map { ("songId", $0) }
        let items = try await subsonicRequest(path: "createPlaylist", query: ["name": name], repeatedQuery: repeated)
        let summary: PlaylistSummary
        if let pl = navidromeDict(items["playlist"]),
           let parsed = parsePlaylistDictSummary(pl) {
            summary = parsed
        } else if let match = try await fetchPlaylistSummaries(limit: 500).first(where: { $0.name == name }) {
            summary = match
        } else {
            throw URLError(.cannotParseResponse)
        }
        try await setPlaylistPublic(playlistId: summary.id, isPublic: isPublic)
        return playlistSummary(summary, isPublic: isPublic)
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

    func renamePlaylist(playlistId: String, name: String, isPublic: Bool? = nil) async throws {
        var query: [String: String] = [
            "playlistId": playlistId,
            "name": name,
        ]
        if let isPublic {
            query["public"] = isPublic ? "true" : "false"
        }
        _ = try await subsonicRequest(path: "updatePlaylist", query: query)
    }

    func deletePlaylist(playlistId: String) async throws {
        _ = try await subsonicRequest(path: "deletePlaylist", query: ["id": playlistId])
    }

    // MARK: - Radio (Subsonic)

    /// Random tracks from the library, optionally filtered by genre tag (`getRandomSongs`).
    func fetchRandomSongs(limit: Int = 50, genre: String? = nil) async throws -> [Track] {
        let cap = max(1, min(limit, 500))
        var query: [String: String] = ["size": "\(cap)"]
        if let genre {
            let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { query["genre"] = trimmed }
        }
        let items = try await subsonicRequest(path: "getRandomSongs", query: query)
        guard let root = navidromeDict(items["randomSongs"]) else { return [] }
        let songs = childDictArray(from: root, key: "song")
        var seen = Set<String>()
        var out: [Track] = []
        out.reserveCapacity(songs.count)
        for dict in songs {
            guard let track = parseSongFromChildDict(dict) else { continue }
            if seen.insert(track.id).inserted {
                out.append(track)
            }
        }
        return out
    }

    /// Internet radio stations configured on the Navidrome server (`getInternetRadioStations`).
    func fetchInternetRadioStations() async throws -> [InternetRadioStation] {
        let items = try await subsonicRequest(path: "getInternetRadioStations", query: [:])
        guard let root = navidromeDict(items["internetRadioStations"]) else { return [] }
        let rows = childDictArray(from: root, key: "internetRadioStation")
        return rows.compactMap(parseInternetRadioStation)
    }

    private func parseInternetRadioStation(_ dict: [String: Any]) -> InternetRadioStation? {
        guard let id = navidromeCoerceString(dict["id"]),
              let name = navidromeCoerceString(dict["name"]),
              !name.isEmpty
        else { return nil }
        let streamRaw =
            navidromeCoerceString(dict["streamUrl"])
            ?? navidromeCoerceString(dict["streamURL"])
        guard let streamRaw,
              let streamURL = URL(string: streamRaw),
              let scheme = streamURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        let homeRaw =
            navidromeCoerceString(dict["homePageUrl"])
            ?? navidromeCoerceString(dict["homepageUrl"])
        let homepageURL = homeRaw.flatMap { URL(string: $0) }
        return InternetRadioStation(id: id, name: name, streamURL: streamURL, homepageURL: homepageURL)
    }

    func deleteTrackFromLibrary(trackId: String) async throws {
        _ = trackId
        throw NavidromeClientError.libraryTrackDeleteUnsupported
    }

    /// Subsonic `startScan`. Fires the server's media scan so files Downtify just
    /// dropped on disk surface in the catalog. The Subsonic spec returns a
    /// `scanStatus` envelope; we don't await completion here — callers poll for
    /// the new track via `searchCatalog` instead.
    func triggerLibraryScan() async throws {
        _ = try await subsonicRequest(path: "startScan")
    }

    func fetchScanStatus() async throws -> NavidromeScanStatus {
        let items = try await subsonicRequest(path: "getScanStatus")
        guard let status = navidromeDict(items["scanStatus"]) else {
            return NavidromeScanStatus(scanning: false, count: 0, total: 0)
        }
        let scanning = navidromeBool(status["scanning"])
        let count = navidromeInt(status["count"]) ?? 0
        let total = navidromeInt(status["total"]) ?? 0
        return NavidromeScanStatus(scanning: scanning, count: count, total: total)
    }

    func similarTracks(to track: Track, limit: Int) async throws -> [Track] {
        let cap = max(1, min(limit, 500))
        let items = try await subsonicRequest(path: "getSimilarSongs", query: [
            "id": track.id,
            "count": "\(cap)",
        ])
        guard let root = navidromeDict(items["similarSongs"]) else { return [] }
        let songs = childDictArray(from: root, key: "song")
        return songs.compactMap { parseSongFromChildDict($0) }.filter { $0.id != track.id }
    }

    func randomTracks(limit: Int, genre: String?) async throws -> [Track] {
        try await fetchRandomSongs(limit: limit, genre: genre)
    }

    func fetchShares() async throws -> [NavidromeShareEntry] {
        let items = try await subsonicRequest(path: "getShares")
        guard let root = navidromeDict(items["shares"]) else { return [] }
        let rows = childDictArray(from: root, key: "share")
        return rows.compactMap { parseShareEntry($0) }
    }

    func createShare(forItemId id: String, description: String?) async throws -> NavidromeShareEntry {
        var query: [String: String] = ["id": id]
        if let description, !description.isEmpty {
            query["description"] = description
        }
        let items = try await subsonicRequest(path: "createShare", query: query)
        guard let root = navidromeDict(items["shares"]) else {
            throw URLError(.cannotParseResponse)
        }
        let rows = childDictArray(from: root, key: "share")
        guard let entry = rows.compactMap({ parseShareEntry($0) }).first else {
            throw URLError(.cannotParseResponse)
        }
        return entry
    }

    func deleteShare(id: String) async throws {
        _ = try await subsonicRequest(path: "deleteShare", query: ["id": id])
    }

    private func parseShareEntry(_ dict: [String: Any]) -> NavidromeShareEntry? {
        guard let id = navidromeCoerceString(dict["id"]) else { return nil }
        let urlRaw = navidromeCoerceString(dict["url"]) ?? navidromeCoerceString(dict["shareUrl"])
        guard let urlRaw, let url = URL(string: urlRaw) else { return nil }
        let description = navidromeCoerceString(dict["description"])
        let created = navidromeOptionalDate(dict["created"])
        let expires = navidromeOptionalDate(dict["expires"])
        let visitCount = navidromeInt(dict["visitCount"]) ?? 0
        let maxVisits = navidromeInt(dict["maxVisits"])
        let entryDict = navidromeDict(dict["entry"])
        let entry: NavidromeShareTarget? = entryDict.flatMap { child in
            guard let entryId = navidromeCoerceString(child["id"]) else { return nil }
            return NavidromeShareTarget(
                id: entryId,
                title: navidromeCoerceString(child["title"]),
                artist: navidromeCoerceString(child["artist"]),
                album: navidromeCoerceString(child["album"]),
                kind: navidromeCoerceString(child["isDir"]).map { $0 == "true" ? "folder" : "song" },
            )
        }
        return NavidromeShareEntry(
            id: id,
            url: url,
            description: description,
            created: created,
            expires: expires,
            visitCount: visitCount,
            maxVisits: maxVisits,
            entry: entry,
        )
    }

    func searchCatalog(query: String, limit: Int) async throws -> CatalogSearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .empty }
        let cap = max(1, min(limit, 100))
        let items = try await subsonicRequest(path: "search3", query: [
            "query": q,
            "songCount": "\(cap)",
            "albumCount": "\(cap)",
            "artistCount": "\(cap)",
        ])
        guard let result = navidromeDict(items["searchResult3"]) else { return .empty }

        let songDicts = childDictArray(from: result, key: "song")
        let songs = songDicts.compactMap { parseSongFromChildDict($0) }

        let albumDicts = childDictArray(from: result, key: "album")
        let albums = albumDicts.compactMap(parseAlbumDict)

        let artistDicts = childDictArray(from: result, key: "artist")
        var artists: [LibraryArtistSummary] = []
        artists.reserveCapacity(artistDicts.count)
        appendLibraryArtists(from: artistDicts, into: &artists)

        return CatalogSearchResults(songs: songs, albums: albums, artists: artists)
    }

    /// One-off summary fetch for a single album id. Used to fill in albums that the
    /// user added to their library but which fell outside the paged `albums(limit:)`
    /// catalog (large libraries past the alphabetical cap).
    func albumSummary(forId id: String) async throws -> AlbumSummary? {
        let items = try await subsonicRequest(path: "getAlbum", query: ["id": id])
        guard let dict = navidromeDict(items["album"]) else { return nil }
        return parseAlbumDict(dict)
    }

    // MARK: - Library magic playlist

    /// Full contents of a single playlist for library-membership bookkeeping.
    struct LibraryPlaylistFetch {
        let id: String
        let name: String
        /// Ordered song IDs, may contain duplicates if the playlist was modified outside Lyra.
        let trackIds: [String]
        /// Free-form comment (used to carry ``LibraryMembershipPayload`` JSON).
        let comment: String?
    }

    /// Finds an existing playlist whose name matches `name` (case-sensitive). Used to bind
    /// the Lyra magic playlist by deterministic name across devices.
    func findPlaylistByName(_ name: String) async throws -> PlaylistSummary? {
        let items = try await subsonicRequest(path: "getPlaylists", query: [:])
        guard let root = navidromeDict(items["playlists"]) else { return nil }
        let rows = childDictArray(from: root, key: "playlist")
        for dict in rows {
            guard let parsed = parsePlaylistDictSummary(dict) else { continue }
            if parsed.name == name { return parsed }
        }
        return nil
    }

    /// One round-trip `getPlaylist` that returns enough to drive Lyra library state:
    /// the ordered track id list (for song membership) and the comment field (for
    /// album / playlist membership and add-dates).
    func fetchLibraryPlaylist(playlistId: String) async throws -> LibraryPlaylistFetch {
        let items = try await subsonicRequest(path: "getPlaylist", query: ["id": playlistId])
        guard let pl = navidromeDict(items["playlist"]) else {
            throw URLError(.cannotParseResponse)
        }
        let name = navidromeCoerceString(pl["name"]) ?? ""
        let comment = navidromeCoerceString(pl["comment"])
        let entries = childDictArray(from: pl, key: "entry")
        let trackIds = entries.compactMap { navidromeCoerceString($0["id"]) }
        return LibraryPlaylistFetch(id: playlistId, name: name, trackIds: trackIds, comment: comment)
    }

    /// Creates an empty, private playlist with the given name. Returns the new id.
    /// Used as the fallback path when find-by-name turns up nothing.
    func createEmptyPrivatePlaylist(name: String) async throws -> String {
        let items = try await subsonicRequest(path: "createPlaylist", query: ["name": name])
        if let pl = navidromeDict(items["playlist"]),
           let id = navidromeCoerceString(pl["id"]) {
            // Subsonic creates public-by-default; flip to private immediately. Best-effort
            // — Navidrome accepts the `public` flag on updatePlaylist.
            try? await setPlaylistPublic(playlistId: id, isPublic: false)
            return id
        }
        // Some Navidrome builds don't return the new playlist body on create — fall back to listing.
        if let match = try await findPlaylistByName(name) {
            try? await setPlaylistPublic(playlistId: match.id, isPublic: false)
            return match.id
        }
        throw URLError(.cannotParseResponse)
    }

    /// Updates the playlist's comment field. Used to persist ``LibraryMembershipPayload``.
    func setPlaylistComment(playlistId: String, comment: String) async throws {
        _ = try await subsonicRequest(path: "updatePlaylist", query: [
            "playlistId": playlistId,
            "comment": comment,
        ])
    }

    private func setPlaylistPublic(playlistId: String, isPublic: Bool) async throws {
        _ = try await subsonicRequest(path: "updatePlaylist", query: [
            "playlistId": playlistId,
            "public": isPublic ? "true" : "false",
        ])
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
        let updated = navidromeCreatedDate(dict["changed"])
        let isPublic = navidromeCoerceBool(dict["public"])
        return PlaylistSummary(
            id: id,
            name: name,
            songCount: count,
            artworkURL: art,
            coverArtId: coverId,
            isPublic: isPublic,
            libraryAddedDate: created,
            serverUpdatedDate: updated,
        )
    }

    private func playlistSummary(_ summary: PlaylistSummary, isPublic: Bool) -> PlaylistSummary {
        PlaylistSummary(
            id: summary.id,
            name: summary.name,
            songCount: summary.songCount,
            artworkURL: summary.artworkURL,
            coverArtId: summary.coverArtId,
            isPublic: isPublic,
            libraryAddedDate: summary.libraryAddedDate,
            serverUpdatedDate: summary.serverUpdatedDate,
        )
    }

    /// Subsonic ``getAvatar`` for the signed-in user (toolbar profile image).
    func accountAvatarURL(username: String? = nil) -> URL? {
        guard !self.username.isEmpty || username != nil else { return nil }
        guard !password.isEmpty else { return nil }
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

    /// Distinguishes "credentials rejected" (Subsonic error 40/41, or wrong-password
    /// message text) from "server unreachable". Mirrors ``JellyfinMusicClient.probeAuthStatus``.
    /// Requires a non-empty password to probe; otherwise returns `.authRejected`.
    func probeAuthStatus() async -> ServerReachabilityProbe {
        guard !password.isEmpty else { return .authRejected }
        do {
            let items = try await subsonicRequest(path: "ping", query: [:])
            if (items["status"] as? String) == "ok" { return .ok }
            if let err = items["error"] as? [String: Any] {
                let code = (err["code"] as? Int) ?? Int(err["code"] as? String ?? "") ?? -1
                if code == 40 || code == 41 { return .authRejected }
            }
            return .unreachable
        } catch let nsError as NSError where nsError.domain == "Navidrome" {
            let msg = nsError.localizedDescription.lowercased()
            if msg.contains("wrong username") || msg.contains("password")
                || msg.contains("not authorized") || msg.contains("token authentication") {
                return .authRejected
            }
            return .unreachable
        } catch {
            return .unreachable
        }
    }

    private func ping() async throws -> Bool {
        let items = try await subsonicRequest(path: "ping", query: [:])
        if let status = items["status"] as? String { return status == "ok" }
        return false
    }

    /// Refreshes ``currentUserMetadata`` (and ``isLibraryAdmin``) from Subsonic ``getUser``.
    /// Non-admin accounts are only allowed to query their own user record, so we try a scoped
    /// call first and fall back to the unscoped form (which the server resolves to the caller).
    @discardableResult
    func refreshUserMetadata() async throws -> NavidromeUserMetadata? {
        let items: [String: Any]
        if let withUser = try? await subsonicRequest(path: "getUser", query: ["username": username]),
           withUser["user"] != nil {
            items = withUser
        } else {
            items = try await subsonicRequest(path: "getUser", query: [:])
        }
        guard let user = items["user"] as? [String: Any] else { return nil }
        let metadata = parseUserMetadata(user)
        currentUserMetadata = metadata
        isLibraryAdmin = metadata.adminRole
        return metadata
    }

    private func parseUserMetadata(_ dict: [String: Any]) -> NavidromeUserMetadata {
        let folders: [String] = {
            let raw = dict["folder"]
            if let arr = raw as? [Any] {
                return arr.compactMap { navidromeCoerceString($0) }
            }
            if let single = navidromeCoerceString(raw) {
                return [single]
            }
            return []
        }()
        let maxBitRate = navidromeInt(dict["maxBitRate"]).flatMap { $0 > 0 ? $0 : nil }
        return NavidromeUserMetadata(
            username: navidromeCoerceString(dict["username"]) ?? username,
            email: navidromeCoerceString(dict["email"]),
            scrobblingEnabled: navidromeCoerceBool(dict["scrobblingEnabled"]),
            maxBitRate: maxBitRate,
            avatarLastChanged: navidromeCreatedDate(dict["avatarLastChanged"]),
            allowedFolderIds: folders,
            adminRole: navidromeCoerceBool(dict["adminRole"]) || navidromeCoerceBool(dict["admin"]),
            settingsRole: navidromeCoerceBool(dict["settingsRole"]),
            streamRole: navidromeCoerceBool(dict["streamRole"]),
            downloadRole: navidromeCoerceBool(dict["downloadRole"]),
            uploadRole: navidromeCoerceBool(dict["uploadRole"]),
            playlistRole: navidromeCoerceBool(dict["playlistRole"]),
            coverArtRole: navidromeCoerceBool(dict["coverArtRole"]),
            commentRole: navidromeCoerceBool(dict["commentRole"]),
            podcastRole: navidromeCoerceBool(dict["podcastRole"]),
            jukeboxRole: navidromeCoerceBool(dict["jukeboxRole"]),
            shareRole: navidromeCoerceBool(dict["shareRole"]),
            videoConversionRole: navidromeCoerceBool(dict["videoConversionRole"]),
        )
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
        let (data, res) = try await URLSession.lyra.data(from: url)
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
        try buildRESTURL(path: path, query: query, repeatedQuery: repeatedQuery, responseFormatJSON: true)
    }

    /// Binary Subsonic endpoints (`stream`, `getCoverArt`, …) must not send `f=json` or the server may return a JSON error body instead of media bytes.
    private func buildMediaURL(path: String, query: [String: String] = [:], repeatedQuery: [(String, String)] = []) throws -> URL {
        try buildRESTURL(path: path, query: query, repeatedQuery: repeatedQuery, responseFormatJSON: false)
    }

    private func buildRESTURL(
        path: String,
        query: [String: String] = [:],
        repeatedQuery: [(String, String)] = [],
        responseFormatJSON: Bool,
    ) throws -> URL {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("rest/\(path)"),
            resolvingAgainstBaseURL: false,
        )!
        // Client id must not match Navidrome `Subsonic.MinimalClients`: minimal payloads omit `albumId`, which breaks favorites.
        var items: [URLQueryItem] = [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "LyraMusicKit"),
        ]
        if responseFormatJSON {
            items.append(URLQueryItem(name: "f", value: "json"))
        }
        // Subsonic salted-token auth: `t = md5(password + salt)` with a per-request random salt.
        // Never send `p=<password>` in the clear.
        let salt = Self.makeSubsonicSalt()
        let tokenHex = Self.subsonicMD5Hex(password + salt)
        items.append(URLQueryItem(name: "t", value: tokenHex))
        items.append(URLQueryItem(name: "s", value: salt))

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

    /// 16 random bytes hex-encoded (32 chars). Subsonic recommends >= 6 chars.
    private static func makeSubsonicSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in 0..<bytes.count {
                bytes[i] = UInt8.random(in: 0...255, using: &rng)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// MD5 hex of UTF-8 bytes (32 lowercase hex chars). MD5 is mandated by the Subsonic spec.
    private static func subsonicMD5Hex(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum NavidromeLyricsParser {
    struct ParseResult {
        let lines: [LyricLine]
        let syncedLineCount: Int
    }

    static func parse(plain: String) -> [LyricLine] {
        parseDetailed(plain: plain).lines
    }

    static func parseDetailed(plain: String) -> ParseResult {
        var globalOffset: TimeInterval = 0
        var synced: [LyricLine] = []
        var unsynced: [String] = []

        for row in plain.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(row).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            if let offset = parseOffsetLine(s) {
                globalOffset += offset
                continue
            }
            if isMetadataOnlyLine(s) { continue }

            if let (start, text) = parseSyncedLine(s), !text.isEmpty {
                synced.append(LyricLine(start: start + globalOffset, text: text))
            } else if !s.hasPrefix("[") {
                unsynced.append(s)
            }
        }

        if synced.lyricsAppearSynced {
            return ParseResult(lines: synced.sorted { $0.start < $1.start }, syncedLineCount: synced.count)
        }

        // Plain unsynced lyrics — do not invent timestamps (that desyncs from playback).
        let lines = unsynced.map { LyricLine(start: 0, text: $0) }
        return ParseResult(lines: lines, syncedLineCount: 0)
    }

    /// `[offset:500]` / `[offset:-500]` — global shift in milliseconds.
    private static func parseOffsetLine(_ line: String) -> TimeInterval? {
        guard line.lowercased().hasPrefix("[offset:"), line.hasSuffix("]") else { return nil }
        let inner = line.dropFirst(8).dropLast()
        guard let ms = Int(inner.trimmingCharacters(in: .whitespaces)) else { return nil }
        return TimeInterval(ms) / 1000.0
    }

    /// `[ti:Title]`, `[ar:Artist]`, `[offset:500]`, etc.
    private static func isMetadataOnlyLine(_ line: String) -> Bool {
        guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { return false }
        let tag = line[line.index(after: line.startIndex)..<end]
        guard let colon = tag.firstIndex(of: ":") else { return false }
        let key = tag[..<colon]
        guard !key.isEmpty, key.allSatisfy(\.isLetter) else { return false }
        return parseTimeTag(String(tag)) == nil
    }

    /// Supports `[mm:ss]`, `[mm:ss.xx]`, `[mm:ss.xxx]`, `[h:mm:ss(.xx)]`, and repeated leading tags.
    private static func parseSyncedLine(_ line: String) -> (TimeInterval, String)? {
        var work = line
        var firstStart: TimeInterval?
        while work.hasPrefix("[") {
            guard let end = work.firstIndex(of: "]") else { break }
            let tag = String(work[work.index(after: work.startIndex)..<end])
            work = String(work[work.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            if let t = parseTimeTag(tag) {
                if firstStart == nil { firstStart = t }
            }
        }
        guard let start = firstStart else { return nil }
        let cleaned = cleanInlineTimeTags(work)
        guard !cleaned.isEmpty else { return nil }
        return (start, cleaned)
    }

    /// Navidrome copies LRC ``[offset:±ms]`` verbatim — apply LRC semantics (add offset to line start).
    static func structuredLineStart(lineStartMs: Double, offsetMs: Double) -> TimeInterval {
        max(0, (lineStartMs + offsetMs) / 1000.0)
    }

    /// Parse a single LRC line that may carry leading or inline timestamps.
    static func parseTimedLine(_ line: String) -> LyricLine? {
        if let (start, text) = parseSyncedLine(line), !text.isEmpty {
            return LyricLine(start: start, text: text)
        }
        if let inline = firstTimestamp(in: line) {
            let display = displayText(line)
            guard !display.isEmpty else { return nil }
            return LyricLine(start: inline, text: display)
        }
        return nil
    }

    /// Display-safe lyric text with inline LRC timestamps removed.
    static func displayText(_ text: String) -> String {
        cleanInlineTimeTags(text)
    }

    /// Earliest `[mm:ss]` / `[h:mm:ss]` timestamp embedded anywhere in a line.
    static func firstTimestamp(in text: String) -> TimeInterval? {
        guard let regex = try? NSRegularExpression(pattern: inlineTimeTagPattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var earliest: TimeInterval?
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let tagRange = Range(match.range(at: 1), in: text) else { return }
            guard let t = parseTimeTag(String(text[tagRange])) else { return }
            if earliest == nil || t < earliest! { earliest = t }
        }
        return earliest
    }

    private static let inlineTimeTagPattern = #"\[((?:\d{1,2}:)?\d{1,2}:\d{2}(?:\.\d{1,3})?)\]"#

    /// Strip enhanced-LRC inline timestamps embedded in the lyric text.
    private static func cleanInlineTimeTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: inlineTimeTagPattern) else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func parseTimeTag(_ tag: String) -> TimeInterval? {
        let normalized = tag.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        func secondsComponent(_ raw: Substring) -> TimeInterval? {
            let pieces = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard let whole = Int(pieces[0]) else { return nil }
            var fraction: TimeInterval = 0
            if pieces.count == 2 {
                let frac = String(pieces[1])
                guard !frac.isEmpty, frac.allSatisfy(\.isNumber) else { return nil }
                let denom: TimeInterval
                switch frac.count {
                case 1: denom = 10
                case 2: denom = 100
                case 3: denom = 1_000
                default: return nil
                }
                guard let value = Int(frac) else { return nil }
                fraction = TimeInterval(value) / denom
            }
            return TimeInterval(whole) + fraction
        }

        if parts.count == 2 {
            guard parts[0].allSatisfy(\.isNumber), let min = Int(parts[0]),
                  let sec = secondsComponent(parts[1]) else { return nil }
            return TimeInterval(min * 60) + sec
        }

        guard parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber),
              let hours = Int(parts[0]), let min = Int(parts[1]),
              let sec = secondsComponent(parts[2]) else { return nil }
        return TimeInterval(hours * 3600 + min * 60) + sec
    }
}
