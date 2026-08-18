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
        let dir = base.appendingPathComponent("VellumMusic", isDirectory: true)
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

    private static let writeQueue = DispatchQueue(label: "VellumMusic.playlist-rows-write", qos: .utility)
    private static let writeLock = NSLock()
    private static var pendingWrite: DispatchWorkItem?
    private static var writeGeneration: UInt64 = 0

    /// Off-main JSON encode + atomic write, debounced to the trailing edge —
    /// every save encodes the *whole* cache (megabytes once the sync-ahead
    /// warm-up has populated it), and the warm-up saves after each fetched
    /// playlist, so back-to-back saves must collapse into one final write.
    /// Worst case on force-quit is losing a few seconds of cache freshness;
    /// the next fetch simply re-fills it.
    static func saveAsync(_ rowsByPlaylistId: [String: [PlaylistRowItem]]) {
        writeLock.lock()
        pendingWrite?.cancel()
        writeGeneration &+= 1
        let generation = writeGeneration
        writeLock.unlock()
        let work = DispatchWorkItem {
            writeLock.lock()
            let stillCurrent = generation == writeGeneration
            writeLock.unlock()
            guard stillCurrent else { return }
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
        writeLock.lock()
        pendingWrite?.cancel()
        pendingWrite = work
        writeLock.unlock()
        writeQueue.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    static func clear() {
        writeLock.lock()
        writeGeneration &+= 1
        pendingWrite?.cancel()
        pendingWrite = nil
        writeLock.unlock()
        guard let url = try? fileURL(),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
