import Foundation

extension AlbumSummary {
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

    /// Stable artist + album identity for deduping catalog rows that share a release under different ids.
    var catalogReleaseIdentityKey: String {
        let artistKey = Self.normalizedReleaseKey(artist)
        let titleKey = Self.normalizedAlbumTitleLoose(title)
        return "\(artistKey)|\(titleKey)"
    }

    /// True when this catalog album is the same release as a **New** tab row (for showing Play).
    func matchesNewTabRelease(artist: String, albumTitle: String) -> Bool {
        let wantArtist = Self.normalizedReleaseKey(artist)
        let wantAlbum = Self.normalizedReleaseKey(albumTitle)
        let wantAlbumLoose = Self.normalizedAlbumTitleLoose(albumTitle)
        guard !wantArtist.isEmpty, !wantAlbum.isEmpty else { return false }

        let haveArtist = Self.normalizedReleaseKey(self.artist)
        let haveAlbum = Self.normalizedReleaseKey(self.title)
        let haveAlbumLoose = Self.normalizedAlbumTitleLoose(self.title)

        if haveAlbum == wantAlbum, haveArtist == wantArtist { return true }

        if haveAlbum == wantAlbum {
            if haveArtist == wantArtist { return true }
            if haveArtist.contains(wantArtist) || wantArtist.contains(haveArtist) { return true }
        }

        if !wantAlbumLoose.isEmpty, haveAlbumLoose == wantAlbumLoose {
            if haveArtist == wantArtist { return true }
            if haveArtist.contains(wantArtist) || wantArtist.contains(haveArtist) { return true }
        }

        return false
    }
}

extension AlbumSummary {
    /// iTunes / chart titles like ``Circles - Single`` vs server tags ``Circles``.
    static func browseReleaseTitleLookupVariants(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        func append(_ value: String) {
            let key = normalizedReleaseKey(value)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            out.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        append(trimmed)
        let suffixes = [
            " - Single", " - single", " - SINGLE",
            " - EP", " - ep",
            " (Single)", " (single)",
            " [Single]", " [single]",
        ]
        for suffix in suffixes {
            if trimmed.hasSuffix(suffix) {
                append(String(trimmed.dropLast(suffix.count)))
            } else if trimmed.localizedCaseInsensitiveHasSuffix(suffix.trimmingCharacters(in: .whitespaces)) {
                let cut = trimmed.count - suffix.trimmingCharacters(in: .whitespaces).count
                if cut > 0 {
                    append(String(trimmed.prefix(cut)))
                }
            }
        }
        if let range = trimmed.range(of: #" - (Single|single|EP|ep)$"#, options: .regularExpression) {
            append(String(trimmed[..<range.lowerBound]))
        }
        return out
    }
}

private extension String {
    func localizedCaseInsensitiveHasSuffix(_ suffix: String) -> Bool {
        lowercased().hasSuffix(suffix.lowercased())
    }
}

extension Array where Element == AlbumSummary {
    func firstMatchingNewTabRelease(artist: String, albumTitle: String) -> AlbumSummary? {
        first { $0.matchesNewTabRelease(artist: artist, albumTitle: albumTitle) }
    }
}

/// O(1) lookup for "is this chart album in the user's catalog?". Built once when
/// ``AppModel.libraryAlbums`` is reassigned; replaces per-cell linear scans through
/// thousands of albums in ``MusicNewTabView`` (each comparison ran multiple regex
/// substitutions, which dominated main-thread time when entering the New tab).
struct LibraryAlbumReleaseIndex {
    /// Each entry stores the album plus its pre-normalized artist so lookup
    /// only does the cheap equal/contains check, not full normalization.
    private struct Entry {
        let album: AlbumSummary
        let artistKey: String
    }
    /// Strict album title key → entries. Same album may appear under both maps.
    private let byStrictAlbumKey: [String: [Entry]]
    /// Loose album title key (trailing "(Deluxe)" etc. stripped) → entries.
    private let byLooseAlbumKey: [String: [Entry]]

    static let empty = LibraryAlbumReleaseIndex(albums: [])

    init(albums: [AlbumSummary]) {
        var strict: [String: [Entry]] = [:]
        var loose: [String: [Entry]] = [:]
        for album in albums {
            let strictAlbum = AlbumSummary.normalizedReleaseKey(album.title)
            let artistKey = AlbumSummary.normalizedReleaseKey(album.artist)
            guard !strictAlbum.isEmpty, !artistKey.isEmpty else { continue }
            let entry = Entry(album: album, artistKey: artistKey)
            strict[strictAlbum, default: []].append(entry)
            let looseAlbum = AlbumSummary.normalizedAlbumTitleLoose(album.title)
            if !looseAlbum.isEmpty, looseAlbum != strictAlbum {
                loose[looseAlbum, default: []].append(entry)
            }
        }
        self.byStrictAlbumKey = strict
        self.byLooseAlbumKey = loose
    }

    /// Mirror of ``AlbumSummary.matchesNewTabRelease`` — equality on title (strict
    /// or loose), with artist match permitting an equal-or-substring relation.
    func firstMatch(artist: String, albumTitle: String) -> AlbumSummary? {
        let wantArtist = AlbumSummary.normalizedReleaseKey(artist)
        let wantStrict = AlbumSummary.normalizedReleaseKey(albumTitle)
        guard !wantArtist.isEmpty, !wantStrict.isEmpty else { return nil }
        if let hit = matchEntries(byStrictAlbumKey[wantStrict], wantArtist: wantArtist) {
            return hit
        }
        let wantLoose = AlbumSummary.normalizedAlbumTitleLoose(albumTitle)
        if !wantLoose.isEmpty, wantLoose != wantStrict {
            if let hit = matchEntries(byLooseAlbumKey[wantLoose], wantArtist: wantArtist) {
                return hit
            }
        }
        return nil
    }

    private func matchEntries(_ entries: [Entry]?, wantArtist: String) -> AlbumSummary? {
        guard let entries else { return nil }
        for entry in entries {
            if entry.artistKey == wantArtist { return entry.album }
            if entry.artistKey.contains(wantArtist) || wantArtist.contains(entry.artistKey) {
                return entry.album
            }
        }
        return nil
    }
}
