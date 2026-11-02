import Foundation

// MARK: - Shared sub-objects

/// A MusicBrainz place reference (`area`, `begin-area`, `end-area`).
struct MusicBrainzArea: Codable, Hashable, Sendable {
    let id: String?
    let name: String?
}

/// `life-span` — when an artist started and (optionally) stopped. Dates are partial:
/// `yyyy`, `yyyy-MM`, or `yyyy-MM-dd`.
struct MusicBrainzLifeSpan: Codable, Hashable, Sendable {
    let begin: String?
    let end: String?
    let ended: Bool?
}

/// A folksonomy tag with its vote count. The tag vocabulary is user-supplied, so counts
/// matter more than order — the wire order is insertion order, not popularity.
struct MusicBrainzTag: Codable, Hashable, Sendable {
    let name: String
    let count: Int?
}

/// One entry in an `artist-credit` array — the credited artist plus the text that joins it to
/// the next one ("Jay-Z" + " & " + "Linkin Park").
///
/// Release-group and recording search rows carry this instead of a plain artist string, and it is
/// the only place the artist's MBID appears on those rows. That matters: it is what lets a song
/// or album hit navigate to a fully-identified artist page without spending a search request
/// rediscovering who the artist is.
struct MusicBrainzArtistCredit: Codable, Hashable, Sendable {
    /// The credited name, which can differ from the artist's own name (a one-off spelling).
    let name: String?
    let joinphrase: String?
    let artist: MusicBrainzCreditedArtist?
}

/// The artist reference inside an `artist-credit` entry. Deliberately not ``MusicBrainzArtist`` —
/// search rows nest only id / name / sort-name here, and decoding into the full type would
/// produce a header-shaped value with every interesting field empty.
struct MusicBrainzCreditedArtist: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let sortName: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case sortName = "sort-name"
    }
}

extension Array where Element == MusicBrainzArtistCredit {
    /// The credit line as MusicBrainz intends it to read, honouring each entry's join phrase.
    ///
    /// Falls back to ", " between entries when a join phrase is absent, which happens on
    /// hand-entered credits. Never returns an empty string for a non-empty array — a row with no
    /// readable artist is worse than a slightly wrong separator.
    var creditLine: String {
        var out = ""
        for credit in self {
            let name = credit.name ?? credit.artist?.name ?? ""
            guard !name.isEmpty else { continue }
            if !out.isEmpty, out.last?.isWhitespace == false, credit.joinphrase == nil {
                out += ", "
            }
            out += name
            if let join = credit.joinphrase, !join.isEmpty { out += join }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The primary credited artist's MBID, when one is present.
    var primaryArtistMBID: String? { first?.artist?.id }

    /// The primary credited artist's own name (not the credited spelling).
    var primaryArtistName: String? { first?.artist?.name ?? first?.name }
}

/// Community rating. Only present on a lookup that asked for `inc=ratings`; the search
/// payload never carries it.
struct MusicBrainzRating: Codable, Hashable, Sendable {
    let value: Double?
    let votesCount: Int?

    enum CodingKeys: String, CodingKey {
        case value
        case votesCount = "votes-count"
    }
}

// MARK: - Artist

/// One artist as MusicBrainz describes it.
///
/// The same shape decodes both the search payload (`/ws/2/artist?query=`) and the lookup
/// payload (`/ws/2/artist/{mbid}?inc=tags+ratings`). That is deliberate: search already
/// returns name, country, area, life-span and tags, so a header rendered from a search hit
/// needs no follow-up request. Only `rating` is lookup-only, and only a cold open — an
/// artist page reached without a search hit in hand — has to pay for the second call.
struct MusicBrainzArtist: Codable, Hashable, Sendable, Identifiable {
    /// The MusicBrainz artist id (MBID). Stable across the whole MusicBrainz graph and the
    /// only identity worth persisting — names are not unique.
    let id: String
    let name: String
    let sortName: String?
    /// Short parenthetical MusicBrainz uses to separate same-named artists ("US emo band").
    let disambiguation: String?
    /// "Person", "Group", "Orchestra", …
    let type: String?
    /// ISO country code.
    let country: String?
    let area: MusicBrainzArea?
    let beginArea: MusicBrainzArea?
    let lifeSpan: MusicBrainzLifeSpan?
    let tags: [MusicBrainzTag]?
    let rating: MusicBrainzRating?
    /// Search relevance, 0–100. Present on search rows only.
    let score: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, disambiguation, type, country, area, tags, rating, score
        case sortName = "sort-name"
        case beginArea = "begin-area"
        case lifeSpan = "life-span"
    }

    // MARK: Presentation

    /// "From" line — origin city plus country when both are known and differ.
    var originLine: String? {
        let city = beginArea?.name?.mbTrimmedNonEmpty
        let region = area?.name?.mbTrimmedNonEmpty
        switch (city, region) {
        case let (c?, r?) where c != r: return "\(c), \(r)"
        case let (c?, _): return c
        case let (_, r?): return r
        default: return country?.mbTrimmedNonEmpty
        }
    }

    /// Label for the start date — a group is "Formed", a person is "Born".
    var lifeSpanBeginLabel: String {
        (type ?? "").caseInsensitiveCompare("Person") == .orderedSame ? "Born" : "Formed"
    }

    /// Formatted start date at the precision MusicBrainz actually stored.
    var lifeSpanBeginDisplay: String? {
        lifeSpan?.begin?.mbTrimmedNonEmpty.map(MusicBrainzPartialDate.display)
    }

    /// Formatted end date, only when the artist is actually marked as ended.
    var lifeSpanEndDisplay: String? {
        guard lifeSpan?.ended == true else { return nil }
        return lifeSpan?.end?.mbTrimmedNonEmpty.map(MusicBrainzPartialDate.display)
    }

    /// Tags ordered by vote count, highest first, title-cased for display.
    func topTags(limit: Int = 5) -> [String] {
        (tags ?? [])
            .compactMap { tag -> (String, Int)? in
                guard let name = tag.name.mbTrimmedNonEmpty else { return nil }
                return (name, tag.count ?? 0)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0.capitalized }
    }

    var primaryGenre: String? { topTags(limit: 1).first }

    /// The line that tells one same-named artist from another in a search result.
    ///
    /// Necessary rather than decorative: a search for a common word returns many artists with
    /// *identical* names — MusicBrainz holds 17 called exactly "Rocket" in one page — and a list
    /// of identical rows is unusable however well ranked it is. The user has to be able to see
    /// which one is the Russian rapper and which is the LA indie band before tapping.
    ///
    /// MusicBrainz's own `disambiguation` is written for exactly this purpose, so it wins when
    /// present. It frequently is not, so the fallback assembles whatever identifying facts the
    /// search row already carries — kind, country, active years — none of which cost a request.
    var searchRowDescriptor: String? {
        if let disambiguation = disambiguation?.mbTrimmedNonEmpty { return disambiguation }

        var parts: [String] = []
        if let type = type?.mbTrimmedNonEmpty, type.caseInsensitiveCompare("Other") != .orderedSame {
            parts.append(type)
        }
        if let origin = originLine { parts.append(origin) }
        if let began = lifeSpan?.begin?.mbTrimmedNonEmpty?.split(separator: "-").first.map(String.init) {
            // Years only. A full date is noise at this size, and the end year matters as much as
            // the start for telling two same-named acts apart.
            if let ended = lifeSpanEndDisplay?.split(separator: " ").last.map(String.init),
               lifeSpan?.ended == true {
                parts.append("\(began)–\(ended)")
            } else {
                parts.append("\(began)–")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The subset of fields a search row is guaranteed to fill. Used to decide whether a
    /// header can render without the lookup.
    var hasRenderableHeaderFacts: Bool {
        originLine != nil || lifeSpanBeginDisplay != nil || !(tags ?? []).isEmpty
    }
}

/// `/ws/2/artist?query=` envelope.
struct MusicBrainzArtistSearchResponse: Codable, Sendable {
    let count: Int?
    let offset: Int?
    let artists: [MusicBrainzArtist]?
}

// MARK: - Release group

/// One release group — MusicBrainz's "work" level, above individual releases/pressings.
/// This is what a discography is made of: an album and its remasters are one group.
struct MusicBrainzReleaseGroup: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let firstReleaseDate: String?
    /// "Album", "Single", "EP", "Broadcast", "Other".
    let primaryType: String?
    /// "Live", "Compilation", "Soundtrack", "Remix", "Demo", …
    let secondaryTypes: [String]?
    let disambiguation: String?
    /// Search relevance, 0–100. Present on search rows only — a browsed discography has no
    /// query to be relevant to.
    let score: Int?
    /// Credited artist(s). Present on search rows; absent from a browse by artist, where the
    /// artist is already the thing being browsed.
    let artistCredit: [MusicBrainzArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id, title, disambiguation, score
        case firstReleaseDate = "first-release-date"
        case primaryType = "primary-type"
        case secondaryTypes = "secondary-types"
        case artistCredit = "artist-credit"
    }

    var releaseYear: Int? {
        guard let raw = firstReleaseDate?.mbTrimmedNonEmpty,
              let year = raw.split(separator: "-").first.flatMap({ Int($0) })
        else { return nil }
        return year
    }

    var releaseDate: Date? {
        firstReleaseDate?.mbTrimmedNonEmpty.flatMap(MusicBrainzPartialDate.date)
    }

    private var normalizedPrimaryType: String { (primaryType ?? "").lowercased() }
    private var normalizedSecondaryTypes: [String] { (secondaryTypes ?? []).map { $0.lowercased() } }

    var isSingle: Bool { normalizedPrimaryType == "single" }
    var isEP: Bool { normalizedPrimaryType == "ep" }
    var isAlbum: Bool { normalizedPrimaryType == "album" }
    var isLive: Bool { normalizedSecondaryTypes.contains("live") }
    var isCompilation: Bool { normalizedSecondaryTypes.contains("compilation") }
}

/// `/ws/2/release-group?artist=` browse envelope.
///
/// The browse endpoint is the only one that reports a total and honours `limit`/`offset`.
/// The lookup form `/artist/{mbid}?inc=release-groups` silently caps at 25, ignores `limit`
/// and reports no total, which drops releases without any signal that it did so.
struct MusicBrainzReleaseGroupBrowseResponse: Codable, Sendable {
    let releaseGroupCount: Int?
    let releaseGroupOffset: Int?
    let releaseGroups: [MusicBrainzReleaseGroup]?

    enum CodingKeys: String, CodingKey {
        case releaseGroupCount = "release-group-count"
        case releaseGroupOffset = "release-group-offset"
        case releaseGroups = "release-groups"
    }
}

/// `/ws/2/release-group?query=` envelope. Carries `count` so a paginated feed knows the total
/// without probing for an empty page.
struct MusicBrainzReleaseGroupSearchResponse: Codable, Sendable {
    let count: Int?
    let offset: Int?
    let releaseGroups: [MusicBrainzReleaseGroup]?

    enum CodingKeys: String, CodingKey {
        case count, offset
        case releaseGroups = "release-groups"
    }
}

// MARK: - Recording

/// One recording — MusicBrainz's song level. A *recording* is a specific performance, so the
/// album cut, the single cut, the live version and each remaster of one song are separate
/// recordings with separate MBIDs.
///
/// That multiplicity is the defining property of this endpoint and it is severe: searching
/// `Paranoid Android` returns eleven identical "Paranoid Android — Radiohead" rows in the first
/// twelve results, each a distinct MBID. Deduplication is therefore not a tidiness pass but the
/// thing that makes the endpoint usable, and it cannot be done on MBID — a single search response
/// has unique MBIDs by construction. It has to collapse on normalized title + artist, which is
/// what ``MusicBrainzSearchFeed`` does.
struct MusicBrainzRecording: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    /// Track length in milliseconds. Frequently absent.
    let length: Int?
    let disambiguation: String?
    let firstReleaseDate: String?
    let artistCredit: [MusicBrainzArtistCredit]?
    /// The releases this recording appears on. Only the first is used — to name a parent album
    /// and, for an album-granularity request plugin, to identify the release group to ask for.
    let releases: [MusicBrainzRecordingRelease]?
    /// Search relevance, 0–100.
    let score: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, length, disambiguation, releases, score
        case firstReleaseDate = "first-release-date"
        case artistCredit = "artist-credit"
    }

    /// The release this song is best represented by: the earliest-dated one, falling back to the
    /// first the server listed. Earliest rather than first because the wire order is relevance,
    /// not chronology, and a song's original album is a better label than whichever compilation
    /// happened to rank highest.
    var primaryRelease: MusicBrainzRecordingRelease? {
        guard let releases, !releases.isEmpty else { return nil }
        let dated = releases.compactMap { release -> (MusicBrainzRecordingRelease, Date)? in
            guard let date = release.date?.mbTrimmedNonEmpty.flatMap(MusicBrainzPartialDate.date) else {
                return nil
            }
            return (release, date)
        }
        return dated.min { $0.1 < $1.1 }?.0 ?? releases.first
    }

    /// Parent album title, for the row's subtitle.
    var albumTitle: String? {
        primaryRelease?.releaseGroup?.title?.mbTrimmedNonEmpty
            ?? primaryRelease?.title?.mbTrimmedNonEmpty
    }

    /// Release group MBID of the parent album. This is the id an album-granularity request
    /// plugin needs — it cannot request one song, so a song row has to resolve to its release.
    var releaseGroupMBID: String? { primaryRelease?.releaseGroup?.id }

    var durationSeconds: Double? {
        guard let length, length > 0 else { return nil }
        return Double(length) / 1000
    }

    var releaseYear: Int? {
        guard let raw = firstReleaseDate?.mbTrimmedNonEmpty,
              let year = raw.split(separator: "-").first.flatMap({ Int($0) })
        else { return nil }
        return year
    }
}

/// A release as nested inside a recording search row.
struct MusicBrainzRecordingRelease: Codable, Hashable, Sendable {
    let id: String?
    let title: String?
    let date: String?
    let releaseGroup: MusicBrainzRecordingReleaseGroup?

    enum CodingKeys: String, CodingKey {
        case id, title, date
        case releaseGroup = "release-group"
    }
}

/// The release-group stub nested two levels deep in a recording search row.
struct MusicBrainzRecordingReleaseGroup: Codable, Hashable, Sendable {
    let id: String?
    let title: String?
    let primaryType: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case primaryType = "primary-type"
    }
}

/// `/ws/2/recording?query=` envelope.
struct MusicBrainzRecordingSearchResponse: Codable, Sendable {
    let count: Int?
    let offset: Int?
    let recordings: [MusicBrainzRecording]?
}

// MARK: - Partial dates

/// MusicBrainz dates come at whatever precision the editor knew: `yyyy`, `yyyy-MM`, or
/// `yyyy-MM-dd`. Render at that precision rather than inventing a January 1st.
enum MusicBrainzPartialDate {
    static func components(_ raw: String) -> DateComponents? {
        let parts = raw.split(separator: "-").map(String.init)
        guard let year = parts.first.flatMap({ Int($0) }) else { return nil }
        var comps = DateComponents()
        comps.year = year
        if parts.count >= 2 { comps.month = Int(parts[1]) }
        if parts.count >= 3 { comps.day = Int(parts[2]) }
        return comps
    }

    static func date(_ raw: String) -> Date? {
        guard let comps = components(raw) else { return nil }
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    static func display(_ raw: String) -> String {
        let parts = raw.split(separator: "-").map(String.init)
        guard let comps = components(raw),
              let date = Calendar(identifier: .gregorian).date(from: comps)
        else { return raw }
        if parts.count == 1 { return String(comps.year ?? 0) }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        if parts.count >= 3 {
            fmt.dateStyle = .long
        } else {
            fmt.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        }
        return fmt.string(from: date)
    }
}

extension String {
    /// Trimmed string, or `nil` when blank after trimming.
    var mbTrimmedNonEmpty: String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
