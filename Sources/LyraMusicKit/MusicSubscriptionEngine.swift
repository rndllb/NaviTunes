import Combine
import Foundation

/// The "follow an artist → keep my collection complete" brain — the piece Lidarr owns
/// when it's present, that Lyra supplies itself when it isn't.
///
/// Design: the brain lives here (in the app), and every backend is an *optional
/// accelerator*. The only hard dependency is the always-available iTunes catalog,
/// which yields the canonical discography. From there:
///   • "have it?"  → matched against the connected server catalog (any backend)
///   • "get it"    → handed to whatever acquisition plugin is active (if any)
/// With no acquisition plugin configured (or a track-only one that can't fetch whole
/// albums), missing releases degrade gracefully to a wishlist (`.pending`) instead of
/// disabling the feature.
@MainActor
final class MusicSubscriptionEngine: ObservableObject {
    /// Injected hooks so the engine stays decoupled from `AppModel` (and unit-testable).
    /// All closures are main-actor isolated — both this engine and `AppModel` are `@MainActor`.
    struct Environment {
        var serverAlbumsForArtist: (_ name: String) async -> [AlbumSummary]
        var enqueue: (_ request: AcquisitionRequest) async -> AcquisitionEnqueueResult
        var isAcquisitionConfigured: () -> Bool
        var acquisitionGranularity: () -> AcquisitionCapabilities.Granularity
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
            // Light spacing between artists to stay friendly to the iTunes API.
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// One artist: canonical discography → diff against the server → request what's missing.
    private func check(artistId: String) async {
        guard let artist = followed.first(where: { $0.id == artistId }) else { return }

        // 1. Canonical discography — from iTunes (Apple's catalog).
        let releases = await ITunesArtistClient.discography(forArtist: artist.name)
        // Only full-length albums and EPs are auto-maintained; singles/live/comps are noisy.
        // iTunes lumps singles + EPs together, so distinguish EPs by track count (≥ 4).
        let maintained = releases.filter {
            $0.bucket == .albums || ($0.bucket == .singlesAndEPs && ($0.trackCount ?? 0) >= 4)
        }

        // 2. "Have it?" — match against whatever library backend is connected.
        let serverAlbums = await env.serverAlbumsForArtist(artist.name)
        let haveTitles = Set(serverAlbums.map { LibraryTrackMatcher.normalize($0.title) })

        // 3. Classify + request missing through the active plugin (graceful when absent).
        let configured = env.isAcquisitionConfigured()
        let canFetchAlbums = configured && env.acquisitionGranularity() == .album
        var requested = artist.requestedReleaseIds
        var statuses: [SubscriptionReleaseStatus] = []

        for release in maintained {
            let titleKey = LibraryTrackMatcher.normalize(release.title)
            if haveTitles.contains(titleKey) {
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
            // Lidarr resolves by artist + album text (it does its own MusicBrainz lookup).
            let request = AcquisitionRequest(
                artist: artist.name,
                albumTitle: release.title,
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
