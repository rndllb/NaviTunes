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
        // Normalize 0–100 → 0–1; clamp.
        progress = min(1, max(0, rawProgress > 1 ? rawProgress / 100.0 : rawProgress))
    }

    /// Synthetic optimistic entry inserted the instant we POST, before the first poll.
    init(optimisticURL: String, title: String?, artist: String?) {
        self.url = optimisticURL
        self.title = title
        self.artist = artist
        self.filename = nil
        self.message = nil
        self.status = .queued
        self.progress = 0
    }

    /// Full memberwise init used by the manager when remapping polled entries.
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

struct DowntifySong: Decodable, Identifiable, Hashable {
    var id: String { songId }
    let songId: String
    let name: String
    let artists: [String]
    let albumName: String
    let url: String
    let coverURL: URL?
    let year: Int?
    let explicit: Bool

    enum CodingKeys: String, CodingKey {
        case songId = "song_id"
        case name, artists
        case albumName = "album_name"
        case url
        case coverURL = "cover_url"
        case year, explicit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songId = try c.decode(String.self, forKey: .songId)
        name = try c.decode(String.self, forKey: .name)
        artists = (try? c.decode([String].self, forKey: .artists)) ?? []
        albumName = (try? c.decode(String.self, forKey: .albumName)) ?? ""
        url = try c.decode(String.self, forKey: .url)
        // cover_url may be absent, null, or an empty string
        if let raw = try? c.decodeIfPresent(String.self, forKey: .coverURL), !raw.isEmpty {
            coverURL = URL(string: raw)
        } else {
            coverURL = nil
        }
        // year can be Int or String in the wild
        if let i = try? c.decodeIfPresent(Int.self, forKey: .year) {
            year = i
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .year) {
            year = Int(s)
        } else {
            year = nil
        }
        // explicit can be Bool or Int (0/1)
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .explicit) {
            explicit = b
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .explicit) {
            explicit = i != 0
        } else {
            explicit = false
        }
    }

    /// Values for UI / downloads when only external chart metadata exists (no Downtify ``url`` yet — use ``DowntifyClient/download(artist:title:)``).
    init(songId: String, name: String, artists: [String], albumName: String, url: String, coverURL: URL?, year: Int?, explicit: Bool) {
        self.songId = songId
        self.name = name
        self.artists = artists
        self.albumName = albumName
        self.url = url
        self.coverURL = coverURL
        self.year = year
        self.explicit = explicit
    }

    init(chartTrack track: ChartTrack) {
        self.init(
            songId: "chart:\(track.id)",
            name: track.name,
            artists: [track.artistName],
            albumName: "",
            url: "",
            coverURL: track.imageURL,
            year: nil,
            explicit: false
        )
    }
}

enum DowntifyClient {
    private static let urlKey = "downtify_base_url"

    /// Report approximate progress while this client talks to your Downtify server (search → enqueue). Real yt-dlp progress happens server-side.
    typealias DownloadProgressHandler = @Sendable (Double) -> Void

    static var storedBaseURL: String? {
        let s = UserDefaults.standard.string(forKey: urlKey) ?? ""
        return s.isEmpty ? nil : s
    }

    static var isConfigured: Bool { storedBaseURL != nil }

    static func save(baseURL: String) {
        UserDefaults.standard.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: urlKey)
    }

    /// Searches Downtify, picks the best match, and triggers a download. Returns the matched song name.
    @discardableResult
    static func download(
        artist: String,
        title: String,
        progress: DownloadProgressHandler? = nil
    ) async throws -> String {
        guard let base = storedBaseURL else {
            throw DowntifyError("Configure Downtify URL in Settings first.")
        }

        progress?(0.04)
        let songs = try await search(base: base, query: "\(artist) \(title)")
        progress?(0.52)
        guard let best = pickBest(from: songs, artist: artist, title: title) else {
            throw DowntifyError("No results found for \"\(title)\" by \(artist).")
        }

        progress?(0.62)
        try await triggerDownload(base: base, youtubeURL: best.url)
        progress?(1.0)
        return best.name
    }

    static func search(query: String) async throws -> [DowntifySong] {
        guard let base = storedBaseURL else {
            throw DowntifyError("Configure Downtify URL in Settings first.")
        }
        return try await search(base: base, query: query)
    }

    /// Snapshot of the server's current download queue (`GET /api/queue`).
    static func queue() async throws -> [DowntifyJob] {
        guard let base = storedBaseURL else {
            throw DowntifyError("Configure Downtify URL in Settings first.")
        }
        guard let url = URL(string: baseURL(base, path: "/api/queue")) else {
            throw DowntifyError("Invalid URL.")
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw DowntifyError("Queue fetch failed.")
        }
        // Tolerate either a bare array or an object wrapping the array under common keys.
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

    @discardableResult
    static func downloadSong(_ song: DowntifySong, progress: DownloadProgressHandler? = nil) async throws -> String {
        guard let base = storedBaseURL else {
            throw DowntifyError("Configure Downtify URL in Settings first.")
        }
        progress?(0.08)
        try await triggerDownload(base: base, youtubeURL: song.url)
        progress?(1.0)
        return song.name
    }

    // MARK: - Private

    static func search(base: String, query: String) async throws -> [DowntifySong] {
        var comps = URLComponents(string: baseURL(base, path: "/api/songs/search"))!
        comps.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = comps.url else { throw DowntifyError("Invalid URL.") }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw DowntifyError("Search failed.")
        }
        return try JSONDecoder().decode([DowntifySong].self, from: data)
    }

    @discardableResult
    private static func triggerDownload(base: String, youtubeURL: String) async throws -> String {
        var comps = URLComponents(string: baseURL(base, path: "/api/download/url"))!
        comps.queryItems = [
            URLQueryItem(name: "url", value: youtubeURL),
            URLQueryItem(name: "client_id", value: UUID().uuidString.lowercased()),
        ]
        guard let url = comps.url else { throw DowntifyError("Invalid download URL.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (_, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DowntifyError("Download request failed (HTTP \(status)).")
        }
        return youtubeURL
    }

    static func pickBest(from songs: [DowntifySong], artist: String, title: String) -> DowntifySong? {
        let t = title.lowercased()
        let a = artist.lowercased()

        let artistMatch = { (s: DowntifySong) in
            s.artists.contains { $0.lowercased().contains(a) || a.contains($0.lowercased()) }
        }

        // Exact title + artist
        if let s = songs.first(where: { $0.name.lowercased() == t && artistMatch($0) }) { return s }
        // Title contains + artist
        if let s = songs.first(where: { $0.name.lowercased().contains(t) && artistMatch($0) }) { return s }
        // Artist match only
        if let s = songs.first(where: { artistMatch($0) }) { return s }
        // First result
        return songs.first
    }

    private static func baseURL(_ base: String, path: String) -> String {
        base.hasSuffix("/") ? "\(base)\(path.dropFirst())" : "\(base)\(path)"
    }
}

private struct DowntifyError: LocalizedError {
    let errorDescription: String?
    init(_ msg: String) { errorDescription = msg }
}
