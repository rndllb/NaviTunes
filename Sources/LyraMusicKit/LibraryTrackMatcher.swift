import Foundation

/// Fuzzy title / artist matching between external metadata (Downtify, Last.fm charts, …) and Jellyfin/Navidrome `Track` rows.
enum LibraryTrackMatcher {
    /// Split on punctuation while keeping words with apostrophes / hyphens intact.
    private static let tokenBoundary =
        CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "'’-"))
            .inverted

    /// Lowercase, strip diacritics, drop punctuation except apostrophe/hyphen inside tokens, collapse whitespace.
    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: .diacriticInsensitive, locale: .current)
        let replacedAmpersand = folded.replacingOccurrences(of: "&", with: " and ")
        let tokens = replacedAmpersand
            .components(separatedBy: tokenBoundary)
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
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

    // MARK: - Last.fm chart tracks

    /// True when this Last.fm chart row matches a library track (same rules as Downtify).
    static func matchesLibrary(_ lfm: LFMTrack, titleIndex: [String: Set<String>]) -> Bool {
        let songArtists = normalizedChartArtists(lfm.artistName)
        guard !songArtists.isEmpty else { return false }

        let titleKeys = normalizedTitleKeys(from: lfm.name)
        guard !titleKeys.isEmpty else { return false }

        for tk in titleKeys {
            guard let libArtists = titleIndex[tk] else { continue }
            if artistsOverlap(songArtists, libArtists) { return true }
        }
        return false
    }

    static func firstLibraryTrack(matching lfm: LFMTrack, in tracks: [Track]) -> Track? {
        tracks.first { trackMatchesLFM($0, lfm: lfm) }
    }

    static func trackMatchesLFM(_ track: Track, lfm: LFMTrack) -> Bool {
        let songArtists = normalizedChartArtists(lfm.artistName)
        guard !songArtists.isEmpty else { return false }
        let songKeys = Set(normalizedTitleKeys(from: lfm.name))
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

    private static func artistsOverlap(_ songArtists: Set<String>, _ libArtists: Set<String>) -> Bool {
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
}
