import AVFoundation
import Combine
import Foundation

enum OfflineDownloadError: Error {
    case pathEscapesRoot
    case unrecognizedAudioFormat
}

/// UI state for an in-flight library offline save (HTTP byte progress when `Content-Length` is known).
enum OfflineDownloadUIState: Equatable {
    /// Server did not advertise a length — show an indeterminate ring only.
    case indeterminate
    /// Fraction received / expected (0…1).
    case progress(Double)
}

private struct OfflineTrackRecord: Codable {
    var track: Track
    var album: AlbumSummary?
    /// Path relative to Downloads root, e.g. `.artwork/albums/{id}.jpg`
    var artworkRelativePath: String?
}

private struct OfflineManifestPayload: Codable {
    var version: Int = 3
    /// Track id → path relative to the Downloads root (folders use `/`).
    var tracks: [String: String] = [:]
    /// Full metadata + local artwork for offline UI and playback.
    var records: [String: OfflineTrackRecord] = [:]
}

@MainActor
final class OfflineDownloadManager: ObservableObject {
    @Published private(set) var downloadedTrackIds: Set<String> = []
    @Published private(set) var activeDownloads: [String: OfflineDownloadUIState] = [:]

    /// Soft-cancel + in-flight `URLSession` task cancellation.
    private var cancelledDownloadIds = Set<String>()
    private var inflightDownloadTasks: [String: URLSessionDownloadTask] = [:]
    private var downloadProgressObservations: [String: NSKeyValueObservation] = [:]
    private var lastReportedDownloadFraction: [String: Double] = [:]

    private static let manifestFilename = "offline-manifest.json"

    /// In-memory manifest; invalidated whenever the on-disk manifest changes.
    private static var manifestCache: OfflineManifestPayload?
    /// One-time index of legacy `{trackId}__*` files at the downloads root.
    private static var legacyFlatFileByTrackId: [String: URL]?

    /// Old flat filenames used `{trackId}__…`; kept only for migrating stray files into the manifest.
    private static let legacyFlatIdSeparator = "__"

    /// Typical read size when buffering network bodies (used only for header sniffing).
    private static let sniffPrefixBytes = 512

    init() {
        Self.migrateLegacyApplicationSupportCachesIfNeeded()
        try? Self.reconcileManifestWithLegacyFlatFilesAtDownloadsRoot()
        if let snap = LibrarySnapshotStore.load() {
            backfillRecordsIfMissing(knownTracks: snap.tracks)
        } else {
            backfillRecordsIfMissing(knownTracks: [])
        }
        downloadedTrackIds = (try? Self.manifestTrackIds()) ?? []
        Task { await enrichCachedDurationsIfNeeded() }
    }

    /// Fills manifest `records` for downloads saved before metadata was persisted (manifest v2).
    func backfillRecordsIfMissing(knownTracks: [Track]) {
        try? Self.backfillRecordsIfMissing(knownTracks: knownTracks)
    }

    /// Saved under **Documents/LyraMusic/Downloads** — browse via Files when sharing is enabled.
    /// Layout: `{Artist}/{Album}/{disc}-{track} {Title}.{ext}` with ``offline-manifest.json`` mapping ids → paths.
    private static func downloadsFolder() throws -> URL {
        let base = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )
        let dir = base.appendingPathComponent("LyraMusic/Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func manifestURL() throws -> URL {
        try downloadsFolder().appendingPathComponent(manifestFilename)
    }

    private static func loadManifest() throws -> OfflineManifestPayload {
        if let manifestCache { return manifestCache }
        let url = try manifestURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode(OfflineManifestPayload.self, from: data)
        else {
            manifestCache = OfflineManifestPayload()
            return manifestCache!
        }
        manifestCache = m
        return m
    }

    private static func saveManifest(_ payload: OfflineManifestPayload) throws {
        let url = try manifestURL()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(payload)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
        manifestCache = payload
        legacyFlatFileByTrackId = nil
    }

    private static func invalidateManifestCache() {
        manifestCache = nil
        legacyFlatFileByTrackId = nil
    }

    private static func manifestTrackIds() throws -> Set<String> {
        Set(try loadManifest().tracks.keys)
    }

    /// Picks up old `{id}__*` files sitting at the Downloads root (pre-manifest builds).
    private static func reconcileManifestWithLegacyFlatFilesAtDownloadsRoot() throws {
        let root = try downloadsFolder()
        var payload = try loadManifest()
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
        )
        var dirty = false
        for url in entries where !url.hasDirectoryPath {
            let name = url.lastPathComponent
            guard name != manifestFilename else { continue }
            guard let id = legacyFlatTrackId(fromFilename: name) else { continue }
            if payload.tracks[id] == nil {
                payload.tracks[id] = name
                dirty = true
            }
        }
        if dirty {
            try saveManifest(payload)
        }
    }

    private static func legacyFlatTrackId(fromFilename filename: String) -> String? {
        let base = (filename as NSString).deletingPathExtension
        guard let range = base.range(of: legacyFlatIdSeparator) else { return nil }
        let id = String(base[..<range.lowerBound])
        return id.isEmpty ? nil : id
    }

    // MARK: - Paths / naming

    /// `{Artist}/{Album}/{orderPrefix}{Title}.{ext}`
    private static func structuredRelativePath(for track: Track, ext: String) -> String {
        let artist = sanitizedPathSegment(track.artist.isEmpty ? "Unknown Artist" : track.artist, maxLen: 96)
        let album = sanitizedPathSegment(track.albumTitle.isEmpty ? "Unknown Album" : track.albumTitle, maxLen: 96)
        let order = trackOrderingPrefix(track)
        let titleRaw = sanitizedFilenameFragment(track.title)
        let title = titleRaw.isEmpty ? "Track" : String(titleRaw.prefix(120))
        let filename = "\(order)\(title).\(ext)"
        return "\(artist)/\(album)/\(filename)"
    }

    private static func uniqueStructuredRelativePath(for track: Track, ext: String, root: URL) -> String {
        var candidate = structuredRelativePath(for: track, ext: ext)
        var dest = root.appendingPathComponent(candidate)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let titleRaw = sanitizedFilenameFragment(track.title)
            let title = titleRaw.isEmpty ? "Track" : String(titleRaw.prefix(120))
            let order = trackOrderingPrefix(track)
            candidate = "\(sanitizedPathSegment(track.artist.isEmpty ? "Unknown Artist" : track.artist, maxLen: 96))/\(sanitizedPathSegment(track.albumTitle.isEmpty ? "Unknown Album" : track.albumTitle, maxLen: 96))/\(order)\(title) (\(n)).\(ext)"
            dest = root.appendingPathComponent(candidate)
            n += 1
        }
        return candidate
    }

    private static func trackOrderingPrefix(_ track: Track) -> String {
        if track.discNumber > 1 {
            return String(format: "D%02d-%02d ", track.discNumber, track.indexNumber)
        }
        return String(format: "%02d ", max(0, track.indexNumber))
    }

    private static func sanitizedPathSegment(_ raw: String, maxLen: Int) -> String {
        let s = sanitizedFilenameFragment(raw)
        let base = s.isEmpty ? "Unknown" : s
        let bounded: String = {
            guard base.count > maxLen else { return base }
            return String(base.prefix(maxLen))
                .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        }()
        let final = sanitizedFilenameFragment(bounded)
        return final.isEmpty ? "Unknown" : final
    }

    /// Single-segment sanitizer. Replaces filesystem-hostile characters AND defangs
    /// traversal tokens (`.`, `..`, leading dots). Never returns an empty or all-dot
    /// string; callers can use the result as a single path component without containment risk.
    private static func sanitizedFilenameFragment(_ raw: String) -> String {
        let stripped = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return "" }

        let banned = CharacterSet(charactersIn: "/:\\?%*|\"<>\u{fffc}")
        var out = String(stripped.unicodeScalars.map { banned.contains($0) ? "-" : Character($0) })

        // Strip leading dots (defeats `.`, `..`, `.hidden`).
        while let f = out.first, f == "." { out.removeFirst() }
        // Trim trailing whitespace AND dots (defeats `foo..`, also Windows-unsafe trailing chars).
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " ."))

        let onlyDotsOrSpace = out.unicodeScalars.allSatisfy { $0 == "." || $0 == " " }
        if out.isEmpty || onlyDotsOrSpace { return "" }
        return out
    }

    /// Verifies that `dest` resolves inside `root` after standardization (collapses `..`,
    /// resolves symlinks, normalizes `//`). Throws if `dest` escapes `root`.
    @discardableResult
    private static func containmentCheck(dest: URL, root: URL) throws -> URL {
        let destStd = dest.standardizedFileURL.resolvingSymlinksInPath()
        let rootStd = root.standardizedFileURL.resolvingSymlinksInPath()
        var rootPath = rootStd.path
        if !rootPath.hasSuffix("/") { rootPath += "/" }
        let destPath = destStd.path
        guard destPath == rootStd.path || destPath.hasPrefix(rootPath) else {
            throw OfflineDownloadError.pathEscapesRoot
        }
        return destStd
    }

    private static func ensureParentDirectory(for fileURL: URL) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private static func cleanupEmptyParents(of dir: URL, stoppingAt root: URL) throws {
        var current = dir.standardizedFileURL
        let rootS = root.standardizedFileURL
        while current.path != rootS.path {
            guard FileManager.default.fileExists(atPath: current.path) else {
                current = current.deletingLastPathComponent()
                continue
            }
            let inner = try FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil)
            if inner.isEmpty {
                try FileManager.default.removeItem(at: current)
                current = current.deletingLastPathComponent()
            } else {
                break
            }
        }
    }

    // MARK: - Legacy Application Support

    private static func legacyCacheFolder() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false,
        )
        return base.appendingPathComponent("LyraMusic/Offline", isDirectory: true)
    }

    private static func migrateLegacyApplicationSupportCachesIfNeeded() {
        guard let legacyDir = try? legacyCacheFolder(),
              FileManager.default.fileExists(atPath: legacyDir.path),
              let destRoot = try? downloadsFolder()
        else { return }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: legacyDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
        ) else { return }

        var payload = (try? loadManifest()) ?? OfflineManifestPayload()

        for url in entries where url.pathExtension == "cache" {
            let trackId = url.deletingPathExtension().lastPathComponent
            guard !trackId.isEmpty else { continue }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            let ext = fileExtension(forMime: nil, sniffing: data)
            let rel = "_Imports/\(sanitizedPathSegment("Recovered", maxLen: 64))/\(trackId)\(legacyFlatIdSeparator)Download.\(ext)"
            let dest = destRoot.appendingPathComponent(rel)
            guard !FileManager.default.fileExists(atPath: dest.path) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            do {
                try ensureParentDirectory(for: dest)
                try data.write(to: dest, options: .atomic)
                payload.tracks[trackId] = rel
                try? FileManager.default.removeItem(at: url)
            } catch { continue }
        }

        try? saveManifest(payload)
        try? FileManager.default.removeItem(at: legacyDir)
    }

    private static func fileExtension(forMime mime: String?, sniffing data: Data?) -> String {
        if let mime {
            let lower = mime.lowercased()
            if lower.contains("flac") { return "flac" }
            if lower.contains("mpeg") || lower.contains("mp3") { return "mp3" }
            if lower.contains("mp4") || lower.contains("aac") || lower.contains("m4a") { return "m4a" }
            if lower.contains("ogg") || lower.contains("opus") || lower.contains("vorbis") { return "ogg" }
            if lower.contains("wav") { return "wav" }
            if lower.contains("webm") { return "webm" }
        }
        if let data, data.count >= 4 {
            if data.starts(with: Data([0x49, 0x44, 0x33])) { return "mp3" }
            let b0 = data[data.startIndex], b1 = data[data.index(data.startIndex, offsetBy: 1)]
            if b0 == 0xff, (b1 & 0xe0) == 0xe0 { return "mp3" }
            if data.starts(with: Data([0x66, 0x4c, 0x61, 0x43])) { return "flac" }
            if data.starts(with: Data([0x4f, 0x67, 0x67, 0x53])) { return "ogg" }
            if data.count >= 12, data.starts(with: Data([0x52, 0x49, 0x46, 0x46])) {
                let wave = data.subdata(in: 8..<12)
                if wave == Data([0x57, 0x41, 0x56, 0x45]) { return "wav" }
            }
            if data.count >= 12 {
                let ftyp = data.subdata(in: 4..<8)
                if ftyp == Data([0x66, 0x74, 0x79, 0x70]) { return "m4a" }
            }
        }
        return "audio"
    }

    private static func peekFileHead(url: URL, max: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        return (try? h.read(upToCount: max)) ?? Data()
    }

    private static func mimeType(from http: HTTPURLResponse) -> String? {
        http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Navidrome/Subsonic may return HTTP 200 with a JSON error when `f=json` was mistakenly sent on a media endpoint.
    private static func looksLikeSubsonicJSONError(_ sniff: Data) -> Bool {
        guard sniff.first == UInt8(ascii: "{") || sniff.first == UInt8(ascii: "[") else { return false }
        guard let prefix = String(data: sniff.prefix(256), encoding: .utf8)?.lowercased() else { return false }
        return prefix.contains("subsonic-response") || prefix.contains("\"status\":\"failed\"") || prefix.contains("\"status\": \"failed\"")
    }

    /// Re-reads the on-disk manifest into ``downloadedTrackIds`` (e.g. after external changes).
    func reloadDownloadedTrackIdsFromManifest() {
        downloadedTrackIds = (try? Self.manifestTrackIds()) ?? []
    }

    private func downloadToTemporary(request: URLRequest, trackId: String) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: request) { [weak self] url, response, error in
                defer {
                    Task { @MainActor in
                        self?.tearDownDownloadObservation(trackId: trackId)
                    }
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                // CFNetwork deletes the temp file when this handler returns — relocate synchronously.
                do {
                    let stable = try Self.relocateURLSessionDownloadTemp(url, trackId: trackId)
                    continuation.resume(returning: (stable, response))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            inflightDownloadTasks[trackId] = task
            downloadProgressObservations[trackId] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor in
                    self?.applyDownloadProgress(trackId: trackId, fraction: progress.fractionCompleted)
                }
            }
            task.resume()
        }
    }

    /// Moves a `URLSession` download out of `CFNetworkDownload_*.tmp` before the completion handler returns.
    private static func relocateURLSessionDownloadTemp(_ source: URL, trackId: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyraOfflineDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeId = sanitizedFilenameFragment(trackId)
        let dest = dir.appendingPathComponent("\(safeId.isEmpty ? "track" : safeId)-\(UUID().uuidString).part")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        do {
            try FileManager.default.moveItem(at: source, to: dest)
        } catch {
            try FileManager.default.copyItem(at: source, to: dest)
            try? FileManager.default.removeItem(at: source)
        }
        return dest
    }

    private func applyDownloadProgress(trackId: String, fraction: Double) {
        guard !cancelledDownloadIds.contains(trackId) else { return }
        if fraction.isNaN || fraction <= 0 {
            activeDownloads[trackId] = .indeterminate
            return
        }
        if fraction >= 1 {
            activeDownloads[trackId] = .progress(0.99)
            return
        }
        let clamped = min(max(fraction, 0), 0.99)
        let previous = lastReportedDownloadFraction[trackId] ?? -1
        guard clamped - previous >= 0.02 || previous < 0 else { return }
        lastReportedDownloadFraction[trackId] = clamped
        activeDownloads[trackId] = .progress(clamped)
    }

    private func tearDownDownloadObservation(trackId: String) {
        downloadProgressObservations.removeValue(forKey: trackId)?.invalidate()
        lastReportedDownloadFraction.removeValue(forKey: trackId)
        inflightDownloadTasks.removeValue(forKey: trackId)
    }

    func cancelDownload(trackId: String) {
        cancelledDownloadIds.insert(trackId)
        inflightDownloadTasks[trackId]?.cancel()
        tearDownDownloadObservation(trackId: trackId)
        activeDownloads.removeValue(forKey: trackId)
    }

    func cache(track: Track, remote: URL, headers: [String: String]) async throws {
        let trackId = track.id
        cancelledDownloadIds.remove(trackId)

        activeDownloads[trackId] = .indeterminate
        defer {
            tearDownDownloadObservation(trackId: trackId)
            activeDownloads.removeValue(forKey: trackId)
            cancelledDownloadIds.remove(trackId)
        }

        var req = URLRequest(url: remote)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        let tmpURL: URL
        let response: URLResponse
        do {
            (tmpURL, response) = try await downloadToTemporary(request: req, trackId: trackId)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if cancelledDownloadIds.contains(trackId) {
                throw CancellationError()
            }
            throw error
        }

        defer {
            if FileManager.default.fileExists(atPath: tmpURL.path) {
                try? FileManager.default.removeItem(at: tmpURL)
            }
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        if cancelledDownloadIds.contains(trackId) {
            throw CancellationError()
        }

        let mime = Self.mimeType(from: http)
        let sniff = try Self.peekFileHead(url: tmpURL, max: Self.sniffPrefixBytes)
        guard !sniff.isEmpty else {
            throw URLError(.zeroByteResource)
        }
        if Self.looksLikeSubsonicJSONError(sniff) {
            throw URLError(.cannotDecodeContentData)
        }

        let ext = Self.fileExtension(forMime: mime, sniffing: sniff)
        let root = try Self.downloadsFolder()
        let relative = Self.uniqueStructuredRelativePath(for: track, ext: ext, root: root)
        let candidate = root.appendingPathComponent(relative)
        let dest = try Self.containmentCheck(dest: candidate, root: root)

        try removeExistingDownload(for: track.id)

        try Self.ensureParentDirectory(for: dest)
        try Self.containmentCheck(dest: dest, root: root)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmpURL, to: dest)

        let artworkRel = await Self.cacheArtwork(for: track, headers: headers, downloadsRoot: root)

        var offlineTrack = track
        if let artworkRel {
            let localArt = root.appendingPathComponent(artworkRel)
            offlineTrack = Self.trackWithLocalArtwork(track, localURL: localArt)
        }
        let probedDuration = await LocalMediaDuration.seconds(at: dest)
        if probedDuration > 0, offlineTrack.duration <= 0 {
            offlineTrack = offlineTrack.withDuration(probedDuration)
        }

        let albumSummary = AlbumSummary(
            id: track.albumId,
            title: track.albumTitle.isEmpty ? "Album" : track.albumTitle,
            artist: track.artist,
            artworkURL: offlineTrack.artworkURL,
            trackCount: nil,
            libraryAddedDate: track.libraryAddedDate,
            genres: track.genres,
            releaseYear: track.releaseYear,
        )

        var payload = try Self.loadManifest()
        payload.tracks[track.id] = relative
        payload.records[track.id] = OfflineTrackRecord(
            track: offlineTrack,
            album: albumSummary,
            artworkRelativePath: artworkRel,
        )
        try Self.saveManifest(payload)

        downloadedTrackIds.insert(track.id)
    }

    func cachedTrack(id: String) -> Track? {
        let payload = (try? Self.loadManifest()) ?? OfflineManifestPayload()
        return payload.records[id]?.track
    }

    /// Resolves downloaded tracks when manifest records are incomplete, without scanning the full library catalog.
    func tracksMatchingDownloadedIds(catalogById: [String: Track]) -> [Track] {
        let ids = downloadedTrackIds
        guard !ids.isEmpty, let root = try? Self.downloadsFolder() else { return [] }
        let payload = (try? Self.loadManifest()) ?? OfflineManifestPayload()
        var seen = Set<String>()
        var out: [Track] = []
        out.reserveCapacity(ids.count)
        for id in ids {
            guard seen.insert(id).inserted else { continue }
            guard Self.localFileURL(trackId: id, payload: payload, root: root) != nil else { continue }
            if let track = payload.records[id]?.track {
                out.append(track)
            } else if let track = catalogById[id] {
                out.append(track)
            }
        }
        return out.sorted {
            let ac = $0.albumTitle.localizedCaseInsensitiveCompare($1.albumTitle)
            if ac != .orderedSame { return ac == .orderedAscending }
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            return $0.indexNumber < $1.indexNumber
        }
    }

    func updateCachedTrackDuration(trackId: String, duration: TimeInterval) throws {
        guard duration > 0 else { return }
        var payload = try Self.loadManifest()
        guard var record = payload.records[trackId] else { return }
        guard record.track.duration <= 0 || abs(record.track.duration - duration) > 0.5 else { return }
        record.track = record.track.withDuration(duration)
        payload.records[trackId] = record
        try Self.saveManifest(payload)
    }

    /// Backfills zero durations on existing downloads from the audio file on disk.
    func enrichCachedDurationsIfNeeded() async {
        guard let root = try? Self.downloadsFolder() else { return }
        var payload = (try? Self.loadManifest()) ?? OfflineManifestPayload()
        var dirty = false
        for (trackId, rel) in payload.tracks {
            guard var record = payload.records[trackId] else { continue }
            guard record.track.duration <= 0 else { continue }
            let fileURL = root.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let secs = await LocalMediaDuration.seconds(at: fileURL)
            guard secs > 0 else { continue }
            record.track = record.track.withDuration(secs)
            payload.records[trackId] = record
            dirty = true
        }
        if dirty {
            try? Self.saveManifest(payload)
        }
    }

    func cachedTracks() -> [Track] {
        guard let root = try? Self.downloadsFolder() else { return [] }
        let payload = (try? Self.loadManifest()) ?? OfflineManifestPayload()
        let tracks = payload.records.values.compactMap { record -> Track? in
            guard Self.localFileURL(trackId: record.track.id, payload: payload, root: root) != nil else { return nil }
            return record.track
        }
        return tracks.sorted {
            if $0.albumTitle != $1.albumTitle {
                return $0.albumTitle.localizedCaseInsensitiveCompare($1.albumTitle) == .orderedAscending
            }
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            return $0.indexNumber < $1.indexNumber
        }
    }

    func cachedTracks(forAlbumId albumId: String) -> [Track] {
        cachedTracks().filter { $0.albumId == albumId }
    }

    func cachedAlbums() -> [AlbumSummary] {
        let payload = (try? Self.loadManifest()) ?? OfflineManifestPayload()
        var byId: [String: AlbumSummary] = [:]
        for rec in payload.records.values {
            if let album = rec.album {
                byId[album.id] = album
            } else {
                let t = rec.track
                byId[t.albumId] = AlbumSummary(
                    id: t.albumId,
                    title: t.albumTitle.isEmpty ? "Album" : t.albumTitle,
                    artist: t.artist,
                    artworkURL: t.artworkURL,
                    trackCount: nil,
                    libraryAddedDate: t.libraryAddedDate,
                    genres: t.genres,
                    releaseYear: t.releaseYear,
                )
            }
        }
        return byId.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Albums with offline audio, newest file modification first (for Library → Downloaded recents).
    func recentlyDownloadedAlbums(limit: Int = 60) -> [AlbumSummary] {
        guard limit > 0, let root = try? Self.downloadsFolder() else { return [] }
        let payload = (try? Self.loadManifest()) ?? OfflineManifestPayload()
        var latestByAlbum: [String: Date] = [:]
        var albumById: [String: AlbumSummary] = [:]

        for trackId in payload.tracks.keys {
            guard let fileURL = Self.localFileURL(trackId: trackId, payload: payload, root: root) else { continue }
            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let record = payload.records[trackId]
            let track = record?.track
            let albumId = track?.albumId ?? ""
            guard !albumId.isEmpty else { continue }
            if mtime > (latestByAlbum[albumId] ?? .distantPast) {
                latestByAlbum[albumId] = mtime
            }
            if albumById[albumId] == nil {
                if let album = record?.album {
                    albumById[albumId] = album
                } else if let track {
                    albumById[albumId] = AlbumSummary(
                        id: albumId,
                        title: track.albumTitle.isEmpty ? "Album" : track.albumTitle,
                        artist: track.artist,
                        artworkURL: track.artworkURL,
                        trackCount: nil,
                        libraryAddedDate: track.libraryAddedDate,
                        genres: track.genres,
                        releaseYear: track.releaseYear,
                    )
                }
            }
        }

        return latestByAlbum
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { albumById[$0.key] }
    }

    func localArtworkURL(forTrackId trackId: String) -> URL? {
        guard let root = try? Self.downloadsFolder() else { return nil }
        let payload = (try? Self.loadManifest()) ?? OfflineManifestPayload()
        guard let rel = payload.records[trackId]?.artworkRelativePath else { return nil }
        let url = root.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func localArtworkURL(forAlbumId albumId: String) -> URL? {
        let payload = (try? Self.loadManifest()) ?? OfflineManifestPayload()
        guard let rec = payload.records.values.first(where: { $0.track.albumId == albumId }),
              let rel = rec.artworkRelativePath
        else { return nil }
        guard let root = try? Self.downloadsFolder() else { return nil }
        let url = root.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func trackWithLocalArtwork(_ track: Track, localURL: URL) -> Track {
        Track(
            id: track.id,
            title: track.title,
            albumId: track.albumId,
            albumTitle: track.albumTitle,
            artist: track.artist,
            duration: track.duration,
            discNumber: track.discNumber,
            indexNumber: track.indexNumber,
            artworkURL: localURL,
            libraryAddedDate: track.libraryAddedDate,
            genres: track.genres,
            releaseYear: track.releaseYear,
            sampleRateHz: track.sampleRateHz,
            audioChannels: track.audioChannels,
            audioCodec: track.audioCodec,
            audioBitDepth: track.audioBitDepth,
            audioBitRateKbps: track.audioBitRateKbps,
        )
    }

    private static func cacheArtwork(
        for track: Track,
        headers: [String: String],
        downloadsRoot: URL,
    ) async -> String? {
        guard let remote = track.artworkURL, remote.isFileURL == false else { return nil }
        var req = URLRequest(url: remote)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, res) = try? await URLSession.shared.data(for: req),
              let http = res as? HTTPURLResponse,
              http.statusCode == 200,
              !data.isEmpty
        else { return nil }

        let artDir = downloadsRoot.appendingPathComponent(".artwork/albums", isDirectory: true)
        try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
        let safeAlbumId = sanitizedFilenameFragment(track.albumId)
        guard !safeAlbumId.isEmpty else { return nil }
        let rel = ".artwork/albums/\(safeAlbumId).jpg"
        let dest = downloadsRoot.appendingPathComponent(rel)
        guard (try? containmentCheck(dest: dest, root: downloadsRoot)) != nil else { return nil }
        do {
            try data.write(to: dest, options: .atomic)
            return rel
        } catch {
            return nil
        }
    }

    private static func backfillRecordsIfMissing(knownTracks: [Track]) throws {
        var payload = try loadManifest()
        guard !payload.tracks.isEmpty else { return }

        let missingIds = Set(payload.tracks.keys.filter { payload.records[$0] == nil })
        guard !missingIds.isEmpty else { return }

        let catalogById = Dictionary(
            knownTracks.filter { missingIds.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first },
        )
        let root = try downloadsFolder()
        var dirty = false

        for (trackId, rel) in payload.tracks where payload.records[trackId] == nil {
            let fileURL = root.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            let baseTrack: Track
            if let known = catalogById[trackId] {
                baseTrack = known
            } else if let parsed = parseTrackFromRelativePath(trackId: trackId, relativePath: rel) {
                baseTrack = parsed
            } else {
                baseTrack = placeholderTrack(trackId: trackId, relativePath: rel)
            }

            let artRel = existingArtworkRelativePath(for: baseTrack, downloadsRoot: root)
            var offlineTrack = baseTrack
            if let artRel {
                let localArt = root.appendingPathComponent(artRel)
                offlineTrack = trackWithLocalArtwork(baseTrack, localURL: localArt)
            }
            let albumSummary = AlbumSummary(
                id: offlineTrack.albumId,
                title: offlineTrack.albumTitle.isEmpty ? "Album" : offlineTrack.albumTitle,
                artist: offlineTrack.artist,
                artworkURL: offlineTrack.artworkURL,
                trackCount: nil,
                libraryAddedDate: offlineTrack.libraryAddedDate,
                genres: offlineTrack.genres,
                releaseYear: offlineTrack.releaseYear,
            )

            payload.records[trackId] = OfflineTrackRecord(
                track: offlineTrack,
                album: albumSummary,
                artworkRelativePath: artRel,
            )
            dirty = true
        }

        if dirty {
            try saveManifest(payload)
        }
    }

    private static func existingArtworkRelativePath(for track: Track, downloadsRoot: URL) -> String? {
        let rel = ".artwork/albums/\(sanitizedFilenameFragment(track.albumId)).jpg"
        let url = downloadsRoot.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? rel : nil
    }

    private static func parseTrackFromRelativePath(trackId: String, relativePath: String) -> Track? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }

        let artist = parts[0]
        let albumTitle = parts[parts.count - 2]
        let filename = (parts.last! as NSString).deletingPathExtension
        let albumId = "offline-\(sanitizedFilenameFragment(albumTitle))"

        var discNumber = 1
        var indexNumber = 0
        var title = filename

        if filename.hasPrefix("D"), let dash = filename.firstIndex(of: "-") {
            let discPart = filename[filename.index(filename.startIndex, offsetBy: 1)..<dash]
            let rest = filename[filename.index(after: dash)...].trimmingCharacters(in: .whitespaces)
            if let d = Int(discPart), let space = rest.firstIndex(of: " ") {
                discNumber = max(1, d)
                let idxPart = String(rest[..<space])
                if let idx = Int(idxPart) { indexNumber = idx }
                title = String(rest[rest.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            }
        } else if let space = filename.firstIndex(of: " ") {
            let prefix = String(filename[..<space])
            if let idx = Int(prefix) {
                indexNumber = idx
                title = String(filename[filename.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            }
        }

        if title.isEmpty { title = "Track" }

        return Track(
            id: trackId,
            title: title,
            albumId: albumId,
            albumTitle: albumTitle,
            artist: artist,
            duration: 0,
            discNumber: discNumber,
            indexNumber: indexNumber,
            artworkURL: nil,
        )
    }

    private static func placeholderTrack(trackId: String, relativePath: String) -> Track {
        let name = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return Track(
            id: trackId,
            title: name.isEmpty ? "Downloaded Track" : name,
            albumId: "offline-\(sanitizedFilenameFragment(trackId))",
            albumTitle: "Downloads",
            artist: "Unknown Artist",
            duration: 0,
            discNumber: 1,
            indexNumber: 0,
            artworkURL: nil,
        )
    }

    func localFile(for forId: String) -> URL? {
        guard let root = try? Self.downloadsFolder() else { return nil }
        let payload = (try? Self.loadManifest()) ?? OfflineManifestPayload()
        return Self.localFileURL(trackId: forId, payload: payload, root: root)
    }

    private static func localFileURL(trackId: String, payload: OfflineManifestPayload, root: URL) -> URL? {
        if let rel = payload.tracks[trackId] {
            let u = root.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return legacyFlatFile(trackId: trackId, root: root)
    }

    private static func legacyFlatFile(trackId: String, root: URL) -> URL? {
        if legacyFlatFileByTrackId == nil {
            var map: [String: URL] = [:]
            if let urls = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles],
            ) {
                for url in urls where !url.hasDirectoryPath {
                    let name = url.lastPathComponent
                    guard let sep = name.range(of: legacyFlatIdSeparator) else { continue }
                    let id = String(name[..<sep.lowerBound])
                    map[id] = url
                }
            }
            legacyFlatFileByTrackId = map
        }
        guard let url = legacyFlatFileByTrackId?[trackId],
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    func remove(trackId: String) throws {
        try removeExistingDownload(for: trackId)
        downloadedTrackIds.remove(trackId)
    }

    private func removeExistingDownload(for forId: String) throws {
        let root = try Self.downloadsFolder()
        var payload = try Self.loadManifest()
        var dirty = false

        if let rel = payload.tracks.removeValue(forKey: forId) {
            let url = root.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                try Self.cleanupEmptyParents(of: url.deletingLastPathComponent(), stoppingAt: root)
            }
            dirty = true
        }
        if payload.records.removeValue(forKey: forId) != nil {
            dirty = true
        }

        let prefix = "\(forId)\(Self.legacyFlatIdSeparator)"
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
        )
        for url in entries where !url.hasDirectoryPath && url.lastPathComponent.hasPrefix(prefix) {
            try FileManager.default.removeItem(at: url)
            dirty = true
        }

        if dirty {
            try Self.saveManifest(payload)
        }
    }
}
