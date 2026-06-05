import Foundation

/// On-disk copy of resolved playlist rows so reopening a playlist is instant on
/// cold launch instead of paying a `fetchPlaylistRows` round-trip first.
///
/// Like ``LibrarySnapshotStore`` this is *not* server-scoped — it's wiped on
/// sign-out / account switch (see the `clear()` call sites in `AppModel`), so it
/// only ever holds rows for the currently signed-in account. Keyed by playlist id.
struct PlaylistRowsCache: Codable {
    var rowsByPlaylistId: [String: [PlaylistRowItem]] = [:]
    var savedAt: Date = .distantPast
}

enum PlaylistRowsCacheStore {
    private static let filename = "playlist-rows-cache.json"
    /// Soft cap so a heavy browsing session can't grow the on-disk cache without
    /// bound. The most-recently-written playlists win; older ones fall back to a
    /// network fetch on next open (still correct, just not pre-warmed).
    private static let maxPlaylists = 60

    private static func fileURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )
        let dir = base.appendingPathComponent("LyraMusic", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    static func load() -> PlaylistRowsCache? {
        guard let url = try? fileURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(PlaylistRowsCache.self, from: data)
        else { return nil }
        return cache
    }

    /// Off-main JSON decode + disk read. Use from app startup so the main thread
    /// stays free while the cache deserializes.
    static func loadAsync() async -> PlaylistRowsCache? {
        await Task.detached(priority: .userInitiated) { load() }.value
    }

    /// Off-main JSON encode + atomic write. Callers hand off a value snapshot
    /// captured on the main actor; the encode happens at background priority.
    static func saveAsync(_ rowsByPlaylistId: [String: [PlaylistRowItem]]) {
        Task.detached(priority: .utility) {
            guard let url = try? fileURL() else { return }
            var trimmed = rowsByPlaylistId
            if trimmed.count > maxPlaylists {
                // Drop empties first, then arbitrary excess — exact eviction order
                // doesn't matter since a missed entry just re-fetches on open.
                for key in trimmed.filter({ $0.value.isEmpty }).keys where trimmed.count > maxPlaylists {
                    trimmed.removeValue(forKey: key)
                }
                while trimmed.count > maxPlaylists, let key = trimmed.keys.first {
                    trimmed.removeValue(forKey: key)
                }
            }
            var cache = PlaylistRowsCache(rowsByPlaylistId: trimmed)
            cache.savedAt = Date()
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    static func clear() {
        guard let url = try? fileURL(),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
