import Foundation

// Types the shipping acquisition sources reference but that live in UI-bearing files. Lifted
// verbatim so `AcquisitionCore.swift` and `LidarrAcquisitionPlugin.swift` can be symlinked in
// and measured as they ship, rather than reimplemented here.

/// Verbatim from `ArtistViewModel.swift` (the `ArtistDiscographyBucket` declaration).
/// `AcquisitionRelease.bucket` returns this, and the bucket split is one of the numbers measured.
enum ArtistDiscographyBucket: Hashable, CaseIterable {
    case albums
    case singlesAndEPs
    case live
    case compilations

    func requestPlanLabel(count: Int) -> String {
        switch self {
        case .albums: return count == 1 ? "1 album" : "\(count) albums"
        case .singlesAndEPs: return count == 1 ? "1 single or EP" : "\(count) singles & EPs"
        case .live: return count == 1 ? "1 live album" : "\(count) live albums"
        case .compilations: return count == 1 ? "1 compilation" : "\(count) compilations"
        }
    }
}

/// Verbatim from `AlbumSummary+NewTabMatch.swift` — the ownership title-key functions, including
/// the applied bare-suffix widening. Only the memo behind `catalogReleaseIdentityKey` is omitted.
enum AlbumSummaryMatch {
    static func normalizedReleaseKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let folded = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let spaced = folded.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return spaced
    }

    static func normalizedAlbumTitleLoose(_ raw: String) -> String {
        var base = normalizedReleaseKey(raw)
        while true {
            guard let r = base.range(of: #"(\s*\([^)]+\)|\s*\[[^\]]+\])$"#, options: .regularExpression) else { break }
            base.removeSubrange(r)
            base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return base
    }

    static func albumVersionBaseKey(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }

        let suffixPattern = #"(?i)(?:\s*[-–—]\s*|\s+)(single|ep|album|deluxe edition|deluxe|expanded edition|remaster(ed)?(\s+\d{4})?)$"#
        while let range = t.range(of: suffixPattern, options: .regularExpression) {
            t = String(t[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        t = t.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalizedReleaseKey(t)
    }

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
