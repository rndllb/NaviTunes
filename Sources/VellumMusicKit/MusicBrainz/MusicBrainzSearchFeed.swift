import Foundation

// MARK: - Entity scope

/// The entity tabs under the Discover search field.
///
/// MusicBrainz answers artists, albums and songs from three separate endpoints with three
/// separate relevance rankings and three separate totals. Tabs rather than one merged list is
/// what makes pagination possible at all: an infinite-scrolling tail needs a stable ordering to
/// append to, and a list re-sorted across three sources by a local relevance score has no stable
/// tail — new pages would insert into the middle and shuffle what the user is looking at.
///
/// ``all`` keeps the merged, locally-ranked view for the common case where the user just wants
/// the best answer, and deliberately does not paginate.
enum MusicBrainzSearchEntity: String, CaseIterable, Hashable, Sendable {
    case all
    case artists
    case albums
    case songs

    var title: String {
        switch self {
        case .all: return "All"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .songs: return "Songs"
        }
    }

    /// Whether this tab supports an infinite-scrolling tail.
    var paginates: Bool { self != .all }
}

// MARK: - Song row

/// One song row after duplicate performances have been collapsed.
///
/// Wraps the winning ``MusicBrainzRecording`` rather than replacing it, and records how many
/// other recordings collapsed into it. That count is not shown to the user; it exists because
/// a row that swallowed forty performances and a row that swallowed none are very different
/// things when something looks wrong, and losing the number makes that undiagnosable.
struct MusicBrainzSongRow: Identifiable, Hashable, Sendable {
    let recording: MusicBrainzRecording
    /// Recordings collapsed into this row, including the winner. Always at least 1.
    let performanceCount: Int

    var id: String { recording.id }
    var title: String { recording.title }
    var artist: String { recording.artistCredit?.creditLine ?? "" }
    var albumTitle: String? { recording.albumTitle }
    var score: Int { recording.score ?? 0 }
}

// MARK: - Feed

/// Query state for the three paginated MusicBrainz search tabs.
///
/// Owns three independent cursors, because the tabs are independent: paging Songs must not
/// disturb Albums, and switching tabs must not re-buy a page already fetched. Pacing is one
/// layer down in ``MusicBrainzRequestQueue`` — nothing here needs to know about the
/// one-request-per-second floor beyond the fact that requests are expensive and must not be
/// spent twice on the same thing.
@MainActor
final class MusicBrainzSearchFeed: ObservableObject {
    @Published private(set) var artists: [MusicBrainzArtist] = []
    @Published private(set) var albums: [MusicBrainzReleaseGroup] = []
    @Published private(set) var songs: [MusicBrainzSongRow] = []

    /// The first page for the active tab is in flight and there is nothing to show yet.
    @Published private(set) var isLoading = false
    /// A further page is in flight below rows already on screen.
    @Published private(set) var isLoadingMore = false
    /// Why the last attempt produced nothing, or `nil` when it succeeded.
    ///
    /// Held separately from an empty row list so the view can tell "no such artist" from
    /// "MusicBrainz refused" — the distinction the previous search silently discarded.
    @Published private(set) var errorMessage: String?
    /// The failure was a rate-limit refusal, which is worth offering a retry for.
    @Published private(set) var isRateLimited = false

    /// How many *new, distinct* rows one `loadMore` tries to add before it stops.
    ///
    /// Needed because dedup makes a page's yield unpredictable: 100 recordings of a popular
    /// title can collapse to two rows. Appending two rows for a scroll-to-bottom reads as a
    /// broken list, so a `loadMore` keeps fetching until it has something worth showing.
    private static let minimumRowsPerLoadMore = 20

    /// Ceiling on pages one `loadMore` may fetch. At one request per second an unbounded loop
    /// could stall the queue for a minute chasing a target it will never reach.
    private static let maximumPagesPerLoadMore = 3

    /// Per-tab pagination state.
    private struct Cursor {
        /// Rows the server has handed over, which is what `offset` must advance by. Deliberately
        /// not the displayed row count: dedup makes those diverge, and paging by the displayed
        /// count would re-request rows already collapsed and loop forever on a popular title.
        var fetched = 0
        /// The server's own total match count.
        var total = 0
        var reachedEnd = false
        /// Identity of every row already emitted, so a later page cannot re-render one.
        var seen = Set<String>()
    }

    private var cursors: [MusicBrainzSearchEntity: Cursor] = [:]
    private var query = ""
    /// Invalidation token. Bumped by ``start`` only — see ``loadMore(entity:)``.
    private var generation: UInt = 0

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }

    /// Rows currently held for `entity`, as a count. Used by the view to decide whether it has
    /// anything to show before a spinner.
    func rowCount(for entity: MusicBrainzSearchEntity) -> Int {
        switch entity {
        case .all: return artists.count + albums.count + songs.count
        case .artists: return artists.count
        case .albums: return albums.count
        case .songs: return songs.count
        }
    }

    /// Whether `entity` has more rows the server says exist.
    func hasMore(for entity: MusicBrainzSearchEntity) -> Bool {
        guard entity.paginates else { return false }
        return !(cursors[entity]?.reachedEnd ?? false)
    }

    // MARK: Starting a search

    /// Begins a new search, discarding everything held for the previous query.
    ///
    /// `All` fetches the first page of all three entities so the merged view has something from
    /// each. That is three serialized requests and therefore around three seconds — which is why
    /// the caller debounces this rather than firing per keystroke.
    func start(query rawQuery: String, entity: MusicBrainzSearchEntity) async {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        generation &+= 1
        let generation = self.generation

        guard !trimmed.isEmpty else {
            reset()
            return
        }

        query = trimmed
        cursors = [:]
        artists = []
        albums = []
        songs = []
        errorMessage = nil
        isRateLimited = false
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }

        await fetchFirstPages(for: entity, generation: generation)
    }

    /// Loads the first page for whichever entities `entity` needs, if not already held.
    ///
    /// Called both by ``start`` and when the user switches tabs, so moving to a tab whose page
    /// is already in hand costs nothing.
    func ensureLoaded(entity: MusicBrainzSearchEntity) async {
        guard !query.isEmpty else { return }
        let needed = entity == .all
            ? [MusicBrainzSearchEntity.artists, .albums, .songs]
            : [entity]
        guard needed.contains(where: { cursors[$0] == nil }) else { return }

        let generation = self.generation
        isLoading = rowCount(for: entity) == 0
        defer { if generation == self.generation { isLoading = false } }
        await fetchFirstPages(for: entity, generation: generation)
    }

    private func fetchFirstPages(for entity: MusicBrainzSearchEntity, generation: UInt) async {
        let targets: [MusicBrainzSearchEntity] = entity == .all ? [.artists, .albums, .songs] : [entity]
        for target in targets where cursors[target] == nil {
            await fetchPage(entity: target, generation: generation)
            if generation != self.generation { return }
        }
    }

    // MARK: Paging

    /// Called from the trailing row of a paginated tab.
    ///
    /// Deliberately does **not** bump `generation` — that token belongs to ``start``, and
    /// invalidating it here would leave a concurrent first load with `isLoading` pinned true and
    /// the skeleton on screen for ever. (Same reasoning as `RadioDirectoryFeed.loadMoreIfNeeded`.)
    func loadMore(entity: MusicBrainzSearchEntity) async {
        guard entity.paginates, !query.isEmpty, !isLoading, !isLoadingMore else { return }
        guard let cursor = cursors[entity], !cursor.reachedEnd else { return }

        let generation = self.generation
        isLoadingMore = true
        defer { if generation == self.generation { isLoadingMore = false } }

        let startingRows = rowCount(for: entity)
        var pages = 0
        // Keeps fetching until the scroll has something worth showing. One page of a popular
        // song title can collapse to a single new row after dedup, and appending one row for a
        // scroll-to-bottom looks like the list is stuck.
        while pages < Self.maximumPagesPerLoadMore,
              rowCount(for: entity) - startingRows < Self.minimumRowsPerLoadMore,
              !(cursors[entity]?.reachedEnd ?? true)
        {
            await fetchPage(entity: entity, generation: generation)
            if generation != self.generation { return }
            pages += 1
        }
    }

    // MARK: One page

    private func fetchPage(entity: MusicBrainzSearchEntity, generation: UInt) async {
        var cursor = cursors[entity] ?? Cursor()
        let offset = cursor.fetched
        let query = self.query

        switch entity {
        case .all:
            return

        case .artists:
            let outcome = await MusicBrainzService.shared.searchArtists(query: query, offset: offset)
            guard generation == self.generation else { return }
            guard applyFailure(outcome.failureMessage, isRateLimit: isRateLimit(outcome)) == false else { return }
            let rows = outcome.rows
            cursor.fetched += rows.count
            cursor.total = outcome.total
            for artist in rows where cursor.seen.insert(artist.id).inserted {
                artists.append(artist)
            }
            cursor.reachedEnd = Self.reachedEnd(received: rows.count, fetched: cursor.fetched, total: cursor.total)
            cursors[entity] = cursor

        case .albums:
            let outcome = await MusicBrainzService.shared.searchReleaseGroups(query: query, offset: offset)
            guard generation == self.generation else { return }
            guard applyFailure(outcome.failureMessage, isRateLimit: isRateLimit(outcome)) == false else { return }
            let rows = outcome.rows
            cursor.fetched += rows.count
            cursor.total = outcome.total
            // Deduped on MBID, not on title+artist. A release *group* is already the collapsed
            // level — an album and its remasters are one group — so two groups sharing a title
            // and artist are genuinely different releases (an album and a same-named single, a
            // studio record and its live counterpart) and both belong on screen.
            for group in rows where cursor.seen.insert(group.id).inserted {
                albums.append(group)
            }
            cursor.reachedEnd = Self.reachedEnd(received: rows.count, fetched: cursor.fetched, total: cursor.total)
            cursors[entity] = cursor

        case .songs:
            let outcome = await MusicBrainzService.shared.searchRecordings(query: query, offset: offset)
            guard generation == self.generation else { return }
            guard applyFailure(outcome.failureMessage, isRateLimit: isRateLimit(outcome)) == false else { return }
            let rows = outcome.rows
            cursor.fetched += rows.count
            cursor.total = outcome.total
            appendCollapsed(recordings: rows, cursor: &cursor)
            cursor.reachedEnd = Self.reachedEnd(received: rows.count, fetched: cursor.fetched, total: cursor.total)
            cursors[entity] = cursor
        }
    }

    /// Collapses a page of recordings onto the song list.
    ///
    /// This is the step that makes the recording endpoint usable. Searching `Paranoid Android`
    /// returns eleven identical Radiohead rows in its first twelve results, each with a distinct
    /// MBID — so the collapse key cannot be the MBID, and a per-page dedup would not help either
    /// since the duplicates continue across page boundaries. The key is normalized title plus
    /// credited artist, and the ``Cursor/seen`` set persists for the whole query.
    ///
    /// The first row to arrive under a key wins, which is the highest-scoring one: MusicBrainz
    /// returns search results in descending relevance and pages are appended in order.
    private func appendCollapsed(recordings: [MusicBrainzRecording], cursor: inout Cursor) {
        // Extra performances are counted per key, including for keys whose row landed on an
        // earlier page, so a page that is entirely duplicates still updates the tallies rather
        // than discarding what it learned.
        var extraPerformances: [String: Int] = [:]
        var newKeys: Set<String> = []
        var arrivals: [(key: String, recording: MusicBrainzRecording)] = []

        for recording in recordings {
            let key = Self.songIdentityKey(recording)
            if cursor.seen.contains(key) || newKeys.contains(key) {
                extraPerformances[key, default: 0] += 1
            } else {
                newKeys.insert(key)
                arrivals.append((key, recording))
            }
        }

        for arrival in arrivals {
            cursor.seen.insert(arrival.key)
            songs.append(
                MusicBrainzSongRow(
                    recording: arrival.recording,
                    performanceCount: 1 + (extraPerformances[arrival.key] ?? 0)
                )
            )
        }

        // Bump the tally on rows that landed on an earlier page.
        let carriedOver = extraPerformances.filter { !newKeys.contains($0.key) }
        guard !carriedOver.isEmpty else { return }
        for index in songs.indices {
            let key = Self.songIdentityKey(songs[index].recording)
            guard let extra = carriedOver[key] else { continue }
            songs[index] = MusicBrainzSongRow(
                recording: songs[index].recording,
                performanceCount: songs[index].performanceCount + extra
            )
        }
    }

    /// Collapse key for a song: normalized title plus normalized credited artist.
    ///
    /// Same normalization as every other match in the app, so punctuation and diacritics cannot
    /// split one song into two rows.
    static func songIdentityKey(_ recording: MusicBrainzRecording) -> String {
        let title = LibraryTrackMatcher.normalize(recording.title)
        let artist = LibraryTrackMatcher.normalize(recording.artistCredit?.creditLine ?? "")
        return "\(title)|\(artist)"
    }

    /// Whether the server has nothing further to give.
    ///
    /// Prefers the reported total over an empty page, because the total is definitive and
    /// arrives with the first page — probing for an empty page costs one wasted request at the
    /// end of every result set. The short-page test stays as a backstop for a response that
    /// reports no total.
    private static func reachedEnd(received: Int, fetched: Int, total: Int) -> Bool {
        if received == 0 { return true }
        if total > 0 { return fetched >= total }
        return received < MusicBrainzClient.searchPageSize
    }

    private func isRateLimit<Row: Sendable>(_ outcome: MusicBrainzSearchOutcome<Row>) -> Bool {
        if case .rateLimited = outcome { return true }
        return false
    }

    /// Records a failure and reports whether one happened.
    ///
    /// A failure never clears rows already on screen. Pages that landed are real data the user
    /// is already reading, and blanking them to show an error is a worse outcome than an
    /// incomplete list with a message under it.
    private func applyFailure(_ message: String?, isRateLimit: Bool) -> Bool {
        guard let message else {
            errorMessage = nil
            self.isRateLimited = false
            return false
        }
        // A cancelled page is not a failure worth telling the user about — the query moved on.
        if message == "Cancelled" { return true }
        errorMessage = message
        self.isRateLimited = isRateLimit
        return true
    }

    private func reset() {
        query = ""
        cursors = [:]
        artists = []
        albums = []
        songs = []
        errorMessage = nil
        isRateLimited = false
        isLoading = false
        isLoadingMore = false
    }

    /// Drops everything and forgets the query. Called when the search field is cleared.
    func clear() {
        generation &+= 1
        reset()
    }

    /// Re-runs the current query from scratch. Used by the rate-limit retry affordance.
    func retry(entity: MusicBrainzSearchEntity) async {
        let current = query
        guard !current.isEmpty else { return }
        await start(query: current, entity: entity)
    }
}
