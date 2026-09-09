import Foundation

// MARK: - Results

/// A discography as the UI needs to see it: what has arrived, how much is still coming, and
/// whether what is on screen is current data or a saved copy that a failed refresh fell back to.
struct MusicBrainzDiscography: Sendable {
    enum Source: Sendable {
        /// Served from disk, still inside its freshness window.
        case cache
        /// An expired copy, surfaced only because a refresh failed. Never served as current —
        /// anything rendering this has to say on screen that it is a saved copy.
        case expiredFallback
        /// Freshly fetched.
        case network
    }

    let artistMBID: String
    /// `release-group-count` — the server's own total, so the UI can show placeholders for
    /// pages that have not landed yet instead of guessing.
    let total: Int
    let releaseGroups: [MusicBrainzReleaseGroup]
    /// Every page accounted for.
    let isComplete: Bool
    let fetchedAt: Date
    let source: Source
    /// A refresh ran and failed. Distinguishes "this artist has no more releases" from "we
    /// could not find out", which otherwise look identical to the UI — the difference between
    /// an honest empty shelf and a silently truncated discography.
    var refreshFailed: Bool = false

    /// A refresh was asked for and turned down by the rate limiter, so nothing was fetched and
    /// nothing was discarded. The page keeps exactly what it had; the caller is expected to say
    /// so, because a refresh that silently does nothing looks identical to one that worked.
    var refreshRefused: Bool = false

    /// True when what is on screen came from an expired copy that could not be refreshed. The
    /// UI must label this rather than presenting it as current.
    var isExpiredFallback: Bool { source == .expiredFallback }

    /// How many rows the server says exist that have not arrived yet.
    var pendingCount: Int { max(0, total - releaseGroups.count) }

    var singles: [MusicBrainzReleaseGroup] { releaseGroups.filter(\.isSingle) }
}

/// What one page of a MusicBrainz search produced.
///
/// A plain `[Row]` cannot express this surface honestly. The previous artist search returned
/// `[]` for a rate-limit refusal, a 503, a transport failure *and* a genuine no-such-artist,
/// which meant the search UI told the user "no results" whenever MusicBrainz was merely busy —
/// and MusicBrainz is busy often. Every other part of this layer already models the distinction
/// (`refreshFailed`, `refreshRefused`, `expiredFallback`); search was the one place that didn't.
enum MusicBrainzSearchOutcome<Row: Sendable>: Sendable {
    /// Rows for the requested offset, plus the server's total match count so a paginated feed
    /// knows whether more exist without probing for an empty page.
    case ok(rows: [Row], total: Int)
    /// MusicBrainz refused for rate-limit reasons. Retryable, and worth saying so.
    case rateLimited
    /// Anything else — transport failure, unexpected status, undecodable body.
    case failed(String)

    var rows: [Row] {
        if case .ok(let rows, _) = self { return rows }
        return []
    }

    var total: Int {
        if case .ok(_, let total) = self { return total }
        return 0
    }

    /// A human-readable reason, or `nil` when the page succeeded.
    var failureMessage: String? {
        switch self {
        case .ok: return nil
        case .rateLimited: return "MusicBrainz is busy right now."
        case .failed(let message): return message
        }
    }
}

// MARK: - Name matching

/// Picks the right artist out of a MusicBrainz search result set.
///
/// Deliberately not a containment test. A three-way `a == b || a.contains(b) || b.contains(a)`
/// with no ranking lets any row whose name merely contains the query win on arrival order —
/// searching "Citizen" would happily settle on "Citizen Cope". Matching here is scored, an
/// exact normalized name always outranks a partial one, and a weak best match is refused
/// outright rather than returned as a guess.
enum MusicBrainzArtistMatcher {
    /// Score for one candidate against a normalized target. Higher is better; 0 is no match.
    static func score(candidate: MusicBrainzArtist, normalizedTarget target: String) -> Int {
        let name = LibraryTrackMatcher.normalize(candidate.name)
        let sortName = LibraryTrackMatcher.normalize(candidate.sortName ?? "")
        guard !target.isEmpty, !name.isEmpty else { return 0 }

        // MusicBrainz relevance, 0-100, as the tiebreaker between equally-shaped names.
        let relevance = min(max(candidate.score ?? 0, 0), 100)

        if name == target { return 10_000 + relevance }
        if sortName == target { return 9_000 + relevance }

        // A partial match is a fallback, never a winner over an exact one. It also has to be
        // substantial: "Ci" containing inside "Citizen" is noise, not a match.
        let shorter = min(name.count, target.count)
        let longer = max(name.count, target.count)
        guard longer > 0, Double(shorter) / Double(longer) >= 0.6 else { return 0 }
        if name.hasPrefix(target) || target.hasPrefix(name) { return 2_000 + relevance }
        if name.contains(target) || target.contains(name) { return 1_000 + relevance }
        return 0
    }

    /// Best candidate, or `nil` when nothing scores above the floor.
    static func bestMatch(for name: String, in candidates: [MusicBrainzArtist]) -> MusicBrainzArtist? {
        let target = LibraryTrackMatcher.normalize(name)
        guard !target.isEmpty else { return nil }
        let scored = candidates
            .map { (artist: $0, score: score(candidate: $0, normalizedTarget: target)) }
            .filter { $0.score > 0 }
        return scored.max { $0.score < $1.score }?.artist
    }
}

// MARK: - Refresh limiter

/// Gate on how often one artist's metadata may be refreshed.
///
/// The ordering around this is the entire point, not an optimisation. The limiter is consulted
/// **before** anything is expired or discarded, so a refused refresh can never be the thing that
/// deletes the page's content and then fails to replace it. Refusing is therefore always safe:
/// nothing has been given up at the moment the answer is "no".
///
/// Getting this backwards — expire, then discover the refresh is not allowed — empties the page
/// and leaves nothing to put back, which is strictly worse than not refreshing at all.
actor MusicBrainzRefreshLimiter {
    static let shared = MusicBrainzRefreshLimiter()

    /// Minimum spacing between accepted refreshes of the same artist. Long enough that a
    /// double-tap or an impatient repeat pull is turned down, short enough that a genuine
    /// second look a few seconds later is not.
    private let minimumInterval: TimeInterval = 10

    private var lastAcceptedByKey: [String: Date] = [:]

    /// Claims the right to refresh `key`. Returns false when the previous refresh was too
    /// recent. A granted claim is recorded immediately, so two callers racing cannot both win.
    func claim(key: String, now: Date = Date()) -> Bool {
        if let last = lastAcceptedByKey[key], now.timeIntervalSince(last) < minimumInterval {
            return false
        }
        lastAcceptedByKey[key] = now
        return true
    }

    /// Seconds until `key` may be refreshed again; zero when it is allowed now.
    func secondsUntilAllowed(key: String, now: Date = Date()) -> TimeInterval {
        guard let last = lastAcceptedByKey[key] else { return 0 }
        return max(0, minimumInterval - now.timeIntervalSince(last))
    }

    func reset() { lastAcceptedByKey.removeAll() }
}

// MARK: - Service

/// The one entry point to MusicBrainz metadata. Owns caching, staleness and pagination;
/// pacing lives one layer down in ``MusicBrainzRequestQueue``.
actor MusicBrainzService {
    static let shared = MusicBrainzService()

    /// Cached search pages, held for the session only. A search string is not a stable identity,
    /// so it gets no disk slot — but the artist rows it returns are seeded into the header
    /// cache by MBID, which is what makes opening one of them a zero-request page load.
    ///
    /// Stored as encoded bodies keyed by entity + query + offset so all three search entities
    /// share one bounded store rather than three unbounded ones.
    private var searchMemo: [String: Data] = [:]

    /// Insertion order for ``searchMemo``, oldest first.
    ///
    /// Present so eviction can drop the oldest entry instead of the whole map. The previous
    /// version called `removeAll()` on reaching its cap, which threw away the user's most recent
    /// queries — the ones most likely to be asked for again — and made every query after the
    /// two-hundredth cost a full request at one-per-second.
    private var searchMemoOrder: [String] = []

    private let searchMemoCapacity = 200

    // MARK: Search

    private func memoKey(entity: String, query: String, offset: Int) -> String {
        "\(entity)|\(LibraryTrackMatcher.normalize(query))|\(offset)"
    }

    private func memoized<Row: Sendable>(
        entity: String,
        query: String,
        offset: Int,
        decode: (Data) -> MusicBrainzSearchOutcome<Row>?
    ) -> MusicBrainzSearchOutcome<Row>? {
        guard let data = searchMemo[memoKey(entity: entity, query: query, offset: offset)] else {
            return nil
        }
        return decode(data)
    }

    private func store(_ data: Data, entity: String, query: String, offset: Int) {
        let key = memoKey(entity: entity, query: query, offset: offset)
        if searchMemo[key] == nil {
            searchMemoOrder.append(key)
            while searchMemoOrder.count > searchMemoCapacity {
                let evicted = searchMemoOrder.removeFirst()
                searchMemo[evicted] = nil
            }
        }
        searchMemo[key] = data
    }

    /// Turns a thrown queue error into the outcome that describes it.
    private nonisolated func outcome<Row: Sendable>(for error: Error) -> MusicBrainzSearchOutcome<Row> {
        if error is CancellationError { return .failed("Cancelled") }
        if let failure = error as? MusicBrainzRequestQueue.Failure, failure.isRateLimit {
            return .rateLimited
        }
        return .failed(error.localizedDescription)
    }

    /// The shortest query worth spending a request on.
    ///
    /// One character, not two. MusicBrainz has real one-character artists — `M`, `Ø`, `X` — and
    /// the previous two-character floor made them permanently unreachable.
    private static let minimumQueryLength = 1

    /// Artist search, one page.
    ///
    /// The rows come back with name, country, area, life-span and tags already filled, so a
    /// header rendered from one of these needs no follow-up lookup. Each row is written into
    /// the header cache under its MBID before returning, which is what lets the artist page
    /// open on a search hit without spending a request.
    func searchArtists(query: String, offset: Int = 0) async -> MusicBrainzSearchOutcome<MusicBrainzArtist> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else { return .ok(rows: [], total: 0) }

        if let memo: MusicBrainzSearchOutcome<MusicBrainzArtist> = memoized(
            entity: "artist", query: trimmed, offset: offset,
            decode: { data in
                guard let decoded = try? JSONDecoder()
                    .decode(MusicBrainzArtistSearchResponse.self, from: data) else { return nil }
                return .ok(rows: decoded.artists ?? [], total: decoded.count ?? 0)
            }
        ) {
            return memo
        }

        let response: MusicBrainzArtistSearchResponse
        do {
            response = try await MusicBrainzClient.searchArtists(query: trimmed, offset: offset)
        } catch {
            return outcome(for: error)
        }

        let artists = response.artists ?? []
        if let raw = try? JSONEncoder().encode(response) {
            store(raw, entity: "artist", query: trimmed, offset: offset)
        }
        for artist in artists {
            await seedHeaderCache(with: artist)
        }
        return .ok(rows: artists, total: response.count ?? artists.count)
    }

    /// Release-group (album / EP / single) search, one page.
    func searchReleaseGroups(
        query: String,
        offset: Int = 0
    ) async -> MusicBrainzSearchOutcome<MusicBrainzReleaseGroup> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else { return .ok(rows: [], total: 0) }

        if let memo: MusicBrainzSearchOutcome<MusicBrainzReleaseGroup> = memoized(
            entity: "release-group", query: trimmed, offset: offset,
            decode: { data in
                guard let decoded = try? JSONDecoder()
                    .decode(MusicBrainzReleaseGroupSearchResponse.self, from: data) else { return nil }
                return .ok(rows: decoded.releaseGroups ?? [], total: decoded.count ?? 0)
            }
        ) {
            return memo
        }

        let response: MusicBrainzReleaseGroupSearchResponse
        do {
            response = try await MusicBrainzClient.searchReleaseGroups(query: trimmed, offset: offset)
        } catch {
            return outcome(for: error)
        }

        let groups = response.releaseGroups ?? []
        if let raw = try? JSONEncoder().encode(response) {
            store(raw, entity: "release-group", query: trimmed, offset: offset)
        }
        return .ok(rows: groups, total: response.count ?? groups.count)
    }

    /// Recording (song) search, one page.
    ///
    /// Rows arrive one per *performance*, so a popular title returns the same song many times
    /// over. Collapsing that is the caller's job — see ``MusicBrainzSearchFeed`` — because
    /// dedup has to persist across pages and this method only sees one.
    func searchRecordings(
        query: String,
        offset: Int = 0
    ) async -> MusicBrainzSearchOutcome<MusicBrainzRecording> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else { return .ok(rows: [], total: 0) }

        if let memo: MusicBrainzSearchOutcome<MusicBrainzRecording> = memoized(
            entity: "recording", query: trimmed, offset: offset,
            decode: { data in
                guard let decoded = try? JSONDecoder()
                    .decode(MusicBrainzRecordingSearchResponse.self, from: data) else { return nil }
                return .ok(rows: decoded.recordings ?? [], total: decoded.count ?? 0)
            }
        ) {
            return memo
        }

        let response: MusicBrainzRecordingSearchResponse
        do {
            response = try await MusicBrainzClient.searchRecordings(query: trimmed, offset: offset)
        } catch {
            return outcome(for: error)
        }

        let recordings = response.recordings ?? []
        if let raw = try? JSONEncoder().encode(response) {
            store(raw, entity: "recording", query: trimmed, offset: offset)
        }
        return .ok(rows: recordings, total: response.count ?? recordings.count)
    }

    /// Stores a search row as a `tags`-only header payload. Kept under its own key so it can
    /// never be mistaken for a `tags+ratings` lookup body, which carries a field this one lacks.
    private func seedHeaderCache(with artist: MusicBrainzArtist) async {
        let key = MusicBrainzCacheStore.artistKey(mbid: artist.id, inc: ["tags"])
        guard let raw = try? JSONEncoder().encode(artist) else { return }
        await MusicBrainzCacheStore.saveAsync(
            MusicBrainzCacheEntry(
                key: key,
                fetchedAt: Date(),
                totalCount: nil,
                heldOffsets: [0],
                rawPages: [raw],
                isComplete: true
            )
        )
    }

    /// Clears the in-session search memo, so a verification run can measure what a relaunched
    /// app would spend when only the on-disk caches survive.
    func clearSessionMemoForVerification() {
        searchMemo.removeAll()
        searchMemoOrder.removeAll()
    }

    // MARK: Header

    /// The artist header for an MBID.
    ///
    /// Reads the cache first — the search-seeded `tags` payload counts, which is the whole
    /// point of seeding it — and only reaches the network on a genuine cold open or a refresh.
    /// A stale copy is returned as-is when the refresh fails.
    func artistHeader(mbid: String, forceRefresh: Bool = false) async -> MusicBrainzArtist? {
        let lookupKey = MusicBrainzCacheStore.artistKey(mbid: mbid, inc: MusicBrainzClient.artistLookupInc)
        let searchKey = MusicBrainzCacheStore.artistKey(mbid: mbid, inc: ["tags"])

        var cached: MusicBrainzArtist?
        var cachedIsExpired = true
        for key in [lookupKey, searchKey] {
            guard let entry = await MusicBrainzCacheStore.loadAsync(key),
                  let raw = entry.rawPages.first,
                  let decoded = try? JSONDecoder().decode(MusicBrainzArtist.self, from: raw)
            else { continue }
            cached = decoded
            cachedIsExpired = entry.isExpired
            break
        }

        if let cached, !forceRefresh, !cachedIsExpired { return cached }

        guard let fetched = try? await MusicBrainzClient.artist(mbid: mbid) else {
            // Refresh failed, so the retained copy is the answer rather than an error. It is
            // reached only on failure — an expired header is never served ahead of a refetch.
            return cached
        }
        await MusicBrainzCacheStore.saveAsync(
            MusicBrainzCacheEntry(
                key: lookupKey,
                fetchedAt: Date(),
                totalCount: nil,
                heldOffsets: [0],
                rawPages: [fetched.raw],
                isComplete: true
            )
        )
        return fetched.artist
    }

    // MARK: Release → release group

    /// Maps a MusicBrainz *release* id to the *release group* it belongs to.
    ///
    /// Needed because the two sides of the discography match speak different id types. A browsed
    /// discography is release groups; Navidrome's Subsonic API reports a release id and has no
    /// way to report the group. Comparing those directly matches nothing — not rarely, but never
    /// — so without this hop an id-first match would be dead code on that backend.
    ///
    /// The mapping is immutable once MusicBrainz has it, so it is cached permanently and the
    /// week-long freshness rule does not apply: a release never changes which group it belongs to.
    /// Only owned albums that failed to match by any other means are ever looked up, so the usual
    /// cost on an artist page is zero requests.
    func releaseGroupId(forReleaseId releaseId: String) async -> String? {
        let key = MusicBrainzCacheStore.releaseToGroupKey(releaseId: releaseId)
        if let entry = await MusicBrainzCacheStore.loadAsync(key),
           let raw = entry.rawPages.first,
           let cached = String(data: raw, encoding: .utf8)?.mbTrimmedNonEmpty {
            return cached == Self.noReleaseGroupSentinel ? nil : cached
        }

        guard let data = try? await MusicBrainzRequestQueue.shared.perform(
            path: "/release/\(releaseId)",
            query: [URLQueryItem(name: "inc", value: "release-groups")]
        ) else { return nil }

        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let groupId = ((obj?["release-group"] as? [String: Any])?["id"] as? String)?.mbTrimmedNonEmpty

        // A negative answer is cached too. Without that, an album whose release MusicBrainz does
        // not know would re-ask on every single page open.
        let stored = groupId ?? Self.noReleaseGroupSentinel
        await MusicBrainzCacheStore.saveAsync(
            MusicBrainzCacheEntry(
                key: key,
                fetchedAt: Date(),
                totalCount: nil,
                heldOffsets: [0],
                rawPages: [Data(stored.utf8)],
                isComplete: true
            )
        )
        return groupId
    }

    private static let noReleaseGroupSentinel = "-"

    /// Resolves a bare artist name to a MusicBrainz artist, for pages opened without a search
    /// hit in hand. This is the cold-open path the header/discography split is designed around:
    /// it costs one search request, and the row it returns is a complete header.
    func resolveArtist(named name: String) async -> MusicBrainzArtist? {
        let normalized = LibraryTrackMatcher.normalize(name)
        let key = MusicBrainzCacheStore.artistNameResolutionKey(normalizedName: normalized)

        // Re-opening an artist page must not re-buy an answer already on disk. Without this, every
        // page opened by name spends a search request on each cold launch just to learn an MBID
        // that has not changed — which is the "hits MusicBrainz every time I open an artist"
        // outcome, arriving through name resolution rather than through the discography fetch.
        if let entry = await MusicBrainzCacheStore.loadAsync(key), !entry.isExpired,
           let raw = entry.rawPages.first,
           let decoded = try? JSONDecoder().decode(MusicBrainzArtist.self, from: raw) {
            return decoded
        }

        let candidates = await searchArtists(query: name).rows
        guard let best = MusicBrainzArtistMatcher.bestMatch(for: name, in: candidates) else { return nil }
        if let raw = try? JSONEncoder().encode(best) {
            await MusicBrainzCacheStore.saveAsync(
                MusicBrainzCacheEntry(
                    key: key, fetchedAt: Date(), totalCount: nil,
                    heldOffsets: [0], rawPages: [raw], isComplete: true
                )
            )
        }
        return best
    }

    // MARK: Discography

    /// Full discography for an artist, paged and delivered as it arrives.
    ///
    /// `onProgress` fires once per landed page — and once up front when a cached copy exists —
    /// so the page can paint the rows it has while placeholders stand in for the rest. The
    /// total arrives with the first page, so the placeholder count is the server's number
    /// rather than a guess.
    ///
    /// Cache behaviour, in order:
    /// - A complete, fresh entry is served without touching the network.
    /// - Otherwise any existing entry is emitted first, so a stale copy paints immediately and
    ///   stands as the fallback, and then a full pass runs.
    /// - The pass overwrites the entry only if it completes. A pass that dies mid-pagination
    ///   leaves the previous entry exactly where it was.
    @discardableResult
    func discography(
        artistMBID: String,
        forceRefresh: Bool = false,
        onProgress: (@Sendable (MusicBrainzDiscography) -> Void)? = nil
    ) async -> MusicBrainzDiscography? {
        let key = MusicBrainzCacheStore.releaseGroupBrowseKey(artistMBID: artistMBID)
        let cachedEntry = await MusicBrainzCacheStore.loadAsync(key)
        let cached = cachedEntry.flatMap { decode(entry: $0, artistMBID: artistMBID) }

        // A copy still inside its freshness window is current data and is served as such.
        if let cached, cached.isComplete, !forceRefresh, cachedEntry?.isExpired == false {
            onProgress?(cached)
            return cached
        }

        // Everything past this point needs the network. Ask the limiter FIRST — before the
        // expired copy is set aside and before a single page is fetched. Refusing here costs
        // nothing because nothing has been discarded yet; refusing after would leave the page
        // holding neither the old data nor the new.
        guard await MusicBrainzRefreshLimiter.shared.claim(key: artistMBID) else {
            return MusicBrainzDiscography(
                artistMBID: artistMBID,
                total: cached?.total ?? 0,
                releaseGroups: cached?.releaseGroups ?? [],
                isComplete: cached?.isComplete ?? false,
                fetchedAt: cached?.fetchedAt ?? Date(),
                // Untouched, not expired — the refresh never ran, so whatever the page is
                // already showing remains valid and stays exactly where it is.
                source: cached == nil ? .network : .cache,
                refreshRefused: true
            )
        }

        // Deliberately no emission of the expired copy here. An out-of-date entry is never
        // painted and then swapped when the refetch lands; the page shows its loading state
        // until real data arrives. The old copy is retained only as a failure fallback below,
        // and when it surfaces it is labelled as a saved copy rather than passed off as current.
        var collected: [MusicBrainzReleaseGroup] = []
        var seen = Set<String>()
        var rawPages: [Data] = []
        var heldOffsets: [Int] = []
        var total = 0
        var offset = 0
        /// Rows handed over by the server, before de-duplication.
        var receivedRows = 0
        /// Whether any response carried `release-group-count`. Without it there is nothing to
        /// check a short page against, and the short page has to be taken at its word.
        var sawCount = false
        /// Whether the loop stopped because the server signalled the end rather than erroring.
        var reachedEnd = false

        while true {
            guard let response = try? await MusicBrainzClient.releaseGroupPage(
                artistMBID: artistMBID,
                offset: offset
            ) else {
                // The pass died after exhausting its retries. Nothing is written to disk — a
                // partial set wearing a fresh date would look complete for ever — so the
                // previous entry survives untouched.
                return failureResult(
                    artistMBID: artistMBID,
                    collected: collected,
                    total: total,
                    cached: cached
                )
            }

            if let count = response.page.releaseGroupCount {
                total = count
                sawCount = true
            }
            let batch = response.page.releaseGroups ?? []
            // Counted before de-duplication: this measures what the server actually handed
            // over, which is what "did we receive everything it said exists" has to be judged
            // on. De-duplicating first would let a repeated row read as a missing one.
            receivedRows += batch.count
            for group in batch where seen.insert(group.id).inserted {
                collected.append(group)
            }
            rawPages.append(response.raw)
            heldOffsets.append(offset)

            onProgress?(
                MusicBrainzDiscography(
                    artistMBID: artistMBID,
                    total: max(total, collected.count),
                    releaseGroups: sorted(collected),
                    isComplete: isPassComplete(received: receivedRows, total: total, sawCount: sawCount, reachedEnd: false),
                    fetchedAt: Date(),
                    source: .network
                )
            )

            // A page shorter than the page size is the server saying there is no more. That is
            // a terminator, but on its own it is not proof of completeness: a hiccup returning
            // a short page mid-run looks identical to the real last page. The count below is
            // what tells the two apart.
            if batch.count < MusicBrainzClient.browsePageSize {
                reachedEnd = true
                break
            }
            offset += MusicBrainzClient.browsePageSize
            if sawCount, offset >= total {
                reachedEnd = true
                break
            }
        }

        // Completeness is derived, never assumed. Reaching the end of the loop is not the same
        // as having everything: an empty or short page arriving mid-pagination also ends the
        // loop, and treating that as a finished pass would cache a truncated discography under
        // a fresh date -- silent data loss that looks healthy and never re-fetches.
        let complete = isPassComplete(received: receivedRows, total: total, sawCount: sawCount, reachedEnd: reachedEnd)
        guard complete else {
            return failureResult(
                artistMBID: artistMBID,
                collected: collected,
                total: total,
                cached: cached
            )
        }

        let result = MusicBrainzDiscography(
            artistMBID: artistMBID,
            total: max(total, collected.count),
            releaseGroups: sorted(collected),
            isComplete: true,
            fetchedAt: Date(),
            source: .network
        )
        await MusicBrainzCacheStore.saveAsync(
            MusicBrainzCacheEntry(
                key: key,
                fetchedAt: result.fetchedAt,
                totalCount: result.total,
                heldOffsets: heldOffsets,
                rawPages: rawPages,
                isComplete: true
            )
        )
        return result
    }

    /// What a failed pass hands back.
    ///
    /// Two different things can be on screen when a pass dies, and they are not interchangeable:
    ///
    /// - **Pages that already landed in this pass are kept.** They are real, current data that
    ///   the reader is already looking at. Three pages in with the fourth failing must not blank
    ///   the three hundred releases already rendered, so the partial wins whenever it has rows.
    /// - **Only when this pass produced nothing at all** does the retained expired copy surface,
    ///   marked `.expiredFallback` so the UI labels it as a saved copy. That is the difference
    ///   between an empty page and an honest old one.
    ///
    /// Either way `refreshFailed` is set, because the caller has to be able to say out loud that
    /// the refresh did not succeed.
    nonisolated func failureResult(
        artistMBID: String,
        collected: [MusicBrainzReleaseGroup],
        total: Int,
        cached: MusicBrainzDiscography?
    ) -> MusicBrainzDiscography {
        if !collected.isEmpty {
            return MusicBrainzDiscography(
                artistMBID: artistMBID,
                total: max(total, collected.count),
                releaseGroups: sorted(collected),
                isComplete: false,
                fetchedAt: Date(),
                source: .network,
                refreshFailed: true
            )
        }
        return MusicBrainzDiscography(
            artistMBID: artistMBID,
            total: cached?.total ?? 0,
            releaseGroups: cached?.releaseGroups ?? [],
            isComplete: cached?.isComplete ?? false,
            fetchedAt: cached?.fetchedAt ?? Date(),
            source: cached == nil ? .network : .expiredFallback,
            refreshFailed: true
        )
    }

    /// Did this pass actually get everything?
    ///
    /// When the server reported a total, that total is the authority and the row count has to
    /// meet it — a short page arriving mid-run is indistinguishable from the real last page by
    /// shape alone, and this is what separates them. With no total reported there is nothing to
    /// check against, so the server ending the sequence is taken at its word.
    nonisolated func isPassComplete(
        received: Int,
        total: Int,
        sawCount: Bool,
        reachedEnd: Bool
    ) -> Bool {
        guard sawCount else { return reachedEnd }
        return received >= total
    }

    private func decode(entry: MusicBrainzCacheEntry, artistMBID: String) -> MusicBrainzDiscography? {
        var groups: [MusicBrainzReleaseGroup] = []
        var seen = Set<String>()
        for raw in entry.rawPages {
            guard let page = try? JSONDecoder().decode(MusicBrainzReleaseGroupBrowseResponse.self, from: raw)
            else { continue }
            for group in page.releaseGroups ?? [] where seen.insert(group.id).inserted {
                groups.append(group)
            }
        }
        guard !groups.isEmpty || entry.totalCount == 0 else { return nil }
        return MusicBrainzDiscography(
            artistMBID: artistMBID,
            total: max(entry.totalCount ?? groups.count, groups.count),
            releaseGroups: sorted(groups),
            isComplete: entry.isComplete,
            fetchedAt: entry.fetchedAt,
            source: entry.isExpired ? .expiredFallback : .cache
        )
    }

    /// Newest first, undated releases last, ties broken by title so the order is stable
    /// across passes (MusicBrainz browse order is not).
    private nonisolated func sorted(_ groups: [MusicBrainzReleaseGroup]) -> [MusicBrainzReleaseGroup] {
        groups.sorted { lhs, rhs in
            switch (lhs.releaseDate, rhs.releaseDate) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }
}
