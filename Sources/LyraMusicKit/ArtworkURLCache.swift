import CryptoKit
import Foundation

/// Disk + memory cache for remote album artwork (shared across list cells and backdrops).
enum ArtworkURLCache {
    private static let folderName = "LyraMusic/ArtworkCache"
    private static let memory = NSCache<NSString, NSData>()

    static func clearAll() {
        memory.removeAllObjects()
        guard let dir = try? cacheDirectory() else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    static func data(for url: URL) async -> Data? {
        let key = cacheKey(for: url)
        if let cached = memory.object(forKey: key as NSString) as Data? {
            return cached
        }
        if let disk = loadFromDisk(key: key) {
            memory.setObject(disk as NSData, forKey: key as NSString)
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
            memory.setObject(data as NSData, forKey: key as NSString)
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

    private static func normalizedCacheURLString(for url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems
        else { return url.absoluteString }
        comps.queryItems = items.filter { item in
            item.name != "t" && item.name != "s"
        }
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
