import Foundation

/// Version stamp for the on-disk caches that hold `Codable` library models.
///
/// The problem this exists to stop is quiet rather than loud. `Track`, `AlbumSummary` and friends
/// are persisted verbatim, and adding an optional field to one of them is source-compatible and
/// decode-compatible — an older file simply reads back with the new field `nil`. Nothing fails,
/// nothing warns, and the app runs on data that structurally cannot answer the question the new
/// field was added for.
///
/// That is exactly how `Track.artistId` behaved on arrival: playlist rows and the library snapshot
/// had been written before the field existed, so every cached track decoded with no artist id and
/// "Go to Artist" kept falling back to name matching. Reinstalling would have fixed it and
/// rebuilding would not, which is the worst possible shape for a bug — it looks like the fix did
/// not work rather than like stale data.
///
/// So: **bump this whenever a persisted model gains a field the app then relies on.** A file
/// stamped with an older version is discarded rather than trusted, and the cache refills from the
/// server with the field populated. Discarding a cache costs one fetch. Trusting a stale one costs
/// a bug that survives a rebuild.
enum PersistedModelSchema {
    /// Current version of the persisted library models.
    ///
    /// History:
    /// - `1` — `Track.artistId` added, so artist navigation can identify an artist rather than
    ///   describe them by name. Caches written before this carry no artist id at all.
    static let current = 1
}
