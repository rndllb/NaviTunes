import Foundation

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

    /// Values for UI / downloads when only Last.fm chart metadata exists (no Downtify ``url`` yet — use ``DowntifyClient/download(artist:title:)``).
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

    init(lastFmChartTrack track: LFMTrack) {
        self.init(
            songId: "lfm-chart:\(track.id)",
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

    private static func search(base: String, query: String) async throws -> [DowntifySong] {
        var comps = URLComponents(string: baseURL(base, path: "/api/songs/search"))!
        comps.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = comps.url else { throw DowntifyError("Invalid URL.") }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw DowntifyError("Search failed.")
        }
        return try JSONDecoder().decode([DowntifySong].self, from: data)
    }

    private static func triggerDownload(base: String, youtubeURL: String) async throws {
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
    }

    private static func pickBest(from songs: [DowntifySong], artist: String, title: String) -> DowntifySong? {
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
