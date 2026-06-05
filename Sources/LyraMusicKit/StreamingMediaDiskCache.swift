import CryptoKit
import Foundation

/// LRU disk cache of fully-streamed media files so replaying a recently-played
/// track is served from local disk (instant) instead of re-streamed.
///
/// Populated opportunistically by ``CachingResourceLoaderDelegate``: a file is
/// only committed once the *entire* byte range `[0, contentLength)` has been
/// observed flowing through to `AVPlayer` during normal playback — so caching
/// adds **no extra network bytes** (we never fetch anything `AVPlayer` didn't ask
/// for; we just keep a copy). Partially-played tracks are never committed.
///
/// Lives in Caches (not Application Support) so the OS may purge it under disk
/// pressure, and it is wiped on sign-out / "clear metadata cache" like the other
/// local caches.
final class StreamingMediaDiskCache: @unchecked Sendable {
    static let shared = StreamingMediaDiskCache()

    /// Total on-disk budget. Oldest-accessed files are evicted past this.
    private let maxBytes: Int64 = 512 * 1024 * 1024
    private let lock = NSLock()

    private lazy var directory: URL? = {
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        ) else { return nil }
        let dir = base.appendingPathComponent("LyraMusic/stream-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Stable cache key for a stream URL. Includes the full query string so the
    /// same track at a different bitrate/format is cached separately (those are
    /// distinct files as far as the player is concerned).
    static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(forKey key: String) -> URL? {
        directory?.appendingPathComponent(key, isDirectory: false)
    }

    /// Returns the local file for a fully-cached stream, or nil. Bumps the file's
    /// modification date so it counts as recently used for LRU eviction.
    func cachedFileURL(forKey key: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let url = fileURL(forKey: key),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// A scratch URL the delegate assembles a candidate file into before committing.
    func makeTemporaryFileURL() -> URL? {
        guard let dir = directory else { return nil }
        return dir.appendingPathComponent("tmp-" + UUID().uuidString, isDirectory: false)
    }

    /// Atomically move a fully-assembled temp file into the cache under `key`,
    /// then enforce the size budget. No-op (temp removed) if anything fails.
    func commit(temporaryFileURL: URL, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        guard let dest = fileURL(forKey: key) else {
            try? FileManager.default.removeItem(at: temporaryFileURL)
            return
        }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: temporaryFileURL, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: temporaryFileURL)
            return
        }
        enforceBudgetLocked()
    }

    func discardTemporaryFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        guard let dir = directory else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in contents { try? FileManager.default.removeItem(at: url) }
    }

    /// Evict least-recently-modified files until under budget. Caller holds `lock`.
    private func enforceBudgetLocked() {
        guard let dir = directory else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
        ) else { return }
        var files: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for url in entries where !url.lastPathComponent.hasPrefix("tmp-") {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? .distantPast
            files.append((url, size, modified))
            total += size
        }
        guard total > maxBytes else { return }
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            if total <= maxBytes { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}
