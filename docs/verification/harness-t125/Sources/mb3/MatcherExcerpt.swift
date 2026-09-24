import Foundation

// Extracted verbatim from AlbumSummary+NewTabMatch.swift (lines 31-90) so this measures
// the shipping matcher. Only the memoised catalogReleaseIdentityKey is omitted.
enum AlbumSummaryMatch {
    /// Normalize titles for comparing chart metadata to Jellyfin / Navidrome catalog rows.
    static func normalizedReleaseKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let folded = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let spaced = folded.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return spaced
    }

    /// Album title key ignoring trailing `(Deluxe)`, `[Bonus Tracks]`, etc., so charts match catalog variants.
    static func normalizedAlbumTitleLoose(_ raw: String) -> String {
        var base = normalizedReleaseKey(raw)
        while true {
            guard let r = base.range(of: #"(\s*\([^)]+\)|\s*\[[^\]]+\])$"#, options: .regularExpression) else { break }
            base.removeSubrange(r)
            base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return base
    }

    /// Base title for matching alternate editions (single, EP, deluxe, reinvented, etc.).
    static func albumVersionBaseKey(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }

        let suffixPattern = #"(?i)\s*[-–—]\s*(single|ep|album|deluxe edition|deluxe|expanded edition|remaster(ed)?(\s+\d{4})?)$"#
        while let range = t.range(of: suffixPattern, options: .regularExpression) {
            t = String(t[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        t = t.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalizedReleaseKey(t)
    }

    /// Title keys for matching plugin rows to server albums (exact normalize plus
    /// ``albumVersionBaseKey`` so "Album - EP" matches a server album without the suffix).
    static func discographyTitleKeys(for title: String) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        func append(_ key: String) {
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            keys.append(key)
        }
        append(LibraryTrackMatcher.normalize(title))
        append(albumVersionBaseKey(title))
        return keys
    }
}
