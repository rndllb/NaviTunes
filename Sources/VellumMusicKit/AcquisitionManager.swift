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
    /// Requests whose plugin answers ``AcquisitionProviding/requestState(for:)``. For these the
    /// backend is the only source of state and the queue-snapshot inference is skipped entirely.
    private var backendAuthoritativeKeys: Set<String> = []
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
            // Sort-only comparison. A job with no reported fraction sorts last among active ones;
            // this never reaches the screen as a value.
            if lhs.progress != rhs.progress { return (lhs.progress ?? -1) > (rhs.progress ?? -1) }
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
        backendAuthoritativeKeys.remove(key)
        // Optimistic about the *phase* only. `progress: nil` because nothing has been measured —
        // the request is still being placed.
        jobs[key] = AcquisitionJob(
            id: key,
            title: request.displayTitle,
            artist: request.artist,
            albumTitle: request.albumTitle,
            status: .searching,
            progress: nil,
            kind: provider.kind
        )

        do {
            let nativeId = try await provider.enqueue(request)
            if let job = jobs[key] {
                // Still `.searching` and still no fraction. All the enqueue proved is that the
                // server accepted the request; whether anything is downloading is a question only
                // the server can answer, and the very next poll asks it.
                jobs[key] = AcquisitionJob(
                    id: key,
                    title: job.title,
                    artist: job.artist,
                    albumTitle: job.albumTitle,
                    status: .searching,
                    progress: nil,
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
                progress: nil,
                message: message,
                kind: provider.kind
            )
            scheduleFailedJobRemoval(key: key)
            return .failed(message)
        }
    }

    // `applyProgress(key:fraction:)` used to live here: the manager's own setter for a job's
    // fraction, fed by the enqueue progress callback. Both are gone. Nothing in the manager can
    // write a progress value any more — the only writes are whole `AcquisitionJob`s built from a
    // plugin's reading of its server.

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
        // Ask the backend about our own requests first, so its answer wins over anything the
        // snapshot-shaped inference below would otherwise conclude.
        await applyBackendStates()
        reconcile(with: snapshot)
        if snapshot.contains(where: { !$0.status.isTerminal }) {
            startPollingIfNeeded()
        }
    }

    /// Asks the plugin for the truth about every live request and renders exactly that.
    ///
    /// This is the shell. Where `reconcile(with:)` infers state by pattern-matching our job against
    /// a queue snapshot — and cannot see anything the queue does not show — this asks a direct
    /// question per request and takes the answer whole. A plugin that has no answer returns nil and
    /// the snapshot path below still applies, so nothing else has to change.
    private func applyBackendStates() async {
        let provider = self.provider
        let live = jobs.filter { !$0.value.status.isTerminal && $0.value.nativeId != nil }
        guard !live.isEmpty else { return }

        for (key, job) in live {
            guard let nativeId = job.nativeId else { continue }
            guard let state = await provider.requestState(for: nativeId) else { continue }
            backendAuthoritativeKeys.insert(key)
            guard let current = jobs[key], !current.status.isTerminal else { continue }
            let resolved = AcquisitionJob(
                id: current.id,
                title: current.title,
                artist: current.artist,
                albumTitle: current.albumTitle,
                status: state.status,
                // Straight through. If Lidarr gave no fraction this stays nil and the UI says so.
                progress: state.progress,
                message: state.detail ?? current.message,
                kind: current.kind,
                nativeId: current.nativeId,
                source: current.source,
                files: current.files,
            )
            guard resolved != current else { continue }
            jobs[key] = resolved
            if resolved.status.isTerminal { finish(key: key, job: resolved) }
        }
    }

    private func reconcile(with snapshot: [AcquisitionJob]) {
        for (key, current) in jobs where !current.status.isTerminal {
            // A plugin that answers `requestState` owns this job's state completely; the
            // queue-shaped guesswork below must not fight it.
            if current.nativeId != nil, backendAuthoritativeKeys.contains(key) { continue }
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
                    // Not 1.0 on success: "complete" is a *status*, and inventing a fraction to
                    // go with it would be the same fiction in a happier costume.
                    progress: current.progress,
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

    /// Fires the completion hook exactly once, then retires the row — but only when it succeeded.
    ///
    /// A `.done` row is retired quickly because the track itself takes its place. `.notFound` and
    /// `.failed` **stay**, because they are the answer: dropping them 1.5s later would return the
    /// row to a plain "Request" button and leave the user exactly where the original bug did,
    /// staring at a control that gives no account of what happened. They clear when the user
    /// retries (`enqueue` resets the key) or when the active plugin changes.
    private func finish(key: String, job: AcquisitionJob) {
        guard !finishedNotified.contains(key) else { return }
        finishedNotified.insert(key)
        observedInServerQueue.remove(key)
        absentPolls[key] = nil
        onJobFinished?(job)
        guard job.status == .done else { return }
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
