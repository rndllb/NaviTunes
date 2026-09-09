import Foundation

/// In-memory, per-session cache for the artist page's plugin catalog payloads
/// (Lidarr / DroppedNeedle releases + overview). Keyed by the normalized artist
/// name so `Slipknot` vs `slipknot` hit the same slot.
///
/// No disk persistence — bouncing in and out of the page within a single app
/// session is instant; relaunching the app re-fetches. Eviction is age-based
/// (15 minutes).
actor ArtistEnrichmentCache {
    static let shared = ArtistEnrichmentCache()

    struct Entry {
        let profile: AcquisitionArtistProfile?
        let releases: [AcquisitionRelease]
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
        profile: AcquisitionArtistProfile?,
        releases: [AcquisitionRelease]
    ) {
        let k = key(forArtistName: name)
        guard !k.isEmpty else { return }
        entries[k] = Entry(profile: profile, releases: releases, savedAt: Date())
    }

    func clear() {
        entries.removeAll()
    }
}
