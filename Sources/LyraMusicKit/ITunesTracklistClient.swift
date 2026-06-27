import Foundation

/// The exact tracklist for an iTunes album via the public lookup API
/// (`itunes.apple.com/lookup?id=<collectionId>&entity=song`). Used to populate browse album
/// detail rows and library "complete album" previews.
enum ITunesTracklistClient {
    /// Best-effort iTunes collection id for an artist + album title.
    static func albumId(artist: String, albumTitle: String, country: String = "us") async -> String? {
        let artistTrimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleTrimmed = albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artistTrimmed.isEmpty, !titleTrimmed.isEmpty else { return nil }
        let term = "\(artistTrimmed) \(titleTrimmed)"
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "12"),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]]
        else { return nil }

        let targetArtist = LibraryTrackMatcher.normalize(artistTrimmed)
        let targetAlbum = LibraryTrackMatcher.normalize(titleTrimmed)
        func artistMatches(_ raw: String) -> Bool {
            let norm = LibraryTrackMatcher.normalize(raw)
            return !norm.isEmpty && (norm == targetArtist || norm.contains(targetArtist) || targetArtist.contains(norm))
        }
        func albumMatches(_ raw: String) -> Bool {
            let norm = LibraryTrackMatcher.normalize(raw)
            return !norm.isEmpty && (norm == targetAlbum || norm.contains(targetAlbum) || targetAlbum.contains(norm))
        }

        if let match = results.first(where: {
            artistMatches(($0["artistName"] as? String) ?? "")
                && albumMatches(($0["collectionName"] as? String) ?? "")
        }), let id = match["collectionId"] as? Int {
            return String(id)
        }
        return results.first(where: {
            artistMatches(($0["artistName"] as? String) ?? "")
        }).flatMap { ($0["collectionId"] as? Int).map(String.init) }
    }

    static func tracks(artist: String, albumTitle: String, country: String = "us") async -> [BrowseAlbumPreviewTrack] {
        guard let albumId = await albumId(artist: artist, albumTitle: albumTitle, country: country) else { return [] }
        return await tracks(forAlbumId: albumId, country: country)
    }

    static func tracks(forAlbumId albumId: String, country: String = "us") async -> [BrowseAlbumPreviewTrack] {
        let trimmed = albumId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard var comps = URLComponents(string: "https://itunes.apple.com/lookup") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "id", value: trimmed),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "200"),
        ]
        guard let url = comps.url else { return [] }

        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]]
        else { return [] }

        var rows: [BrowseAlbumPreviewTrack] = []
        for r in results where (r["wrapperType"] as? String) == "track" {
            guard let title = r["trackName"] as? String else { continue }
            let number = (r["trackNumber"] as? Int) ?? (rows.count + 1)
            let duration = (r["trackTimeMillis"] as? Int).map { TimeInterval($0) / 1000 }
            let id = (r["trackId"] as? Int).map(String.init) ?? "\(trimmed)-\(number)"
            rows.append(BrowseAlbumPreviewTrack(id: id, position: number, title: title, duration: duration))
        }
        return rows.sorted { $0.position < $1.position }
    }
}
