import Foundation

/// Forever-cache of per-track analysis on disk, keyed by track id **and** a fingerprint of the
/// audio file. A re-download at a different bitrate, a retag that changed the file, or a stale
/// id remapped onto another file must not reuse beats measured on different audio.
///
/// Layout: one JSON per key under `Caches/VellumMusic/automix/`. Caches, not Application Support:
/// the OS may purge it under pressure and the only cost is one re-analysis.
struct TransitionAnalysisStore {
    /// What identifies the audio: size in bytes plus modification time. Cheap to read, changes
    /// whenever the bytes do, and never requires hashing a 40 MB FLAC on the main thread.
    struct Fingerprint: Hashable, Codable, Equatable {
        let byteCount: Int
        let modifiedAt: TimeInterval

        static func of(fileURL: URL) -> Fingerprint? {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else { return nil }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return Fingerprint(byteCount: size, modifiedAt: date)
        }
    }

    struct Key: Hashable, Equatable {
        let trackId: String
        let fingerprint: Fingerprint

        /// Filesystem-safe name: the id with separators replaced, then the fingerprint.
        var fileName: String {
            let safe = trackId.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
            return "\(String(safe))-\(fingerprint.byteCount)-\(Int(fingerprint.modifiedAt)).json"
        }
    }

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("VellumMusic/automix", isDirectory: true)
    }

    func load(_ key: Key) -> TransitionMetadata? {
        let url = directory.appendingPathComponent(key.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? TransitionMetadata.decode(data)
    }

    func save(_ metadata: TransitionMetadata, for key: Key) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: directory.appendingPathComponent(key.fileName), options: .atomic)
    }

    func contains(_ key: Key) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(key.fileName).path)
    }

    /// Bytes on disk across every cached analysis — surfaced in Settings → Library next to the
    /// other cache rows.
    func totalBytes() -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
