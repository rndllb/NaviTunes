import Foundation

/// Structured biographical facts for an artist — birthplace, birth/formation date, country, and
/// genres — the "From / Born / Genre" details Apple Music shows. Sourced from MusicBrainz's free
/// public API in a **single** artist-search request (the result carries `area`, `begin-area`,
/// `life-span`, and `tags` inline), so it doesn't depend on MusicBrainz for any other feature.
struct ArtistProfile: Sendable, Equatable {
    /// MusicBrainz artist id — used to look up similar artists (ListenBrainz).
    let mbid: String?
    /// Formatted "From" line — birthplace city plus country when both are known.
    let origin: String?
    /// Formatted "Born"/"Formed" line — full date when MusicBrainz has one, else the year.
    let born: String?
    /// Top genre tag, title-cased.
    let genre: String?

    var isEmpty: Bool { origin == nil && born == nil && genre == nil }
}

enum ArtistProfileClient {
    private static let userAgent = "VellumMusic/1.0 (https://github.com/randll)"

    static func fetch(name: String) async -> ArtistProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard var comps = URLComponents(string: "https://musicbrainz.org/ws/2/artist") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(trimmed)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artist = (obj["artists"] as? [[String: Any]])?.first
        else { return nil }

        // Only trust the match if the name lines up — search can return a loose top hit.
        let returned = (artist["name"] as? String) ?? ""
        guard LibraryTrackMatcher.normalize(returned) == LibraryTrackMatcher.normalize(trimmed) else { return nil }

        let beginArea = ((artist["begin-area"] as? [String: Any])?["name"] as? String)?.trimmedNonEmpty
        let area = ((artist["area"] as? [String: Any])?["name"] as? String)?.trimmedNonEmpty
        let origin: String? = {
            switch (beginArea, area) {
            case let (city?, country?) where city != country: return "\(city), \(country)"
            case let (city?, _): return city
            case let (_, country?): return country
            default: return nil
            }
        }()

        let beginDate = ((artist["life-span"] as? [String: Any])?["begin"] as? String)?.trimmedNonEmpty
        let born = beginDate.map(formattedDate)

        let genre = topGenre(from: artist["tags"] as? [[String: Any]])
        let mbid = (artist["id"] as? String)?.trimmedNonEmpty

        let profile = ArtistProfile(mbid: mbid, origin: origin, born: born, genre: genre)
        return (profile.isEmpty && mbid == nil) ? nil : profile
    }

    /// MusicBrainz dates are `yyyy`, `yyyy-MM`, or `yyyy-MM-dd`. Show the most precise readable form.
    private static func formattedDate(_ raw: String) -> String {
        let parts = raw.split(separator: "-").map(String.init)
        var comps = DateComponents()
        guard let year = parts.first.flatMap({ Int($0) }) else { return raw }
        comps.year = year
        if parts.count >= 2 { comps.month = Int(parts[1]) }
        if parts.count >= 3 { comps.day = Int(parts[2]) }
        let cal = Calendar(identifier: .gregorian)
        guard let date = cal.date(from: comps) else { return raw }

        let fmt = DateFormatter()
        fmt.calendar = cal
        if parts.count >= 3 {
            fmt.dateStyle = .long          // "February 16, 1995"
        } else if parts.count == 2 {
            fmt.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        } else {
            return String(year)
        }
        return fmt.string(from: date)
    }

    private static func topGenre(from tags: [[String: Any]]?) -> String? {
        guard let tags else { return nil }
        let best = tags
            .compactMap { tag -> (String, Int)? in
                guard let name = (tag["name"] as? String)?.trimmedNonEmpty else { return nil }
                return (name, (tag["count"] as? Int) ?? 0)
            }
            .max { $0.1 < $1.1 }?.0
        return best.map { $0.capitalized }
    }
}

private extension String {
    /// Trimmed string, or `nil` if blank after trim.
    var trimmedNonEmpty: String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
