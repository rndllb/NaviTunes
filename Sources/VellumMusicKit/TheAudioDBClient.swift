import Foundation

/// Chart row from [TheAudioDB](https://www.theaudiodb.com/free_music_api) `trending.php` (iTunes regional charts).
struct AudioDBTrendEntry: Identifiable, Sendable {
    enum ChartKind: Sendable {
        case albumChart
        case singleChart
    }

    let id: String
    let artistName: String
    let albumName: String
    /// Present on singles chart rows — the promoted track.
    let trackName: String?
    let artworkURL: URL?
    let chartKind: ChartKind
    let musicBrainzAlbumId: String?
    let musicBrainzTrackId: String?

    /// Primary line for tiles (track title on singles chart, album otherwise).
    var tileTitle: String {
        if chartKind == .singleChart, let t = trackName?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        return albumName
    }

    /// Second line under the title.
    var tileSubtitle: String {
        artistName.isEmpty ? "Unknown Artist" : artistName
    }

    /// Lidarr `/api/v1/album/lookup` query — always targets the parent album.
    var lidarrAlbumLookupTerm: String {
        "\(artistName) \(albumName)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var albumDedupeKey: String {
        let mb = musicBrainzAlbumId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !mb.isEmpty { return "mb-album-\(mb)" }
        return "txt-\(artistName.lowercased())|\(albumName.lowercased())"
    }

    var singleDedupeKey: String {
        let mbT = musicBrainzTrackId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !mbT.isEmpty { return "mb-track-\(mbT)" }
        let track = trackName ?? ""
        return "txt-\(artistName.lowercased())|\(albumName.lowercased())|\(track.lowercased())"
    }

    init?(trendingDictionary dict: [String: Any], chartKind: ChartKind) {
        guard let artist = dict["strArtist"] as? String,
              artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let album = dict["strAlbum"] as? String,
              album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }
        let trackRaw = dict["strTrack"] as? String
        let track = trackRaw.trimmedNonEmpty

        let mbAlbum = (dict["strAlbumMBID"] as? String).trimmedNonEmpty
        let mbTrack = (dict["strTrackMBID"] as? String).trimmedNonEmpty
        let idTrend = dict["idTrend"] as? String

        let id: String
        switch chartKind {
        case .albumChart:
            id = mbAlbum ?? idTrend ?? UUID().uuidString
        case .singleChart:
            id = mbTrack ?? mbAlbum ?? idTrend ?? UUID().uuidString
        }

        self.id = id
        self.artistName = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.albumName = album.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trackName = track
        self.artworkURL = Self.pickArtworkURL(dict)
        self.chartKind = chartKind
        self.musicBrainzAlbumId = mbAlbum
        self.musicBrainzTrackId = mbTrack
    }

    private static func pickArtworkURL(_ dict: [String: Any]) -> URL? {
        let keys = ["strAlbumThumb", "strArtistThumb", "strTrackThumb"]
        for k in keys {
            guard let s = dict[k] as? String,
                  let u = URL(string: s),
                  s.contains("upload_icon") == false,
                  s.contains("transparent2") == false
            else {
                continue
            }
            return u
        }
        return nil
    }
}

private extension Optional where Wrapped == String {
    /// Trimmed string, or `nil` if missing / blank after trim.
    var trimmedNonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

/// Lightweight client for TheAudioDB v1 JSON API ([documentation](https://www.theaudiodb.com/free_music_api)).
enum TheAudioDBClient {
    /// Public demo key from TheAudioDB docs; replace with a supporter key for higher limits if needed.
    static let publicDemoKey = "123"

    private static let chartCountries = [
        "us", "gb", "de", "it", "es", "nl", "se", "no", "ie", "ch", "at", "be", "nz",
    ]

    /// Dedicated session so chart fetches don’t stampede `URLSession.shared` (fewer “socket not connected” simulator logs).
    private static let trendingSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 90
        return URLSession(configuration: cfg)
    }()

    /// Countries processed per batch (each country runs albums + singles in parallel → ~2× batch concurrent requests).
    private static let trendingFetchBatchSize = 3

    static func fetchRegionalTrending(apiKey: String = publicDemoKey) async -> (
        albums: [AudioDBTrendEntry],
        singles: [AudioDBTrendEntry],
    ) {
        var albumBuckets: [AudioDBTrendEntry] = []
        var singleBuckets: [AudioDBTrendEntry] = []

        for batchStart in stride(from: 0, to: chartCountries.count, by: trendingFetchBatchSize) {
            let end = min(batchStart + trendingFetchBatchSize, chartCountries.count)
            let batch = Array(chartCountries[batchStart ..< end])
            await withTaskGroup(of: ([AudioDBTrendEntry], [AudioDBTrendEntry]).self) { group in
                for country in batch {
                    group.addTask {
                        async let albums = fetchTrendingEntries(apiKey: apiKey, country: country, format: "albums")
                        async let singles = fetchTrendingEntries(apiKey: apiKey, country: country, format: "singles")
                        return await (albums, singles)
                    }
                }
                for await pair in group {
                    albumBuckets.append(contentsOf: pair.0)
                    singleBuckets.append(contentsOf: pair.1)
                }
            }
        }

        return (dedupeAlbums(albumBuckets), dedupeSingles(singleBuckets))
    }

    private static func trendingURL(apiKey: String, country: String, format: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "www.theaudiodb.com"
        comps.path = "/api/v1/json/\(apiKey)/trending.php"
        comps.queryItems = [
            URLQueryItem(name: "country", value: country.lowercased()),
            URLQueryItem(name: "type", value: "itunes"),
            URLQueryItem(name: "format", value: format),
        ]
        return comps.url
    }

    private static func fetchTrendingEntries(apiKey: String, country: String, format: String) async -> [AudioDBTrendEntry] {
        guard let url = trendingURL(apiKey: apiKey, country: country, format: format) else { return [] }
        do {
            let (data, response) = try await trendingSession.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let trending = obj["trending"] as? [[String: Any]]
            else {
                return []
            }
            let kind: AudioDBTrendEntry.ChartKind = format == "singles" ? .singleChart : .albumChart
            return trending.compactMap { AudioDBTrendEntry(trendingDictionary: $0, chartKind: kind) }
        } catch {
            return []
        }
    }

    private static func dedupeAlbums(_ items: [AudioDBTrendEntry]) -> [AudioDBTrendEntry] {
        var seen = Set<String>()
        var out: [AudioDBTrendEntry] = []
        for item in items {
            let k = item.albumDedupeKey
            guard !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(item)
        }
        return out
    }

    private static func dedupeSingles(_ items: [AudioDBTrendEntry]) -> [AudioDBTrendEntry] {
        var seen = Set<String>()
        var out: [AudioDBTrendEntry] = []
        for item in items {
            let k = item.singleDedupeKey
            guard !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(item)
        }
        return out
    }

    // MARK: - Artist details (artist page enrichment)

    /// Enrichment payload from TheAudioDB `search.php?s=<name>` — banner artwork,
    /// biography, origin, formed year, and primary genre tag. Every field is
    /// optional because TheAudioDB coverage is uneven (well-known acts are
    /// thorough; smaller artists may have only a name + thumb).
    struct ArtistDetails: Sendable, Equatable {
        let name: String
        let wideArtworkURL: URL?
        let thumbArtworkURL: URL?
        let biography: String?
        let country: String?
        let formedYear: Int?
        let genre: String?
    }

    static func fetchArtistDetails(name: String, apiKey: String = publicDemoKey) async -> ArtistDetails? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "www.theaudiodb.com"
        comps.path = "/api/v1/json/\(apiKey)/search.php"
        comps.queryItems = [URLQueryItem(name: "s", value: trimmed)]
        guard let url = comps.url else { return nil }

        do {
            let (data, response) = try await trendingSession.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artists = obj["artists"] as? [[String: Any]],
                  let dict = artists.first
            else { return nil }
            return parseArtistDetails(dict)
        } catch {
            return nil
        }
    }

    private static func parseArtistDetails(_ dict: [String: Any]) -> ArtistDetails? {
        let name = (dict["strArtist"] as? String).trimmedNonEmpty ?? ""
        guard !name.isEmpty else { return nil }

        let wideKeys = ["strArtistFanart", "strArtistFanart2", "strArtistFanart3", "strArtistBanner", "strArtistWideThumb"]
        let thumbKeys = ["strArtistThumb", "strArtistCutout", "strArtistLogo"]

        // Prefer the explicit English bio; fall back to the default `strBiography`
        // field, which TheAudioDB populates in English for most artists (the
        // per-language fields are translations layered on top of it).
        let bio = (dict["strBiographyEN"] as? String).trimmedNonEmpty
            ?? (dict["strBiography"] as? String).trimmedNonEmpty

        let formedYear: Int? = {
            if let s = (dict["intFormedYear"] as? String).trimmedNonEmpty, let n = Int(s), n > 0 { return n }
            if let s = (dict["intBornYear"] as? String).trimmedNonEmpty, let n = Int(s), n > 0 { return n }
            return nil
        }()

        return ArtistDetails(
            name: name,
            wideArtworkURL: firstURL(in: dict, keys: wideKeys),
            thumbArtworkURL: firstURL(in: dict, keys: thumbKeys),
            biography: bio,
            country: (dict["strCountry"] as? String).trimmedNonEmpty,
            formedYear: formedYear,
            genre: (dict["strGenre"] as? String).trimmedNonEmpty
        )
    }

    private static func firstURL(in dict: [String: Any], keys: [String]) -> URL? {
        for k in keys {
            if let s = (dict[k] as? String).trimmedNonEmpty, let u = URL(string: s) {
                return u
            }
        }
        return nil
    }
}
