import Combine
import Foundation

/// The "follow an artist → keep my collection complete" brain — the piece Lidarr owns
/// when it's present, that Vellum supplies itself when it isn't.
///
/// Design: the brain lives here (in the app). Canonical discography comes from
/// the active acquisition plugin (Lidarr library, or DroppedNeedle search).
///   • "have it?"  → matched against the connected server catalog (any backend)
///   • "get it"    → handed to whatever acquisition plugin is active (if any)
/// With no catalog plugin configured, completeness is server-only (have vs wishlist).
@MainActor
final class MusicSubscriptionEngine: ObservableObject {
    /// Injected hooks so the engine stays decoupled from `AppModel` (and unit-testable).
    /// All closures are main-actor isolated — both this engine and `AppModel` are `@MainActor`.
    struct Environment {
        var serverAlbumsForArtist: (_ name: String) async -> [AlbumSummary]
        var enqueue: (_ request: AcquisitionRequest) async -> AcquisitionEnqueueResult
        var isAcquisitionConfigured: () -> Bool
        var acquisitionGranularity: () -> AcquisitionCapabilities.Granularity
        var artistReleases: (_ name: String) async -> [AcquisitionRelease]
    }

    @Published private(set) var followed: [FollowedArtist] = []
    /// Last-pass per-release status, keyed by `FollowedArtist.id`. Drives the Subscriptions UI.
    @Published private(set) var statusByArtist: [String: [SubscriptionReleaseStatus]] = [:]
    @Published private(set) var isChecking = false

    private let env: Environment
    private let persistence: MusicSubscriptionPersistence
    /// Artists with a pass running, so a follow's first pass and a "check now" can't both
    /// request the same missing album.
    private var checking: Set<String> = []

    init(env: Environment, persistence: MusicSubscriptionPersistence = .disk) {
        self.env = env
        self.persistence = persistence
        followed = persistence.load()
        for artist in followed {
            if let statuses = artist.lastStatuses { statusByArtist[artist.id] = statuses }
        }
    }

    // MARK: Follow / unfollow

    func isFollowing(name: String, mbid: String? = nil) -> Bool {
        followed.contains { $0.matches(name: name, mbid: mbid) }
    }

    /// Follow an artist and immediately run a first completeness pass for them. Returns that
    /// pass, so a caller that needs it finished can await it; `nil` when nothing was started.
    ///
    /// Following an artist already followed by name, now with their MBID, records the MBID on
    /// the existing follow instead of adding a second one.
    @discardableResult
    func follow(name: String, mbid: String? = nil, coverURL: URL? = nil) -> Task<Void, Never>? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let index = followed.firstIndex(where: { $0.matches(name: name, mbid: mbid) }) {
            guard let mbid, followed[index].artistMBID == nil else { return nil }
            let oldId = followed[index].id
            followed[index].artistMBID = mbid
            if followed[index].coverURL == nil { followed[index].coverURL = coverURL }
            statusByArtist[followed[index].id] = statusByArtist.removeValue(forKey: oldId)
            persist()
            return nil
        }
        let artist = FollowedArtist(name: name, artistMBID: mbid, coverURL: coverURL)
        followed.append(artist)
        persist()
        return Task { await check(artistId: artist.id) }
    }

    func unfollow(name: String, mbid: String? = nil) {
        for artist in followed where artist.matches(name: name, mbid: mbid) {
            unfollow(id: artist.id)
        }
    }

    func unfollow(id: String) {
        followed.removeAll { $0.id == id }
        statusByArtist[id] = nil
        persist()
    }

    func toggle(name: String, mbid: String? = nil, coverURL: URL? = nil) {
        if isFollowing(name: name, mbid: mbid) {
            unfollow(name: name, mbid: mbid)
        } else {
            follow(name: name, mbid: mbid, coverURL: coverURL)
        }
    }

    // MARK: The completeness pass

    /// Re-check every followed artist. Safe to call on foreground / library refresh / manually.
    func checkAll() async {
        await check(followed.map(\.id))
    }

    /// The automatic pass: re-check only artists not checked within `interval`, so coming back
    /// to the app notices a followed artist's new release without re-asking about everyone on
    /// every foreground.
    func checkStale(olderThan interval: TimeInterval, now: Date = Date()) async {
        let due = followed.filter { artist in
            guard let last = artist.lastChecked else { return true }
            return now.timeIntervalSince(last) >= interval
        }
        await check(due.map(\.id))
    }

    private func check(_ ids: [String]) async {
        guard !isChecking, !ids.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        for (index, id) in ids.enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(150)) }
            await check(artistId: id)
        }
    }

    /// One artist: canonical discography → diff against the server → request what's missing.
    private func check(artistId: String) async {
        guard let artist = followed.first(where: { $0.id == artistId }),
              checking.insert(artistId).inserted
        else { return }
        defer { checking.remove(artistId) }

        // 1. Canonical discography — from the active plugin (Lidarr / DroppedNeedle).
        let releases = await env.artistReleases(artist.name)
        let maintained = releases.filter {
            $0.bucket == .albums || ($0.bucket == .singlesAndEPs && ($0.trackCount ?? 0) >= 4)
        }

        // 2. "Have it?" — match against whatever library backend is connected.
        let serverAlbums = await env.serverAlbumsForArtist(artist.name)
        let haveTitles = Set(serverAlbums.flatMap { AlbumSummary.discographyTitleKeys(for: $0.title) })

        // 3. Classify + request missing through the active plugin (graceful when absent).
        let configured = env.isAcquisitionConfigured()
        let canFetchAlbums = configured && env.acquisitionGranularity() == .album
        var requested = artist.requestedReleaseIds
        var statuses: [SubscriptionReleaseStatus] = []

        if maintained.isEmpty {
            statuses = serverAlbums.map { album in
                SubscriptionReleaseStatus(
                    id: album.id,
                    title: album.title,
                    year: album.releaseYear,
                    coverURL: album.artworkURL,
                    state: .have
                )
            }
        }

        for release in maintained {
            let remoteKeys = Set(AlbumSummary.discographyTitleKeys(for: release.title))
            if !remoteKeys.isDisjoint(with: haveTitles) {
                statuses.append(.init(id: release.id, title: release.title,
                                      year: release.releaseYear, coverURL: release.artworkURL, state: .have))
                continue
            }
            if requested.contains(release.id) {
                statuses.append(.init(id: release.id, title: release.title,
                                      year: release.releaseYear, coverURL: release.artworkURL, state: .requested))
                continue
            }
            guard canFetchAlbums else {
                // No fetcher (or a track-only plugin that can't pull whole albums): wishlist it.
                statuses.append(.init(id: release.id, title: release.title,
                                      year: release.releaseYear, coverURL: release.artworkURL, state: .pending))
                continue
            }
            let request = AcquisitionRequest(
                artist: artist.name,
                albumTitle: release.title,
                artistMBID: release.artistMBID ?? artist.artistMBID,
                releaseGroupMBID: release.releaseGroupMBID,
                coverURL: release.artworkURL
            )
            let result = await env.enqueue(request)
            switch result {
            case .started, .alreadyActive:
                requested.insert(release.id)
                statuses.append(.init(id: release.id, title: release.title,
                                      year: release.releaseYear, coverURL: release.artworkURL, state: .requested))
            case .notConfigured, .failed:
                statuses.append(.init(id: release.id, title: release.title,
                                      year: release.releaseYear, coverURL: release.artworkURL, state: .pending))
            }
        }

        // 4. Persist what we requested, when, and what we found; publish status for the UI.
        let sorted = statuses.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        if let idx = followed.firstIndex(where: { $0.id == artistId }) {
            followed[idx].requestedReleaseIds = requested
            followed[idx].lastChecked = Date()
            followed[idx].lastStatuses = sorted
            persist()
        }
        statusByArtist[artistId] = sorted
    }

    // MARK: Summary helpers for the UI

    func missingCount(for artist: FollowedArtist) -> Int {
        (statusByArtist[artist.id] ?? []).filter { $0.state != .have }.count
    }

    private func persist() {
        persistence.save(followed)
    }
}
