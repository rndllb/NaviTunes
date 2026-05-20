import Foundation

/// Recent album **release groups** from MusicBrainz (free, no API key; polite ``User-Agent`` + rate limits apply).
enum MusicBrainzNewReleasesClient {
    private static let userAgent = "LyraMusic/1.0 (https://github.com/randll)"

    /// Albums whose first release date falls in the rolling window ending today (newest first).
    static func fetchRecentAlbums(limit: Int = 50, windowDays: Int = 120) async throws -> [ChartAlbum] {
        let capped = min(max(limit, 1), 80)
        let cal = Calendar(identifier: .gregorian)
        let end = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -max(windowDays, 14), to: end) else {
            throw NSError(domain: "MusicBrainzNewReleasesClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not build date range"])
        }
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        let startStr = fmt.string(from: start)
        let endStr = fmt.string(from: end)
        let query = "primarytype:album AND firstreleasedate:[\(startStr) TO \(endStr)]"

        guard var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release-group") else {
            throw NSError(domain: "MusicBrainzNewReleasesClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid MusicBrainz URL"])
        }
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "\(capped)"),
        ]
        guard let url = comps.url else {
            throw NSError(domain: "MusicBrainzNewReleasesClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not build search URL"])
        }

        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "MusicBrainzNewReleasesClient", code: 4, userInfo: [NSLocalizedDescriptionKey: "No HTTP response from MusicBrainz"])
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "MusicBrainzNewReleasesClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "MusicBrainz search failed (\(http.statusCode)): \(body.prefix(240))"]
            )
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = obj["release-groups"] as? [[String: Any]]
        else {
            throw NSError(domain: "MusicBrainzNewReleasesClient", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unexpected MusicBrainz JSON"])
        }

        var albums: [ChartAlbum] = []
        var seen = Set<String>()
        for g in groups {
            guard let id = g["id"] as? String, !id.isEmpty,
                  let title = g["title"] as? String, !title.isEmpty
            else { continue }
            guard seen.insert(id).inserted else { continue }
            let artist = artistLine(from: g)
            let cover = URL(string: "https://coverartarchive.org/release-group/\(id)/front-250")
            albums.append(ChartAlbum(id: id, name: title, artistName: artist, imageURL: cover))
        }

        let sorted = albums.sorted { firstReleaseDate(for: $0.id, in: groups) > firstReleaseDate(for: $1.id, in: groups) }
        return Array(sorted.prefix(capped))
    }

    private static func firstReleaseDate(for id: String, in groups: [[String: Any]]) -> String {
        guard let g = groups.first(where: { ($0["id"] as? String) == id }),
              let d = g["first-release-date"] as? String
        else { return "" }
        return d
    }

    private static func artistLine(from group: [String: Any]) -> String {
        guard let credit = group["artist-credit"] as? [[String: Any]] else {
            return "Unknown Artist"
        }
        let parts = credit.compactMap { entry -> String? in
            if let n = entry["name"] as? String, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return n
            }
            if let artist = entry["artist"] as? [String: Any],
               let n = artist["name"] as? String,
               !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return n
            }
            return nil
        }
        return parts.isEmpty ? "Unknown Artist" : parts.joined(separator: ", ")
    }
}
