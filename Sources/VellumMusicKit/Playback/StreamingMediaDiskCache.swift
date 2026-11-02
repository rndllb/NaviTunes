import CryptoKit
import Foundation

/// LRU disk cache of fully-streamed media files so replaying a recently-played
/// track is served from local disk (instant) instead of re-streamed.
///
/// Populated two ways:
/// 1. Opportunistically by ``CachingResourceLoaderDelegate``: a file is committed once the
///    *entire* byte range `[0, contentLength)` has been observed flowing through to `AVPlayer`
///    during normal playback — no extra network bytes, we just keep a copy.
/// 2. Deliberately by ``AutoMixStreamPrefetcher`` through ``fetchAndCommit``: with AutoMix on,
///    the next queued stream is fetched whole while the current song plays, so it can be
///    analysed and then played from the cached copy with no second download.
///
/// Lives in Caches (not Application Support) so the OS may purge it under disk
/// pressure, and it is wiped on sign-out / "clear metadata cache" like the other
/// local caches.
final class StreamingMediaDiskCache: @unchecked Sendable {
    static let shared = StreamingMediaDiskCache()

    /// Total on-disk budget. Oldest-accessed files are evicted past this.
    private let maxBytes: Int64 = 512 * 1024 * 1024
    /// Tiny files are HTML/JSON error bodies or truncated commits — never playable audio.
    private static let minimumUsableBytes: Int64 = 32_768
    private let lock = NSLock()
    private let directory: URL?
    /// Fires (off the lock, on whatever thread committed) with the key of every file that lands —
    /// from the resource loader finishing a stream the player pulled, or from a deliberate fetch.
    /// `PlaybackEngine` uses it to re-plan an AutoMix boundary the moment the playing track
    /// becomes a local file mid-song.
    var onCommit: ((String) -> Void)?

    /// The app's cache under `Caches/VellumMusic/stream-cache`. Tests pass their own directory.
    init(directory: URL? = nil) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.directory = directory
            return
        }
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        ) else {
            self.directory = nil
            return
        }
        let dir = base.appendingPathComponent("VellumMusic/stream-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
    }

    /// Stable cache key for a stream URL. Keeps the query (the same track at a different
    /// bitrate/format is a different file) but drops the **auth** parameters: Subsonic's salted
    /// token (`s`, `t`, `p`) is regenerated on every `streamURL(for:)` call and Jellyfin's
    /// `api_key` changes per session, so keying on the full string meant a file committed under one
    /// URL was never found by the next lookup for the same track — and AutoMix's early fetch
    /// re-downloaded the same song on every re-plan.
    static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(mediaIdentityString(for: url).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Query names that identify the *requester*, not the media.
    static let volatileQueryNames: Set<String> = ["s", "t", "p", "api_key", "apikey", "x-emby-token", "c", "v", "f"]

    static func mediaIdentityString(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let kept = (components.queryItems ?? [])
            .filter { !volatileQueryNames.contains($0.name.lowercased()) }
            .sorted { $0.name < $1.name }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.string ?? url.absoluteString
    }

    /// The container of a cached file, read from its first bytes. Cache files carry no extension,
    /// so `AVURLAsset` cannot identify them on its own (T665); the result is passed to the asset
    /// as its out-of-band MIME type. `nil` for anything unrecognised, and the asset is then built
    /// as before.
    nonisolated static func sniffedMIMEType(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12) else { return nil }
        return sniffedMIMEType(head: head)
    }

    nonisolated static func sniffedMIMEType(head: Data) -> String? {
        let b = [UInt8](head)
        guard b.count >= 4 else { return nil }
        func ascii(_ s: String, at offset: Int) -> Bool {
            let u = Array(s.utf8)
            guard b.count >= offset + u.count else { return false }
            return Array(b[offset ..< offset + u.count]) == u
        }
        if ascii("fLaC", at: 0) { return "audio/flac" }
        if ascii("OggS", at: 0) { return "audio/ogg" }
        if ascii("ID3", at: 0) { return "audio/mpeg" }
        if ascii("RIFF", at: 0), ascii("WAVE", at: 8) { return "audio/wav" }
        if ascii("FORM", at: 0) { return "audio/aiff" }
        if ascii("ftyp", at: 4) { return "audio/mp4" }
        // ADTS AAC: sync 0xFFF, layer 00 → second byte 0xF1 / 0xF9. Checked before the MPEG
        // audio sync below, which it also matches.
        if b[0] == 0xFF, b[1] & 0xF6 == 0xF0 { return "audio/aac" }
        if b[0] == 0xFF, b[1] & 0xE0 == 0xE0 { return "audio/mpeg" }
        return nil
    }

    private func fileURL(forKey key: String) -> URL? {
        directory?.appendingPathComponent(key, isDirectory: false)
    }

    /// Fast existence + size check. Evicts truncated or error-page files so playback
    /// never prefers a dead cache entry over the live stream.
    func peekCachedFileURL(forKey key: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return usableCachedFileURLLocked(forKey: key)
    }

    func evict(fileURL url: URL) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    func evict(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        guard let url = fileURL(forKey: key) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Returns the local file for a fully-cached stream, or nil. Bumps the file's
    /// modification date so it counts as recently used for LRU eviction.
    func cachedFileURL(forKey key: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let url = usableCachedFileURLLocked(forKey: key) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    func markAccessed(fileURL: URL) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
    }

    /// A scratch URL the delegate assembles a candidate file into before committing.
    func makeTemporaryFileURL() -> URL? {
        guard let dir = directory else { return nil }
        return dir.appendingPathComponent("tmp-" + UUID().uuidString, isDirectory: false)
    }

    /// Atomically move a fully-assembled temp file into the cache under `key`,
    /// then enforce the size budget. No-op (temp removed) if anything fails.
    func commit(temporaryFileURL: URL, forKey key: String) {
        lock.lock()
        guard let dest = fileURL(forKey: key) else {
            lock.unlock()
            try? FileManager.default.removeItem(at: temporaryFileURL)
            return
        }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: temporaryFileURL, to: dest)
        } catch {
            lock.unlock()
            try? FileManager.default.removeItem(at: temporaryFileURL)
            return
        }
        enforceBudgetLocked()
        let landed = usableCachedFileURLLocked(forKey: key) != nil
        lock.unlock()
        if landed { onCommit?(key) }
    }

    func discardTemporaryFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Fetches a whole progressive stream and commits it under its key, returning the cached
    /// file. Returns the existing file without touching the network when it is already cached.
    /// Cancellation of the calling task cancels the download. The session is a parameter so a
    /// test can count exactly what went over the wire.
    ///
    /// This is the one deliberate writer of the cache; the resource-loader path commits only what
    /// playback already streamed. It replaced two fire-and-forget warmers that had no callers.
    func fetchAndCommit(
        url: URL,
        headers: [String: String] = [:],
        session: URLSession = .shared,
        timeout: TimeInterval = 120,
    ) async throws -> URL {
        let key = Self.key(for: url)
        if let existing = peekCachedFileURL(forKey: key) {
            markAccessed(fileURL: existing)
            return existing
        }
        guard CachingResourceLoaderDelegate.isCacheable(url) else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (tempDownloadURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempDownloadURL)
            throw URLError(.badServerResponse)
        }
        do {
            try Task.checkCancellation()
        } catch {
            // Cancelled between the download landing and the commit: the temp file is ours to
            // remove, nobody else will (T643 c3).
            try? FileManager.default.removeItem(at: tempDownloadURL)
            throw error
        }
        commit(temporaryFileURL: tempDownloadURL, forKey: key)
        guard let cached = peekCachedFileURL(forKey: key) else {
            evict(forKey: key)
            throw URLError(.cannotCreateFile)
        }
        markAccessed(fileURL: cached)
        return cached
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        guard let dir = directory else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in contents { try? FileManager.default.removeItem(at: url) }
    }

    private func usableCachedFileURLLocked(forKey key: String) -> URL? {
        guard let url = fileURL(forKey: key) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size < Self.minimumUsableBytes {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
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

