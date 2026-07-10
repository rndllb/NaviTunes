import Foundation

enum EqualizerProfileStore {
    private static let filename = "eq-profiles.json"

    private static func fileURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )
        let dir = base.appendingPathComponent("VellumMusic", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    static func load() -> [EqualizerProfile] {
        guard let url = try? fileURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([EqualizerProfile].self, from: data)
        else { return [] }
        return items.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func save(_ items: [EqualizerProfile]) {
        guard let url = try? fileURL(),
              let data = try? JSONEncoder().encode(items)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    @discardableResult
    static func upsert(
        kind: EqualizerProfileKind,
        key: String,
        displayName: String,
        gains: [Float],
    ) -> EqualizerProfile {
        var items = load()
        let profile = EqualizerProfile(
            kind: kind,
            key: key,
            displayName: displayName,
            gains: gains,
        )
        if let index = items.firstIndex(where: { $0.kind == kind && $0.key == key }) {
            items[index] = profile
        } else {
            items.append(profile)
        }
        save(items)
        return profile
    }

    static func remove(id: String) {
        var items = load()
        items.removeAll { $0.id == id }
        save(items)
    }
}
