import Foundation
import Combine

/// Owns all in-flight acquisition requests for the whole app, independent of which
/// backend is active. Feature code talks only to this manager + ``AcquisitionRequest``;
/// the active ``AcquisitionProviding`` plugin is swappable at runtime.
///
/// Jobs are keyed by the backend-agnostic ``AcquisitionRequest/requestKey`` so progress
/// and completion survive navigation and plugin internals.
@MainActor
final class AcquisitionManager: ObservableObject {
    /// Active + recently-finished jobs this app issued, keyed by `requestKey`.
    @Published private(set) var jobs: [String: AcquisitionJob] = [:]
    /// Server-side queue snapshot from the active plugin (includes items started elsewhere).
    @Published private(set) var serverJobs: [AcquisitionJob] = []
    /// The currently selected backend; persisted.
    @Published var activePlugin: AcquisitionPluginKind {
        didSet {
            guard oldValue != activePlugin else { return }
            UserDefaults.standard.set(activePlugin.rawValue, forKey: Self.activeKey)
            jobs.removeAll()
            serverJobs = []
            finishedNotified.removeAll()
            objectWillChange.send()
        }
    }

    /// Called once per job when it first reaches a terminal state.
    var onJobFinished: ((AcquisitionJob) -> Void)?

    private static let activeKey = "acquisition.activePlugin"
    private var pollTask: Task<Void, Never>?
    private var finishedNotified: Set<String> = []
    /// Keys that have actually been seen in the server's queue, so a later disappearance is
    /// meaningful rather than just "not started yet". See `noteAbsentFromQueue`.
    private var observedInServerQueue: Set<String> = []
    private var absentPolls: [String: Int] = [:]
    private var unattendedPollingStartedAt: ContinuousClock.Instant?
    /// Settings → Downloads (and similar surfaces) hold this > 0 while visible so
    /// server queue progress keeps updating without a manual refresh.
    private var liveRefreshClients = 0

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.activeKey)
        if let stored, let kind = AcquisitionPluginKind(rawValue: stored) {
            activePlugin = kind
        } else {
            activePlugin = .lidarr
        }
    }

    // MARK: - Active provider

    var provider: AcquisitionProviding {
        Self.makeProvider(activePlugin)
    }

    var capabilities: AcquisitionCapabilities { provider.capabilities }
    var isConfigured: Bool { provider.isConfigured }

    static func makeProvider(_ kind: AcquisitionPluginKind) -> AcquisitionProviding {
        switch kind {
        case .lidarr: return LidarrAcquisitionPlugin()
        case .downtify: return DowntifyAcquisitionPlugin()
        case .droppedNeedle: return DroppedNeedleAcquisitionPlugin()
        }
    }

    static func capabilities(for kind: AcquisitionPluginKind) -> AcquisitionCapabilities {
        makeProvider(kind).capabilities
    }

    // MARK: - Lookups for views

    func job(forKey key: String) -> AcquisitionJob? { jobs[key] }

    func isActive(key: String) -> Bool {
        guard let j = jobs[key] else { return false }
        return !j.status.isTerminal
    }

    /// Match a tracked job to a preview/row by normalized title (rows that build their
    /// own request key may differ slightly from the resolved one).
    /// True when the active plugin's catalog includes this artist (Lidarr → MusicBrainz).
    func canRequestArtist(named name: String) async -> Bool {
        await provider.canRequestArtist(named: name)
    }

    func job(matchingTitle title: String) -> AcquisitionJob? {
        let keys = Set(LibraryTrackMatcher.normalizedTitleKeys(from: title))
        guard !keys.isEmpty else { return nil }
        return jobs.values.first { job in
            guard let t = job.title, !t.isEmpty else { return false }
            return !Set(LibraryTrackMatcher.normalizedTitleKeys(from: t)).isDisjoint(with: keys)
        }
    }

    /// Merged, de-duplicated view for the Settings activity surface: app-issued jobs
    /// first, then server-only entries not already represented.
    var displayJobs: [AcquisitionJob] {
        var out = Array(jobs.values)
        let appNativeIds = Set(out.compactMap(\.nativeId))
        for server in serverJobs where !(server.nativeId.map(appNativeIds.contains) ?? false) {
            out.append(server)
        }
        return out.sorted { lhs, rhs in
            let lActive = !lhs.status.isTerminal
            let rActive = !rhs.status.isTerminal
            if lActive != rActive { return lActive }
            if lhs.progress != rhs.progress { return lhs.progress > rhs.progress }
            return (lhs.title ?? "") < (rhs.title ?? "")
        }
    }

    // MARK: - Search

    func search(query: String) async -> [AcquisitionResult] {
        guard provider.capabilities.supportsTrackSearch, provider.isConfigured else { return [] }
        return (try? await provider.search(query: query)) ?? []
    }

    /// Release search for Discover, for plugins that request whole albums.
    ///
    /// Gated on granularity for the same reason ``search(query:)`` is gated on
    /// `supportsTrackSearch`: a track-granularity plugin answers a query through that call, and
    /// asking it for albums as well would list a release it cannot request as a unit.
    func searchAlbums(query: String) async -> [AcquisitionRelease] {
        guard provider.isConfigured, provider.capabilities.granularity == .album else { return [] }
        return await provider.searchAlbums(query: query)
    }

    func artistReleases(named name: String) async -> [AcquisitionRelease] {
        guard provider.isConfigured else { return [] }
        return await provider.artistReleases(named: name)
    }

    func upcomingAndWanted(since: Date, until: Date) async -> [AcquisitionRelease] {
        guard provider.isConfigured, provider.capabilities.supportsReleaseCatalog else { return [] }
        return await provider.upcomingAndWanted(since: since, until: until)
    }

    func artistProfile(named name: String) async -> AcquisitionArtistProfile? {
        guard provider.isConfigured else { return nil }
        return await provider.artistProfile(named: name)
    }

    func searchArtists(query: String) async -> [AcquisitionArtist] {
        guard provider.isConfigured else { return [] }
        return await provider.searchArtists(query: query)
    }

    func tracks(forRelease release: AcquisitionRelease) async -> [BrowseAlbumPreviewTrack] {
        guard provider.isConfigured else { return [] }
        return await provider.tracks(forRelease: release)
    }

    func tracks(forBrowseAlbumId albumId: String?, artist: String, title: String) async -> [BrowseAlbumPreviewTrack] {
        guard provider.isConfigured else { return [] }
        var native: String?
        var mbid: String?
        if let albumId {
            if albumId.hasPrefix("native:") {
                native = String(albumId.dropFirst("native:".count))
            } else if albumId.hasPrefix("mbid:") {
                mbid = String(albumId.dropFirst("mbid:".count))
            } else if albumId.count >= 36 {
                mbid = albumId
            } else if Int(albumId) != nil {
                native = albumId
            }
        }
        let release = AcquisitionRelease(
            id: albumId ?? "\(artist)|\(title)",
            title: title,
            artist: artist,
            releaseDate: nil,
            artworkURL: nil,
            albumType: nil,
            secondaryTypes: [],
            trackCount: nil,
            releaseGroupMBID: mbid,
            artistMBID: nil,
            nativeAlbumId: native,
            overview: nil,
            artistOverview: nil,
            artistArtworkURL: nil,
            monitored: false,
            wanted: false
        )
        let fromId = await provider.tracks(forRelease: release)
        if !fromId.isEmpty { return fromId }
        return await provider.tracks(artist: artist, albumTitle: title)
    }

    // MARK: - Enqueue

    /// The one entry point every UI call site uses.
    @discardableResult
    func enqueue(_ request: AcquisitionRequest) async -> AcquisitionEnqueueResult {
        let provider = self.provider
        guard provider.isConfigured else { return .notConfigured }
        let key = request.requestKey
        if isActive(key: key) { return .alreadyActive }

        finishedNotified.remove(key)
        // Optimistic entry so the UI flips immediately, before the first poll.
        jobs[key] = AcquisitionJob(
            id: key,
            title: request.displayTitle,
            artist: request.artist,
            albumTitle: request.albumTitle,
            status: .searching,
            progress: 0.05,
            kind: provider.kind
        )

        do {
            let nativeId = try await provider.enqueue(request) { [weak self] fraction in
                Task { @MainActor in self?.applyProgress(key: key, fraction: fraction) }
            }
            if let job = jobs[key] {
                // `.queued`, not `.downloading`, and the progress the plugin actually reported
                // rather than a floor of 0.4. The request has been placed; for an album-granularity
                // backend that means the server is only now going looking for a release. Claiming
                // a transfer that has not started is how the bar ended up parked at 100%.
                jobs[key] = AcquisitionJob(
                    id: key,
                    title: job.title,
                    artist: job.artist,
                    albumTitle: job.albumTitle,
                    status: .queued,
                    progress: job.progress,
                    message: job.message,
                    kind: provider.kind,
                    nativeId: nativeId
                )
            }
            startPollingIfNeeded()
            return .started
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            jobs[key] = AcquisitionJob(
                id: key,
                title: request.displayTitle,
                artist: request.artist,
                albumTitle: request.albumTitle,
                status: .failed,
                progress: 0,
                message: message,
                kind: provider.kind
            )
            scheduleFailedJobRemoval(key: key)
            return .failed(message)
        }
    }

    private func applyProgress(key: String, fraction: Double) {
        guard let job = jobs[key], !job.status.isTerminal else { return }
        jobs[key] = AcquisitionJob(
            id: key,
            title: job.title,
            artist: job.artist,
            albumTitle: job.albumTitle,
            // The status used to flip to `.downloading` the moment a plugin reported 1.0, which
            // for an album backend was the *request* completing, not the download. A plugin's
            // progress callback reports how far along it is, and says nothing about which phase
            // the job is in — the phase comes from the enqueue result and the server queue.
            status: job.status,
            progress: min(1, max(job.progress, fraction)),
            message: job.message,
            kind: job.kind,
            nativeId: job.nativeId,
            files: job.files
        )
    }

    private func scheduleFailedJobRemoval(key: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            self?.jobs.removeValue(forKey: key)
        }
    }

    // MARK: - Poll loop

    /// Keep polling live while a progress UI (Settings → Downloads) is on screen.
    func beginLiveRefresh() {
        liveRefreshClients += 1
        startPollingIfNeeded()
        Task { await refreshFromServer() }
    }

    func endLiveRefresh() {
        liveRefreshClients = max(0, liveRefreshClients - 1)
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.runPollLoop() }
    }

    private var hasActiveWork: Bool {
        let appActive = jobs.values.contains { !$0.status.isTerminal }
        let serverActive = serverJobs.contains { !$0.status.isTerminal }
        return appActive || serverActive
    }

    /// How long unattended polling — no progress UI on screen — is allowed to continue.
    ///
    /// This is a phone. Before, a request that Lidarr never queued left a non-terminal job in
    /// `jobs` forever, `hasActiveWork` stayed true forever, and the loop polled every 2.5s for the
    /// life of the process. The budget ends that: the job is left exactly as it is, and the next
    /// foreground (``refreshOnForeground()``) picks the thread back up.
    private static let unattendedPollBudget: Duration = .seconds(20 * 60)

    /// Unattended backoff. A download takes minutes, so there is nothing to learn from asking
    /// every second when nobody is watching a progress bar.
    private static let unattendedIntervals: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(30)]

    private var unattendedPollsSoFar = 0

    private var shouldContinuePolling: Bool {
        if liveRefreshClients > 0 { return true }
        guard hasActiveWork else { return false }
        guard let started = unattendedPollingStartedAt else { return true }
        return ContinuousClock.now - started < Self.unattendedPollBudget
    }

    private var pollInterval: Duration {
        guard liveRefreshClients == 0 else { return .seconds(1) }
        let index = min(unattendedPollsSoFar, Self.unattendedIntervals.count - 1)
        return Self.unattendedIntervals[index]
    }

    private func runPollLoop() async {
        defer {
            pollTask = nil
            unattendedPollingStartedAt = nil
            unattendedPollsSoFar = 0
        }
        while !Task.isCancelled {
            // A visible progress UI restarts the budget: someone is watching, and the loop is
            // wanted for as long as they are.
            if liveRefreshClients > 0 {
                unattendedPollingStartedAt = nil
                unattendedPollsSoFar = 0
            } else if unattendedPollingStartedAt == nil {
                unattendedPollingStartedAt = ContinuousClock.now
            }
            await refreshFromServer()
            guard shouldContinuePolling else { return }
            let interval = pollInterval
            if liveRefreshClients == 0 { unattendedPollsSoFar += 1 }
            try? await Task.sleep(for: interval)
        }
    }

    /// One refresh when the app comes back to the front, restarting the loop if there is still
    /// work. This is the cheap half of the deal made by capping ``unattendedPollBudget``: catch up
    /// when the user is actually here, rather than polling while they are not.
    func refreshOnForeground() {
        guard provider.isConfigured else { return }
        unattendedPollingStartedAt = nil
        unattendedPollsSoFar = 0
        Task { [weak self] in
            await self?.refreshFromServer()
            await MainActor.run { self?.restartPollingIfWorkRemains() }
        }
    }

    private func restartPollingIfWorkRemains() {
        guard hasActiveWork else { return }
        startPollingIfNeeded()
    }

    /// Pulls the active plugin's server-side queue and reconciles our app jobs against it.
    func refreshFromServer() async {
        let provider = self.provider
        guard provider.isConfigured else {
            if !serverJobs.isEmpty { serverJobs = [] }
            return
        }
        let snapshot = await provider.activeJobs()
        // This loop runs at 1 Hz while the Activity list is open. Reassigning unconditionally
        // republished the manager (and every view observing it) on every idle poll.
        if snapshot != serverJobs { serverJobs = snapshot }
        reconcile(with: snapshot)
        if snapshot.contains(where: { !$0.status.isTerminal }) {
            startPollingIfNeeded()
        }
    }

    private func reconcile(with snapshot: [AcquisitionJob]) {
        for (key, current) in jobs where !current.status.isTerminal {
            guard let match = bestMatch(for: current, in: snapshot) else {
                noteAbsentFromQueue(key: key, job: current)
                continue
            }
            // This job is really in the server's queue now, so a later disappearance means
            // something — see `noteAbsentFromQueue`.
            observedInServerQueue.insert(key)
            absentPolls[key] = nil
            // The server's fraction is the truth and replaces ours outright. It used to be
            // `max(current, match)`, which could only ever ratchet upwards — so the 1.0 an
            // album plugin reported on *request* permanently masked the real transfer, and the
            // bar sat at 100% from the first second. The guard above it only spared plugins
            // that report per-file progress, which is exactly the set Lidarr is not in.
            let mergedProgress = match.progress
            let merged = AcquisitionJob(
                id: key,
                title: current.title ?? match.title,
                artist: current.artist ?? match.artist,
                albumTitle: current.albumTitle ?? match.albumTitle,
                status: match.status,
                progress: mergedProgress,
                message: match.message ?? current.message,
                kind: current.kind,
                nativeId: current.nativeId ?? match.nativeId,
                files: match.files ?? current.files
            )
            guard merged != current else { continue }
            jobs[key] = merged
            if merged.status.isTerminal { finish(key: key, job: merged) }
        }
    }

    /// A job we are tracking is not in the server's queue this time round.
    ///
    /// This is the case that made a finished request look like it did nothing. A completed Lidarr
    /// download **leaves the queue** once it imports, so the app's job never saw a terminal status,
    /// `onJobFinished` never fired, and `AppModel.handleAcquisitionJobFinished` — which does the
    /// server scan and the catalog re-fetch — never ran. The track only appeared after a relaunch
    /// reloaded the library by hand.
    ///
    /// Absence alone proves nothing: before the server has found a release the job is not in the
    /// queue *yet*, and a failed grab is removed from it just like a successful one. So this only
    /// draws a conclusion once the job has actually been seen in the queue, and then asks the
    /// plugin whether files really landed rather than assuming. Two consecutive absences are
    /// required, so a row momentarily missing between queue and import is not called finished.
    private func noteAbsentFromQueue(key: String, job: AcquisitionJob) {
        guard observedInServerQueue.contains(key) else { return }
        let absences = (absentPolls[key] ?? 0) + 1
        absentPolls[key] = absences
        guard absences >= 2, !finishedNotified.contains(key) else { return }

        let provider = self.provider
        let nativeId = job.nativeId
        Task { [weak self] in
            let satisfied: Bool?
            if let nativeId {
                satisfied = await provider.isRequestSatisfied(nativeId: nativeId)
            } else {
                satisfied = nil
            }
            await MainActor.run {
                guard let self, let current = self.jobs[key], !current.status.isTerminal else { return }
                // `nil` is "the plugin can't tell". The item did leave the queue after really
                // being in it, so the optimistic reading is the right default — the catalog
                // re-fetch downstream is itself a check, and it gives up quietly if nothing
                // shows up.
                let done = satisfied ?? true
                let resolved = AcquisitionJob(
                    id: current.id,
                    title: current.title,
                    artist: current.artist,
                    albumTitle: current.albumTitle,
                    status: done ? .done : .failed,
                    progress: done ? 1 : current.progress,
                    message: done ? current.message : "The download stopped without completing.",
                    kind: current.kind,
                    nativeId: current.nativeId,
                    files: current.files
                )
                self.jobs[key] = resolved
                self.finish(key: key, job: resolved)
            }
        }
    }

    /// Fires the completion hook exactly once, then retires the row.
    private func finish(key: String, job: AcquisitionJob) {
        guard !finishedNotified.contains(key) else { return }
        finishedNotified.insert(key)
        observedInServerQueue.remove(key)
        absentPolls[key] = nil
        onJobFinished?(job)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.jobs.removeValue(forKey: key)
        }
    }

    /// Prefer native-id match, else normalized title overlap.
    private func bestMatch(for job: AcquisitionJob, in snapshot: [AcquisitionJob]) -> AcquisitionJob? {
        if let native = job.nativeId,
           let exact = snapshot.first(where: { $0.nativeId == native }) {
            return exact
        }
        guard let title = job.title, !title.isEmpty else { return nil }
        let jobKeys = Set(LibraryTrackMatcher.normalizedTitleKeys(from: title))
        return snapshot.first { entry in
            guard let et = entry.title, !et.isEmpty else { return false }
            return !Set(LibraryTrackMatcher.normalizedTitleKeys(from: et)).isDisjoint(with: jobKeys)
        }
    }
}

/// Result of an enqueue, so callers only toast success on an actual start.
enum AcquisitionEnqueueResult: Sendable {
    case notConfigured
    case alreadyActive
    case started
    case failed(String)
}
