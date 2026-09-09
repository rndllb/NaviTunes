import Foundation

/// Per-session cache for album-detail "More By" / "Other Versions" discography fetches.
actor AlbumDetailArtistCatalogCache {
    static let shared = AlbumDetailArtistCatalogCache()

    private struct Entry {
        let albums: [AlbumSummary]
        let savedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 15 * 60

    private func key(artistName: String, sessionKey: String) -> String {
        let artist = LibraryTrackMatcher.normalize(artistName)
        guard !artist.isEmpty, !sessionKey.isEmpty else { return "" }
        return "\(sessionKey)|\(artist)"
    }

    func load(artistName: String, sessionKey: String) -> [AlbumSummary]? {
        let k = key(artistName: artistName, sessionKey: sessionKey)
        guard !k.isEmpty, let entry = entries[k] else { return nil }
        if Date().timeIntervalSince(entry.savedAt) > ttl {
            entries.removeValue(forKey: k)
            return nil
        }
        return entry.albums
    }

    func save(artistName: String, sessionKey: String, albums: [AlbumSummary]) {
        let k = key(artistName: artistName, sessionKey: sessionKey)
        guard !k.isEmpty, !albums.isEmpty else { return }
        entries[k] = Entry(albums: albums, savedAt: Date())
    }

    func clear() {
        entries.removeAll()
    }
}
