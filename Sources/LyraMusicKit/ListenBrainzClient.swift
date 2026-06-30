import Foundation

/// Similar artists from MetaBrainz's free, public **ListenBrainz Labs** API
/// (`labs.api.listenbrainz.org/similar-artists`). No API key required; keyed by the artist's
/// MusicBrainz id (which the artist page already resolves for the About page). Used as the
/// Similar Artists source since the iTunes API has no related-artists endpoint.
enum ListenBrainzClient {
    private static let algorithm =
        "session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30"

    static func similarArtists(mbid: String, limit: Int = 16) async -> [LastFmSimilarArtist] {
        let trimmed = mbid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard var comps = URLComponents(string: "https://labs.api.listenbrainz.org/similar-artists/json") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "artist_mbids", value: trimmed),
            URLQueryItem(name: "algorithm", value: algorithm),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        var seen = Set<String>()
        var artists: [LastFmSimilarArtist] = []
        for row in rows {
            guard let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  // Skip the queried artist itself (it can appear as a self-reference).
                  row["artist_mbid"] as? String != trimmed
            else { continue }
            let key = LibraryTrackMatcher.normalize(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let score = (row["score"] as? Double) ?? Double((row["score"] as? Int) ?? 0)
            artists.append(LastFmSimilarArtist(
                name: name,
                mbid: (row["artist_mbid"] as? String),
                imageURL: nil,
                match: score,
            ))
            if artists.count >= limit { break }
        }
        return artists
    }
}
