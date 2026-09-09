import Foundation

/// Apple iTunes Search API — songs and albums **not** on the user's server.
/// Always available (no acquisition plugin required); results surface as
/// ``AcquisitionResult`` rows in Discover search.
enum ITunesSearchClient {
    private static let iso = ISO8601DateFormatter()
    private static let gregorian = Calendar(identifier: .gregorian)
    /// Compiled once: iTunes artwork URLs embed a `NNNxNNNbb` size token we swap for 512×512.
    private static let artworkSizeRegex = try? NSRegularExpression(pattern: "[0-9]+x[0-9]+bb")

    /// Songs + albums from iTunes matching `query`, mapped for Discover hybrid search.
    static func acquisitionResults(query: String, songLimit: Int = 20, albumLimit: Int = 12, country: String = "us") async -> [AcquisitionResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        async let songs = fetchSongs(term: trimmed, limit: songLimit, country: country)
        async let albums = fetchAlbums(term: trimmed, limit: albumLimit, country: country)
        let (songRows, albumRows) = await (songs, albums)

        var seen = Set<String>()
        var out: [AcquisitionResult] = []
        out.reserveCapacity(songRows.count + albumRows.count)
        for row in songRows + albumRows where seen.insert(row.request.requestKey).inserted {
            out.append(row)
        }
        return out
    }

    // MARK: - Fetch

    private static func fetchSongs(term: String, limit: Int, country: String) async -> [AcquisitionResult] {
        guard let rows = await search(term: term, entity: "song", limit: limit, country: country) else { return [] }
        var out: [AcquisitionResult] = []
        out.reserveCapacity(rows.count)
        for r in rows {
            guard let trackId = r["trackId"] as? Int,
                  let title = r["trackName"] as? String,
                  let artist = r["artistName"] as? String
            else { continue }
            let album = (r["collectionName"] as? String) ?? ""
            let art = (r["artworkUrl100"] as? String).flatMap(upscale)
            let year = releaseYear(from: r["releaseDate"] as? String)
            let explicit = (r["trackExplicitness"] as? String) == "explicit"
            out.append(AcquisitionResult(
                id: "itunes:track:\(trackId)",
                title: title,
                artists: [artist],
                albumName: album,
                coverURL: art,
                year: year,
                explicit: explicit,
                subtitle: "Song · \(artist)",
                request: AcquisitionRequest(
                    artist: artist,
                    trackTitle: title,
                    albumTitle: album.isEmpty ? nil : album,
                    coverURL: art,
                    requestKey: "itunes:track:\(trackId)",
                ),
            ))
        }
        return out
    }

    private static func fetchAlbums(term: String, limit: Int, country: String) async -> [AcquisitionResult] {
        guard let rows = await search(term: term, entity: "album", limit: limit, country: country) else { return [] }
        var out: [AcquisitionResult] = []
        out.reserveCapacity(rows.count)
        for r in rows {
            guard let collectionId = r["collectionId"] as? Int,
                  let title = r["collectionName"] as? String,
                  let artist = r["artistName"] as? String
            else { continue }
            let art = (r["artworkUrl100"] as? String).flatMap(upscale)
            let year = releaseYear(from: r["releaseDate"] as? String)
            let explicit = (r["collectionExplicitness"] as? String) == "explicit"
            out.append(AcquisitionResult(
                id: "itunes:album:\(collectionId)",
                title: title,
                artists: [artist],
                albumName: title,
                coverURL: art,
                year: year,
                explicit: explicit,
                subtitle: "Album · \(artist)",
                request: AcquisitionRequest(
                    artist: artist,
                    albumTitle: title,
                    coverURL: art,
                    requestKey: "itunes:album:\(collectionId)",
                ),
            ))
        }
        return out
    }

    private static func search(term: String, entity: String, limit: Int, country: String) async -> [[String: Any]]? {
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 50)))),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]]
        else { return nil }
        return results
    }

    private static func releaseYear(from raw: String?) -> Int? {
        guard let raw, let date = iso.date(from: raw) else { return nil }
        return gregorian.component(.year, from: date)
    }

    private static func upscale(_ raw: String) -> URL? {
        guard let regex = artworkSizeRegex else { return URL(string: raw) }
        let range = NSRange(raw.startIndex..., in: raw)
        return URL(string: regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "512x512bb"))
    }
}
