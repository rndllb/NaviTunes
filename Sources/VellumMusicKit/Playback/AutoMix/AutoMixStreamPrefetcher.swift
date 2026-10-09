import Foundation

/// With AutoMix on, fetches the next queued *streamed* track into `StreamingMediaDiskCache` while
/// the current song plays, so the analyzer has a file to read and playback then starts from that
/// cached copy — no second download. One fetch at a time, keyed by track id; a queue change
/// cancels any fetch for a track that is no longer next; the toggle going off cancels everything.
///
/// Lead time: the fetch starts the moment planning runs for a new current track, i.e. as early as
/// possible. The chain that must complete before the cue point is fetch → analysis (≈ 10 s on an
/// A15 for a 4-min song) → the 2 s handoff lead, and a 4-min 320 kbps stream is ~10 MB: 5 s on
/// Wi-Fi, 50 s on a slow cellular link. Starting at track start leaves over two minutes of margin
/// on a 4-min song; any shorter lead would only save bytes on songs the user skips, and those
/// fetches are cancelled anyway. Nothing here runs while AutoMix is off.
@MainActor
final class AutoMixStreamPrefetcher {
    enum Status: Equatable {
        /// The stream is in the cache at this file.
        case cached(URL)
        /// A fetch for this track is running.
        case fetching
        /// Not a progressive http(s) stream, or AutoMix is off: no fetch, ever.
        case notFetched
    }

    private let cache: StreamingMediaDiskCache
    private let session: URLSession
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// Fires on the main actor when a fetch lands, with the track id and the cached file.
    var onFetched: ((String, URL) -> Void)?
    /// Bytes committed by this prefetcher since it was created — for the debug screen.
    private(set) var bytesFetched: Int64 = 0
    private(set) var log: [String] = []

    init(cache: StreamingMediaDiskCache = .shared, session: URLSession = .shared) {
        self.cache = cache
        self.session = session
    }

    /// Where a track's stream stands, starting a fetch when `enabled` and nothing is cached.
    /// `enabled` is the AutoMix toggle: when false this never touches the network and never
    /// reports `.fetching`.
    @discardableResult
    func ensure(trackId: String, url: URL, headers: [String: String], enabled: Bool) -> Status {
        let key = StreamingMediaDiskCache.key(for: url)
        if let cached = cache.peekCachedFileURL(forKey: key) { return .cached(cached) }
        guard enabled, CachingResourceLoaderDelegate.isCacheable(url) else { return .notFetched }
        if inFlight[trackId] != nil { return .fetching }
        let cache = self.cache
        let session = self.session
        let task = Task(priority: .utility) { [weak self] in
            let result: Result<URL, Error>
            do {
                result = .success(try await cache.fetchAndCommit(url: url, headers: headers, session: session))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            await self?.finish(trackId: trackId, result: result)
        }
        inFlight[trackId] = task
        log.append("fetch started \(trackId)")
        return .fetching
    }

    /// Cancel every fetch for a track not in `trackIds` — the queue changed.
    func retainOnly(trackIds: Set<String>) {
        for (id, task) in inFlight where !trackIds.contains(id) {
            task.cancel()
            inFlight[id] = nil
            log.append("fetch cancelled \(id)")
        }
    }

    func cancelAll() {
        retainOnly(trackIds: [])
    }

    var inFlightTrackIds: Set<String> { Set(inFlight.keys) }

    private func finish(trackId: String, result: Result<URL, Error>) {
        inFlight[trackId] = nil
        switch result {
        case let .success(url):
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            bytesFetched += size
            log.append("fetch landed \(trackId) \(size) bytes")
            onFetched?(trackId, url)
        case let .failure(error):
            log.append("fetch failed \(trackId): \(error)")
        }
    }
}
