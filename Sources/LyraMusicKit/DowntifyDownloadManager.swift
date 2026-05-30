import Foundation
import Combine

/// Owns all in-flight Downtify downloads for the whole app, keyed by the
/// submitted YouTube URL. Polls `/api/queue` on a single shared task so progress
/// and completion survive navigation between views. Fires ``onJobFinished`` when
/// a job reaches a terminal state so the app can refresh the catalog and auto-add
/// the track to the personal library.
@MainActor
final class DowntifyDownloadManager: ObservableObject {
    /// Active + recently-finished jobs, keyed by submitted YouTube URL.
    @Published private(set) var jobs: [String: DowntifyJob] = [:]

    /// Set by `AppModel` at wire-up. Called once per job when it first reaches a
    /// terminal (`done`/`failed`) state.
    var onJobFinished: ((DowntifyJob) -> Void)?

    private var wsTask: Task<Void, Never>?
    private var finishedNotified: Set<String> = []
    /// Stable per-app-launch identifier sent on `POST /api/download/url` and as the
    /// `client_id` query param when opening the `/api/ws` WebSocket — lets Downtify
    /// associate enqueues with progress events for this client.
    let clientId = UUID().uuidString.lowercased()

    // MARK: - Lookups for views

    func job(forURL url: String) -> DowntifyJob? { jobs[url] }
    func isActive(url: String) -> Bool {
        guard let j = jobs[url] else { return false }
        return !j.status.isTerminal
    }

    /// Match a tracked job to a preview/row by normalized title (rows without a URL).
    func job(matchingTitle title: String) -> DowntifyJob? {
        let keys = Set(LibraryTrackMatcher.normalizedTitleKeys(from: title))
        guard !keys.isEmpty else { return nil }
        return jobs.values.first { job in
            guard let t = job.title, !t.isEmpty else { return false }
            return !Set(LibraryTrackMatcher.normalizedTitleKeys(from: t)).isDisjoint(with: keys)
        }
    }

    // MARK: - Enqueue

    /// Direct path: the song already carries a Downtify `url`.
    func enqueue(song: DowntifySong) async {
        guard !song.url.isEmpty else { return }
        await enqueue(url: song.url, title: song.name, artist: song.artists.first)
    }

    /// Search-by-term path (chart / MusicBrainz preview rows have no `url` yet).
    /// Mirrors `DowntifyClient.download(artist:title:)`: search → pickBest → enqueue.
    /// Inserts a synthetic placeholder job *before* the network search so title-keyed
    /// rows flip to a progress state instantly, then re-keys to the resolved URL.
    func enqueue(artist: String, title: String) async {
        guard let base = DowntifyClient.storedBaseURL else { return }
        let placeholderKey = "pending:\(artist)|\(title)"
        if jobs[placeholderKey] == nil, job(matchingTitle: title) == nil {
            jobs[placeholderKey] = DowntifyJob(optimisticURL: placeholderKey, title: title, artist: artist)
        }
        defer { jobs.removeValue(forKey: placeholderKey) }
        do {
            let songs = try await DowntifyClient.search(base: base, query: "\(artist) \(title)")
            guard let best = DowntifyClient.pickBest(from: songs, artist: artist, title: title) else {
                return
            }
            await enqueue(url: best.url, title: best.name, artist: best.artists.first ?? artist)
        } catch {
            // Surface nothing here; callers show their own "couldn't start" affordance.
        }
    }

    private func enqueue(url: String, title: String?, artist: String?) async {
        guard !url.isEmpty else { return }
        if isActive(url: url) { return }  // debounce duplicates
        finishedNotified.remove(url)
        // Optimistic entry so the UI flips immediately, before the first poll.
        jobs[url] = DowntifyJob(optimisticURL: url, title: title, artist: artist)
        do {
            _ = try await DowntifyClient.downloadSong(
                DowntifySong(songId: url, name: title ?? "", artists: artist.map { [$0] } ?? [],
                             albumName: "", url: url, coverURL: nil, year: nil, explicit: false)
            )
            startProgressFeedIfNeeded()
        } catch {
            jobs.removeValue(forKey: url)
        }
    }

    // MARK: - Progress feed (WebSocket)

    private func startProgressFeedIfNeeded() {
        guard wsTask == nil else { return }
        wsTask = Task { [weak self] in
            await self?.runProgressFeed()
        }
    }

    /// Subscribes to Downtify's `/api/ws` WebSocket and drains progress messages
    /// into the jobs map. On each (re)connect we also fetch a `/api/queue` snapshot
    /// so any state changes that happened while we were disconnected are caught.
    /// Exits when there are no active jobs left; the next `enqueue` revives it.
    private func runProgressFeed() async {
        defer { wsTask = nil }
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            if let snap = try? await DowntifyClient.queue() {
                reconcile(with: snap)
            }
            let didReceive = await runWebSocketPump()
            if Task.isCancelled { return }
            let stillActive = jobs.values.contains { !$0.status.isTerminal }
            if !stillActive { return }
            backoff = didReceive ? .seconds(1) : min(backoff * 2, .seconds(15))
            try? await Task.sleep(for: backoff)
        }
    }

    /// Opens one WebSocket connection and reads messages until it fails. Returns
    /// `true` if at least one message landed (so the caller can reset its backoff).
    private func runWebSocketPump() async -> Bool {
        guard let url = webSocketURL() else { return false }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        var receivedAny = false
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                receivedAny = true
                handle(webSocketMessage: message)
            } catch {
                return receivedAny
            }
        }
        return receivedAny
    }

    private func webSocketURL() -> URL? {
        guard let baseStr = DowntifyClient.storedBaseURL,
              var comps = URLComponents(string: baseStr) else { return nil }
        switch comps.scheme?.lowercased() {
        case "https": comps.scheme = "wss"
        default: comps.scheme = "ws"
        }
        let basePath = comps.path
        comps.path = basePath.hasSuffix("/") ? basePath + "api/ws" : basePath + "/api/ws"
        comps.queryItems = [URLQueryItem(name: "client_id", value: clientId)]
        return comps.url
    }

    private func handle(webSocketMessage message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        guard let job = try? JSONDecoder().decode(DowntifyJob.self, from: data) else { return }
        reconcile(with: [job])
    }

    /// Merges a fresh queue snapshot (HTTP or WS message) into our URL-keyed jobs.
    private func reconcile(with fresh: [DowntifyJob]) {
        for (url, current) in jobs where !current.status.isTerminal {
            guard let match = bestMatch(for: current, in: fresh) else { continue }
            jobs[url] = DowntifyJob(remappedURL: url, from: match)
            if match.status.isTerminal, !finishedNotified.contains(url) {
                finishedNotified.insert(url)
                onJobFinished?(jobs[url] ?? match)
                let key = url
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    self?.jobs.removeValue(forKey: key)
                }
            }
        }
    }

    /// Match a tracked job to a queue entry: prefer exact URL, else normalized title+artist.
    private func bestMatch(for job: DowntifyJob, in fresh: [DowntifyJob]) -> DowntifyJob? {
        if let exact = fresh.first(where: { $0.url == job.url }) { return exact }
        guard let title = job.title, !title.isEmpty else { return nil }
        let jobTitleKeys = Set(LibraryTrackMatcher.normalizedTitleKeys(from: title))
        return fresh.first { entry in
            guard let et = entry.title, !et.isEmpty else { return false }
            let keys = Set(LibraryTrackMatcher.normalizedTitleKeys(from: et))
            return !keys.isDisjoint(with: jobTitleKeys)
        }
    }
}

private extension DowntifyJob {
    /// Re-key a polled entry under the URL we originally submitted (queue entries
    /// may omit the source URL).
    init(remappedURL url: String, from polled: DowntifyJob) {
        self.init(forcedURL: url, title: polled.title, artist: polled.artist,
                  filename: polled.filename, message: polled.message,
                  status: polled.status, progress: polled.progress)
    }
}
