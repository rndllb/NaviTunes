import Foundation

/// One album in an artist's iTunes discography, already classified into a discography bucket.
struct ITunesArtistAlbum: Hashable {
    let id: String          // iTunes collection id (drives the iTunes tracklist lookup)
    let title: String
    let artist: String
    let artworkURL: URL?
    let releaseDate: Date?
    let bucket: ArtistDiscographyBucket
    let trackCount: Int?

    var releaseYear: Int? {
        guard let releaseDate else { return nil }
        return Calendar(identifier: .gregorian).component(.year, from: releaseDate)
    }
}

/// An artist's discography from Apple's free, public iTunes APIs — the sole external metadata
/// source for browse/discovery. Two-step: resolve the artist's iTunes id (Search), then list
/// every album (`lookup?entity=album`). Artwork comes built in from the fast `mzstatic` CDN.
enum ITunesArtistClient {
    private static let iso = ISO8601DateFormatter()

    struct SearchResult: Identifiable, Hashable {
        let id: String
        let name: String
        let artworkURL: URL?
    }

    /// Artists matching `name` for Discover search (not on the user's server).
    static func searchArtists(name: String, limit: Int = 5, country: String = "us") async -> [SearchResult] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 25)))),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]]
        else { return [] }

        var artists: [SearchResult] = []
        var seen = Set<String>()
        for r in results {
            guard let artistId = r["artistId"] as? Int,
                  let artistName = r["artistName"] as? String
            else { continue }
            let id = String(artistId)
            let norm = LibraryTrackMatcher.normalize(artistName)
            guard !norm.isEmpty, seen.insert(norm).inserted else { continue }
            artists.append(SearchResult(
                id: id,
                name: artistName,
                artworkURL: (r["artworkUrl100"] as? String).flatMap(upscale),
            ))
        }
        return artists
    }

    /// The iTunes artist id best matching `name`, or `nil`.
    static func artistId(forName name: String, country: String = "us") async -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]]
        else { return nil }

        // Prefer an exact (normalized) name match; otherwise take the top result.
        let target = LibraryTrackMatcher.normalize(trimmed)
        let exact = results.first {
            LibraryTrackMatcher.normalize(($0["artistName"] as? String) ?? "") == target
        }
        return (exact ?? results.first)?["artistId"] as? Int
    }

    /// Every album in the artist's iTunes discography, newest-first, bucketed.
    static func discography(forArtist name: String, country: String = "us") async -> [ITunesArtistAlbum] {
        guard let artistId = await artistId(forName: name, country: country) else { return [] }
        return await discography(forArtistId: artistId, country: country)
    }

    static func discography(forArtistId artistId: Int, country: String = "us") async -> [ITunesArtistAlbum] {
        guard var comps = URLComponents(string: "https://itunes.apple.com/lookup") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "id", value: String(artistId)),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "200"),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]]
        else { return [] }

        var albums: [ITunesArtistAlbum] = []
        var seen = Set<String>()
        for r in results where (r["wrapperType"] as? String) == "collection" {
            guard let collectionId = r["collectionId"] as? Int,
                  let title = r["collectionName"] as? String,
                  let artist = r["artistName"] as? String
            else { continue }
            let id = String(collectionId)
            guard seen.insert(id).inserted else { continue }
            let trackCount = r["trackCount"] as? Int
            albums.append(ITunesArtistAlbum(
                id: id,
                title: title,
                artist: artist,
                artworkURL: (r["artworkUrl100"] as? String).flatMap(upscale),
                releaseDate: (r["releaseDate"] as? String).flatMap { iso.date(from: $0) },
                bucket: bucket(title: title, trackCount: trackCount),
                trackCount: trackCount,
            ))
        }
        return dedupedEditions(albums).sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
    }

    // MARK: - Helpers

    /// Collapse iTunes' multiple editions of the same release (standard / deluxe / remaster /
    /// regional variants all share a title but carry distinct collection ids) down to one card
    /// per album, keeping the most complete edition (highest track count).
    private static func dedupedEditions(_ albums: [ITunesArtistAlbum]) -> [ITunesArtistAlbum] {
        var bestByKey: [String: ITunesArtistAlbum] = [:]
        var order: [String] = []
        for album in albums {
            let key = "\(album.bucket)|\(editionKey(album.title))"
            if let existing = bestByKey[key] {
                if preferredEdition(album, over: existing) { bestByKey[key] = album }
            } else {
                bestByKey[key] = album
                order.append(key)
            }
        }
        return order.compactMap { bestByKey[$0] }
    }

    /// Pick the canonical edition to show: the standard (unqualified) title wins so the card
    /// reads cleanly and matches the user's server album; otherwise the most complete edition.
    private static func preferredEdition(_ candidate: ITunesArtistAlbum, over current: ITunesArtistAlbum) -> Bool {
        let candidateClean = editionKey(candidate.title) == LibraryTrackMatcher.normalize(candidate.title)
        let currentClean = editionKey(current.title) == LibraryTrackMatcher.normalize(current.title)
        if candidateClean != currentClean { return candidateClean }
        return (candidate.trackCount ?? 0) > (current.trackCount ?? 0)
    }

    /// Normalised title with edition qualifiers stripped, so "Album", "Album (Deluxe)" and
    /// "Album - EP" collapse to the same key.
    private static func editionKey(_ title: String) -> String {
        var t = title.lowercased()
        t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(
            of: #"\s*-\s*(single|ep|deluxe|deluxe edition|remaster(ed)?|special edition|expanded edition|anniversary edition|bonus track version|live).*$"#,
            with: "",
            options: .regularExpression,
        )
        return LibraryTrackMatcher.normalize(t)
    }

    /// Classify an iTunes album into a discography bucket (iTunes' `collectionType` is always
    /// "Album", so we infer from the title and track count — same heuristic as server albums).
    private static func bucket(title: String, trackCount: Int?) -> ArtistDiscographyBucket {
        let lower = title.lowercased()
        if lower.range(of: #"\blive\b"#, options: .regularExpression) != nil { return .live }
        if lower.range(of: #"\bgreatest hits\b|\bbest of\b|\banthology\b|\bcompilation\b|\bcollection\b"#, options: .regularExpression) != nil {
            return .compilations
        }
        if lower.hasSuffix("- single") || lower.hasSuffix("- ep") { return .singlesAndEPs }
        if let n = trackCount, n <= 6 { return .singlesAndEPs }
        return .albums
    }

    private static func upscale(_ raw: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "[0-9]+x[0-9]+bb") else { return URL(string: raw) }
        let range = NSRange(raw.startIndex..., in: raw)
        return URL(string: regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "512x512bb"))
    }
}
