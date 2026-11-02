import CryptoKit
import Foundation

/// Disk + memory cache for remote album artwork (shared across list cells and backdrops).
enum ArtworkURLCache {
    private static let folderName = "VellumMusic/ArtworkCache"
    // Capped for the same reason as the decoded-image caches: an uncapped `NSCache` only evicts
    // on a system memory warning, in one large purge. This one holds compressed bytes rather
    // than decoded bitmaps, so it buys a lot more entries per megabyte.
    private static let memory: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func clearAll() {
        memory.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
        guard let dir = try? cacheDirectory() else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    static func listDiskEntries() -> [CachedImageEntry] {
        guard let dir = try? cacheDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: dir,
                  includingPropertiesForKeys: [.fileSizeKey],
                  options: [.skipsHiddenFiles],
              )
        else { return [] }

        return urls
            .filter { !$0.hasDirectoryPath }
            .map { url in
                let key = url.deletingPathExtension().lastPathComponent
                let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                return CachedImageEntry(
                    id: "remote-art:\(key)",
                    source: .remoteArtwork,
                    title: String(key.prefix(12)) + "…",
                    subtitle: url.lastPathComponent,
                    fileBytes: bytes,
                    previewURL: url,
                    deleteToken: key,
                )
            }
            .sorted { $0.fileBytes > $1.fileBytes }
    }

    static func totalDiskBytes() -> Int64 {
        listDiskEntries().reduce(0) { $0 + $1.fileBytes }
    }

    static func removeDiskEntry(key: String) {
        guard let url = try? fileURL(key: key) else { return }
        memory.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: url)
    }

    static func data(for url: URL) async -> Data? {
        let key = cacheKey(for: url)
        if let cached = memory.object(forKey: key as NSString) as Data? {
            return cached
        }
        // Off the caller's executor. This function is `async` but not actor-isolated, and there
        // is no suspension point before this line — so Swift ran `loadFromDisk`'s blocking
        // `Data(contentsOf:)` synchronously on whoever called it, which for the hero image and
        // the backdrop tint is the main actor, right as a detail page appears. It is hit
        // whenever the memory cache was evicted but the file is still on disk, which is the
        // common steady state. The network path below was already offloaded correctly; this was
        // an inconsistency inside one function rather than a deliberate tradeoff. The in-memory
        // lookup above is untouched, so warm hits still return without suspending.
        if let disk = await Task.detached(priority: .utility, operation: { loadFromDisk(key: key) }).value {
            memory.setObject(disk as NSData, forKey: key as NSString, cost: max(1, disk.count))
            return disk
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 25
        // Inject per-host auth headers so Jellyfin artwork loads without leaking the
        // access token into the URL — see MediaAuthHeaderRegistry. Cache key is the URL,
        // which is stable for a given server session, so this is safe to layer here.
        let authHeaders = await MediaAuthHeaderRegistry.shared.headers(for: url)
        for (k, v) in authHeaders { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode),
                  !data.isEmpty
            else { return nil }
            let valid = await Task.detached(priority: .utility) {
                ArtworkImageDecoder.cgImage(from: data, maxPixelSize: 64) != nil
            }.value
            guard valid else { return nil }
            memory.setObject(data as NSData, forKey: key as NSString, cost: max(1, data.count))
            saveToDisk(data: data, key: key)
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private static func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(normalizedCacheURLString(for: url).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Sorted as well as filtered — see the matching note in ``DecodedArtworkCache``. Subsonic
    /// URLs are assembled from a Swift `Dictionary`, so query order varies between two requests
    /// for the same cover; without sorting, one image occupied two keys here and on disk.
    private static func normalizedCacheURLString(for url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems
        else { return url.absoluteString }
        comps.queryItems = items
            .filter { $0.name != "t" && $0.name != "s" }
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        return comps.url?.absoluteString ?? url.absoluteString
    }

    private static func cacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(key: String) throws -> URL {
        try cacheDirectory().appendingPathComponent(key + ".img", isDirectory: false)
    }

    private static func loadFromDisk(key: String) -> Data? {
        guard let url = try? fileURL(key: key),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty
        else { return nil }
        return data
    }

    private static func saveToDisk(data: Data, key: String) {
        guard let url = try? fileURL(key: key) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
