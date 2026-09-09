import Foundation

// MARK: - Queue persistence

extension OfflineDownloadManager {
    static func queueURL() throws -> URL {
        try downloadsFolder().appendingPathComponent(queueFilename)
    }

    static func loadQueue() throws -> [OfflineDownloadQueueItem] {
        let url = try queueURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(OfflineQueuePayload.self, from: data)
        else { return [] }
        return payload.items
    }

    private static let queueDiskWriter = CoalescingDiskWriter(label: "VellumMusic.offline.queue-write")

    /// Queue items embed full `Track` arrays, so encoding the whole queue per
    /// mutation is O(playlist size) — done on a utility queue (coalesced) so
    /// per-track completion updates don't stack JSON encodes on the main thread.
    func saveQueue() {
        let payload = OfflineQueuePayload(items: downloadQueue)
        guard let url = try? Self.queueURL() else { return }
        Self.queueDiskWriter.schedule {
            guard let data = try? JSONEncoder().encode(payload) else { return }
            CoalescingDiskWriter.writeAtomically(data, to: url)
        }
    }
}

// MARK: - Enqueue

extension OfflineDownloadManager {
    func enqueueAlbum(_ album: AlbumSummary, tracks: [Track], topUp: Bool = true) {
        let itemId = album.id
        guard !tracks.isEmpty else { return }
        let missing = tracks.filter { !downloadedTrackIds.contains($0.id) || localFile(for: $0.id) == nil }
        guard !missing.isEmpty else {
            upsertCachedItem(
                itemId: itemId,
                kind: .album,
                name: album.title,
                trackIds: tracks.map(\.id),
            )
            return
        }
        if downloadQueue.contains(where: { $0.itemId == itemId && !$0.isTerminal }) {
            return
        }
        let tracksToFetch = topUp ? missing : tracks
        upsertCachedItem(
            itemId: itemId,
            kind: .album,
            name: album.title,
            trackIds: tracks.map(\.id),
        )
        appendQueueItem(
            kind: .album,
            itemId: itemId,
            name: album.title,
            tracks: tracksToFetch,
        )
    }

    func enqueuePlaylist(_ playlist: PlaylistSummary, tracks: [Track], topUp: Bool = true) {
        let itemId = playlist.id
        guard !tracks.isEmpty else { return }
        let missing = tracks.filter { !downloadedTrackIds.contains($0.id) || localFile(for: $0.id) == nil }
        guard !missing.isEmpty else {
            upsertCachedItem(
                itemId: itemId,
                kind: .playlist,
                name: playlist.name,
                trackIds: tracks.map(\.id),
            )
            return
        }
        if downloadQueue.contains(where: { $0.itemId == itemId && !$0.isTerminal }) {
            return
        }
        upsertCachedItem(
            itemId: itemId,
            kind: .playlist,
            name: playlist.name,
            trackIds: tracks.map(\.id),
        )
        appendQueueItem(
            kind: .playlist,
            itemId: itemId,
            name: playlist.name,
            tracks: topUp ? missing : tracks,
        )
    }

    func enqueueFavorites(name: String = "Favorite Songs", tracks: [Track], topUp: Bool = true) {
        let itemId = OfflineDownloadQueueItem.favoritesItemId
        guard !tracks.isEmpty else { return }
        let missing = tracks.filter { !downloadedTrackIds.contains($0.id) || localFile(for: $0.id) == nil }
        guard !missing.isEmpty else {
            upsertCachedItem(itemId: itemId, kind: .favorites, name: name, trackIds: tracks.map(\.id))
            return
        }
        if downloadQueue.contains(where: { $0.itemId == itemId && !$0.isTerminal }) {
            return
        }
        upsertCachedItem(itemId: itemId, kind: .favorites, name: name, trackIds: tracks.map(\.id))
        appendQueueItem(
            kind: .favorites,
            itemId: itemId,
            name: name,
            tracks: topUp ? missing : tracks,
        )
    }

    func enqueueTracks(_ tracks: [Track], itemName: String? = nil) {
        for track in tracks {
            enqueueTrack(track, itemName: itemName)
        }
    }

    func enqueueTrack(_ track: Track, itemName: String? = nil) {
        guard !downloadedTrackIds.contains(track.id) || localFile(for: track.id) == nil else { return }
        if downloadQueue.contains(where: { $0.itemId == track.id && !$0.isTerminal && $0.kind == .track }) {
            return
        }
        let name = itemName ?? track.title
        appendQueueItem(kind: .track, itemId: track.id, name: name, tracks: [track])
    }

    private func appendQueueItem(
        kind: OfflineDownloadQueueItemKind,
        itemId: String,
        name: String,
        tracks: [Track],
    ) {
        guard !tracks.isEmpty else { return }
        let item = OfflineDownloadQueueItem(
            id: UUID().uuidString,
            kind: kind,
            itemId: itemId,
            name: name,
            tracks: tracks,
            status: .queued,
            completedTrackIds: [],
            addedAt: Date(),
            errorMessage: nil,
        )
        persistQueueMutation { $0.append(item) }
        kickQueueWorker()
    }

    func upsertCachedItem(
        itemId: String,
        kind: OfflineDownloadQueueItemKind,
        name: String,
        trackIds: [String],
    ) {
        guard !trackIds.isEmpty else { return }
        var payload = (try? Self.loadManifest()) ?? OfflineManifestPayload()
        let existing = payload.cachedItems[itemId]
        payload.cachedItems[itemId] = OfflineCachedItemRecord(
            kind: kind,
            name: name,
            trackIds: trackIds,
            addedAt: existing?.addedAt ?? Date(),
        )
        try? Self.saveManifest(payload)
    }
}

// MARK: - Queue control

extension OfflineDownloadManager {
    func cancelQueueItem(id: String) {
        persistQueueMutation { items in
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
            for track in items[idx].pendingTracks {
                cancelDownload(trackId: track.id)
            }
            items.remove(at: idx)
        }
        kickQueueWorker()
    }

    func retryQueueItem(id: String) {
        persistQueueMutation { items in
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
            items[idx].status = .queued
            items[idx].errorMessage = nil
            // Give previously failed tracks another chance.
            items[idx].failedTrackIds = nil
        }
        kickQueueWorker()
    }

    func clearCompletedQueueItems() {
        persistQueueMutation { $0.removeAll { $0.status == .complete } }
    }

    func clearQueue() {
        for item in downloadQueue where !item.isTerminal {
            for track in item.pendingTracks {
                cancelDownload(trackId: track.id)
            }
        }
        downloadQueue = []
        saveQueue()
        activeQueueTrackIds.removeAll()
    }

    func reorderQueue(fromOffsets: IndexSet, toOffset: Int) {
        persistQueueMutation { $0.move(fromOffsets: fromOffsets, toOffset: toOffset) }
    }

    func recoverStalledDownloads() {
        persistQueueMutation { items in
            for idx in items.indices {
                if items[idx].status == .downloading {
                    items[idx].status = .queued
                }
            }
        }
        activeQueueTrackIds.removeAll()
        kickQueueWorker()
    }
}

// MARK: - Worker

extension OfflineDownloadManager {
    private struct QueueWorkSlot {
        let queueItemId: String
        let track: Track
    }

    func kickQueueWorker() {
        guard queueWorkerTask == nil || queueWorkerTask?.isCancelled == true else { return }
        queueWorkerTask = Task { @MainActor in
            await runQueueWorker()
            queueWorkerTask = nil
        }
    }

    private func runQueueWorker() async {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        defer { isProcessingQueue = false }

        while !Task.isCancelled {
            if await evaluateQueuePause() {
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            let slots = pendingWorkSlots(limit: maxConcurrentDownloads.rawValue)
            guard !slots.isEmpty else { break }

            await withTaskGroup(of: Void.self) { group in
                for slot in slots {
                    activeQueueTrackIds.insert(slot.track.id)
                    markQueueItemDownloading(queueItemId: slot.queueItemId)
                    group.addTask { @MainActor in
                        await self.downloadQueueTrack(slot.track, queueItemId: slot.queueItemId)
                        self.activeQueueTrackIds.remove(slot.track.id)
                    }
                }
            }
        }

        // One full reconciliation when the queue drains — per-track completions
        // only bump the byte total incrementally (see `cache`).
        recalculateCacheBytes()

        if downloadQueue.contains(where: { $0.status == .queued || $0.status == .downloading }) {
            kickQueueWorker()
        }
    }

    private func pendingWorkSlots(limit: Int) -> [QueueWorkSlot] {
        var slots: [QueueWorkSlot] = []
        var reserved = activeQueueTrackIds
        for item in downloadQueue where item.status == .queued || item.status == .downloading {
            for track in item.tracks {
                guard slots.count < limit else { return slots }
                guard !item.completedTrackIds.contains(track.id) else { continue }
                guard !item.failedIds.contains(track.id) else { continue }
                guard !reserved.contains(track.id) else { continue }
                if downloadedTrackIds.contains(track.id), localFile(for: track.id) != nil {
                    markTrackCompleteInQueue(queueItemId: item.id, trackId: track.id)
                    continue
                }
                reserved.insert(track.id)
                slots.append(QueueWorkSlot(queueItemId: item.id, track: track))
            }
            if item.pendingTracks.isEmpty {
                markQueueItemComplete(queueItemId: item.id)
            }
        }
        return slots
    }

    private func evaluateQueuePause() async -> Bool {
        let policy = networkPolicy()
        if wifiOnlyDownloads, policy.online, !policy.wifiLike {
            isQueuePaused = true
            queuePauseReason = "Downloads paused on cellular. Connect to Wi‑Fi or allow cellular downloads in Settings."
            return true
        }
        if isStorageLimitReached(additionalBytes: 0) {
            isStorageFull = true
            isQueuePaused = true
            queuePauseReason = "Storage limit reached. Free space or raise the cap in Settings."
            return true
        }
        isQueuePaused = false
        isStorageFull = false
        queuePauseReason = nil
        return false
    }

    private func downloadQueueTrack(_ track: Track, queueItemId: String) async {
        guard let lib = libraryProvider?() else {
            markQueueItemError(queueItemId: queueItemId, message: "Not signed in")
            return
        }
        do {
            let url = try lib.offlineDownloadURL(for: track)
            try await cache(
                track: track,
                remote: url,
                headers: lib.httpHeadersForMediaRequests(),
            )
            markTrackCompleteInQueue(queueItemId: queueItemId, trackId: track.id)
        } catch is CancellationError {
            return
        } catch {
            // One bad track must not abort the rest of the playlist/album — record
            // it and keep the item going; Retry re-attempts just the failures.
            markTrackFailedInQueue(
                queueItemId: queueItemId,
                trackId: track.id,
                message: error.localizedDescription,
            )
        }
    }

    private func markQueueItemDownloading(queueItemId: String) {
        persistQueueMutation { items in
            guard let idx = items.firstIndex(where: { $0.id == queueItemId }) else { return }
            if items[idx].status == .queued {
                items[idx].status = .downloading
            }
        }
    }

    private func markTrackCompleteInQueue(queueItemId: String, trackId: String) {
        persistQueueMutation { items in
            guard let idx = items.firstIndex(where: { $0.id == queueItemId }) else { return }
            items[idx].completedTrackIds.insert(trackId)
            Self.finalizeQueueItemIfDrained(&items[idx])
        }
    }

    private func markTrackFailedInQueue(queueItemId: String, trackId: String, message: String) {
        persistQueueMutation { items in
            guard let idx = items.firstIndex(where: { $0.id == queueItemId }) else { return }
            var failed = items[idx].failedIds
            failed.insert(trackId)
            items[idx].failedTrackIds = failed
            items[idx].errorMessage = message
            Self.finalizeQueueItemIfDrained(&items[idx])
        }
    }

    private func markQueueItemComplete(queueItemId: String) {
        persistQueueMutation { items in
            guard let idx = items.firstIndex(where: { $0.id == queueItemId }) else { return }
            Self.finalizeQueueItemIfDrained(&items[idx])
        }
    }

    /// All tracks accounted for (completed or failed) → settle the item's terminal
    /// state. Clean run = `.complete`; any failures = `.error` with a count so the
    /// queue UI's Retry can re-attempt just the failed tracks.
    private static func finalizeQueueItemIfDrained(_ item: inout OfflineDownloadQueueItem) {
        guard item.pendingTracks.isEmpty else { return }
        let failedCount = item.failedIds.count
        if failedCount == 0 {
            item.status = .complete
            item.errorMessage = nil
        } else {
            item.status = .error
            item.errorMessage = failedCount == 1
                ? "1 track failed to download."
                : "\(failedCount) tracks failed to download."
        }
    }

    private func markQueueItemError(queueItemId: String, message: String) {
        persistQueueMutation { items in
            guard let idx = items.firstIndex(where: { $0.id == queueItemId }) else { return }
            items[idx].status = .error
            items[idx].errorMessage = message
        }
    }
}

// MARK: - Storage

extension OfflineDownloadManager {
    private static var cacheByteRecalculationGeneration: UInt = 0

    func recalculateCacheBytes() {
        Self.cacheByteRecalculationGeneration &+= 1
        let generation = Self.cacheByteRecalculationGeneration
        Task {
            let bytes = await Task.detached(priority: .utility) {
                OfflineDiskCacheMetrics.computeDownloadsFolderByteSize()
            }.value
            guard !Task.isCancelled, generation == Self.cacheByteRecalculationGeneration else { return }
            totalCacheBytes = bytes
            isStorageFull = isStorageLimitReached(additionalBytes: 0)
        }
    }

    func isStorageLimitReached(additionalBytes: Int64) -> Bool {
        guard storageLimitMode == .fixed, maxCacheSizeGB > 0 else { return false }
        let budget = Int64(maxCacheSizeGB * 1024 * 1024 * 1024)
        return totalCacheBytes + additionalBytes >= budget
    }

    func availableBudgetBytes() -> Int64? {
        guard storageLimitMode == .fixed, maxCacheSizeGB > 0 else { return nil }
        let budget = Int64(maxCacheSizeGB * 1024 * 1024 * 1024)
        return max(0, budget - totalCacheBytes)
    }
}

// MARK: - Offline search

extension OfflineDownloadManager {
    func searchCachedCatalog(query: String, limit: Int = 30) -> CatalogSearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return .empty }
        let tracks = cachedTracks()
        var albums: [AlbumSummary] = []
        var albumIds = Set<String>()
        var songs: [Track] = []
        var artists: [LibraryArtistSummary] = []
        var artistKeys = Set<String>()

        for track in tracks {
            let hay = "\(track.title) \(track.artist) \(track.albumTitle)".lowercased()
            guard hay.contains(q) else { continue }
            songs.append(track)
            if !albumIds.contains(track.albumId) {
                albumIds.insert(track.albumId)
                albums.append(AlbumSummary(
                    id: track.albumId,
                    title: track.albumTitle.isEmpty ? "Album" : track.albumTitle,
                    artist: track.artist,
                    artworkURL: track.artworkURL,
                    trackCount: nil,
                    libraryAddedDate: track.libraryAddedDate,
                    genres: track.genres,
                    releaseYear: track.releaseYear,
                ))
            }
            let artistKey = track.artist.lowercased()
            if !artistKey.isEmpty, !artistKeys.contains(artistKey) {
                artistKeys.insert(artistKey)
                artists.append(LibraryArtistSummary(
                    id: artistKey,
                    name: track.artist,
                    artworkURL: nil,
                ))
            }
            if songs.count >= limit, albums.count >= limit, artists.count >= limit { break }
        }

        return CatalogSearchResults(
            songs: Array(songs.prefix(limit)),
            albums: Array(albums.prefix(limit)),
            artists: Array(artists.prefix(limit)),
        )
    }
}
