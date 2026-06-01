import Foundation

struct StaleSongRecoveryResult: Equatable {
    let current: Track
    let swaps: [String: Track]
}

enum StaleSongMatching {
    private static let durationToleranceSeconds: TimeInterval = 2

    /// Builds `{oldId → freshTrack}` for every song in `oldTracks` whose id no longer exists on the server.
    static func buildSwapMap(oldTracks: [Track], freshTracks: [Track]) -> [String: Track] {
        let freshById = Dictionary(uniqueKeysWithValues: freshTracks.map { ($0.id, $0) })
        var swaps: [String: Track] = [:]
        for old in oldTracks {
            if freshById[old.id] != nil { continue }
            guard let match = findMatchingSong(needle: old, in: freshTracks) else { continue }
            swaps[old.id] = match
        }
        return swaps
    }

    static func findMatchingSong(needle: Track, in haystack: [Track]) -> Track? {
        guard !haystack.isEmpty else { return nil }

        let titleArtistMatches = haystack.filter {
            $0.title.caseInsensitiveCompare(needle.title) == .orderedSame
                && $0.artist.caseInsensitiveCompare(needle.artist) == .orderedSame
        }
        if titleArtistMatches.count == 1 { return titleArtistMatches[0] }
        if titleArtistMatches.count > 1, needle.duration > 0 {
            if let byDuration = titleArtistMatches.first(where: {
                $0.duration > 0 && abs($0.duration - needle.duration) <= durationToleranceSeconds
            }) {
                return byDuration
            }
        }

        if let byDiscIndex = haystack.first(where: {
            $0.discNumber == needle.discNumber
                && $0.indexNumber == needle.indexNumber
                && $0.title.caseInsensitiveCompare(needle.title) == .orderedSame
        }) {
            return byDiscIndex
        }

        let titleOnly = haystack.filter { $0.title.caseInsensitiveCompare(needle.title) == .orderedSame }
        if titleOnly.count == 1 { return titleOnly[0] }
        if titleOnly.count > 1, needle.indexNumber > 0 {
            if let byTrack = titleOnly.first(where: { $0.indexNumber == needle.indexNumber }) {
                return byTrack
            }
        }
        return nil
    }
}
