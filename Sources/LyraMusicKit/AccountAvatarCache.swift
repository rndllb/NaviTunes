import CoreGraphics
import CryptoKit
import Foundation

/// Stable key for the signed-in account avatar on a specific server.
struct AccountAvatarIdentity: Hashable, Codable, Sendable {
    let backend: String
    let serverKey: String
    let userKey: String
}

/// On-disk cache for Jellyfin / Navidrome profile images so the toolbar avatar survives poor or no connectivity.
enum AccountAvatarCache {
    private static let folderName = "LyraMusic/AccountAvatar"
    private static let decodedLock = NSLock()
    private static var decodedImages: [String: CGImage] = [:]

    static func identity(backend: BackendKind, baseURL: URL, userKey: String) -> AccountAvatarIdentity {
        AccountAvatarIdentity(
            backend: backend == .jellyfin ? "jellyfin" : "navidrome",
            serverKey: LibraryMembership.normalizedServerKey(from: baseURL),
            userKey: userKey,
        )
    }

    static func loadData(identity: AccountAvatarIdentity) -> Data? {
        guard let url = try? fileURL(for: identity),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    static func remove(identity: AccountAvatarIdentity) {
        guard let url = try? fileURL(for: identity) else { return }
        try? FileManager.default.removeItem(at: url)
        clearDecodedImages(matching: identity)
    }

    static func clearAll() {
        guard let dir = try? cacheDirectory() else { return }
        try? FileManager.default.removeItem(at: dir)
        decodedLock.lock()
        decodedImages.removeAll()
        decodedLock.unlock()
    }

    /// Decoded avatar kept in memory so toolbar headers can show/hide without re-decoding.
    static func cachedDecodedImage(identity: AccountAvatarIdentity, maxPixelSize: CGFloat) -> CGImage? {
        let key = decodedCacheKey(identity: identity, maxPixelSize: maxPixelSize)
        decodedLock.lock()
        if let hit = decodedImages[key] {
            decodedLock.unlock()
            return hit
        }
        decodedLock.unlock()

        guard let data = loadData(identity: identity),
              let cg = ArtworkImageDecoder.cgImage(from: data, maxPixelSize: maxPixelSize)
        else { return nil }

        decodedLock.lock()
        decodedImages[key] = cg
        decodedLock.unlock()
        return cg
    }

    /// Downloads and stores avatar bytes when online; keeps the previous file on failure.
    static func prefetch(url: URL, identity: AccountAvatarIdentity) async {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 20
        // Inject per-host auth headers (Jellyfin) so the avatar fetch authenticates
        // without leaking the access token into the URL.
        let authHeaders = await MediaAuthHeaderRegistry.shared.headers(for: url)
        for (k, v) in authHeaders { request.setValue(v, forHTTPHeaderField: k) }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            guard (200 ..< 300).contains(http.statusCode), !data.isEmpty else { return }
            let looksLikeImage = await Task.detached(priority: .utility) {
                ArtworkImageDecoder.cgImage(from: data, maxPixelSize: 96) != nil
            }.value
            guard looksLikeImage else { return }
            save(data: data, identity: identity)
        } catch {
            // Keep any previously cached avatar.
        }
    }

    // MARK: - Private

    private static func cacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for identity: AccountAvatarIdentity) throws -> URL {
        let digest = SHA256.hash(data: cacheSeed(identity))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".img"
        return try cacheDirectory().appendingPathComponent(name, isDirectory: false)
    }

    private static func cacheSeed(_ identity: AccountAvatarIdentity) -> Data {
        Data("\(identity.backend)|\(identity.serverKey)|\(identity.userKey)".utf8)
    }

    private static func decodedCacheKey(identity: AccountAvatarIdentity, maxPixelSize: CGFloat) -> String {
        "\(identity.backend)|\(identity.serverKey)|\(identity.userKey)|\(Int(maxPixelSize))"
    }

    private static func clearDecodedImages(matching identity: AccountAvatarIdentity) {
        let prefix = "\(identity.backend)|\(identity.serverKey)|\(identity.userKey)|"
        decodedLock.lock()
        decodedImages = decodedImages.filter { !$0.key.hasPrefix(prefix) }
        decodedLock.unlock()
    }

    private static func save(data: Data, identity: AccountAvatarIdentity) {
        guard let dest = try? fileURL(for: identity) else { return }
        let tmp = dest.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
