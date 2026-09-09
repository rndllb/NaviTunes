import Foundation

/// Persists per-playlist Kill Mode state in `UserDefaults`. Device-local; not synced.
///
/// - `enabledPlaylistsKey` → JSON-encoded `[String]` of playlist ids with Kill Mode on.
/// - `pendingRemovalsKey`  → JSON-encoded `[String: [String]]` (playlistId → trackIds queued for removal).
/// - `passedTracksKey`     → JSON-encoded `[String: [String]]` (playlistId → trackIds kept/green).
///
/// Pure value-passing API: callers hold the in-memory `Set`/`Dictionary`, mutate, and write back.
enum KillModeStore {
    private static let enabledPlaylistsKey = "vellum.killMode.enabledPlaylists"
    private static let pendingRemovalsKey = "vellum.killMode.pendingRemovals"
    private static let passedTracksKey = "vellum.killMode.passed"

    static func loadEnabled() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: enabledPlaylistsKey),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(arr)
    }

    static func saveEnabled(_ ids: Set<String>) {
        let payload = Array(ids).sorted()
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: enabledPlaylistsKey)
        }
    }

    /// Order is significant: index 0 is the most-recently-added track id (newest skip first).
    static func loadPending() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: pendingRemovalsKey),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return dict
    }

    static func savePending(_ map: [String: [String]]) {
        // Drop empty buckets so the persisted shape stays lean. Order is preserved as-is.
        let cleaned = map.compactMapValues { $0.isEmpty ? nil : $0 }
        if let data = try? JSONEncoder().encode(cleaned) {
            UserDefaults.standard.set(data, forKey: pendingRemovalsKey)
        }
    }

    /// Kept (green) tracks — unordered, stored as sorted arrays for a stable on-disk shape.
    static func loadPassed() -> [String: Set<String>] {
        guard let data = UserDefaults.standard.data(forKey: passedTracksKey),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return dict.mapValues { Set($0) }
    }

    static func savePassed(_ map: [String: Set<String>]) {
        // Drop empty buckets; sort within each for deterministic output.
        let cleaned = map.compactMapValues { $0.isEmpty ? nil : Array($0).sorted() }
        if let data = try? JSONEncoder().encode(cleaned) {
            UserDefaults.standard.set(data, forKey: passedTracksKey)
        }
    }
}
