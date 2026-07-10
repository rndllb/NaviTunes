import Foundation

/// User-added internet radio station persisted locally in Vellum (not on the server).
struct CustomRadioStation: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var streamURL: URL
    var homepageURL: URL?
    /// Relative path under the custom-radio folder, e.g. `artwork/<id>.jpg`.
    var artworkRelativePath: String?
    var dateAdded: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        streamURL: URL,
        homepageURL: URL? = nil,
        artworkRelativePath: String? = nil,
        dateAdded: Date = Date(),
    ) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.homepageURL = homepageURL
        self.artworkRelativePath = artworkRelativePath
        self.dateAdded = dateAdded
    }

    func artworkFileURL() -> URL? {
        guard let artworkRelativePath else { return nil }
        return CustomRadioStationStore.artworkURL(relativePath: artworkRelativePath)
    }

    func asInternetRadioStation() -> InternetRadioStation {
        InternetRadioStation(
            id: "custom-\(id)",
            name: name,
            streamURL: streamURL,
            homepageURL: homepageURL,
            artworkURL: artworkFileURL(),
            isUserAdded: true,
        )
    }
}

enum CustomRadioStationStore {
    private static let filename = "custom-radio-stations.json"
    private static let artworkFolder = "artwork"

    private static func rootDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )
        let dir = base.appendingPathComponent("VellumMusic/custom-radio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func manifestURL() throws -> URL {
        try rootDirectory().appendingPathComponent(filename)
    }

    static func artworkURL(relativePath: String) -> URL? {
        guard let root = try? rootDirectory() else { return nil }
        return root.appendingPathComponent(relativePath)
    }

    static func load() -> [CustomRadioStation] {
        guard let url = try? manifestURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([CustomRadioStation].self, from: data)
        else { return [] }
        return items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @discardableResult
    static func add(name: String, streamURL: URL, artworkData: Data?) throws -> CustomRadioStation {
        var items = load()
        let id = UUID().uuidString
        var relativePath: String?
        if let artworkData, !artworkData.isEmpty {
            relativePath = try writeArtwork(data: artworkData, stationId: id)
        }
        let station = CustomRadioStation(
            id: id,
            name: name,
            streamURL: streamURL,
            artworkRelativePath: relativePath,
        )
        items.append(station)
        try save(items)
        return station
    }

    static func remove(id: String) {
        var items = load()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: index)
        if let path = removed.artworkRelativePath,
           let fileURL = artworkURL(relativePath: path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        try? save(items)
    }

    private static func save(_ items: [CustomRadioStation]) throws {
        let url = try manifestURL()
        let data = try JSONEncoder().encode(items)
        try data.write(to: url, options: .atomic)
    }

    private static func writeArtwork(data: Data, stationId: String) throws -> String {
        let root = try rootDirectory()
        let artDir = root.appendingPathComponent(artworkFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
        let file = artDir.appendingPathComponent("\(stationId).jpg")
        try data.write(to: file, options: .atomic)
        return "\(artworkFolder)/\(stationId).jpg"
    }
}
