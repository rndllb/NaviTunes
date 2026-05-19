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

extension Array where Element == AlbumSummary {
    func firstMatchingNewTabRelease(artist: String, albumTitle: String) -> AlbumSummary? {
        first { $0.matchesNewTabRelease(artist: artist, albumTitle: albumTitle) }
    }
}
