import Foundation

/// One release-group credited to an artist on MusicBrainz, used by the artist page
/// to classify the user's server discography (album vs single vs EP vs live vs
/// compilation) and to surface "other releases" not present on the user's server.
struct MusicBrainzArtistRelease: Identifiable, Hashable {
    enum Kind: String, Hashable, Sendable {
        case album
        case ep
        case single
        case live
        case compilation
        case other
    }

    let id: String
    let title: String
    let primaryType: String?
    let secondaryTypes: [String]
    let firstReleaseDate: String?
    let artistCredit: String

    var kind: Kind {
        let lowerSecondary = Set(secondaryTypes.map { $0.lowercased() })
        if lowerSecondary.contains("live") { return .live }
        if lowerSecondary.contains("compilation") || lowerSecondary.contains("mixtape/street")
            || lowerSecondary.contains("interview") || lowerSecondary.contains("demo")
        {
            return .compilation
        }
        switch primaryType?.lowercased() {
        case "album": return .album
        case "single": return .single
        case "ep": return .ep
        default: return .other
        }
    }

    /// Cover Art Archive front-cover URL by release-group id. CAA returns 404 when missing — clients should treat the
    /// image as optional and fall back gracefully.
    var coverArtURL: URL? {
        URL(string: "https://coverartarchive.org/release-group/\(id)/front-250")
    }

    /// Year extracted from `firstReleaseDate` (`yyyy-MM-dd` or `yyyy`).
    var releaseYear: Int? {
        guard let s = firstReleaseDate?.prefix(4), let y = Int(s) else { return nil }
        return y
    }
}

/// MusicBrainz lookups scoped to a single artist — name → id, and id → release-groups.
/// Used by the artist page for discography classification and to surface non-library releases.
enum MusicBrainzArtistClient {
    private static let userAgent = "LyraMusic/1.0 (https://github.com/randll)"

    /// Search `/ws/2/artist?query=` and return the top match's MBID, or nil when nothing scores.
    static func findArtistId(name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Treat "Various Artists" as a sentinel — it matches everything and produces a useless page.
        if trimmed.lowercased() == "various artists" { return nil }

        guard var comps = URLComponents(string: "https://musicbrainz.org/ws/2/artist") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(trimmed)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = comps.url else { return nil }

        do {
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artists = obj["artists"] as? [[String: Any]]
            else { return nil }

            // Prefer an exact case-insensitive name match before falling back to the top-ranked row.
            let lower = trimmed.lowercased()
            if let exact = artists.first(where: { ($0["name"] as? String)?.lowercased() == lower }),
               let id = exact["id"] as? String, !id.isEmpty
            {
                return id
            }
            if let first = artists.first, let id = first["id"] as? String, !id.isEmpty {
                return id
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Artist name search returning up to `limit` candidates (id + display name), ranked by
    /// MusicBrainz score. Used to surface artists not in the server library as search results.
    static func searchArtists(name: String, limit: Int = 5) async -> [(id: String, name: String)] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "various artists" else { return [] }
        guard var comps = URLComponents(string: "https://musicbrainz.org/ws/2/artist") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(trimmed)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "\(max(1, min(limit, 25)))"),
        ]
        guard let url = comps.url else { return [] }
        do {
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artists = obj["artists"] as? [[String: Any]]
            else { return [] }
            return artists.compactMap { dict in
                guard let id = dict["id"] as? String, !id.isEmpty,
                      let n = dict["name"] as? String, !n.isEmpty
                else { return nil }
                return (id, n)
            }
        } catch {
            return []
        }
    }

    /// All release-groups credited to `artistId`, deduped, newest first.
    /// Walks the paginated `/release-group?artist=` endpoint until exhaustion or `maxPages`.
    static func releaseGroups(artistId: String, maxPages: Int = 4, pageSize: Int = 100) async -> [MusicBrainzArtistRelease] {
        let trimmedId = artistId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return [] }

        var collected: [MusicBrainzArtistRelease] = []
        var seen = Set<String>()
        for page in 0..<max(1, maxPages) {
            let offset = page * pageSize
            guard let url = pageURL(artistId: trimmedId, offset: offset, limit: pageSize) else { break }
            do {
                var req = URLRequest(url: url)
                req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { break }
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let groups = obj["release-groups"] as? [[String: Any]]
                else { break }
                if groups.isEmpty { break }

                for g in groups {
                    guard let id = g["id"] as? String, !id.isEmpty,
                          let title = g["title"] as? String, !title.isEmpty
                    else { continue }
                    guard seen.insert(id).inserted else { continue }
                    let primary = g["primary-type"] as? String
                    let secondary = (g["secondary-types"] as? [String]) ?? []
                    let firstDate = g["first-release-date"] as? String
                    let credit = artistCreditLine(from: g)
                    collected.append(MusicBrainzArtistRelease(
                        id: id,
                        title: title,
                        primaryType: primary,
                        secondaryTypes: secondary,
                        firstReleaseDate: firstDate,
                        artistCredit: credit
                    ))
                }

                if groups.count < pageSize { break }
            } catch {
                break
            }
        }

        return collected.sorted { lhs, rhs in
            (lhs.firstReleaseDate ?? "") > (rhs.firstReleaseDate ?? "")
        }
    }

    private static func pageURL(artistId: String, offset: Int, limit: Int) -> URL? {
        guard var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release-group") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "artist", value: artistId),
            URLQueryItem(name: "type", value: "album|single|ep"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        return comps.url
    }

    private static func artistCreditLine(from group: [String: Any]) -> String {
        guard let credit = group["artist-credit"] as? [[String: Any]] else { return "" }
        let parts = credit.compactMap { entry -> String? in
            if let n = entry["name"] as? String, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return n
            }
            if let artist = entry["artist"] as? [String: Any],
               let n = artist["name"] as? String,
               !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return n
            }
            return nil
        }
        return parts.joined(separator: ", ")
    }
}
