import Foundation

/// One cached MusicBrainz payload.
///
/// Raw response bodies are stored rather than decoded models so a later change to the
/// model shape can re-read what was already fetched instead of forcing a refetch that the
/// rate limit makes expensive.
struct MusicBrainzCacheEntry: Codable, Sendable {
    /// MBID plus the `inc` set the payload was fetched with. Two different `inc` sets are
    /// two different payloads and must not share a slot — a `tags`-only body has no rating
    /// in it, and reading it as though it did would silently drop the field.
    var key: String
    var fetchedAt: Date
    /// `release-group-count` as the server reported it. Browse entries only.
    var totalCount: Int?
    /// Offsets whose page bodies are held, ascending. A lookup holds the single offset 0.
    var heldOffsets: [Int]
    /// Raw bodies, parallel to `heldOffsets`.
    var rawPages: [Data]
    /// Whether `heldOffsets` covered the entire result set when this entry was written.
    var isComplete: Bool

    /// Past its freshness window, so it is no longer servable as current data.
    ///
    /// An expired entry is never painted to screen and then replaced when the refetch lands —
    /// that swap under the reader is the thing this rule exists to prevent. It is retained
    /// only as a failure fallback, and when it is shown it is shown labelled as a saved copy.
    var isExpired: Bool { Date().timeIntervalSince(fetchedAt) > MusicBrainzCacheStore.staleAfter }
}

/// On-disk store for MusicBrainz payloads, one file per key.
///
/// Two rules shape this store, and both exist because the rate limit makes a refetch costly:
///
/// - **Expiry means stale, never deleted.** Nothing here is removed for being old. Pull-to-
///   refresh rescans and falls back to the stale copy when the rescan fails, so an entry has
///   to outlive its own expiry to be worth anything.
/// - **Replace only on a complete pass.** A rescan that dies halfway through pagination must
///   not overwrite a complete entry with a partial one wearing a fresh date — that would turn
///   a recoverable network blip into permanent silent data loss, with a timestamp that says
///   everything is fine. Partial passes are discarded; the previous entry stands.
enum MusicBrainzCacheStore {
    /// One week.
    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    // MARK: Keys

    /// Key for an artist lookup payload: MBID plus the `inc` set it was fetched with.
    static func artistKey(mbid: String, inc: [String]) -> String {
        let incPart = inc.isEmpty ? "none" : inc.sorted().joined(separator: "+")
        return "artist:\(mbid)|inc=\(incPart)"
    }

    /// Key for a browsed discography, carrying the `inc` set the payload was fetched with.
    ///
    /// The `inc` belongs in the key for the same reason it does in ``artistKey(mbid:inc:)``: a
    /// payload fetched with a narrower `inc` is missing fields the caller is now asking for, and
    /// serving it back is indistinguishable from the server not having them. Browse acquired an
    /// `inc` when artist credits were added to it, and a key that ignored that would have kept
    /// serving credit-less pages — the exact bug — for up to ``staleAfter`` after the fix landed,
    /// on precisely the artists looked at most recently.
    ///
    /// Entries written under the old key are orphaned rather than migrated. Nothing here is ever
    /// deleted for being old (see the store's rules below), so they sit until ``clearAll()``.
    /// That is a bounded one-off — one stale file per artist browsed before this change — and the
    /// alternative is reading a payload that cannot answer the question being asked of it.
    static func releaseGroupBrowseKey(artistMBID: String, inc: [String] = ["artist-credits"]) -> String {
        let incPart = inc.isEmpty ? "none" : inc.sorted().joined(separator: "+")
        return "artist:\(artistMBID)|browse=release-group|inc=\(incPart)"
    }

    /// Key for a release → release-group mapping. Exempt from the freshness window in practice:
    /// a release cannot move to a different release group, so the answer never goes out of date.
    static func releaseToGroupKey(releaseId: String) -> String {
        "release:\(releaseId)|inc=release-groups"
    }

    /// Key for a resolved artist-name → MBID lookup, so re-opening an artist page does not spend
    /// a search request rediscovering an answer already on disk.
    static func artistNameResolutionKey(normalizedName: String) -> String {
        "artistname:\(normalizedName)|resolve"
    }

    // MARK: Disk

    private static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base
            .appendingPathComponent("VellumMusic", isDirectory: true)
            .appendingPathComponent("musicbrainz", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Filesystem-safe filename for a key. Keys are MBIDs and short ASCII tokens, so a
    /// character filter keeps the name readable for debugging rather than hashing it away.
    private static func filename(for key: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let safe = String(key.map { allowed.contains($0) ? $0 : "_" })
        return safe + ".json"
    }

    private static func fileURL(for key: String) throws -> URL {
        try directory().appendingPathComponent(filename(for: key))
    }

    static func load(_ key: String) -> MusicBrainzCacheEntry? {
        guard let url = try? fileURL(for: key),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(MusicBrainzCacheEntry.self, from: data),
              entry.key == key
        else { return nil }
        return entry
    }

    static func loadAsync(_ key: String) async -> MusicBrainzCacheEntry? {
        await Task.detached(priority: .userInitiated) { load(key) }.value
    }

    /// Writes an entry, refusing any write that would replace a complete entry with a
    /// partial one. Callers are expected to only offer complete passes; this is the
    /// backstop that makes the rule structural instead of a habit.
    @discardableResult
    static func save(_ entry: MusicBrainzCacheEntry) -> Bool {
        guard let url = try? fileURL(for: entry.key) else { return false }
        if !entry.isComplete, let existing = load(entry.key), existing.isComplete {
            return false
        }
        guard let data = try? JSONEncoder().encode(entry) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func saveAsync(_ entry: MusicBrainzCacheEntry) async -> Bool {
        await Task.detached(priority: .utility) { save(entry) }.value
    }

    /// Drops every cached payload. Wired to the app's "clear cache" action — a user asking
    /// to reclaim disk is the one case where removal is correct. Expiry still never deletes.
    static func clearAll() {
        guard let dir = try? directory() else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension == "json" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Total bytes held, for the settings cache readout.
    static func diskBytes() -> Int64 {
        guard let dir = try? directory() else { return 0 }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents.reduce(into: Int64(0)) { total, url in
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
