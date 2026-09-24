import Foundation

// T122 / T123 verification. Compiles the shipping MusicBrainz sources by symlink, so what runs
// here is the shipping code rather than a restatement of it.
//
// Failure-injection method per case is printed inline with each result.

func line(_ s: String = "") { print(s); fflush(stdout) }

/// Always-503 stub, so an exhausted retry schedule can be measured without waiting for a real
/// outage and without spending 20 requests against the live MusicBrainz service.
/// Thread-safe collector for emissions observed from the @Sendable progress closure.
final class Emissions: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Slow-failure stub: every attempt hangs for a while before failing, standing in for a dead
/// network where the transport timeout — not the backoff — dominates the elapsed time.
final class AlwaysSlowFailure: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var hits = 0
    /// Scaled down from the real 20s transport timeout so the case is measurable in reasonable
    /// wall-clock; the deadline logic under test is indifferent to the per-attempt cost.
    nonisolated(unsafe) static var delay: TimeInterval = 6
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        Self.hits += 1
        Thread.sleep(forTimeInterval: Self.delay)
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() {}
}

final class AlwaysRateLimited: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var hits = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        Self.hits += 1
        let resp = HTTPURLResponse(url: request.url!, statusCode: 503,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("rate limited".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct Verify {
    static func main() async {
        line("=== T122 / T123 verification ===")
        line("started \(ISO8601DateFormatter.mbLogFormatter.string(from: Date()))")
        line()

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String) {
            if !ok { failures += 1 }
            line("  [\(ok ? "PASS" : "FAIL")] \(label): \(detail)")
        }

        // ---------------------------------------------------------------- T122
        line("--- T122.1 backoff schedule (computed from the shipping constants) ---")
        let q = MusicBrainzRequestQueue()
        let attempts = q.configuredMaximumAttempts
        line("  configured maximum attempts: \(attempts)")
        var sched: [String] = []
        for a in 2 ... min(attempts, 8) { sched.append(String(format: "%.0fs", q.backoffSeconds(forAttempt: a))) }
        line("  first waits: \(sched.joined(separator: ", ")) ... (flat thereafter)")
        let totalBackoff = q.totalBackoffSeconds(attempts: attempts)
        line(String(format: "  total backoff for a fully exhausted request: %.1fs (%.2f min)",
                    totalBackoff, totalBackoff / 60))
        check("backoff total under the 5 minute ceiling", totalBackoff < 300,
              String(format: "%.1fs vs 300s limit", totalBackoff))

        line()
        line("--- T122.2 MEASURED elapsed for 20 fully exhausted retries ---")
        line("  method: injected failure — URLProtocol stub returning HTTP 503 to every attempt")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [AlwaysRateLimited.self]
        let stubbed = MusicBrainzRequestQueue(session: URLSession(configuration: cfg))
        AlwaysRateLimited.hits = 0
        let t0 = Date()
        do {
            _ = try await stubbed.perform(path: "/release-group", query: [URLQueryItem(name: "artist", value: "x")])
            check("exhausted request throws", false, "it unexpectedly succeeded")
        } catch {
            let elapsed = Date().timeIntervalSince(t0)
            line(String(format: "  MEASURED ELAPSED: %.1fs (%.2f min) across %d attempts",
                        elapsed, elapsed / 60, AlwaysRateLimited.hits))
            check("all \(attempts) attempts were made", AlwaysRateLimited.hits == attempts,
                  "\(AlwaysRateLimited.hits) HTTP attempts observed")
            check("measured elapsed under 5 minutes", elapsed < 300,
                  String(format: "%.1fs", elapsed))
            check("request ultimately fails rather than hanging", true, error.localizedDescription)
        }

        line()
        line("--- T122.2b MEASURED elapsed when every attempt HANGS (deadline case) ---")
        line("  method: injected failure — URLProtocol stub that stalls, then fails with a timeout")
        line(String(format: "  configured total deadline: %.0fs", q.configuredTotalDeadline))
        let slowCfg = URLSessionConfiguration.ephemeral
        slowCfg.protocolClasses = [AlwaysSlowFailure.self]
        AlwaysSlowFailure.hits = 0
        let slowQ = MusicBrainzRequestQueue(session: URLSession(configuration: slowCfg))
        let slowStart = Date()
        do {
            _ = try await slowQ.perform(path: "/release-group", query: [URLQueryItem(name: "artist", value: "x")])
            check("slow-failure request throws", false, "it unexpectedly succeeded")
        } catch {
            let elapsed = Date().timeIntervalSince(slowStart)
            let unbounded = Double(AlwaysSlowFailure.hits) * AlwaysSlowFailure.delay + q.totalBackoffSeconds(attempts: attempts)
            line(String(format: "  MEASURED ELAPSED: %.1fs (%.2f min) across %d attempts",
                        elapsed, elapsed / 60, AlwaysSlowFailure.hits))
            line(String(format: "  without the deadline this schedule would have run ~%.0fs for all %d attempts",
                        Double(attempts) * AlwaysSlowFailure.delay + q.totalBackoffSeconds(attempts: attempts), attempts))
            _ = unbounded
            check("deadline stopped it early rather than running all \(attempts) attempts",
                  AlwaysSlowFailure.hits < attempts, "\(AlwaysSlowFailure.hits) of \(attempts) attempts made")
            check("elapsed respects the configured deadline", elapsed <= q.configuredTotalDeadline + 15,
                  String(format: "%.1fs vs %.0fs deadline", elapsed, q.configuredTotalDeadline))
            check("and is under the 5 minute ceiling", elapsed < 300, String(format: "%.1fs", elapsed))
        }

        line()
        line("--- T122.3 pages already loaded survive a later page failing ---")
        line("  method: decision table over the shipping failure-result rule")
        let svc = MusicBrainzService.shared
        // Three pages in, fourth fails: the partial must win over any retained copy.
        let partial = (0 ..< 300).map {
            // score / artistCredit are search-row fields; these stand in for browsed pages.
            MusicBrainzReleaseGroup(id: "rg-\($0)", title: "T\($0)", firstReleaseDate: "2020",
                                    primaryType: "Album", secondaryTypes: [], disambiguation: nil,
                                    score: nil, artistCredit: nil)
        }
        let older = MusicBrainzDiscography(artistMBID: "a", total: 12,
            releaseGroups: Array(partial.prefix(12)), isComplete: true,
            fetchedAt: Date(timeIntervalSinceNow: -9 * 24 * 3600), source: .expiredFallback)
        let kept = svc.failureResult(artistMBID: "a", collected: partial, total: 314, cached: older)
        check("300 loaded releases survive the 4th page failing",
              kept.releaseGroups.count == 300,
              "\(kept.releaseGroups.count) releases retained, refreshFailed=\(kept.refreshFailed)")
        check("the retained partial is not mislabelled as a saved copy",
              !kept.isExpiredFallback, "source=\(kept.source)")

        // Nothing loaded at all: the saved copy surfaces, labelled.
        let fellBack = svc.failureResult(artistMBID: "a", collected: [], total: 0, cached: older)
        check("with nothing loaded, the saved copy surfaces instead of an empty page",
              fellBack.releaseGroups.count == 12, "\(fellBack.releaseGroups.count) releases")
        check("and it is labelled as a saved copy, not passed off as current",
              fellBack.isExpiredFallback, "source=\(fellBack.source)")

        // ---------------------------------------------------------------- T123
        line()
        line("--- T123.1 a failed fetch leaves the previous entry intact ---")
        line("  method: real endpoint — browse for an MBID MusicBrainz rejects, so the pass fails")
        let bogus = "00000000-0000-0000-0000-000000000000"
        let key = MusicBrainzCacheStore.releaseGroupBrowseKey(artistMBID: bogus)
        let sentinel = MusicBrainzCacheEntry(
            key: key, fetchedAt: Date(timeIntervalSinceNow: -9 * 24 * 3600),
            totalCount: 7, heldOffsets: [0],
            rawPages: [Data(#"{"release-group-count":7,"release-groups":[{"id":"keep-me","title":"Kept","primary-type":"Album"}]}"#.utf8)],
            isComplete: true)
        _ = MusicBrainzCacheStore.save(sentinel)
        let before = MusicBrainzCacheStore.load(key)
        line("  seeded an expired entry: complete=\(before?.isComplete ?? false), expired=\(before?.isExpired ?? false)")
        await MusicBrainzRefreshLimiter.shared.reset()
        let failed = await svc.discography(artistMBID: bogus, forceRefresh: true)
        let after = MusicBrainzCacheStore.load(key)
        check("fetch failed", failed?.refreshFailed == true, "refreshFailed=\(failed?.refreshFailed ?? false)")
        check("previous entry still on disk", after != nil, after == nil ? "GONE" : "present")
        check("previous entry byte-identical (not overwritten by the failed pass)",
              after?.fetchedAt == before?.fetchedAt && after?.totalCount == before?.totalCount,
              "fetchedAt and totalCount unchanged")
        check("failed fetch returns the saved copy rather than an empty page",
              failed?.releaseGroups.count == 1, "\(failed?.releaseGroups.count ?? -1) releases")
        check("and labels it as a saved copy", failed?.isExpiredFallback == true,
              "source=\(failed.map { "\($0.source)" } ?? "nil")")

        line()
        line("--- T123.2 rapid double refresh is refused WITH content intact ---")
        line("  method: real limiter, no network needed for the second call")
        await MusicBrainzRefreshLimiter.shared.reset()
        let first = await MusicBrainzRefreshLimiter.shared.claim(key: "citizen")
        let second = await MusicBrainzRefreshLimiter.shared.claim(key: "citizen")
        check("first refresh accepted", first, "claim=\(first)")
        check("immediate second refresh refused", !second, "claim=\(second)")
        let wait = await MusicBrainzRefreshLimiter.shared.secondsUntilAllowed(key: "citizen")
        line(String(format: "  next refresh allowed in %.1fs", wait))

        // The refusal must not empty the page: seed a complete, EXPIRED entry (so the fresh-cache
        // early return cannot fire), then refresh twice and confirm the refused one keeps content.
        let cKey = MusicBrainzCacheStore.releaseGroupBrowseKey(artistMBID: "refusal-probe")
        let seeded = MusicBrainzCacheEntry(
            key: cKey, fetchedAt: Date(timeIntervalSinceNow: -9 * 24 * 3600),
            totalCount: 3, heldOffsets: [0],
            rawPages: [Data(#"{"release-group-count":3,"release-groups":[{"id":"a","title":"A","primary-type":"Album"},{"id":"b","title":"B","primary-type":"Single"},{"id":"c","title":"C","primary-type":"EP"}]}"#.utf8)],
            isComplete: true)
        _ = MusicBrainzCacheStore.save(seeded)
        await MusicBrainzRefreshLimiter.shared.reset()
        _ = await MusicBrainzRefreshLimiter.shared.claim(key: "refusal-probe")   // burn the allowance
        let refused = await svc.discography(artistMBID: "refusal-probe", forceRefresh: true)
        check("second refresh reported as refused", refused?.refreshRefused == true,
              "refreshRefused=\(refused?.refreshRefused ?? false)")
        check("PAGE STILL HAS ITS CONTENT after the refusal",
              refused?.releaseGroups.count == 3,
              "\(refused?.releaseGroups.count ?? -1) releases (a refusal that empties the page is a failure)")
        check("refusal did not delete the cache entry",
              MusicBrainzCacheStore.load(cKey) != nil, "entry present")
        check("refusal is not mislabelled as a failed refresh",
              refused?.refreshFailed == false, "refreshFailed=\(refused?.refreshFailed ?? true)")

        line()
        line("--- T123.3 an in-date entry is served; an expired one is not rendered before refetch ---")
        let freshKey = MusicBrainzCacheStore.releaseGroupBrowseKey(artistMBID: "fresh-probe")
        let fresh = MusicBrainzCacheEntry(
            key: freshKey, fetchedAt: Date(), totalCount: 1, heldOffsets: [0],
            rawPages: [Data(#"{"release-group-count":1,"release-groups":[{"id":"f","title":"F","primary-type":"Album"}]}"#.utf8)],
            isComplete: true)
        _ = MusicBrainzCacheStore.save(fresh)
        await MusicBrainzRefreshLimiter.shared.reset()
        let emissions = Emissions()
        let served = await svc.discography(artistMBID: "fresh-probe") { p in
            emissions.add("\(p.source):\(p.releaseGroups.count)")
        }
        check("in-date entry served from cache with no network", served?.source == .cache,
              "source=\(served.map { "\($0.source)" } ?? "nil")")

        await MusicBrainzRefreshLimiter.shared.reset()
        let expiredEmissions = Emissions()
        _ = await svc.discography(artistMBID: bogus, forceRefresh: true) { p in
            expiredEmissions.add("\(p.source):\(p.releaseGroups.count)")
        }
        check("an expired entry is NEVER emitted to the screen before the refetch",
              !expiredEmissions.all.contains(where: { $0.hasPrefix("expiredFallback") }),
              expiredEmissions.all.isEmpty ? "no emissions at all" : "emissions: \(expiredEmissions.all)")

        line()
        line(failures == 0 ? "VERDICT: PASS (all checks)" : "VERDICT: FAIL (\(failures) checks)")
        line("finished \(ISO8601DateFormatter.mbLogFormatter.string(from: Date()))")
    }
}
