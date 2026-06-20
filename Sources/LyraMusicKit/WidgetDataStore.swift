import Foundation

/// Shared widget data model. Written by the main app, read by the LyraWidgets extension.
/// Both targets share an App Group whose id is per-developer (the signing team owns it),
/// so it's resolved from the bundle's `LyraAppGroupID` Info.plist key (injected from the
/// `LYRA_APP_GROUP` build setting) rather than hardcoded. App and widget read the same
/// value because both targets build with the same prefix. Falls back to the upstream id.
public enum WidgetDataStore {
    public static let appGroupID: String = {
        (Bundle.main.object(forInfoDictionaryKey: "LyraAppGroupID") as? String)
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
            ?? "group.com.randll.lyra"
    }()
    static let defaultsKey = "lyraWidgetData"

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
            c.scheme = "lyra"
            c.host = kind.rawValue
            c.path = "/\(id)"
            return c.url ?? URL(string: "lyra://home")!
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

    /// Download artwork for each item and save to the shared container.
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
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                try? data.write(to: dest, options: .atomic)
                wrote = true
            }
        }
        return wrote
    }
}
