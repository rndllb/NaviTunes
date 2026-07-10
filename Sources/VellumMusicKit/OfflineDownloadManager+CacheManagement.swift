import Foundation

/// Disk metrics that must not run on the main actor (Settings scroll, cache byte refresh).
enum OfflineDiskCacheMetrics {
    static func computeDownloadsFolderByteSize() -> Int64 {
        guard let root = try? OfflineDownloadManager.downloadsFolder() else { return 0 }
        return directoryByteSize(at: root)
    }

    static func computeLocalCacheUsageSummary(downloadedTrackCount: Int) -> LocalCacheUsageSummary {
        let remoteArt = ArtworkURLCache.listDiskEntries()
        let offlineArt = listOfflineArtworkEntriesFromDisk()
        let imageCacheBytes = remoteArt.reduce(Int64(0)) { $0 + $1.fileBytes }
            + offlineArt.reduce(Int64(0)) { $0 + $1.fileBytes }
        let snap = LibrarySnapshotStore.load()
        let metadataCount = snap.map { $0.albums.count + $0.playlists.count + $0.tracks.count } ?? 0
        return LocalCacheUsageSummary(
            downloadedMusicBytes: computeDownloadsFolderByteSize(),
            downloadedTrackCount: downloadedTrackCount,
            imageCacheBytes: imageCacheBytes,
            imageCacheCount: remoteArt.count + offlineArt.count,
            metadataEntryCount: metadataCount,
            metadataSavedAt: snap?.savedAt,
        )
    }

    private static func listOfflineArtworkEntriesFromDisk() -> [CachedImageEntry] {
        guard let root = try? OfflineDownloadManager.downloadsFolder() else { return [] }
        let artDir = root.appendingPathComponent(".artwork/albums", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: artDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles],
        ) else { return [] }

        return urls
            .filter { !$0.hasDirectoryPath }
            .map { url in
                let albumId = url.deletingPathExtension().lastPathComponent
                let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                return CachedImageEntry(
                    id: "offline-art:\(albumId)",
                    source: .offlineDownload,
                    title: albumId,
                    subtitle: "Offline download artwork",
                    fileBytes: bytes,
                    previewURL: url,
                    deleteToken: albumId,
                )
            }
    }

    private static func directoryByteSize(at url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }
}

extension OfflineDownloadManager {
    func cachedTrackEntries() -> [OfflineCachedTrackEntry] {
        guard let root = try? Self.downloadsFolder() else { return [] }
        let payload = (try? Self.loadManifest()) ?? OfflineManifestPayload()
        var out: [OfflineCachedTrackEntry] = []
        out.reserveCapacity(payload.tracks.count)

        for (trackId, relativePath) in payload.tracks {
            let fileURL = root.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let bytes = fileByteSize(at: fileURL)
            let record = payload.records[trackId]
            let track = record?.track ?? Self.placeholderTrack(trackId: trackId, relativePath: relativePath)
            let artURL = localArtworkURL(forTrackId: trackId) ?? (record?.artworkRelativePath.map { root.appendingPathComponent($0) })
            out.append(OfflineCachedTrackEntry(
                id: trackId,
                track: track,
                relativePath: relativePath,
                fileBytes: bytes,
                localArtworkURL: artURL,
                localFileURL: fileURL,
            ))
        }

        return out.sorted {
            let album = $0.track.albumTitle.localizedCaseInsensitiveCompare($1.track.albumTitle)
            if album != .orderedSame { return album == .orderedAscending }
            if $0.track.discNumber != $1.track.discNumber { return $0.track.discNumber < $1.track.discNumber }
            return $0.track.indexNumber < $1.track.indexNumber
        }
    }

    func listOfflineArtworkEntries() -> [CachedImageEntry] {
        guard let root = try? Self.downloadsFolder() else { return [] }
        let artDir = root.appendingPathComponent(".artwork/albums", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: artDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles],
        ) else { return [] }

        return urls
            .filter { !$0.hasDirectoryPath }
            .map { url in
                let albumId = url.deletingPathExtension().lastPathComponent
                let bytes = fileByteSize(at: url)
                return CachedImageEntry(
                    id: "offline-art:\(albumId)",
                    source: .offlineDownload,
                    title: albumId,
                    subtitle: "Offline download artwork",
                    fileBytes: bytes,
                    previewURL: url,
                    deleteToken: albumId,
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func removeOfflineArtwork(albumId: String) {
        guard let root = try? Self.downloadsFolder() else { return }
        let rel = ".artwork/albums/\(albumId).jpg"
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.removeItem(at: url)
        recalculateCacheBytes()
    }

    func clearOfflineArtworkCache() {
        guard let root = try? Self.downloadsFolder() else { return }
        let artDir = root.appendingPathComponent(".artwork", isDirectory: true)
        try? FileManager.default.removeItem(at: artDir)
        recalculateCacheBytes()
    }

    func clearAllDownloads() {
        clearQueue()
        guard let root = try? Self.downloadsFolder() else { return }
        if let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for url in entries {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? Self.saveManifest(OfflineManifestPayload())
        resetDownloadedTrackIds()
        Self.invalidateManifestCache()
        recalculateCacheBytes()
    }

    func cacheUsageSummary(imageCacheBytes: Int64, imageCacheCount: Int) -> LocalCacheUsageSummary {
        let snap = LibrarySnapshotStore.load()
        let metadataCount = snap.map { $0.albums.count + $0.playlists.count + $0.tracks.count } ?? 0
        return LocalCacheUsageSummary(
            downloadedMusicBytes: totalCacheBytes,
            downloadedTrackCount: downloadedTrackIds.count,
            imageCacheBytes: imageCacheBytes,
            imageCacheCount: imageCacheCount,
            metadataEntryCount: metadataCount,
            metadataSavedAt: snap?.savedAt,
        )
    }

    private func fileByteSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
