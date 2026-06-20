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
    /// Settings → Downloads (and similar surfaces) hold this > 0 while visible so
    /// server queue progress keeps updating without a manual refresh.
    private var liveRefreshClients = 0

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.activeKey)
        // A previously-stored "downtify" no longer decodes (plugin removed) and falls through
        // to the Lidarr default.
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
            if var job = jobs[key] {
                jobs[key] = AcquisitionJob(
                    id: key,
                    title: job.title,
                    artist: job.artist,
                    albumTitle: job.albumTitle,
                    status: .downloading,
                    progress: max(job.progress, 0.4),
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
            status: fraction >= 1 ? .downloading : job.status,
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

    private var shouldContinuePolling: Bool {
        hasActiveWork || liveRefreshClients > 0
    }

    private var pollInterval: Duration {
        liveRefreshClients > 0 ? .seconds(1) : .seconds(2.5)
    }

    private func runPollLoop() async {
        defer { pollTask = nil }
        while !Task.isCancelled {
            await refreshFromServer()
            guard shouldContinuePolling else { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Pulls the active plugin's server-side queue and reconciles our app jobs against it.
    func refreshFromServer() async {
        let provider = self.provider
        guard provider.isConfigured else {
            serverJobs = []
            return
        }
        let snapshot = await provider.activeJobs()
        serverJobs = snapshot
        reconcile(with: snapshot)
        if snapshot.contains(where: { !$0.status.isTerminal }) {
            startPollingIfNeeded()
        }
    }

    private func reconcile(with snapshot: [AcquisitionJob]) {
        for (key, current) in jobs where !current.status.isTerminal {
            guard let match = bestMatch(for: current, in: snapshot) else { continue }
            // Plugins with per-file progress — don't let the enqueue callback's
            // temporary 100% mask the real transfer fraction.
            let mergedProgress = (match.files?.isEmpty == false)
                ? match.progress
                : max(current.progress, match.progress)
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
            jobs[key] = merged
            if merged.status.isTerminal, !finishedNotified.contains(key) {
                finishedNotified.insert(key)
                onJobFinished?(merged)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    self?.jobs.removeValue(forKey: key)
                }
            }
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
