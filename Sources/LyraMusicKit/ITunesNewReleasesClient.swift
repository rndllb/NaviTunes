import Foundation

/// Fresh album content from Apple's free, public iTunes feeds — the New tab's content source
/// (replacing MusicBrainz). Two surfaces:
///   • **Top albums by genre** (`/{country}/rss/topalbums/genre={id}`) — what's hot per genre,
///     carrying full release dates and artwork so we can favor genuinely recent releases.
///   • **An artist's recent albums** via the Search API — powers the "From Artists You Play" shelf.
///
/// Both return artwork from Apple's fast `mzstatic` CDN, so no separate cover-art enrichment is
/// needed (unlike the slow Cover Art Archive).
enum ITunesNewReleasesClient {
    /// Canonical genre name (lowercased, as produced by ``GenreCanonicalizer``) → iTunes genre id.
    static let genreIds: [String: Int] = [
        "hip-hop": 18, "r&b": 15, "electronic": 7, "lo-fi": 7, "metal": 1153, "punk": 1144,
        "jazz": 11, "blues": 2, "country": 6, "folk": 1062, "reggae": 24,
        "latin": 12, "classical": 5, "gospel": 22, "funk": 15, "alternative": 20,
        "pop": 14, "rock": 21, "soundtrack": 16, "world": 19, "holiday": 8,
    ]

    private static let iso = ISO8601DateFormatter()

    /// Top albums for a genre (or all music when `genreId` is `nil`), newest-first.
    static func topAlbums(genreId: Int?, limit: Int = 25, country: String = "us") async -> [ChartAlbum] {
        var path = "https://itunes.apple.com/\(country)/rss/topalbums/limit=\(max(1, min(limit, 100)))"
        if let genreId { path += "/genre=\(genreId)" }
        path += "/json"
        guard let url = URL(string: path) else { return [] }

        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = obj["feed"] as? [String: Any],
              let entries = feed["entry"] as? [[String: Any]]
        else { return [] }

        var albums: [ChartAlbum] = []
        var seen = Set<String>()
        for entry in entries {
            guard let id = ((entry["id"] as? [String: Any])?["attributes"] as? [String: Any])?["im:id"] as? String,
                  !id.isEmpty, seen.insert(id).inserted,
                  let name = (entry["im:name"] as? [String: Any])?["label"] as? String,
                  let artist = (entry["im:artist"] as? [String: Any])?["label"] as? String
            else { continue }
            let releaseRaw = (entry["im:releaseDate"] as? [String: Any])?["label"] as? String
            albums.append(ChartAlbum(
                id: id,
                name: name,
                artistName: artist,
                imageURL: largestImage(from: entry["im:image"]),
                releaseDate: releaseRaw.flatMap { iso.date(from: $0) },
            ))
        }
        return albums.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
    }

    /// New content across the user's top genres, fetched concurrently (no rate-limit pacing,
    /// unlike MusicBrainz). Each genre name is mapped to its iTunes genre id; unknown genres
    /// are skipped.
    static func newReleasesForGenres(
        _ genres: [String],
        perGenre: Int = 20,
        country: String = "us",
    ) async -> [ChartAlbum] {
        let ids = genres.compactMap { genreIds[$0.lowercased()] }
        guard !ids.isEmpty else { return [] }

        var collected: [ChartAlbum] = []
        var seen = Set<String>()
        await withTaskGroup(of: [ChartAlbum].self) { group in
            for id in ids {
                group.addTask { await topAlbums(genreId: id, limit: perGenre, country: country) }
            }
            for await albums in group {
                for album in albums where seen.insert(album.id).inserted {
                    collected.append(album)
                }
            }
        }
        return collected
    }

    /// Top songs for a genre (or all music when `genreId` is `nil`), chart order.
    static func topSongs(genreId: Int?, limit: Int = 25, country: String = "us") async -> [ChartTrack] {
        var path = "https://itunes.apple.com/\(country)/rss/topsongs/limit=\(max(1, min(limit, 100)))"
        if let genreId { path += "/genre=\(genreId)" }
        path += "/json"
        guard let url = URL(string: path) else { return [] }

        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = obj["feed"] as? [String: Any],
              let rawEntries = feed["entry"]
        else { return [] }

        let entries = rssEntries(rawEntries)
        var tracks: [ChartTrack] = []
        var seen = Set<String>()
        for entry in entries {
            guard let id = ((entry["id"] as? [String: Any])?["attributes"] as? [String: Any])?["im:id"] as? String,
                  !id.isEmpty, seen.insert(id).inserted,
                  let name = (entry["im:name"] as? [String: Any])?["label"] as? String,
                  let artist = (entry["im:artist"] as? [String: Any])?["label"] as? String
            else { continue }
            tracks.append(ChartTrack(
                id: id,
                name: name,
                artistName: artist,
                imageURL: largestImage(from: entry["im:image"]),
                playcount: 0,
                browseKind: "Single",
            ))
        }
        return tracks
    }

    /// Charting songs across the user's top genres, fetched concurrently.
    static func topSongsForGenres(
        _ genres: [String],
        perGenre: Int = 20,
        country: String = "us",
    ) async -> [ChartTrack] {
        let ids = genres.compactMap { genreIds[$0.lowercased()] }
        guard !ids.isEmpty else { return [] }

        var collected: [ChartTrack] = []
        var seen = Set<String>()
        await withTaskGroup(of: [ChartTrack].self) { group in
            for id in ids {
                group.addTask { await topSongs(genreId: id, limit: perGenre, country: country) }
            }
            for await batch in group {
                for track in batch where seen.insert(track.id).inserted {
                    collected.append(track)
                }
            }
        }
        return collected
    }

    /// An artist's recent **official** releases via iTunes artist id + discography lookup.
    /// Unlike a plain Search `artistTerm` query, this excludes tribute/bootleg singles that
    /// only mention the artist in the title (e.g. "Patience (R.I.P. Speaker Knockerz)").
    static func recentAlbums(forArtist name: String, limit: Int = 8, country: String = "us") async -> [ChartAlbum] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let artistId = await ITunesArtistClient.artistId(forName: trimmed, country: country) else { return [] }
        let discography = await ITunesArtistClient.discography(forArtistId: artistId, country: country)
        return discography
            .filter { ITunesArtistMatching.isOfficialRelease(title: $0.title, artistLine: $0.artist, targetName: trimmed) }
            .prefix(limit)
            .map {
                ChartAlbum(
                    id: $0.id,
                    name: $0.title,
                    artistName: $0.artist,
                    imageURL: $0.artworkURL,
                    releaseDate: $0.releaseDate,
                )
            }
    }

    /// Recent singles from an artist's iTunes discography (official releases only).
    static func recentSingles(forArtist name: String, limit: Int = 6, country: String = "us") async -> [ChartTrack] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let artistId = await ITunesArtistClient.artistId(forName: trimmed, country: country) else { return [] }
        let discography = await ITunesArtistClient.discography(forArtistId: artistId, country: country)
        return discography
            .filter {
                $0.bucket == .singlesAndEPs
                    && ITunesArtistMatching.isOfficialRelease(title: $0.title, artistLine: $0.artist, targetName: trimmed)
            }
            .prefix(limit)
            .map {
                ChartTrack(
                    id: $0.id,
                    name: $0.title,
                    artistName: $0.artist,
                    imageURL: $0.artworkURL,
                    playcount: 0,
                    browseKind: "Single",
                )
            }
    }

    // MARK: - Helpers

    private static func rssEntries(_ raw: Any) -> [[String: Any]] {
        if let one = raw as? [String: Any] { return [one] }
        return raw as? [[String: Any]] ?? []
    }

    /// The largest `im:image` URL from an RSS entry, upscaled to a high-res cover.
    private static func largestImage(from raw: Any?) -> URL? {
        guard let images = raw as? [[String: Any]],
              let last = images.last,
              let label = last["label"] as? String
        else { return nil }
        return upscale(label)
    }

    /// Rewrite an `…/NxNbb.<ext>` artwork URL to a 512px edge (Apple serves any size).
    private static func upscale(_ raw: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "[0-9]+x[0-9]+bb") else { return URL(string: raw) }
        let range = NSRange(raw.startIndex..., in: raw)
        let replaced = regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "512x512bb")
        return URL(string: replaced)
    }
}

/// Filters iTunes catalog rows so taste-artist fetches don't pull tribute / feature credits.
enum ITunesArtistMatching {
    /// True when `artistLine` is the target artist or a direct collaboration (`Drake & Future`).
    static func lineMatchesArtist(_ artistLine: String, targetName: String) -> Bool {
        let target = LibraryTrackMatcher.normalize(targetName)
        guard !target.isEmpty else { return false }
        let line = LibraryTrackMatcher.normalize(artistLine)
        if line == target { return true }
        if line.hasPrefix(target + " &") || line.hasPrefix(target + ",") { return true }

        let parts = artistLine
            .split { $0 == "&" || $0 == "," }
            .map { LibraryTrackMatcher.normalize(String($0)) }
            .filter { !$0.isEmpty }
        return parts.contains(target)
    }

    /// Drop rows where the title name-drops the artist but the primary credit is someone else.
    static func isFeatureOrTributeCredit(title: String, artistLine: String, targetName: String) -> Bool {
        guard !lineMatchesArtist(artistLine, targetName: targetName) else { return false }
        let titleLower = title.lowercased()
        let targetLower = targetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !targetLower.isEmpty else { return true }
        if titleLower.contains("feat. \(targetLower)") || titleLower.contains("(feat. \(targetLower)") {
            return true
        }
        if titleLower.contains("featuring \(targetLower)") { return true }
        if titleLower.contains("rip \(targetLower)") || titleLower.contains("r.i.p. \(targetLower)") {
            return true
        }
        return false
    }

    static func isOfficialRelease(title: String, artistLine: String, targetName: String) -> Bool {
        lineMatchesArtist(artistLine, targetName: targetName)
            && !isFeatureOrTributeCredit(title: title, artistLine: artistLine, targetName: targetName)
    }
}
