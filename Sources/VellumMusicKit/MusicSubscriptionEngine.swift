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

    init(env: Environment) {
        self.env = env
        followed = MusicSubscriptionStore.load()
    }

    // MARK: Follow / unfollow

    func isFollowing(name: String, mbid: String? = nil) -> Bool {
        let probe = FollowedArtist(name: name, artistMBID: mbid)
        return followed.contains { $0.id == probe.id }
    }

    /// Follow an artist and immediately run a first completeness pass for them.
    func follow(name: String, mbid: String? = nil, coverURL: URL? = nil) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let artist = FollowedArtist(name: name, artistMBID: mbid, coverURL: coverURL)
        guard !followed.contains(where: { $0.id == artist.id }) else { return }
        followed.append(artist)
        persist()
        Task { await check(artistId: artist.id) }
    }

    func unfollow(name: String, mbid: String? = nil) {
        let probe = FollowedArtist(name: name, artistMBID: mbid)
        unfollow(id: probe.id)
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
        guard !isChecking, !followed.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        for artist in followed {
            await check(artistId: artist.id)
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// One artist: canonical discography → diff against the server → request what's missing.
    private func check(artistId: String) async {
        guard let artist = followed.first(where: { $0.id == artistId }) else { return }

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

        // 4. Persist what we requested + when, publish status for the UI.
        if let idx = followed.firstIndex(where: { $0.id == artistId }) {
            followed[idx].requestedReleaseIds = requested
            followed[idx].lastChecked = Date()
            persist()
        }
        statusByArtist[artistId] = statuses.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    // MARK: Summary helpers for the UI

    func missingCount(for artist: FollowedArtist) -> Int {
        (statusByArtist[artist.id] ?? []).filter { $0.state != .have }.count
    }

    private func persist() {
        MusicSubscriptionStore.save(followed)
    }
}
