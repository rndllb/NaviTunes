import Foundation

/// Persists per-playlist Kill Mode state in `UserDefaults`. Device-local; not synced.
///
/// State is **scoped to an account** — backend, normalized server, user — because playlist ids are
/// only unique per server: two servers can hand out the same id for different playlists. Each
/// scope has its own three keys under `vellum.killMode.<scope>.`:
///
/// - `enabledPlaylists` → JSON-encoded `[String]` of playlist ids with Kill Mode on.
/// - `pendingRemovals`  → JSON-encoded `[String: [String]]` (playlistId → trackIds queued for removal).
/// - `passed`           → JSON-encoded `[String: [String]]` (playlistId → trackIds kept/green).
///
/// **Nothing here deletes.** Sign-out only unloads, so signing back in to the same account finds
/// its progress. History written before scoping existed — under the unscoped `vellum.killMode.*`
/// keys, which is also where `LegacyLyraMigration` copies `lyra.killMode.*` — is adopted once by
/// the first account that loads, and the unscoped copy is left on disk.
///
/// Pure value-passing API: callers hold the in-memory `Set`/`Dictionary`, mutate, and write back.
enum KillModeStore {
    struct Snapshot: Equatable {
        var enabled: Set<String> = []
        var pending: [String: [String]] = [:]
        var passed: [String: Set<String>] = [:]
    }

    private static let keyPrefix = "vellum.killMode."
    private static let enabledSuffix = "enabledPlaylists"
    private static let pendingSuffix = "pendingRemovals"
    private static let passedSuffix = "passed"
    /// The scope that adopted the unscoped history. Set once; its presence stops a second account
    /// from adopting the same history.
    private static let legacyAdoptedByKey = "vellum.killMode.legacyAdoptedBy"

    /// The signed-in account's scope. The scope-less save calls write here; with no account they
    /// write nothing, since there is no account the state could belong to.
    @MainActor static var activeScope: String?

    /// `<backend>/<normalized server>/<lowercased user>` — the same inputs as the magic playlist's
    /// identity. Nil when either the server or the user is unknown.
    static func scope(backend: BackendKind, baseURLString: String, userKey: String?) -> String? {
        guard let server = LibraryMembership.normalizedServerKey(from: baseURLString) else { return nil }
        let user = (userKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !user.isEmpty else { return nil }
        return "\(backend.rawValue)/\(server)/\(user)"
    }

    private static func key(_ suffix: String, scope: String) -> String {
        "\(keyPrefix)\(scope).\(suffix)"
    }

    // MARK: - Load

    static func load(scope: String, defaults: UserDefaults = .standard) -> Snapshot {
        adoptUnscopedHistoryIfNeeded(scope: scope, defaults: defaults)
        var snapshot = Snapshot()
        if let data = defaults.data(forKey: key(enabledSuffix, scope: scope)),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            snapshot.enabled = Set(ids)
        }
        // Order is significant: index 0 is the most-recently-added track id (newest skip first).
        if let data = defaults.data(forKey: key(pendingSuffix, scope: scope)),
           let map = try? JSONDecoder().decode([String: [String]].self, from: data) {
            snapshot.pending = map
        }
        if let data = defaults.data(forKey: key(passedSuffix, scope: scope)),
           let map = try? JSONDecoder().decode([String: [String]].self, from: data) {
            snapshot.passed = map.mapValues { Set($0) }
        }
        return snapshot
    }

    /// Copies the unscoped keys into `scope` the first time any account loads while they exist.
    /// Values the scope already has win. The unscoped keys are not removed.
    private static func adoptUnscopedHistoryIfNeeded(scope: String, defaults: UserDefaults) {
        guard defaults.string(forKey: legacyAdoptedByKey) == nil else { return }
        let suffixes = [enabledSuffix, pendingSuffix, passedSuffix]
        guard suffixes.contains(where: { defaults.object(forKey: keyPrefix + $0) != nil }) else { return }
        for suffix in suffixes where defaults.object(forKey: key(suffix, scope: scope)) == nil {
            if let data = defaults.data(forKey: keyPrefix + suffix) {
                defaults.set(data, forKey: key(suffix, scope: scope))
            }
        }
        defaults.set(scope, forKey: legacyAdoptedByKey)
    }

    // MARK: - Save (explicit scope)

    static func saveEnabled(_ ids: Set<String>, scope: String, defaults: UserDefaults = .standard) {
        let payload = Array(ids).sorted()
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: key(enabledSuffix, scope: scope))
        }
    }

    static func savePending(_ map: [String: [String]], scope: String, defaults: UserDefaults = .standard) {
        // Drop empty buckets so the persisted shape stays lean. Order is preserved as-is.
        let cleaned = map.compactMapValues { $0.isEmpty ? nil : $0 }
        if let data = try? JSONEncoder().encode(cleaned) {
            defaults.set(data, forKey: key(pendingSuffix, scope: scope))
        }
    }

    /// Kept (green) tracks — unordered, stored as sorted arrays for a stable on-disk shape.
    static func savePassed(_ map: [String: Set<String>], scope: String, defaults: UserDefaults = .standard) {
        // Drop empty buckets; sort within each for deterministic output.
        let cleaned = map.compactMapValues { $0.isEmpty ? nil : Array($0).sorted() }
        if let data = try? JSONEncoder().encode(cleaned) {
            defaults.set(data, forKey: key(passedSuffix, scope: scope))
        }
    }

    // MARK: - Save (active account)

    @MainActor static func saveEnabled(_ ids: Set<String>) {
        guard let scope = activeScope else { return }
        saveEnabled(ids, scope: scope)
    }

    @MainActor static func savePending(_ map: [String: [String]]) {
        guard let scope = activeScope else { return }
        savePending(map, scope: scope)
    }

    @MainActor static func savePassed(_ map: [String: Set<String>]) {
        guard let scope = activeScope else { return }
        savePassed(map, scope: scope)
    }
}
