import Foundation

struct LFMTrack: Identifiable, Hashable {
    let id: String
    let name: String
    let artistName: String
    let imageURL: URL?
    let playcount: Int
    /// `"Album"` when the row represents a release; `"Single"` for Last.fm chart tracks.
    let browseKind: String

    init(id: String, name: String, artistName: String, imageURL: URL?, playcount: Int, browseKind: String = "Single") {
        self.id = id
        self.name = name
        self.artistName = artistName
        self.imageURL = imageURL
        self.playcount = playcount
        self.browseKind = browseKind
    }
}

struct LFMAlbum: Identifiable {
    let id: String
    let name: String
    let artistName: String
    let imageURL: URL?
}


enum LastFmChartsClient {
    static func fetchAll() async -> (tracks: [LFMTrack], albums: [LFMAlbum], recentAlbums: [LFMAlbum]) {
        async let tracksTask = fetchTopTracks()
        async let albumsTask = fetchTopAlbums()
        async let recentTask = fetchRecentReleaseAlbums()
        let (rawTracks, rawAlbums, rawRecent) = await (tracksTask, albumsTask, recentTask)

        async let enrichedTracks = enrichTracks(rawTracks)
        async let enrichedAlbums = enrichAlbums(rawAlbums)
        let (tracks, albums) = await (enrichedTracks, enrichedAlbums)
        return (tracks, albums, rawRecent)
    }

    /// Last.fm has no dedicated “new releases” API; we use ``tag.getTopAlbums`` with common release-oriented tags.
    static func fetchRecentReleaseAlbums(limit: Int = 15) async -> [LFMAlbum] {
        guard let key = storedApiKey else { return [] }
        let year = Calendar.current.component(.year, from: Date())
        let tagCandidates = [
            "new releases",
            "new album",
            "\(year)",
            "\(year - 1)",
            "recent releases",
        ]
        for tag in tagCandidates {
            guard let data = await fetch(method: "tag.getTopAlbums", params: ["tag": tag, "limit": "\(limit)"], apiKey: key)
            else { continue }
            guard let decoded = try? JSONDecoder().decode(LFMTagAlbumsEnvelope.self, from: data) else { continue }
            let rawAlbums = decoded.albums.album
            guard !rawAlbums.isEmpty else { continue }
            let albums = rawAlbums.map(\.toModel)
            return await enrichAlbums(albums)
        }
        return []
    }

    static func fetchTopTracks(limit: Int = 30) async -> [LFMTrack] {
        guard let key = storedApiKey else { return [] }
        guard let data = await fetch(method: "chart.getTopTracks", params: ["limit": "\(limit)"], apiKey: key) else { return [] }
        return (try? JSONDecoder().decode(LFMTracksEnvelope.self, from: data))?.tracks.track.map(\.toModel) ?? []
    }

    static func fetchTopAlbums(tag: String = "pop", limit: Int = 25) async -> [LFMAlbum] {
        guard let key = storedApiKey else { return [] }
        guard let data = await fetch(method: "tag.getTopAlbums", params: ["tag": tag, "limit": "\(limit)"], apiKey: key) else { return [] }
        return (try? JSONDecoder().decode(LFMTagAlbumsEnvelope.self, from: data))?.albums.album.map(\.toModel) ?? []
    }

    static var storedApiKey: String? {
        let k = UserDefaults.standard.string(forKey: "lastfm_api_key") ?? ""
        return k.isEmpty ? nil : k
    }

    // MARK: - iTunes artwork enrichment

    private static func enrichTracks(_ tracks: [LFMTrack]) async -> [LFMTrack] {
        await withTaskGroup(of: (Int, LFMTrack).self) { group in
            for (i, track) in tracks.enumerated() {
                group.addTask {
                    guard needsArtwork(track.imageURL) else { return (i, track) }
                    let url = await iTunesArtwork(artist: track.artistName, title: track.name, entity: "musicTrack")
                    return (
                        i,
                        LFMTrack(
                            id: track.id,
                            name: track.name,
                            artistName: track.artistName,
                            imageURL: url,
                            playcount: track.playcount,
                            browseKind: track.browseKind
                        )
                    )
                }
            }
            var results = [(Int, LFMTrack)]()
            for await pair in group { results.append(pair) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func enrichAlbums(_ albums: [LFMAlbum]) async -> [LFMAlbum] {
        await withTaskGroup(of: (Int, LFMAlbum).self) { group in
            for (i, album) in albums.enumerated() {
                group.addTask {
                    guard needsArtwork(album.imageURL) else { return (i, album) }
                    let url = await iTunesArtwork(artist: album.artistName, title: album.name, entity: "album")
                    return (i, LFMAlbum(id: album.id, name: album.name, artistName: album.artistName, imageURL: url))
                }
            }
            var results = [(Int, LFMAlbum)]()
            for await pair in group { results.append(pair) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // Last.fm serves this hash as their default placeholder image for missing art.
    private static let lfmPlaceholderHash = "2a96cbd8b46e442fc41c2b86b821562f"

    private static func needsArtwork(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.absoluteString.contains(Self.lfmPlaceholderHash)
    }

    private static func iTunesArtwork(artist: String, title: String, entity: String) async -> URL? {
        let term = "\(artist) \(title)"
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps.url else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = try JSONDecoder().decode(iTunesSearchResponse.self, from: data)
            guard let raw = json.results.first?.artworkUrl100, !raw.isEmpty else { return nil }
            // Upscale from 100x100 to 600x600
            let hd = raw.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            return URL(string: hd)
        } catch { return nil }
    }

    private static func fetch(method: String, params: [String: String], apiKey: String) async -> Data? {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
        ]
        for (k, v) in params { items.append(URLQueryItem(name: k, value: v)) }
        var comps = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        comps.queryItems = items
        guard let url = comps.url else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            return (resp as? HTTPURLResponse)?.statusCode == 200 ? data : nil
        } catch { return nil }
    }
}

// MARK: - Decodable shims

private struct LFMTracksEnvelope: Decodable {
    let tracks: TrackList
    struct TrackList: Decodable { let track: [RawTrack] }
}

private struct RawTrack: Decodable {
    let name: String
    let playcount: String?
    let artist: RawNameObj
    let image: [RawImage]?

    var toModel: LFMTrack {
        LFMTrack(
            id: "\(artist.name)-\(name)",
            name: name,
            artistName: artist.name,
            imageURL: largestImageURL(image),
            playcount: Int(playcount ?? "0") ?? 0
        )
    }
}

private struct LFMTagAlbumsEnvelope: Decodable {
    let albums: AlbumList
    struct AlbumList: Decodable { let album: [RawAlbum] }
}

private struct RawAlbum: Decodable {
    let name: String
    let artist: RawNameObj
    let image: [RawImage]?

    var toModel: LFMAlbum {
        LFMAlbum(
            id: "\(artist.name)-\(name)",
            name: name,
            artistName: artist.name,
            imageURL: largestImageURL(image)
        )
    }
}

private struct RawNameObj: Decodable { let name: String }

private struct RawImage: Decodable {
    let text: String
    let size: String
    enum CodingKeys: String, CodingKey { case text = "#text"; case size }
}

private struct iTunesSearchResponse: Decodable {
    let results: [iTunesResult]
    struct iTunesResult: Decodable { let artworkUrl100: String? }
}

private func largestImageURL(_ images: [RawImage]?) -> URL? {
    images?.last(where: { !$0.text.isEmpty }).flatMap { URL(string: $0.text) }
}

