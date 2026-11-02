import Foundation

// MARK: - Request log

/// One MusicBrainz request attempt, stamped at the moment it left the queue.
///
/// Recorded for every attempt including retries, so the spacing between consecutive
/// `startedAt` values is a direct measurement of the rate limiter rather than an
/// inference about it.
struct MusicBrainzRequestLogEntry: Sendable, Hashable {
    let startedAt: Date
    let path: String
    let query: String
    let attempt: Int
    /// Why the attempt failed, or `nil` if it succeeded. Filled in after the fact — a request
    /// that fails silently is indistinguishable from an artist with no releases, which is the
    /// worst possible way for a metadata layer to be wrong.
    var outcome: String?
}

/// Rolling in-memory log of MusicBrainz traffic. Bounded; never written to disk.
actor MusicBrainzRequestLog {
    static let shared = MusicBrainzRequestLog()

    private var entries: [MusicBrainzRequestLogEntry] = []
    private let capacity = 500

    /// Mirrors each entry to stdout. Off by default; the pacing harness turns it on.
    var echoesToConsole = false

    func record(_ entry: MusicBrainzRequestLogEntry) {
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        if echoesToConsole {
            let stamp = ISO8601DateFormatter.mbLogFormatter.string(from: entry.startedAt)
            print("[MB] \(stamp) attempt=\(entry.attempt) \(entry.path)?\(entry.query)")
        }
    }

    /// Attaches the outcome to the most recently recorded attempt.
    func recordOutcome(_ outcome: String) {
        guard !entries.isEmpty else { return }
        entries[entries.count - 1].outcome = outcome
        if echoesToConsole { print("[MB]      -> \(outcome)") }
    }

    func setEchoesToConsole(_ on: Bool) { echoesToConsole = on }

    func snapshot() -> [MusicBrainzRequestLogEntry] { entries }

    func reset() { entries.removeAll() }

    /// Smallest gap between two consecutive request starts, or `nil` with fewer than two.
    func smallestGapSeconds() -> TimeInterval? {
        guard entries.count >= 2 else { return nil }
        return zip(entries.dropFirst(), entries).map { $0.startedAt.timeIntervalSince($1.startedAt) }.min()
    }
}

extension ISO8601DateFormatter {
    static let mbLogFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Serial queue with a one-second floor

/// The single gate every MusicBrainz request passes through.
///
/// MusicBrainz allows one request per second per source IP and will answer 503 above that.
/// Two things are needed to honour it, and only one of them is a delay:
///
/// 1. **Serialization.** Concurrent callers must not each wait "one second from my own last
///    request" — they would all clear the same instant. Requests are chained: each waits for
///    the previous one to finish before it even asks for a slot.
/// 2. **A floor between starts.** The gap is measured start-to-start, not end-to-start, so a
///    slow response does not let the next one fire immediately behind it.
///
/// Everything MusicBrainz-facing goes through ``perform(path:query:)``. There is no second
/// path, which is what makes the floor an invariant rather than a convention.
actor MusicBrainzRequestQueue {
    static let shared = MusicBrainzRequestQueue()

    /// Minimum wall-clock gap between the starts of two requests. The 50 ms over the
    /// documented one second absorbs timer and scheduling jitter, so a burst cannot land
    /// two calls inside the same second and trip the limiter.
    private let minimumSpacing: TimeInterval = 1.05

    /// Base wait before retrying a 503 or transient failure. Longer than the floor because a
    /// 503 means the server already thinks we are going too fast, and retrying at the same
    /// cadence that provoked it just spends the attempt.
    private let retryBackoff: TimeInterval = 2.0

    /// Ceiling on the backoff. Doubling is right for the first few attempts and wrong after
    /// that: uncapped, twenty doublings would run for days, which is a worse outcome than
    /// failing — nobody is waiting that long, and the request holds the serial queue the whole
    /// time. Capped, the schedule is 2s, 4s, 8s, then 8s for the remainder.
    private let maximumBackoff: TimeInterval = 8.0

    /// How hard one request should try before giving up.
    ///
    /// Two callers want opposite things from the same queue, and a single setting cannot serve
    /// both. A discography page is worth waiting minutes for: the user is looking at a
    /// half-filled shelf, nothing else is competing, and giving up loses data. A search is worth
    /// waiting seconds for: the user is still typing, the query is already stale, and — because
    /// this queue is strictly serial — a search that keeps retrying is not merely slow, it is
    /// *blocking every other request in the app* for as long as it persists.
    ///
    /// That is the failure this type exists to prevent. Before it, one search drawing repeated
    /// 503s could hold the only queue for the full four-minute deadline, during which no artist
    /// page could load and no further search could run. MusicBrainz 503s often enough under
    /// ordinary load for that to be a routine outcome rather than an edge case.
    struct RequestPolicy: Sendable {
        /// Attempts before giving up.
        let maximumAttempts: Int
        /// Ceiling on total elapsed time across every attempt, including backoff.
        let totalDeadline: TimeInterval

        /// For work the user is waiting on right now. Short, because the answer stops being
        /// wanted almost immediately and the queue is needed by someone else.
        static let interactive = RequestPolicy(maximumAttempts: 3, totalDeadline: 10)

        /// For work that is filling in behind the UI. Patient, because MusicBrainz rate-limits
        /// by returning 503 and a burst that trips it recovers on its own given a little time —
        /// abandoning a page after three tries threw away a whole discography over a momentary
        /// refusal.
        static let background = RequestPolicy(maximumAttempts: 20, totalDeadline: 240)
    }

    private let session: URLSession
    private var tail: Task<Void, Never>?
    private var lastStart: Date?

    init(session: URLSession = .shared) {
        self.session = session
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        /// True when MusicBrainz refused the request for rate-limit reasons (503 / 429) rather
        /// than because the thing being asked for does not exist.
        ///
        /// Carried as a flag rather than left for the caller to infer from the message, because
        /// the two cases need opposite UI: "MusicBrainz is busy, try again" invites a retry,
        /// while "no results" tells the user to change their query. Rendering a refusal as an
        /// empty result set — which is what happens when this distinction is lost — tells the
        /// user the artist does not exist.
        let isRateLimit: Bool

        init(_ message: String, isRateLimit: Bool = false) {
            errorDescription = message
            self.isRateLimit = isRateLimit
        }
    }

    /// Runs one MusicBrainz request, queued behind every other one and paced to the floor.
    ///
    /// Cancelling the calling task cancels the request. That is not incidental tidiness: the
    /// detached task below does **not** inherit cancellation, so without the handler a search
    /// abandoned mid-keystroke still went out and still spent a full second of the
    /// one-request-per-second budget on an answer nobody would ever see. Typing eight characters
    /// burned eight seconds of the app's entire MusicBrainz allowance.
    func perform(
        path: String,
        query: [URLQueryItem],
        policy: RequestPolicy = .background
    ) async throws -> Data {
        let previous = tail
        let task = Task<Result<Data, Error>, Never>.detached(priority: .userInitiated) { [weak self] in
            if let previous { _ = await previous.value }
            guard let self else { return .failure(Failure("MusicBrainz queue went away")) }
            do {
                return .success(try await self.execute(path: path, query: query, policy: policy))
            } catch {
                return .failure(error)
            }
        }
        // The chain awaits the task's `Result`, which a cancelled task still produces, so
        // cancelling one request cannot strand the queue behind it.
        tail = Task.detached(priority: .userInitiated) { _ = await task.value }
        return try await withTaskCancellationHandler {
            try await task.value.get()
        } onCancel: {
            task.cancel()
        }
    }

    /// Attempt loop for a single queued request. Runs alone — the chain guarantees no other
    /// request is in flight — so every attempt, including retries, can take a slot directly.
    private func execute(
        path: String,
        query: [URLQueryItem],
        policy: RequestPolicy
    ) async throws -> Data {
        var lastError: Error = Failure("MusicBrainz request never ran")
        let startedAt = Date()

        for attempt in 1 ... policy.maximumAttempts {
            // Checked before the slot is reserved, so a cancelled request gives its second back
            // to the budget instead of consuming it on the way out.
            if Task.isCancelled { throw CancellationError() }
            if attempt > 1 {
                let backoff = backoffSeconds(forAttempt: attempt)
                // Stop when the next attempt could not finish inside the budget. Checked before
                // sleeping so the deadline is never overshot by a wait that was already doomed.
                guard Date().timeIntervalSince(startedAt) + backoff < policy.totalDeadline else {
                    await MusicBrainzRequestLog.shared.recordOutcome(
                        String(format: "gave up after %.0fs (deadline)", Date().timeIntervalSince(startedAt))
                    )
                    break
                }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                if Task.isCancelled { throw CancellationError() }
            }
            await reserveSlot()
            await MusicBrainzRequestLog.shared.record(
                MusicBrainzRequestLogEntry(
                    startedAt: Date(),
                    path: path,
                    query: query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&"),
                    attempt: attempt
                )
            )

            do {
                let (data, response) = try await session.data(for: Self.request(path: path, query: query))
                guard let http = response as? HTTPURLResponse else {
                    throw Failure("MusicBrainz returned a non-HTTP response")
                }
                switch http.statusCode {
                case 200 ..< 300:
                    return data
                case 503, 429:
                    // Rate limited. Worth another attempt after a longer pause.
                    await MusicBrainzRequestLog.shared.recordOutcome("HTTP \(http.statusCode) rate limited")
                    lastError = Failure(
                        "MusicBrainz rate limited the request (HTTP \(http.statusCode))",
                        isRateLimit: true
                    )
                case 404:
                    await MusicBrainzRequestLog.shared.recordOutcome("HTTP 404")
                    throw Failure("MusicBrainz has no such resource (HTTP 404)")
                default:
                    await MusicBrainzRequestLog.shared.recordOutcome("HTTP \(http.statusCode)")
                    throw Failure("MusicBrainz returned HTTP \(http.statusCode)")
                }
            } catch let failure as Failure {
                throw failure
            } catch {
                // Transport-level failure — retry.
                await MusicBrainzRequestLog.shared.recordOutcome("transport: \(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    /// Wait before `attempt`, doubling from ``retryBackoff`` and then flattening at
    /// ``maximumBackoff``. Exposed so the schedule's total cost can be measured directly
    /// rather than inferred from a stopwatch around a live request.
    nonisolated func backoffSeconds(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let doublings = min(attempt - 2, 16)  // 2^16 already dwarfs any sane cap
        let uncapped = retryBackoff * pow(2, Double(doublings))
        return min(uncapped, maximumBackoff)
    }

    /// Total time the backoff schedule alone spends across a fully exhausted request.
    nonisolated func totalBackoffSeconds(attempts: Int) -> TimeInterval {
        guard attempts > 1 else { return 0 }
        return (2 ... attempts).reduce(0) { $0 + backoffSeconds(forAttempt: $1) }
    }

    /// The configured attempt ceiling, for measurement and reporting.
    /// Reports the ``RequestPolicy/background`` ceilings, which are the ones the pacing harness
    /// measures — an interactive request deliberately gives up long before these.
    nonisolated var configuredMaximumAttempts: Int { RequestPolicy.background.maximumAttempts }

    /// The configured total-elapsed ceiling, for measurement and reporting.
    nonisolated var configuredTotalDeadline: TimeInterval { RequestPolicy.background.totalDeadline }

    /// Holds the start-to-start floor. Only ever reached by the one request the chain has
    /// let through, so the sleep here cannot be raced by a second caller.
    private func reserveSlot() async {
        if let lastStart {
            let elapsed = Date().timeIntervalSince(lastStart)
            if elapsed < minimumSpacing {
                try? await Task.sleep(nanoseconds: UInt64((minimumSpacing - elapsed) * 1_000_000_000))
            }
        }
        lastStart = Date()
    }

    private static func request(path: String, query: [URLQueryItem]) throws -> URLRequest {
        guard var comps = URLComponents(string: MusicBrainzClient.baseURL + path) else {
            throw Failure("Could not build a MusicBrainz URL for \(path)")
        }
        comps.queryItems = query + [URLQueryItem(name: "fmt", value: "json")]
        guard let url = comps.url else {
            throw Failure("Could not build a MusicBrainz URL for \(path)")
        }
        var req = URLRequest(url: url)
        req.setValue(MusicBrainzClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        return req
    }
}

// MARK: - Endpoints

/// Thin typed wrapper over the three MusicBrainz endpoints this app uses. Holds no state
/// and no policy beyond URL shape — pacing lives in ``MusicBrainzRequestQueue``, caching and
/// staleness in ``MusicBrainzService``.
enum MusicBrainzClient {
    static let baseURL = "https://musicbrainz.org/ws/2"

    /// A named User-Agent with a contact address. MusicBrainz throttles anonymous and
    /// generic-library agents more aggressively than identified ones, so this is not
    /// decoration — it is what keeps the client in the ordinary rate-limit class.
    static let userAgent = "Vellum/1.0 ( ithegreenguy@gmail.com )"

    /// Page size for browse. 100 is the endpoint's maximum.
    static let browsePageSize = 100

    /// The `inc` set used for a cold-open artist lookup.
    static let artistLookupInc = ["tags", "ratings"]

    /// Maximum `limit` the search endpoints accept. The default is 25; asking for 100 costs the
    /// same single request and the same single second, so there is no reason to ask for less.
    static let searchPageSize = 100

    /// Runs one search request against `entity` and returns the raw body.
    ///
    /// Every search goes through here so the query builder, the page size and the interactive
    /// request policy apply uniformly. `offset` is what makes the paginated feed possible: the
    /// search endpoints honour it and report `count`, so a caller can page to the end of a result
    /// set and know when it has arrived there.
    private static func search(
        entity: String,
        luceneQuery: String,
        limit: Int,
        offset: Int
    ) async throws -> Data {
        try await MusicBrainzRequestQueue.shared.perform(
            path: "/\(entity)",
            query: [
                URLQueryItem(name: "query", value: luceneQuery),
                URLQueryItem(name: "limit", value: String(max(1, min(limit, searchPageSize)))),
                URLQueryItem(name: "offset", value: String(max(0, offset))),
            ],
            // A search is something the user is waiting on, and this queue is serial — a search
            // that retries for minutes blocks every other request in the app.
            policy: .interactive
        )
    }

    /// Artist search. The response rows already carry name, country, area, life-span and
    /// tags, so a header can be rendered straight from a search hit with no second call.
    static func searchArtists(
        query: String,
        limit: Int = searchPageSize,
        offset: Int = 0
    ) async throws -> MusicBrainzArtistSearchResponse {
        let data = try await search(
            entity: "artist",
            luceneQuery: MusicBrainzQuery.artists(query),
            limit: limit,
            offset: offset
        )
        return try JSONDecoder().decode(MusicBrainzArtistSearchResponse.self, from: data)
    }

    /// Release-group (album / EP / single) search — the album half of a search.
    ///
    /// Release *groups* rather than releases: a group is the album as a work, so an album and its
    /// remasters, reissues and regional pressings are one row instead of nine. Searching
    /// `/release` instead would return the pressings and drown the result set.
    static func searchReleaseGroups(
        query: String,
        limit: Int = searchPageSize,
        offset: Int = 0
    ) async throws -> MusicBrainzReleaseGroupSearchResponse {
        let data = try await search(
            entity: "release-group",
            luceneQuery: MusicBrainzQuery.releaseGroups(query),
            limit: limit,
            offset: offset
        )
        return try JSONDecoder().decode(MusicBrainzReleaseGroupSearchResponse.self, from: data)
    }

    /// Recording (song) search — the song half of a search.
    ///
    /// Returns one row per *performance*, not per song, so the caller must collapse duplicates
    /// before display. See ``MusicBrainzRecording`` for why, and ``MusicBrainzSearchFeed`` for
    /// where it happens.
    static func searchRecordings(
        query: String,
        limit: Int = searchPageSize,
        offset: Int = 0
    ) async throws -> MusicBrainzRecordingSearchResponse {
        let data = try await search(
            entity: "recording",
            luceneQuery: MusicBrainzQuery.recordings(query),
            limit: limit,
            offset: offset
        )
        return try JSONDecoder().decode(MusicBrainzRecordingSearchResponse.self, from: data)
    }

    /// Artist lookup by MBID. Only needed on a cold open — reaching an artist page without a
    /// search payload in hand — or to pick up `rating`, which search never returns.
    static func artist(mbid: String, inc: [String] = artistLookupInc) async throws -> (artist: MusicBrainzArtist, raw: Data) {
        var query: [URLQueryItem] = []
        if !inc.isEmpty {
            query.append(URLQueryItem(name: "inc", value: inc.joined(separator: "+")))
        }
        let data = try await MusicBrainzRequestQueue.shared.perform(path: "/artist/\(mbid)", query: query)
        return (try JSONDecoder().decode(MusicBrainzArtist.self, from: data), data)
    }

    /// One page of an artist's discography.
    ///
    /// Browse, not the `inc=release-groups` lookup: browse honours `limit`/`offset` and
    /// reports `release-group-count`, so the caller can tell a short page from a truncated
    /// one. The lookup form caps at 25 with no total and no warning, and what it drops is
    /// not evenly spread — singles go first.
    ///
    /// `inc=artist-credits` is not an optimisation. Browse omits `artist-credit` entirely by
    /// default, so without it every row arrives anonymous and the only artist name available
    /// downstream is the one being browsed — which turns a collaboration into a solo record.
    /// Citizen's discography holds three of these in thirty (`stay up` is credited to
    /// "jayo & Citizen"), and each rendered as "Citizen". It costs no extra request: the
    /// credits ride along on the page that was already being fetched.
    ///
    /// **`inc` does not truncate this endpoint**, and the measurement is recorded here because
    /// the opposite is true one endpoint over and someone will eventually "fix" that by deleting
    /// this line. Measured against Citizen's discography, twice, independently:
    ///
    ///     browse, no inc                -> release-group-count 30, rows returned 30
    ///     browse, inc=artist-credits    -> release-group-count 30, rows returned 30,
    ///                                      30 of 30 rows carrying a credit
    ///
    /// The 25-row cap is a property of the **lookup** form, `/artist/{mbid}?inc=release-groups`,
    /// where release groups are a capped sub-resource and `limit` is ignored outright. Browse is
    /// a different endpoint: it pages at 100, reports a total, and `inc` changes neither. That is
    /// the whole reason this function uses browse (see above) — so adding `inc` here does not
    /// reintroduce the lookup's cap, because the cap was never a property of `inc`.
    static func releaseGroupPage(
        artistMBID: String,
        offset: Int,
        limit: Int = browsePageSize
    ) async throws -> (page: MusicBrainzReleaseGroupBrowseResponse, raw: Data) {
        let data = try await MusicBrainzRequestQueue.shared.perform(
            path: "/release-group",
            query: [
                URLQueryItem(name: "artist", value: artistMBID),
                URLQueryItem(name: "inc", value: "artist-credits"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
        )
        return (try JSONDecoder().decode(MusicBrainzReleaseGroupBrowseResponse.self, from: data), data)
    }
}
