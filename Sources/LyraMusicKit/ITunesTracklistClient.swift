import Foundation

/// The exact tracklist for an iTunes album via the public lookup API
/// (`itunes.apple.com/lookup?id=<collectionId>&entity=song`). Used to populate the New tab
/// album-detail preview rows — far more reliable than searching MusicBrainz by name, since the
/// album id comes straight from the iTunes feed that surfaced the album.
enum ITunesTracklistClient {
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
