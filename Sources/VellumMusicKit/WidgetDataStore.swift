import Foundation

/// Shared widget data model. Written by the main app, read by the VellumWidgets extension.
/// Both targets share the App Group `group.com.randll.vellum`.
public enum WidgetDataStore {
    public static let appGroupID = "group.com.randll.vellum"
    static let defaultsKey = "vellumWidgetData"

    public struct MusicItem: Codable, Identifiable {
        public let id: String
        public let title: String
        public let artist: String
        public let artworkURLString: String?
        public let kind: Kind

        public enum Kind: String, Codable { case album, track }

        public init(id: String, title: String, artist: String, artworkURLString: String?, kind: Kind) {
            self.id = id
            self.title = title
            self.artist = artist
            self.artworkURLString = artworkURLString
            self.kind = kind
        }

        public var artworkURL: URL? { artworkURLString.flatMap(URL.init(string:)) }
        public var deepLinkURL: URL {
            var c = URLComponents()
            c.scheme = "vellum"
            c.host = kind.rawValue
            c.path = "/\(id)"
            return c.url ?? URL(string: "vellum://home")!
        }
    }

    public struct Payload: Codable {
        public let recentlyPlayed: [MusicItem]
        public let nowPlaying: MusicItem?
        public let isPlaying: Bool
        public let updatedAt: Date
        public let accentHex: String

        public init(recentlyPlayed: [MusicItem], nowPlaying: MusicItem?, isPlaying: Bool, updatedAt: Date, accentHex: String) {
            self.recentlyPlayed = recentlyPlayed
            self.nowPlaying = nowPlaying
            self.isPlaying = isPlaying
            self.updatedAt = updatedAt
            self.accentHex = accentHex
        }
    }

    public static func write(_ payload: Payload) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(payload)
        else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    public static func read() -> Payload? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: defaultsKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return payload
    }

    // MARK: - Artwork file cache (App Group container)

    static var artworkCacheDir: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("widget-artwork", isDirectory: true)
    }

    public static func artworkCacheURL(for id: String) -> URL? {
        // Sanitise the id so it's safe as a filename
        let safe = id.replacingOccurrences(of: "/", with: "_")
                     .replacingOccurrences(of: ":", with: "_")
        return artworkCacheDir?.appendingPathComponent("\(safe).jpg")
    }

    /// Load a previously-cached artwork image from the shared container. Call from the widget.
    public static func cachedArtworkData(for id: String) -> Data? {
        guard let url = artworkCacheURL(for: id) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Download artwork for each item and save to the shared container, then prune any
    /// cached files that are no longer referenced by the current payload.
    /// Returns true if any new files were written (caller can trigger a timeline reload).
    @discardableResult
    public static func cacheArtwork(items: [MusicItem]) async -> Bool {
        guard let dir = artworkCacheDir else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var wrote = false
        for item in items {
            guard let urlString = item.artworkURLString,
                  let url = URL(string: urlString),
                  let dest = artworkCacheURL(for: item.id)
            else { continue }
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            if let (data, _) = try? await URLSession.shared.data(for: request) {
                try? data.write(to: dest, options: .atomic)
                wrote = true
            }
        }
        pruneArtworkCache(keeping: items)
        return wrote
    }

    /// Removes cached artwork files not referenced by the current payload, so the shared
    /// container doesn't grow unbounded as the recently-played set churns.
    private static func pruneArtworkCache(keeping items: [MusicItem]) {
        guard let dir = artworkCacheDir else { return }
        let keepPaths = Set(items.compactMap { artworkCacheURL(for: $0.id)?.path })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where !keepPaths.contains(file.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
