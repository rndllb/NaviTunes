import Foundation

// MARK: - Models

/// One station from the Radio Browser directory (radio-browser.info) — a free,
/// community-maintained dataset of ~57k live streams, independent of the connected
/// Navidrome / Jellyfin server.
///
/// Identity is `stationuuid`. The API also returns numeric `id` fields; those are
/// **not** stable across mirrors and must never be persisted or compared.
struct RadioDirectoryStation: Identifiable, Hashable, Sendable {
    let stationUUID: String
    let name: String
    /// The directory's pre-resolved stream (`url_resolved`) when present, else `url`.
    /// Resolved URLs point at the audio directly, so the player never has to parse
    /// a `.pls` / `.m3u` wrapper.
    let streamURL: URL
    let homepageURL: URL?
    /// Station logo. Often missing, and often a dead link even when present.
    let faviconURL: URL?
    let tags: [String]
    let countryCode: String
    let languages: [String]
    let codec: String
    let bitrate: Int
    /// All-time community votes.
    let votes: Int
    /// Plays registered across every app using the directory — this is "what's popular".
    let clickCount: Int

    var id: String { stationUUID }

    /// "Jazz · 320 kbps" line for list rows.
    var detailLine: String {
        var parts: [String] = []
        let genre = RadioDirectoryCatalog.genreLabel(forTags: tags)
        if !genre.isEmpty {
            parts.append(genre)
        }
        if bitrate > 0 {
            parts.append("\(bitrate) kbps")
        } else if !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    func asInternetRadioStation() -> InternetRadioStation {
        InternetRadioStation(
            id: stationUUID,
            name: name,
            streamURL: streamURL,
            homepageURL: homepageURL,
            artworkURL: faviconURL,
            isUserAdded: false,
            directoryStationUUID: stationUUID,
            detailLine: detailLine,
        )
    }

    /// Persisted form for "Your Stations". Artwork stays a remote favicon URL rather
    /// than a downloaded file, so saving is instant and costs no disk.
    func asCustomRadioStation() -> CustomRadioStation {
        CustomRadioStation(
            name: name,
            streamURL: streamURL,
            homepageURL: homepageURL,
            remoteArtworkURL: faviconURL,
            directoryStationUUID: stationUUID,
            detailLine: detailLine,
        )
    }
}

/// A genre tag with how many stations carry it.
struct RadioDirectoryTag: Identifiable, Hashable, Sendable {
    let name: String
    let stationCount: Int

    var id: String { name }
}

/// A country with how many stations it has, plus a localized display name resolved
/// once at decode time (`Locale.localizedString(forRegionCode:)` is too costly to
/// call from a view body for a 241-row list).
struct RadioDirectoryCountry: Identifiable, Hashable, Sendable {
    let code: String
    let displayName: String
    let stationCount: Int

    var id: String { code }
}

/// Search / browse parameters for `/json/stations/search`.
struct RadioDirectoryQuery: Hashable, Sendable {
    enum Order: String, Sendable {
        /// Directory-wide play count. The closest thing to a popularity chart.
        case clickCount = "clickcount"
        case votes
        case name
    }

    var name: String?
    var tag: String?
    var countryCode: String?
    var order: Order = .clickCount
    var reverse = true
    var limit = 60
    var offset = 0

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "order", value: order.rawValue),
            URLQueryItem(name: "reverse", value: reverse ? "true" : "false"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            // 5.5k of the directory's stations are known-dead; never show them.
            URLQueryItem(name: "hidebroken", value: "true"),
        ]
        if let name, !name.isEmpty {
            items.append(URLQueryItem(name: "name", value: name))
        }
        if let tag, !tag.isEmpty {
            items.append(URLQueryItem(name: "tag", value: tag))
        }
        if let countryCode, !countryCode.isEmpty {
            items.append(URLQueryItem(name: "countrycode", value: countryCode))
        }
        return items
    }
}

struct RadioDirectoryError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

// MARK: - Client

/// Read-only client for the Radio Browser directory.
///
/// Mirror handling follows the API's own guidance: **never hardcode a single server**,
/// because mirror names come and go. The list is fetched from `/json/servers` on the
/// round-robin host, cached for a day, shuffled, and requests rotate to the next
/// mirror on failure. `all.api.radio-browser.info` serves queries itself, so it is
/// also the fallback when the mirror list can't be read.
actor RadioBrowserClient {
    static let shared = RadioBrowserClient()

    /// Round-robin DNS name in front of every mirror.
    private static let bootstrapHost = "all.api.radio-browser.info"
    private static let mirrorRefreshInterval: TimeInterval = 86_400
    private static let listCacheTTL: TimeInterval = 600
    private static let cacheEntryLimit = 48

    private let session: URLSession
    private let userAgent: String

    private var mirrors: [String] = []
    private var mirrorsFetchedAt: Date?
    private var cache: [String: (storedAt: Date, data: Data)] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        // The API asks for a "speaking" agent string so operators can see who is
        // hitting them. Anonymous clients are the ones that get blocked.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        userAgent = "VellumMusic/\(version ?? "1.0")"
    }

    // MARK: Directory reads

    func stations(_ query: RadioDirectoryQuery) async throws -> [RadioDirectoryStation] {
        let data = try await get(
            path: "/json/stations/search",
            queryItems: query.queryItems,
            cacheTTL: Self.listCacheTTL,
        )
        return decodeStations(data)
    }

    /// Merges several tag spellings into one result set. The directory's tag
    /// vocabulary is user-supplied, so a single genre is split across variants
    /// ("hip hop" and "hiphop" are different tags with different stations).
    func stations(
        tags: [String],
        countryCode: String?,
        order: RadioDirectoryQuery.Order = .clickCount,
        limit: Int = 60,
    ) async throws -> [RadioDirectoryStation] {
        guard !tags.isEmpty else {
            var query = RadioDirectoryQuery()
            query.countryCode = countryCode
            query.order = order
            query.limit = limit
            return try await stations(query)
        }

        // Concurrently: "Electronic" spans five tags, and running those sequentially
        // made a genre page cost five round trips end to end. One dead tag must not
        // empty the whole genre, so failures are per-tag and only a clean sweep throws.
        let pages = try await withThrowingTaskGroup(
            of: (Int, Result<[RadioDirectoryStation], Error>).self,
        ) { group in
            for (index, tag) in tags.enumerated() {
                var query = RadioDirectoryQuery()
                query.tag = tag
                query.countryCode = countryCode
                query.order = order
                query.limit = limit
                group.addTask { [query] in
                    do {
                        return (index, .success(try await self.stations(query)))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var out: [Int: Result<[RadioDirectoryStation], Error>] = [:]
            for try await (index, page) in group {
                out[index] = page
            }
            return out
        }

        // Merge in declared tag order so results are stable across loads.
        var merged: [RadioDirectoryStation] = []
        var seen = Set<String>()
        var firstError: Error?
        for index in tags.indices {
            switch pages[index] {
            case .success(let page):
                for station in page where seen.insert(station.stationUUID).inserted {
                    merged.append(station)
                }
            case .failure(let error):
                if firstError == nil { firstError = error }
            case nil:
                continue
            }
        }

        if merged.isEmpty, let firstError { throw firstError }
        merged.sort { $0.clickCount > $1.clickCount }
        return Array(merged.prefix(limit))
    }

    /// Genre tags ordered by how many stations use them.
    func topTags(limit: Int = 200) async throws -> [RadioDirectoryTag] {
        let data = try await get(
            path: "/json/tags",
            queryItems: [
                URLQueryItem(name: "order", value: "stationcount"),
                URLQueryItem(name: "reverse", value: "true"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "hidebroken", value: "true"),
            ],
            cacheTTL: Self.mirrorRefreshInterval,
        )
        guard let rows = try? JSONDecoder().decode([TagDTO].self, from: data) else { return [] }
        return rows.compactMap { row in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, row.stationcount > 0 else { return nil }
            return RadioDirectoryTag(name: name, stationCount: row.stationcount)
        }
    }

    func countries() async throws -> [RadioDirectoryCountry] {
        let data = try await get(
            path: "/json/countrycodes",
            queryItems: [URLQueryItem(name: "hidebroken", value: "true")],
            cacheTTL: Self.mirrorRefreshInterval,
        )
        guard let rows = try? JSONDecoder().decode([CountryDTO].self, from: data) else { return [] }
        let locale = Locale.current
        return rows
            .compactMap { row -> RadioDirectoryCountry? in
                let code = row.name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard code.count == 2, row.stationcount > 0 else { return nil }
                return RadioDirectoryCountry(
                    code: code,
                    displayName: locale.localizedString(forRegionCode: code) ?? code,
                    stationCount: row.stationcount,
                )
            }
            .sorted { $0.stationCount > $1.stationCount }
    }

    /// Registers a play so the station's `clickcount` reflects it. The directory's
    /// popularity data only works because clients report back; this is the one write
    /// the API asks for, and it is deliberately fire-and-forget.
    func registerPlay(stationUUID: String) async {
        guard !stationUUID.isEmpty else { return }
        _ = try? await get(path: "/json/url/\(stationUUID)", queryItems: [], cacheTTL: nil)
    }

    // MARK: Transport

    private func get(path: String, queryItems: [URLQueryItem], cacheTTL: TimeInterval?) async throws -> Data {
        let key = cacheKey(path: path, queryItems: queryItems)
        if let cacheTTL, let hit = cache[key], Date().timeIntervalSince(hit.storedAt) < cacheTTL {
            return hit.data
        }

        let hosts = await resolvedHosts()
        var lastError: Error = RadioDirectoryError(message: "The radio directory is unavailable.")

        for host in hosts {
            if Task.isCancelled { throw CancellationError() }
            do {
                let data = try await fetch(host: host, path: path, queryItems: queryItems)
                if cacheTTL != nil { store(data, forKey: key) }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func fetch(host: String, path: String, queryItems: [URLQueryItem]) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw RadioDirectoryError(message: "Couldn't build the directory request.")
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RadioDirectoryError(message: "The radio directory returned \(http.statusCode).")
        }
        return data
    }

    private func cacheKey(path: String, queryItems: [URLQueryItem]) -> String {
        let query = queryItems
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
            .joined(separator: "&")
        return "\(path)?\(query)"
    }

    private func store(_ data: Data, forKey key: String) {
        if cache.count >= Self.cacheEntryLimit,
           let oldest = cache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[key] = (Date(), data)
    }

    // MARK: Mirrors

    /// Shuffled mirror list, with the round-robin host appended as a last resort.
    private func resolvedHosts() async -> [String] {
        await refreshMirrorsIfNeeded()
        var hosts = mirrors.shuffled()
        if !hosts.contains(Self.bootstrapHost) {
            hosts.append(Self.bootstrapHost)
        }
        return hosts
    }

    private func refreshMirrorsIfNeeded() async {
        if let mirrorsFetchedAt,
           Date().timeIntervalSince(mirrorsFetchedAt) < Self.mirrorRefreshInterval,
           !mirrors.isEmpty {
            return
        }

        // Deliberately not a DNS lookup: `/json/servers` on the round-robin host
        // returns the same mirror names without reverse-DNS plumbing, and the
        // bootstrap host stays usable if this fails.
        mirrorsFetchedAt = Date()
        guard let data = try? await fetch(host: Self.bootstrapHost, path: "/json/servers", queryItems: []),
              let rows = try? JSONDecoder().decode([ServerDTO].self, from: data)
        else { return }

        var names: [String] = []
        var seen = Set<String>()
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        if !names.isEmpty { mirrors = names }
    }

    // MARK: Decoding

    private func decodeStations(_ data: Data) -> [RadioDirectoryStation] {
        guard let rows = try? JSONDecoder().decode([StationDTO].self, from: data) else { return [] }
        var out: [RadioDirectoryStation] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard let station = row.asStation() else { continue }
            out.append(station)
        }
        return out
    }
}

// MARK: - Wire format

/// The API mixes types across versions (numbers that used to be strings), so every
/// numeric field is optional and defaulted rather than trusted.
private struct StationDTO: Decodable {
    let stationuuid: String
    let name: String
    let url: String?
    let urlResolved: String?
    let homepage: String?
    let favicon: String?
    let tags: String?
    let countrycode: String?
    let language: String?
    let codec: String?
    let bitrate: Int?
    let votes: Int?
    let clickcount: Int?

    enum CodingKeys: String, CodingKey {
        case stationuuid
        case name
        case url
        case urlResolved = "url_resolved"
        case homepage
        case favicon
        case tags
        case countrycode
        case language
        case codec
        case bitrate
        case votes
        case clickcount
    }

    func asStation() -> RadioDirectoryStation? {
        let uuid = stationuuid.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uuid.isEmpty, !title.isEmpty else { return nil }

        let candidates = [urlResolved, url]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let stream = candidates.compactMap({ URL(string: $0) }).first,
              stream.scheme?.hasPrefix("http") == true
        else { return nil }

        return RadioDirectoryStation(
            stationUUID: uuid,
            name: title,
            streamURL: stream,
            homepageURL: Self.optionalURL(homepage),
            faviconURL: Self.optionalURL(favicon),
            tags: Self.splitList(tags),
            countryCode: (countrycode ?? "").uppercased(),
            languages: Self.splitList(language),
            codec: codec ?? "",
            bitrate: max(0, bitrate ?? 0),
            votes: max(0, votes ?? 0),
            clickCount: max(0, clickcount ?? 0),
        )
    }

    private static func optionalURL(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true
        else { return nil }
        return url
    }

    private static func splitList(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for part in raw.split(separator: ",") {
            let value = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            out.append(value)
        }
        return out
    }
}

private struct TagDTO: Decodable {
    let name: String
    let stationcount: Int
}

private struct CountryDTO: Decodable {
    /// The API returns the ISO code in `name` for `/json/countrycodes`.
    let name: String
    let stationcount: Int
}

private struct ServerDTO: Decodable {
    let name: String
}
