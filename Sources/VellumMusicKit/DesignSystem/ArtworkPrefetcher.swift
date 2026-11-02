import CoreGraphics
import Foundation

/// Starts artwork loading when the URL is known rather than when the row scrolls into view.
///
/// `AlbumArtworkView` fetches from a `.task` on its own body, so inside a lazy container nothing
/// is requested until the cell is built — which is when it is nearly on screen. On a long shelf
/// that reads as the page filling in underneath you as you scroll.
///
/// The obvious correction is worse than the bug: kicking off a request per row the moment a
/// discography lands would put several hundred image fetches in flight at once on a large artist,
/// which is a stampede rather than a fix — it competes with the fetch the reader is actually
/// waiting for, and on cellular it is somebody's data. So this is bounded three ways:
///
/// - **A cap per shelf.** Only the leading run of rows is prefetched; the rest still load on
///   demand, which is the correct behaviour for artwork nobody may ever scroll to.
/// - **A concurrency limit.** A small number in flight at a time, so the queue drains in order
///   instead of contending with itself.
/// - **One job per owner.** Starting a new prefetch for the same shelf cancels the previous one,
///   so re-rendering a shelf does not stack up duplicate work.
///
/// Cache hits cost nothing: an already-decoded cover is skipped without touching the network.
actor ArtworkPrefetcher {
    static let shared = ArtworkPrefetcher()

    /// Rows to warm ahead of the reader per shelf. Chosen to cover roughly the first two
    /// screenfuls of a horizontal carousel, which is what a reader can reach before a fetch
    /// started now would have landed anyway.
    static let defaultLeadingCount = 12

    /// Images fetched at once. Deliberately small — artwork is background work and must not
    /// crowd out the metadata request the page is still waiting on.
    private let maximumConcurrent = 4

    private var jobs: [String: Task<Void, Never>] = [:]

    /// Warms the first `limit` URLs for `owner`, replacing any prefetch already running for it.
    func prefetch(
        owner: String,
        urls: [URL],
        limit: Int = ArtworkPrefetcher.defaultLeadingCount,
        maxPixelSize: CGFloat
    ) {
        jobs[owner]?.cancel()
        let targets = Array(urls.prefix(max(0, limit)))
        guard !targets.isEmpty else {
            jobs[owner] = nil
            return
        }
        let concurrency = maximumConcurrent
        jobs[owner] = Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func addTask() {
                    guard next < targets.count else { return }
                    let url = targets[next]
                    next += 1
                    group.addTask {
                        if Task.isCancelled { return }
                        // Already decoded — no request, no decode, no cost.
                        if DecodedArtworkCache.image(for: url, maxPixelSize: maxPixelSize) != nil { return }
                        _ = await RemoteArtworkLoad.cgImage(from: url, maxPixelSize: maxPixelSize)
                    }
                }
                for _ in 0 ..< min(concurrency, targets.count) { addTask() }
                while await group.next() != nil {
                    if Task.isCancelled { break }
                    addTask()
                }
            }
        }
    }

    /// Stops a shelf's prefetch — used when the view goes away so background work does not
    /// outlive the screen that wanted it.
    func cancel(owner: String) {
        jobs[owner]?.cancel()
        jobs[owner] = nil
    }

    func cancelAll() {
        for (_, task) in jobs { task.cancel() }
        jobs.removeAll()
    }
}
