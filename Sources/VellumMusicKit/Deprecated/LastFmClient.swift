import Foundation

/// Globally-ranked top track for an artist (Last.fm `artist.getTopTracks`).
/// `playcount` and `listeners` are global aggregates, not per-user, so they reflect
/// catalog-wide popularity — the same signal Apple Music's "Top Songs" row uses.
struct LastFmTopTrack: Identifiable, Hashable {
    let title: String
    let playcount: Int
    let listeners: Int
    let mbid: String?

    var id: String { mbid?.isEmpty == false ? mbid! : "txt-\(title.lowercased())" }
}

/// "Listeners also like" artist row (Last.fm `artist.getSimilar`).
struct LastFmSimilarArtist: Identifiable, Hashable {
    let name: String
    let mbid: String?
    let imageURL: URL?
    let match: Double

    var id: String { mbid?.isEmpty == false ? mbid! : "txt-\(name.lowercased())" }
}

/// Lightweight client for Last.fm's free [`audioscrobbler` API](https://www.last.fm/api).
/// Used by the artist page for catalog-wide Top Songs ranking and Similar Artists.
/// API key falls back to the demo key shipped with this app; production deployments
/// can replace `defaultAPIKey` with their own.
enum LastFmClient {
    /// Demo key — replace in a production build with your own from https://www.last.fm/api/account/create.
    static let defaultAPIKey = "9c2c8c3a78dbfbfb6f9e7a9c0e6b7e3f"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        return URLSession(configuration: cfg)
    }()

    static func topTracks(artist: String, limit: Int = 12, apiKey: String = defaultAPIKey) async -> [LastFmTopTrack] {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let url = makeURL(method: "artist.gettoptracks", apiKey: apiKey, extras: [
            "artist": trimmed,
            "limit": "\(limit)",
            "autocorrect": "1",
        ]) else { return [] }

        guard let payload = await fetchJSON(url),
              let root = payload["toptracks"] as? [String: Any]
        else { return [] }

        let raw = root["track"]
        let dicts: [[String: Any]]
        if let arr = raw as? [[String: Any]] {
            dicts = arr
        } else if let one = raw as? [String: Any] {
            dicts = [one]
        } else {
            return []
        }

        var out: [LastFmTopTrack] = []
        for dict in dicts {
            guard let title = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty
            else { continue }
            let playcount = intish(dict["playcount"])
            let listeners = intish(dict["listeners"])
            let mbid = (dict["mbid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(LastFmTopTrack(
                title: title,
                playcount: playcount,
                listeners: listeners,
                mbid: (mbid?.isEmpty == false) ? mbid : nil
            ))
        }
        return out
    }

    /// English-language biography from `artist.getInfo`. Always English (Last.fm
    /// has no localized bios), so this is the natural fallback when TheAudioDB
    /// doesn't have an English `strBiographyEN` for the artist.
    /// Strips Last.fm's trailing `<a href="…">Read more on Last.fm</a>` link
    /// and any raw HTML tags. Returns nil when no bio is available.
    static func artistBio(artist: String, apiKey: String = defaultAPIKey) async -> String? {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = makeURL(method: "artist.getinfo", apiKey: apiKey, extras: [
            "artist": trimmed,
            "autocorrect": "1",
            "lang": "en",
        ]) else { return nil }

        guard let payload = await fetchJSON(url),
              let artist = payload["artist"] as? [String: Any],
              let bio = artist["bio"] as? [String: Any]
        else { return nil }

        let content = (bio["content"] as? String) ?? (bio["summary"] as? String) ?? ""
        let cleaned = stripBioMarkup(content).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Last.fm's bio content is HTML-ish: real biographical prose followed by a
    /// boilerplate `<a href="…">Read more on Last.fm</a>` tail. Strip both the
    /// link and the surrounding "User-contributed text…" boilerplate so the
    /// artist page shows only the actual biographical content.
    private static func stripBioMarkup(_ raw: String) -> String {
        var s = raw
        if let range = s.range(of: #"\s*<a\s+href=\"http[^\"]+\">.*?</a>\s*\.?\s*$"#,
                               options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(range)
        }
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
        return s
    }

    static func similarArtists(artist: String, limit: Int = 16, apiKey: String = defaultAPIKey) async -> [LastFmSimilarArtist] {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let url = makeURL(method: "artist.getsimilar", apiKey: apiKey, extras: [
            "artist": trimmed,
            "limit": "\(limit)",
            "autocorrect": "1",
        ]) else { return [] }

        guard let payload = await fetchJSON(url),
              let root = payload["similarartists"] as? [String: Any]
        else { return [] }

        let raw = root["artist"]
        let dicts: [[String: Any]]
        if let arr = raw as? [[String: Any]] {
            dicts = arr
        } else if let one = raw as? [String: Any] {
            dicts = [one]
        } else {
            return []
        }

        var out: [LastFmSimilarArtist] = []
        for dict in dicts {
            guard let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { continue }
            let mbidRaw = (dict["mbid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let match: Double = {
                if let s = dict["match"] as? String { return Double(s) ?? 0 }
                if let n = dict["match"] as? Double { return n }
                if let n = dict["match"] as? NSNumber { return n.doubleValue }
                return 0
            }()
            let imageURL = pickArtistImageURL(dict["image"])
            out.append(LastFmSimilarArtist(
                name: name,
                mbid: (mbidRaw?.isEmpty == false) ? mbidRaw : nil,
                imageURL: imageURL,
                match: match
            ))
        }
        return out
    }

    // MARK: - Private helpers

    private static func makeURL(method: String, apiKey: String, extras: [String: String]) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "ws.audioscrobbler.com"
        comps.path = "/2.0/"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
        ]
        for (k, v) in extras {
            items.append(URLQueryItem(name: k, value: v))
        }
        comps.queryItems = items
        return comps.url
    }

    private static func fetchJSON(_ url: URL) async -> [String: Any]? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private static func intish(_ value: Any?) -> Int {
        if let n = value as? Int { return n }
        if let s = value as? String { return Int(s) ?? 0 }
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }

    /// Last.fm returns `image` as an array of `{ "#text": URL, "size": "small|medium|large|extralarge|mega" }`.
    /// Most artist entries return the well-known star placeholder; filter that out.
    private static func pickArtistImageURL(_ raw: Any?) -> URL? {
        guard let arr = raw as? [[String: Any]] else { return nil }
        let preferred = ["mega", "extralarge", "large", "medium", "small"]
        for size in preferred {
            for entry in arr where (entry["size"] as? String) == size {
                if let s = entry["#text"] as? String,
                   !s.isEmpty,
                   !s.contains("2a96cbd8b46e442fc41c2b86b821562f"),
                   let u = URL(string: s)
                {
                    return u
                }
            }
        }
        return nil
    }
}
