import Foundation

/// In-memory, per-session cache for the artist page's enrichment payloads
/// (TheAudioDB details, Last.fm top tracks + similar artists, MusicBrainz
/// discography). Keyed by the normalized artist name so cross-source matches
/// (the same artist as `Slipknot` vs `slipknot`) hit the same slot.
///
/// No disk persistence — bouncing in and out of the page within a single app
/// session is instant; relaunching the app re-fetches. Eviction is age-based
/// (15 minutes); the dictionary stays tiny in practice (one entry per unique
/// artist navigated to).
actor ArtistEnrichmentCache {
    static let shared = ArtistEnrichmentCache()

    struct Entry {
        let details: TheAudioDBClient.ArtistDetails?
        let topTracks: [LastFmTopTrack]
        let similarArtists: [LastFmSimilarArtist]
        let releases: [MusicBrainzArtistRelease]
        let savedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 15 * 60

    private func key(forArtistName name: String) -> String {
        LibraryTrackMatcher.normalize(name)
    }

    func load(forArtistName name: String) -> Entry? {
        let k = key(forArtistName: name)
        guard !k.isEmpty, let entry = entries[k] else { return nil }
        if Date().timeIntervalSince(entry.savedAt) > ttl {
            entries.removeValue(forKey: k)
            return nil
        }
        return entry
    }

    func save(
        forArtistName name: String,
        details: TheAudioDBClient.ArtistDetails?,
        topTracks: [LastFmTopTrack],
        similarArtists: [LastFmSimilarArtist],
        releases: [MusicBrainzArtistRelease]
    ) {
        let k = key(forArtistName: name)
        guard !k.isEmpty else { return }
        entries[k] = Entry(
            details: details,
            topTracks: topTracks,
            similarArtists: similarArtists,
            releases: releases,
            savedAt: Date()
        )
    }

    func clear() {
        entries.removeAll()
    }
}
