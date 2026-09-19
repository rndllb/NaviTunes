import Foundation

struct PendingScrobble: Identifiable, Codable, Equatable {
    var id: UUID
    var trackId: String
    var title: String
    var artist: String
    var albumId: String?
    var playlistId: String?
    var timestamp: Date

    init(
        id: UUID = UUID(),
        track: Track,
        playlistId: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.trackId = track.id
        self.title = track.title
        self.artist = track.artist
        self.albumId = track.albumId.isEmpty ? nil : track.albumId
        self.playlistId = playlistId
        self.timestamp = timestamp
    }
}

struct CompletedScrobble: Identifiable, Codable, Equatable {
    var id: UUID
    var trackId: String
    var title: String
    var artist: String
    var timestamp: Date

    init(id: UUID = UUID(), track: Track, timestamp: Date = Date()) {
        self.id = id
        self.trackId = track.id
        self.title = track.title
        self.artist = track.artist
        self.timestamp = timestamp
    }

    init(id: UUID = UUID(), trackId: String, title: String, artist: String, timestamp: Date) {
        self.id = id
        self.trackId = trackId
        self.title = title
        self.artist = artist
        self.timestamp = timestamp
    }
}

struct ScrobbleExclusion: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case album
        case artist
        case playlist
    }

    var id: String
    var kind: Kind
    var name: String
}

@MainActor
final class ScrobbleStore: ObservableObject {
    @Published private(set) var pending: [PendingScrobble] = []
    @Published private(set) var completed: [CompletedScrobble] = []
    @Published private(set) var exclusions: [ScrobbleExclusion] = []

    /// Every completed scrobble ever recorded, counted rather than stored.
    ///
    /// `completed` is capped at 500 so the defaults blob stays small, which meant "Total plays"
    /// — `completed.count` — silently stopped climbing at 500 and reported a cap as a lifetime
    /// figure. This counter is incremented at the same moments the array is appended to, so it
    /// keeps counting after the array starts dropping its tail.
    ///
    /// It is exact from the build that introduced it onward. For a library that already trimmed
    /// history before then it is a floor, not a recovered total — there is no way back to plays
    /// that were discarded. Seeded from the surviving array on first run so it starts at the
    /// best number available rather than at zero.
    @Published private(set) var lifetimeCompletedCount: Int = 0

    private static let pendingKey = "vellumPendingScrobbles"
    private static let completedKey = "vellumCompletedScrobbles"
    private static let exclusionsKey = "vellumScrobbleExclusions"
    private static let lifetimeCompletedKey = "vellumLifetimeCompletedScrobbleCount"
    private static let completedCap = 500

    init() {
        pending = Self.load(Self.pendingKey, as: [PendingScrobble].self) ?? []
        completed = Self.load(Self.completedKey, as: [CompletedScrobble].self) ?? []
        exclusions = Self.load(Self.exclusionsKey, as: [ScrobbleExclusion].self) ?? []
        // `object(forKey:)` rather than `integer(forKey:)` — the latter cannot tell "absent"
        // from a stored 0, and absent is what the seed-from-array case has to detect.
        if let stored = UserDefaults.standard.object(forKey: Self.lifetimeCompletedKey) as? Int {
            lifetimeCompletedCount = max(stored, completed.count)
        } else {
            lifetimeCompletedCount = completed.count
        }
        persistLifetimeCompletedCount()
    }

    private func persistLifetimeCompletedCount() {
        UserDefaults.standard.set(lifetimeCompletedCount, forKey: Self.lifetimeCompletedKey)
    }

    func addPending(_ item: PendingScrobble) {
        pending.append(item)
        persistPending()
    }

    func removePending(id: UUID) {
        pending.removeAll { $0.id == id }
        persistPending()
    }

    func recordCompleted(_ item: CompletedScrobble) {
        completed.insert(item, at: 0)
        lifetimeCompletedCount += 1
        persistLifetimeCompletedCount()
        if completed.count > Self.completedCap {
            completed = Array(completed.prefix(Self.completedCap))
        }
        persistCompleted()
    }

    func addExclusion(_ exclusion: ScrobbleExclusion) {
        guard !exclusions.contains(where: { $0.id == exclusion.id && $0.kind == exclusion.kind }) else { return }
        exclusions.append(exclusion)
        persistExclusions()
    }

    func removeExclusion(id: String, kind: ScrobbleExclusion.Kind) {
        exclusions.removeAll { $0.id == id && $0.kind == kind }
        persistExclusions()
    }

    /// Restore-from-backup. The imported array is the only evidence of its own size, so the
    /// lifetime count is raised to it where it is larger — never lowered, since a restore must
    /// not erase plays this install already counted past the cap.
    func replaceCompleted(_ items: [CompletedScrobble]) {
        completed = Array(items.prefix(Self.completedCap))
        lifetimeCompletedCount = max(lifetimeCompletedCount, items.count)
        persistLifetimeCompletedCount()
        persistCompleted()
    }

    func replaceExclusions(_ items: [ScrobbleExclusion]) {
        exclusions = items
        persistExclusions()
    }

    func mergeCompleted(_ items: [CompletedScrobble]) -> (inserted: Int, skipped: Int) {
        var inserted = 0
        var skipped = 0
        let existing = Set(completed.map { "\($0.trackId)|\($0.timestamp.timeIntervalSince1970)" })
        for item in items {
            let key = "\(item.trackId)|\(item.timestamp.timeIntervalSince1970)"
            if existing.contains(key) || completed.contains(where: { $0.id == item.id }) {
                skipped += 1
                continue
            }
            completed.insert(item, at: 0)
            inserted += 1
        }
        lifetimeCompletedCount += inserted
        persistLifetimeCompletedCount()
        if completed.count > Self.completedCap {
            completed = Array(completed.prefix(Self.completedCap))
        }
        persistCompleted()
        return (inserted, skipped)
    }

    func mergeExclusions(_ items: [ScrobbleExclusion]) -> (inserted: Int, skipped: Int) {
        var inserted = 0
        var skipped = 0
        for item in items {
            if exclusions.contains(where: { $0.id == item.id && $0.kind == item.kind }) {
                skipped += 1
                continue
            }
            exclusions.append(item)
            inserted += 1
        }
        persistExclusions()
        return (inserted, skipped)
    }

    func isExcluded(track: Track, playlistId: String?) -> Bool {
        if !track.albumId.isEmpty, exclusions.contains(where: { $0.kind == .album && $0.id == track.albumId }) {
            return true
        }
        if let playlistId, exclusions.contains(where: { $0.kind == .playlist && $0.id == playlistId }) {
            return true
        }
        return false
    }

    private func persistPending() {
        Self.save(pending, key: Self.pendingKey)
    }

    private func persistCompleted() {
        Self.save(completed, key: Self.completedKey)
    }

    private func persistExclusions() {
        Self.save(exclusions, key: Self.exclusionsKey)
    }

    private static func load<T: Decodable>(_ key: String, as: T.Type) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

@MainActor
final class ScrobbleService {
    let store = ScrobbleStore()
    private weak var app: AppModel?
    private var processTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    func bind(app: AppModel) {
        self.app = app
        startPeriodicProcessing()
        Task { await processPendingScrobbles() }
    }

    func sendNowPlaying(track: Track, source: PlaybackSource?) {
        guard let app, !app.effectiveOfflineMode, !track.isInternetRadioStream else { return }
        let playlistId = sourcePlaylistId(source)
        guard !store.isExcluded(track: track, playlistId: playlistId) else { return }
        guard let lib = app.activeLibrary else { return }
        Task {
            try? await lib.reportNowPlaying(trackId: track.id)
        }
    }

    func recordCompletedScrobble(track: Track, source: PlaybackSource?) {
        guard let app, !track.isInternetRadioStream else { return }
        let playlistId = sourcePlaylistId(source)
        guard !store.isExcluded(track: track, playlistId: playlistId) else { return }
        let pending = PendingScrobble(track: track, playlistId: playlistId)
        store.addPending(pending)
        Task { await processPendingScrobbles() }
    }

    func excludeAlbum(_ album: AlbumSummary) {
        store.addExclusion(ScrobbleExclusion(id: album.id, kind: .album, name: album.title))
    }

    func excludeArtist(_ artist: LibraryArtistSummary) {
        store.addExclusion(ScrobbleExclusion(id: artist.id, kind: .artist, name: artist.name))
    }

    func excludePlaylist(_ playlist: PlaylistSummary) {
        store.addExclusion(ScrobbleExclusion(id: playlist.id, kind: .playlist, name: playlist.name))
    }

    func onNetworkRestored() {
        Task { await processPendingScrobbles() }
    }

    private func sourcePlaylistId(_ source: PlaybackSource?) -> String? {
        guard case .playlist(let summary) = source else { return nil }
        return summary.id
    }

    private func startPeriodicProcessing() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.processPendingScrobbles()
            }
        }
    }

    func processPendingScrobbles() async {
        guard processTask == nil else { return }
        guard let app, let lib = app.activeLibrary, !app.effectiveOfflineMode else { return }
        processTask = Task { @MainActor in
            defer { processTask = nil }
            let queue = store.pending
            for item in queue {
                if Task.isCancelled { return }
                do {
                    try await lib.submitScrobble(trackId: item.trackId, timestamp: item.timestamp)
                    store.removePending(id: item.id)
                    store.recordCompleted(
                        CompletedScrobble(
                            trackId: item.trackId,
                            title: item.title,
                            artist: item.artist,
                            timestamp: item.timestamp
                        )
                    )
                } catch {
                    continue
                }
            }
        }
        await processTask?.value
    }
}
