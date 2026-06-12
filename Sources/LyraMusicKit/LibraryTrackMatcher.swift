import Foundation

/// Fuzzy title / artist matching between external metadata (Downtify, chart browse, …) and Jellyfin/Navidrome `Track` rows.
enum LibraryTrackMatcher {
    /// Split on punctuation while keeping words with apostrophes / hyphens intact.
    private static let tokenBoundary =
        CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "'’-"))
            .inverted

    /// Lowercase, strip diacritics, drop apostrophes inside tokens (so "Whats" and
    /// "What's" collapse to the same key — Downtify and the server frequently disagree
    /// on apostrophes), drop other punctuation, collapse whitespace. Hyphens inside
    /// tokens stay so "well-known" remains a single token.
    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: .diacriticInsensitive, locale: .current)
        let replacedAmpersand = folded.replacingOccurrences(of: "&", with: " and ")
        let tokens = replacedAmpersand
            .components(separatedBy: tokenBoundary)
            .map {
                $0.lowercased()
                    .replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: "\u{2019}", with: "")  // U+2019 (’) smart apostrophe
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        return tokens.joined(separator: " ")
    }

    /// Removes ``(feat. …)`` / ``[featuring …]`` clauses before normalization (common catalog mismatch).
    static func stripFeaturedClauses(_ raw: String) -> String {
        var s = raw
        let patterns = [
            #"\([^)]*\b(feat\.?|featuring|ft\.?)\b[^)]*\)"#,
            #"\[[^\]]*\b(feat\.?|featuring|ft\.?)\b[^\]]*\]"#,
        ]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return s
    }

    /// Distinct normalized titles to try when matching a single display title.
    static func normalizedTitleKeys(from rawTitle: String) -> [String] {
        let candidates = [
            normalize(rawTitle),
            normalize(stripFeaturedClauses(rawTitle)),
        ]
        var seen = Set<String>()
        var out: [String] = []
        for c in candidates where !c.isEmpty {
            if seen.insert(c).inserted { out.append(c) }
        }
        return out
    }

    /// Normalized artist tokens from Downtify’s `artists` array.
    static func normalizedDowntifyArtists(_ artists: [String]) -> Set<String> {
        Set(artists.map { normalize($0) }.filter { !$0.isEmpty })
    }

    /// Builds `normalizedTitle -> normalized artist strings` for every library track.
    static func titleIndex(from tracks: [Track]) -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for t in tracks {
            let titKeys = normalizedTitleKeys(from: t.title)
            let art = normalize(t.artist)
            guard !art.isEmpty else { continue }
            for tk in titKeys {
                map[tk, default: []].insert(art)
            }
        }
        return map
    }

    /// True when this Downtify hit corresponds to at least one library track (same normalized title + overlapping artists).
    static func matchesLibrary(_ song: DowntifySong, titleIndex: [String: Set<String>]) -> Bool {
        let songArtists = normalizedDowntifyArtists(song.artists)
        guard !songArtists.isEmpty else { return false }

        let titleKeys = normalizedTitleKeys(from: song.name)
        guard !titleKeys.isEmpty else { return false }

        for tk in titleKeys {
            guard let libArtists = titleIndex[tk] else { continue }
            if artistsOverlap(songArtists, libArtists) { return true }
        }
        return false
    }

    /// Same rules as ``matchesLibrary``, returning the first catalog row (stable order follows `tracks`).
    static func firstLibraryTrack(matching song: DowntifySong, in tracks: [Track]) -> Track? {
        tracks.first { trackMatchesDowntifySong($0, song: song) }
    }

    static func trackMatchesDowntifySong(_ track: Track, song: DowntifySong) -> Bool {
        let songArtists = normalizedDowntifyArtists(song.artists)
        guard !songArtists.isEmpty else { return false }
        let songKeys = Set(normalizedTitleKeys(from: song.name))
        let trackKeys = Set(normalizedTitleKeys(from: track.title))
        guard !songKeys.isDisjoint(with: trackKeys) else { return false }
        let libArtist = normalize(track.artist)
        guard !libArtist.isEmpty else { return false }
        return artistsOverlap(songArtists, Set([libArtist]))
    }

    // MARK: - Acquisition results (backend-agnostic title + artists)

    static func matchesLibrary(title: String, artists: [String], titleIndex: [String: Set<String>]) -> Bool {
        let songArtists = Set(artists.map { normalize($0) }.filter { !$0.isEmpty })
        guard !songArtists.isEmpty else { return false }
        let titleKeys = normalizedTitleKeys(from: title)
        guard !titleKeys.isEmpty else { return false }
        for tk in titleKeys {
            guard let libArtists = titleIndex[tk] else { continue }
            if artistsOverlap(songArtists, libArtists) { return true }
        }
        return false
    }

    static func matchesLibrary(_ result: AcquisitionResult, titleIndex: [String: Set<String>]) -> Bool {
        matchesLibrary(title: result.title, artists: result.artists, titleIndex: titleIndex)
    }

    static func firstLibraryTrack(matching result: AcquisitionResult, in tracks: [Track]) -> Track? {
        let songArtists = Set(result.artists.map { normalize($0) }.filter { !$0.isEmpty })
        guard !songArtists.isEmpty else { return nil }
        let songKeys = Set(normalizedTitleKeys(from: result.title))
        return tracks.first { track in
            let trackKeys = Set(normalizedTitleKeys(from: track.title))
            guard !songKeys.isDisjoint(with: trackKeys) else { return false }
            let libArtist = normalize(track.artist)
            guard !libArtist.isEmpty else { return false }
            return artistsOverlap(songArtists, Set([libArtist]))
        }
    }

    // MARK: - External chart tracks

    /// True when this chart row matches a library track (same rules as Downtify).
    static func matchesLibrary(_ chart: ChartTrack, titleIndex: [String: Set<String>]) -> Bool {
        let songArtists = normalizedChartArtists(chart.artistName)
        guard !songArtists.isEmpty else { return false }

        let titleKeys = normalizedTitleKeys(from: chart.name)
        guard !titleKeys.isEmpty else { return false }

        for tk in titleKeys {
            guard let libArtists = titleIndex[tk] else { continue }
            if artistsOverlap(songArtists, libArtists) { return true }
        }
        return false
    }

    static func firstLibraryTrack(matching chart: ChartTrack, in tracks: [Track]) -> Track? {
        tracks.first { trackMatchesChart($0, chart: chart) }
    }

    static func trackMatchesChart(_ track: Track, chart: ChartTrack) -> Bool {
        let songArtists = normalizedChartArtists(chart.artistName)
        guard !songArtists.isEmpty else { return false }
        let songKeys = Set(normalizedTitleKeys(from: chart.name))
        let trackKeys = Set(normalizedTitleKeys(from: track.title))
        guard !songKeys.isDisjoint(with: trackKeys) else { return false }
        let libArtist = normalize(track.artist)
        guard !libArtist.isEmpty else { return false }
        return artistsOverlap(songArtists, Set([libArtist]))
    }

    /// Split chart artist lines like ``A & B`` or ``A + B`` so either name can match the library’s primary artist.
    private static func normalizedChartArtists(_ artistLine: String) -> Set<String> {
        let trimmed = artistLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var splitSource = trimmed
        splitSource = splitSource.replacingOccurrences(of: " & ", with: ",")
        splitSource = splitSource.replacingOccurrences(of: " + ", with: ",")
        splitSource = splitSource.replacingOccurrences(of: "/", with: ",")
        let pieces = splitSource
            .split(separator: ",")
            .map { normalize(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
        if pieces.isEmpty { return Set([normalize(trimmed)]) }
        return Set(pieces)
    }

    static func artistsOverlap(_ songArtists: Set<String>, _ libArtists: Set<String>) -> Bool {
        for sa in songArtists {
            if libArtists.contains(sa) { return true }
            for la in libArtists {
                if sa == la { return true }
                if sa.count >= 4 && la.count >= 4 {
                    if sa.contains(la) || la.contains(sa) { return true }
                }
            }
        }
        return false
    }

    /// Split a chart artist string into normalized tokens (`"A & B"` → `{"a", "b"}`).
    /// Mirrors the private helper used internally, exposed so callers can reuse the
    /// same set across many lookups.
    static func normalizedChartArtistTokens(_ artistLine: String) -> Set<String> {
        normalizedChartArtists(artistLine)
    }
}

/// O(1) lookup of chart rows → library `Track`. Built once when
/// ``AppModel.discoveryLibraryTracks`` is reassigned; replaces per-cell scans
/// over up to 50k tracks (each comparison ran multiple regex substitutions),
/// which made the New tab unresponsive on large libraries.
struct LibraryChartTrackIndex {
    private struct Entry {
        let track: Track
        let artistKey: String
    }
    /// Normalized title key → entries. A track is inserted under every key its
    /// title produces (strict + featured-stripped) so chart variants line up.
    private let byTitleKey: [String: [Entry]]

    static let empty = LibraryChartTrackIndex(tracks: [])

    init(tracks: [Track]) {
        var map: [String: [Entry]] = [:]
        for track in tracks {
            let artistKey = LibraryTrackMatcher.normalize(track.artist)
            guard !artistKey.isEmpty else { continue }
            let entry = Entry(track: track, artistKey: artistKey)
            for titleKey in LibraryTrackMatcher.normalizedTitleKeys(from: track.title) {
                map[titleKey, default: []].append(entry)
            }
        }
        self.byTitleKey = map
    }

    /// Mirrors ``LibraryTrackMatcher.trackMatchesChart``: title-key overlap +
    /// `artistsOverlap` over the chart's tokenized artist string.
    func firstMatch(chart: ChartTrack) -> Track? {
        let chartArtists = LibraryTrackMatcher.normalizedChartArtistTokens(chart.artistName)
        guard !chartArtists.isEmpty else { return nil }
        let titleKeys = LibraryTrackMatcher.normalizedTitleKeys(from: chart.name)
        guard !titleKeys.isEmpty else { return nil }
        return firstMatch(titleKeys: titleKeys, artistTokens: chartArtists)
    }

    /// Same rules as ``LibraryTrackMatcher.firstLibraryTrack(matching:in:)`` for Downtify / browse preview rows.
    func firstMatch(song: DowntifySong) -> Track? {
        let songArtists = LibraryTrackMatcher.normalizedDowntifyArtists(song.artists)
        guard !songArtists.isEmpty else { return nil }
        let titleKeys = LibraryTrackMatcher.normalizedTitleKeys(from: song.name)
        guard !titleKeys.isEmpty else { return nil }
        return firstMatch(titleKeys: titleKeys, artistTokens: songArtists)
    }

    private func firstMatch(titleKeys: [String], artistTokens: Set<String>) -> Track? {
        var seenTrackIds = Set<String>()
        for titleKey in titleKeys {
            guard let entries = byTitleKey[titleKey] else { continue }
            for entry in entries where seenTrackIds.insert(entry.track.id).inserted {
                if LibraryTrackMatcher.artistsOverlap(artistTokens, Set([entry.artistKey])) {
                    return entry.track
                }
            }
        }
        return nil
    }
}
