import Combine
import Foundation
import SwiftUI

/// Selector for what the artist page should load. We accept either a resolved
/// server artist id (`LibraryArtistSummary`) or a free-form name string (Now Playing
/// "Go to Artist" only carries a name, as do album-hero artist taps).
enum ArtistPageInput: Hashable {
    case libraryArtist(LibraryArtistSummary)
    case named(String)
    /// Opened from a search hit whose MusicBrainz payload is already in hand.
    ///
    /// The search response carries name, country, area, life-span and tags, so a page entered
    /// this way renders its header with no request at all. Only a cold open — every other case
    /// here — has to resolve the name and look the artist up.
    case musicBrainzArtist(MusicBrainzArtist)
    /// Opened from a row that knew the artist's MBID but not the rest of their metadata.
    ///
    /// Preferred over ``named`` wherever an id exists. A name has to be searched for and can
    /// resolve to the wrong artist entirely — two acts sharing a name are common enough that
    /// this is a real failure, not a theoretical one — while an id identifies exactly one.
    case musicBrainzArtistId(id: String, name: String)

    var displayName: String {
        switch self {
        case .libraryArtist(let a): return a.name
        case .named(let n): return n
        case .musicBrainzArtist(let a): return a.name
        case .musicBrainzArtistId(_, let name): return name
        }
    }

    var serverArtworkURL: URL? {
        switch self {
        case .libraryArtist(let a): return a.artworkURL
        case .named, .musicBrainzArtist, .musicBrainzArtistId: return nil
        }
    }

    var libraryArtistId: String? {
        if case .libraryArtist(let a) = self { return a.id }
        return nil
    }

    /// The MusicBrainz header this page was handed on entry, when it was handed one.
    var musicBrainzArtist: MusicBrainzArtist? {
        if case .musicBrainzArtist(let a) = self { return a }
        return nil
    }

    /// The MusicBrainz artist id this page was opened with, however it arrived.
    var musicBrainzArtistId: String? {
        switch self {
        case .musicBrainzArtist(let a): return a.id
        case .musicBrainzArtistId(let id, _): return id
        case .libraryArtist(let a): return a.musicBrainzArtistId
        case .named: return nil
        }
    }

    /// Cover-zoom key for the artist *page* — the id its hero registers and the one the tiles
    /// and rows that open it mark themselves with.
    ///
    /// Derived from the name rather than an id because the entry points know a name and often
    /// nothing else, and because `.libraryArtist` and `.named` for the same artist have to land
    /// on one key or the push and the pop would disagree about which cover is in play.
    var coverZoomPageId: String { Self.coverZoomPageId(forName: displayName) }

    static func coverZoomPageId(forName name: String) -> String {
        "artist-page:" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// One row in the artist page's "Top Songs" section. Either matches a real track
/// on the user's server (`libraryTrack` non-nil, fully playable) or a scrobbled
/// title that isn't resolved locally yet.
struct ArtistTopSongRow: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let albumTitle: String?
    let releaseYear: Int?
    let artworkURL: URL?
    let libraryTrack: Track?
    let playcount: Int
}

/// Bucketing of a release for the artist page's discography sections.
///
/// `CaseIterable` in declaration order, and that order is the shelf order the page renders
/// (`ArtistPageView.swift:78-81`). "Request Missing" walks `allCases`, so a bucket added
/// here is picked up by both the shelves and the bulk request rather than only the shelves.
enum ArtistDiscographyBucket: Hashable, CaseIterable {
    case albums
    case singlesAndEPs
    case live
    case compilations

    /// How the "Request Missing" confirmation names this bucket's share of the count.
    /// Singular where the count is 1, so "1 albums" never reaches the screen.
    func requestPlanLabel(count: Int) -> String {
        switch self {
        case .albums: return count == 1 ? "1 album" : "\(count) albums"
        case .singlesAndEPs: return count == 1 ? "1 single or EP" : "\(count) singles & EPs"
        case .live: return count == 1 ? "1 live album" : "\(count) live albums"
        case .compilations: return count == 1 ? "1 compilation" : "\(count) compilations"
        }
    }
}

/// A discography card — either an album on the user's server (playable) or a
/// plugin catalog album not present locally (links to BrowseAlbumDetailView for request).
struct ArtistDiscographyItem: Identifiable, Hashable {
    enum Source: Hashable {
        case libraryAlbum(AlbumSummary)
        case remote(AcquisitionRelease)
    }

    let id: String
    let title: String
    let artist: String
    let bucket: ArtistDiscographyBucket
    let releaseYear: Int?
    /// Best-effort sort date — the most precise date the source exposes
    /// (Jellyfin/Subsonic ``AlbumSummary/releaseDate`` when present, otherwise
    /// the first-of-year fallback derived from ``releaseYear``; for a plugin
    /// release, ``AcquisitionRelease/releaseDate`` when present).
    let releaseSortDate: Date?
    let artworkURL: URL?
    let source: Source

    var libraryAlbum: AlbumSummary? {
        if case .libraryAlbum(let a) = source { return a }
        return nil
    }

    var remoteAlbum: AcquisitionRelease? {
        if case .remote(let a) = source { return a }
        return nil
    }

    /// True when the card represents a release the user's server doesn't have —
    /// tapping should open the request flow (``BrowseAlbumDetailView`` via the request backend).
    var needsRequest: Bool {
        if case .remote = source { return true }
        return false
    }
}

/// View state for ``ArtistPageView``. Loads server data + enrichment in parallel
/// and publishes each slice independently so the matching section can render the
/// moment its data arrives. Empty/failed slices leave their section hidden.
@MainActor
final class ArtistViewModel: ObservableObject {
    let input: ArtistPageInput

    @Published private(set) var resolvedArtistId: String?
    @Published private(set) var serverAlbums: [AlbumSummary] = []
    @Published private(set) var serverTracks: [Track] = []
    @Published private(set) var topSongs: [ArtistTopSongRow] = []
    @Published private(set) var discography: [ArtistDiscographyBucket: [ArtistDiscographyItem]] = [:]
    @Published private(set) var similarArtists: [LastFmSimilarArtist] = []
    @Published private(set) var pluginProfile: AcquisitionArtistProfile?
    @Published private(set) var jellyfinOverview: String?

    @Published private(set) var isLoadingServerCatalog = true
    @Published private(set) var isLoadingTopSongs = true
    @Published private(set) var isLoadingDiscography = true
    @Published private(set) var isLoadingEnrichment = true

    @Published private(set) var loadError: String?
    /// False when the artist is known off-server but the active acquisition plugin (Lidarr) has no catalog match.
    @Published private(set) var canRequestViaAcquisition = true

    // MARK: MusicBrainz metadata

    /// Header facts — origin, formation date, tags. Present without a network round-trip when
    /// the page was opened from a search hit, which already carried all of them.
    @Published private(set) var musicBrainzArtist: MusicBrainzArtist?
    /// First of the two loading states: the header. Resolves before the discography does.
    @Published private(set) var isLoadingArtistHeader = true
    /// `release-group-count` as MusicBrainz reports it. The number of discography rows that
    /// will exist once every page lands, so placeholders can be counted rather than guessed.
    @Published private(set) var discographyTotal = 0
    /// Release groups received so far. Below `discographyTotal` while pages are still arriving.
    @Published private(set) var discographyLoadedCount = 0
    /// A discography refresh ran and failed. Distinct from "this artist has no releases" — the
    /// page shows what it has rather than pretending the shelf is genuinely empty.
    @Published private(set) var discographyRefreshFailed = false
    /// What is on screen is a saved copy that could not be refreshed. Rendered with a label
    /// saying so; an out-of-date discography is never presented as though it were current.
    @Published private(set) var discographyIsSavedCopy = false
    /// When that saved copy was fetched, for the label.
    @Published private(set) var discographyFetchedAt: Date?


    /// Rows the server says exist but that have not arrived yet — the placeholder count.
    var discographyPendingCount: Int { max(0, discographyTotal - discographyLoadedCount) }

    /// What the page as a whole should be showing.
    ///
    /// These three were collapsed into one test, and the collapse is the bug: a page with no
    /// content yet, a page that finished and genuinely has none, and a page whose fetch failed
    /// all rendered the same "we couldn't find anything" copy. Only the middle one is entitled
    /// to it. The other two are a spinner and an apology-with-a-retry, and telling a reader
    /// "not found" while the answer is still on its way is simply false.
    enum ContentState {
        /// Something is still in flight. Never show not-found copy here.
        case loading
        /// There is something to render.
        case content
        /// Everything finished and there genuinely is nothing. The honest empty state.
        case empty
        /// Everything finished and something went wrong. Needs a retry, not an empty state.
        case failed
    }

    var contentState: ContentState {
        if hasAnyContent { return .content }
        if isLoadingServerCatalog || isLoadingEnrichment || isLoadingTopSongs
            || isLoadingDiscography || isLoadingArtistHeader {
            return .loading
        }
        // A refusal is not an absence either: nothing was fetched, so "nothing exists" is not a
        // conclusion the page is entitled to draw. It gets the retry affordance too.
        if discographyRefreshFailed || discographyRefreshRefused { return .failed }
        return .empty
    }

    /// Whether the page owes the reader an explanation about the discography load.
    ///
    /// Shown once loading has settled, so a pass still paging in is not accused of failing.
    /// A refusal is deliberately not included: that is reported by a snackbar at the moment of
    /// the pull, because nothing about the page's contents changed and a persistent banner
    /// would outlive the thing it describes.
    var showsDiscographyLoadNotice: Bool {
        guard !isLoadingDiscography else { return false }
        return discographyRefreshFailed || discographyIsSavedCopy
    }

    /// Whether a second page (or more) is still in flight.
    var isPagingDiscography: Bool { discographyPendingCount > 0 && !discographyRefreshFailed }

    init(input: ArtistPageInput) {
        self.input = input
        if case .libraryArtist(let a) = input {
            self.resolvedArtistId = a.id
        }
        // A page entered from a search hit already holds its header. Render it immediately and
        // spend no request on it; only a cold open pays for the lookup.
        if let handed = input.musicBrainzArtist {
            self.musicBrainzArtist = handed
            self.isLoadingArtistHeader = false
        }
    }

    var displayName: String { input.displayName }

    var hasAnyContent: Bool {
        !serverAlbums.isEmpty
            || !serverTracks.isEmpty
            || !topSongs.isEmpty
            || !discography.isEmpty
            || !similarArtists.isEmpty
            || (pluginProfile?.overview?.isEmpty == false)
            || (jellyfinOverview?.isEmpty == false)
    }

    var hasRenderableBodyContent: Bool {
        !topSongs.isEmpty
            || discography.values.contains { !$0.isEmpty }
            || !similarArtists.isEmpty
    }

    var hasPlayableTracks: Bool {
        !topSongs.compactMap(\.libraryTrack).isEmpty || !serverTracks.isEmpty
    }

    /// The artist's most recent plugin/server-adjacent release, shown as a
    /// featured card under the hero. `remoteReleasesSnapshot` is newest-first.
    var latestRelease: AcquisitionRelease? {
        remoteReleasesSnapshot.first(where: { $0.releaseDate != nil }) ?? remoteReleasesSnapshot.first
    }

    /// The server album matching a remote release by title, when the user already has it.
    func serverAlbum(matching release: AcquisitionRelease) -> AlbumSummary? {
        let keys = Set(discographyTitleKeys(for: release.title))
        guard !keys.isEmpty else { return nil }
        return serverAlbums.first { !Set(discographyTitleKeys(for: $0.title)).isDisjoint(with: keys) }
    }

    var hasAboutSection: Bool {
        if let overview = pluginProfile?.overview, !overview.isEmpty { return true }
        if let overview = jellyfinOverview, !overview.isEmpty { return true }
        if let genres = pluginProfile?.genres, !genres.isEmpty { return true }
        // MusicBrainz header facts are enough on their own — origin and formation date are
        // the About page's content even when no source has a bio to show.
        if musicBrainzArtist?.hasRenderableHeaderFacts == true { return true }
        if isLoadingArtistHeader { return true }
        return false
    }

    /// Hero banner URL — wide artist photo when available, then thumb, album-cover fallback, then library input art.
    /// True when this artist exists on the connected Navidrome/Jellyfin server.
    /// On-server pages use only server-provided art — no TheAudioDB / iTunes covers.
    var isOnServerArtist: Bool {
        resolvedArtistId != nil
            || input.libraryArtistId != nil
            || input.serverArtworkURL != nil
            || !serverAlbums.isEmpty
    }

    var bannerArtworkURL: URL? {
        if isOnServerArtist {
            return input.serverArtworkURL
                ?? serverAlbums.first(where: { $0.artworkURL != nil })?.artworkURL
        }
        return pluginProfile?.artworkURL
            ?? remoteReleasesSnapshot.first(where: { $0.artistArtworkURL != nil })?.artistArtworkURL
            ?? remoteReleasesSnapshot.first(where: { $0.artworkURL != nil })?.artworkURL
    }

    var hasOffServerCatalogContent: Bool {
        discography.values.contains { $0.contains(where: \.needsRequest) } || !remoteReleasesSnapshot.isEmpty
    }

    var showsCannotRequestBanner: Bool {
        !canRequestViaAcquisition && hasOffServerCatalogContent
    }

    // MARK: - Request Missing (bulk)

    /// Everything "Request Missing" is about to ask for, counted before it asks.
    ///
    /// The counts are what the confirmation puts in front of the user; `releases` is what the
    /// run then walks. Both come off the same array, so the number shown and the number sent
    /// cannot drift apart.
    struct DiscographyRequestPlan {
        var releases: [AcquisitionRelease] = []
        /// Per-bucket counts in shelf order, empty buckets omitted — the confirmation's breakdown.
        var breakdown: [(label: String, count: Int)] = []
        /// Release groups MusicBrainz has counted but not yet delivered. They are *not* in
        /// `releases`, and the confirmation says so rather than letting the number look complete.
        var pending: Int = 0

        var count: Int { releases.count }
        var isEmpty: Bool { releases.isEmpty }
    }

    /// The releases "Request Missing" would ask for: exactly the cards the shelves already
    /// draw with a request badge, and nothing else.
    ///
    /// **There is deliberately no second ownership test here.** Ownership is decided once, in
    /// ``applyDiscography(releases:serverAlbums:)`` (`ArtistViewModel.swift:907`), where a
    /// MusicBrainz release group becomes either a `.libraryAlbum` row (owned, playable) or a
    /// `.remote` one (missing, requestable) — and that same decision is what
    /// ``ArtistDiscographyItem/needsRequest`` reports and what
    /// `ArtistDiscographyCard.showsRequestBadge` (`ArtistPageView.swift:1375`) draws. This
    /// filters that flag on the very array the shelves render, so the menu cannot offer to
    /// request something the list is showing as owned: the row it would need does not exist.
    ///
    /// It also inherits, for free, the two narrower suppressions `applyDiscography` applies —
    /// live/compilation release groups are never offered, and a single already present as a
    /// server *track* is dropped — for the same reason.
    ///
    /// Stored rather than computed on demand: the toolbar menu reads its count on every body
    /// evaluation of this page, and every publish on ``AppModel`` re-runs those. Walking a
    /// 1000-release discography there is exactly the kind of scan `Rules/swiftui-body-cost.md`
    /// forbids, so the walk happens once, where the list it summarises is built.
    @Published private(set) var discographyRequestPlan = DiscographyRequestPlan()

    private func makeDiscographyRequestPlan() -> DiscographyRequestPlan {
        var plan = DiscographyRequestPlan(pending: isPagingDiscography ? discographyPendingCount : 0)
        for bucket in ArtistDiscographyBucket.allCases {
            let missing = (discography[bucket] ?? []).filter(\.needsRequest).compactMap(\.remoteAlbum)
            guard !missing.isEmpty else { continue }
            plan.releases.append(contentsOf: missing)
            plan.breakdown.append((label: bucket.requestPlanLabel(count: missing.count), count: missing.count))
        }
        return plan
    }


    func playbackTracks(for mode: ArtistPlayMode) -> [Track] {
        switch mode {
        case .topSongs:
            let fromTop = topSongs.compactMap(\.libraryTrack)
            if !fromTop.isEmpty { return fromTop }
            return sortedServerTracks()
        case .fullCatalog:
            return sortedServerTracks()
        }
    }

    private func sortedServerTracks() -> [Track] {
        serverTracks.sorted { lhs, rhs in
            if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
            if lhs.indexNumber != rhs.indexNumber { return lhs.indexNumber < rhs.indexNumber }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// Drives the whole page: resolve the server artist id (when input was a bare name),
    /// then load the server catalog plus the active plugin's discography (if any).
    func load(using app: AppModel) async {
        await load(using: app, forceRefresh: false)
    }

    /// Pull-to-refresh. Expires the cached copy and refetches.
    ///
    /// The refresh can be turned down by the rate limiter, and when it is, nothing has been
    /// expired — the page keeps everything it was showing and the only visible effect is a
    /// snackbar saying the refresh did not happen. A refusal that emptied the page would be
    /// worse than never offering the refresh at all.
    func refresh(using app: AppModel) async {
        await load(using: app, forceRefresh: true)
        if discographyRefreshRefused {
            app.showTransientToast("Refreshing artist page too many times")
        }
    }

    /// Set when the last refresh was turned down by the limiter rather than attempted.
    @Published private(set) var discographyRefreshRefused = false

    private func load(using app: AppModel, forceRefresh: Bool) async {
        if let cached = await ArtistEnrichmentCache.shared.load(forArtistName: input.displayName) {
            self.pluginProfile = cached.profile
            self.isLoadingEnrichment = false
        }

        await resolveServerArtistIdIfNeeded(using: app)

        // The plugin is still asked for the artist portrait and bio — MusicBrainz publishes
        // neither — but no longer for the discography. Those are independent round-trips, so
        // they run alongside the MusicBrainz pass rather than in front of it.
        let pluginConfigured = app.acquisitionConfigured
        // Held as tasks rather than bare `async let`s so the identity tie-break can wait for the
        // evidence it needs. Both feed that decision — the server's albums and the request
        // backend's artist id — and both were previously racing the MusicBrainz pass that reads
        // them, which made a cold open decide the artist differently depending on which network
        // call happened to land first.
        let pluginTask = Task { @MainActor [weak self] in
            guard let self, pluginConfigured else { return }
            await self.loadPluginProfile(using: app)
        }
        let catalogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadServerCatalog(using: app)
        }
        pluginProfileTask = pluginTask
        serverCatalogTask = catalogTask

        async let musicBrainzSide: Void = self.loadMusicBrainzMetadata(forceRefresh: forceRefresh)
        async let pluginSide: Void = pluginTask.value

        await catalogTask.value
        rebuildTopSongs(using: app)
        // Deliberately no discography paint here.
        //
        // This used to render the server's albums immediately and merge the catalogue in behind
        // them, which meant an artist you own one record by showed exactly that one record and
        // then reshuffled a moment later when the rest arrived. Content that appears and then
        // rearranges is worse than a slightly longer wait: the first list was never wrong, but it
        // was never the answer either, and it moved under the reader while they were reading it.
        //
        // The discography now paints once, from the catalogue, as soon as the catalogue answers —
        // which for an artist opened before is straight off disk. The existing skeleton covers the
        // gap until then.

        await musicBrainzSide
        await pluginSide
        isLoadingEnrichment = false
        isLoadingDiscography = false
        applyDiscography(releases: remoteReleasesSnapshot, serverAlbums: serverAlbums)
        if pluginConfigured {
            await ArtistEnrichmentCache.shared.save(
                forArtistName: input.displayName,
                profile: pluginProfile,
                releases: []
            )
        }
        await loadAcquisitionRequestability(using: app)
    }

    // MARK: - MusicBrainz

    /// Header then discography, in that order, each published the moment it is available.
    ///
    /// The order is what makes the two loading states meaningful: the header resolves from one
    /// request (or none at all, when the page arrived from a search hit), so it can stop
    /// shimmering long before a 300-release discography has finished paging in behind it.
    private func loadMusicBrainzMetadata(forceRefresh: Bool) async {
        guard let mbid = await resolveMusicBrainzID(forceRefresh: forceRefresh) else {
            isLoadingArtistHeader = false
            isLoadingDiscography = false
            return
        }

        if musicBrainzArtist == nil || forceRefresh {
            if let header = await MusicBrainzService.shared.artistHeader(mbid: mbid, forceRefresh: forceRefresh) {
                musicBrainzArtist = header
            }
        }
        isLoadingArtistHeader = false

        let artistName = input.displayName
        let portrait = pluginProfile?.artworkURL
        let overview = pluginProfile?.overview

        discographyRefreshRefused = false

        // Each landed page is applied on arrival, so the shelves fill in progressively and the
        // placeholder count shrinks toward zero instead of the whole discography appearing at once.
        let result = await MusicBrainzService.shared.discography(
            artistMBID: mbid,
            forceRefresh: forceRefresh
        ) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.applyMusicBrainzProgress(
                    progress,
                    artistName: artistName,
                    portrait: portrait,
                    overview: overview
                )
            }
        }

        if let result {
            discographyRefreshRefused = result.refreshRefused
            // A refusal means nothing was fetched and nothing was given up, so the page is left
            // exactly as it was rather than being repainted from an empty result.
            if !result.refreshRefused {
                applyMusicBrainzProgress(result, artistName: artistName, portrait: portrait, overview: overview)
                await resolveReleaseGroupIdsForUnmatchedAlbums(releases: remoteReleasesSnapshot)
                if !resolvedReleaseGroupIdByAlbumId.isEmpty {
                    applyDiscography(releases: remoteReleasesSnapshot, serverAlbums: serverAlbums)
                }
            }
        }
        isLoadingDiscography = false
    }

    private func applyMusicBrainzProgress(
        _ progress: MusicBrainzDiscography,
        artistName: String,
        portrait: URL?,
        overview: String?
    ) {
        // Each page hops to the main actor as its own task, and those are not guaranteed to be
        // delivered in the order they were created. Dropping any emission that would shrink the
        // shelf keeps a late-arriving earlier page from visibly un-loading rows that already
        // landed. A completed or failed pass is always authoritative and applies regardless.
        if !progress.isComplete, !progress.refreshFailed,
           progress.releaseGroups.count < discographyLoadedCount {
            return
        }
        discographyTotal = progress.total
        discographyLoadedCount = progress.releaseGroups.count
        discographyRefreshFailed = progress.refreshFailed
        discographyIsSavedCopy = progress.isExpiredFallback
        discographyFetchedAt = progress.fetchedAt
        remoteReleasesSnapshot = progress.asAcquisitionReleases(
            artist: artistName,
            artistArtworkURL: portrait,
            artistOverview: overview
        )
        applyDiscography(releases: remoteReleasesSnapshot, serverAlbums: serverAlbums)
    }

    /// The artist's MBID: handed over by the search hit, or resolved by name on a cold open.
    ///
    /// Name resolution is scored, not a containment test — an exact normalized name always
    /// beats a longer one that merely contains the query, and a weak best match is refused
    /// rather than returned as a guess. Settling for "whichever row contains this string"
    /// is how a page for `Citizen` ends up showing the discography of `Citizen Cope`.
    private func resolveMusicBrainzID(forceRefresh: Bool) async -> String? {
        // An id the page was opened with is the answer, whatever form it arrived in. No search,
        // and no chance of landing on a different artist who happens to share the name.
        if let handed = input.musicBrainzArtistId, !handed.isEmpty, !forceRefresh {
            noteIdentity(handed, source: .handedIn)
            return handed
        }
        if let known = musicBrainzArtist?.id, !forceRefresh {
            noteIdentity(known, source: .alreadyLoaded)
            return known
        }
        // The server may already know the answer. When it does this costs nothing at all —
        // no search, no guess, and no chance of resolving to a different artist of the same name.
        if let serverMBID = serverArtistMBID, !serverMBID.isEmpty {
            noteIdentity(serverMBID, source: .serverTag)
            return serverMBID
        }
        // Wait for the evidence before deciding. This is the only place that needs it, so the
        // wait is here rather than in `load`, and an unambiguous artist never pays for it.
        await awaitIdentityEvidence()
        identityOwnedAlbumsSeen = serverAlbums.count

        // When the name ties, the request backend's own id and the albums on the server are what
        // break it — see ``ArtistIdentityResolver``. Falls back to the ranking when neither does.
        guard let resolution = await ArtistIdentityResolver.resolve(
            name: input.displayName,
            ownedAlbums: serverAlbums,
            pluginArtistMBID: pluginProfile?.mbid
        ) else {
            noteIdentity(musicBrainzArtist?.id, source: .unresolved)
            return musicBrainzArtist?.id
        }
        let resolved = resolution.artist
        let source: IdentitySource = {
            if resolution.decidedByRequestBackend { return .requestBackend }
            if resolution.decidedByOwnedAlbums { return .ownedAlbums }
            return .nameSearch
        }()
        noteIdentity(resolved.id, source: source, matchedAlbums: resolution.matchedAlbumCount)
        musicBrainzArtist = resolved
        return resolved.id
    }

    /// MusicBrainz artist id as reported by the connected server, when it has one.
    private var serverArtistMBID: String? {
        if case .libraryArtist(let a) = input, let mbid = a.musicBrainzArtistId { return mbid }
        return resolvedServerArtistMBID
    }

    /// Filled in when the artist was resolved by name against the server's own artist list.
    private var resolvedServerArtistMBID: String?

    /// How the page decided *which* MusicBrainz artist it is showing.
    ///
    /// Worth surfacing rather than keeping internal: when a page shows the wrong artist, the
    /// useful question is never "what is the id" but "where did the id come from". A name search
    /// is a guess among same-named candidates; everything else is an identity.
    enum IdentitySource: String {
        /// The row that opened the page already knew the id.
        case handedIn = "Passed in by the row that opened this page"
        /// Already resolved earlier in this page's life.
        case alreadyLoaded = "Already resolved for this page"
        /// The server had the artist tagged with a MusicBrainz id.
        case serverTag = "From the server's own MusicBrainz tag"
        /// Resolved by searching MusicBrainz for the name — a guess when names collide.
        case nameSearch = "Guessed by searching MusicBrainz for the name"
        /// Several artists shared the name and the albums on this server decided between them.
        case ownedAlbums = "Chosen by matching your albums against each same-named artist"
        /// The request backend already held this artist, and its MusicBrainz id named one of them.
        case requestBackend = "Chosen from the artist already added in your request backend"
        /// No id at all.
        case unresolved = "Not resolved"
    }

    @Published private(set) var musicBrainzIdentity: String?
    @Published private(set) var musicBrainzIdentitySource: IdentitySource = .unresolved

    /// How many owned albums the winning candidate accounted for, when albums decided it.
    @Published private(set) var identityMatchedAlbums = 0
    /// How many server albums were actually available when the tie-break ran.
    ///
    /// Reported rather than assumed: the whole defect here was the resolver reading this set
    /// while it was still being filled, and "the ordering is fixed" is a claim that should be
    /// checkable on the device rather than taken on trust.
    @Published private(set) var identityOwnedAlbumsSeen = 0

    /// Tasks the identity tie-break depends on, awaited only at the point of decision.
    private var serverCatalogTask: Task<Void, Never>?
    private var pluginProfileTask: Task<Void, Never>?

    /// Blocks until the server catalog and the request-backend profile have landed.
    private func awaitIdentityEvidence() async {
        await serverCatalogTask?.value
        await pluginProfileTask?.value
    }

    private func noteIdentity(_ id: String?, source: IdentitySource, matchedAlbums: Int = 0) {
        musicBrainzIdentity = id
        musicBrainzIdentitySource = id == nil ? .unresolved : source
        identityMatchedAlbums = matchedAlbums
    }

    /// Everything the page knows about who it thinks this artist is, as displayable text.
    var identityReport: String {
        var lines: [String] = ["Artist: \(displayName)"]
        lines.append("MusicBrainz id: \(musicBrainzIdentity ?? "none")")
        lines.append("Resolved: \(musicBrainzIdentitySource.rawValue)")
        if musicBrainzIdentitySource == .nameSearch {
            lines.append("⚠︎ A name search picks one of possibly many artists sharing this name, so the releases below may belong to a different act.")
        }
        if musicBrainzIdentitySource == .ownedAlbums {
            lines.append("Matched \(identityMatchedAlbums) of your albums against this artist's catalogue.")
        }
        lines.append("Albums available to the tie-break: \(identityOwnedAlbumsSeen)")
        lines.append("Server artist id: \(resolvedArtistId ?? "not on this server")")
        if let disambiguation = musicBrainzArtist?.disambiguation, !disambiguation.isEmpty {
            lines.append("MusicBrainz says: \(disambiguation)")
        }
        lines.append("Albums on your server: \(serverAlbums.count)")
        lines.append("Catalogue releases: \(discographyLoadedCount) of \(discographyTotal)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Subloads

    private func resolveServerArtistIdIfNeeded(using app: AppModel) async {
        if resolvedArtistId != nil { return }
        guard let lib = app.activeLibrary else { return }
        do {
            let artists = try await lib.libraryArtists(limit: 12_000)
            let target = LibraryTrackMatcher.normalize(input.displayName)
            guard !target.isEmpty else { return }
            let sameName = artists.filter { LibraryTrackMatcher.normalize($0.name) == target }
            guard !sameName.isEmpty else { return }

            // Taking the first row that shares the name is what mixed unrelated acts together.
            // A name is not an identity: "Rocket" is eighteen different artists on MusicBrainz
            // alone, and picking whichever row happened to come back first put one band's albums
            // on another band's page, rendered as owned because they genuinely are on the server.
            if let pageMBID = input.musicBrainzArtistId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pageMBID.isEmpty {
                if let exact = sameName.first(where: { $0.musicBrainzArtistId == pageMBID }) {
                    self.resolvedArtistId = exact.id
                    self.resolvedServerArtistMBID = exact.musicBrainzArtistId
                    return
                }
                // Every same-named row carries an id and none of them is this artist, so the
                // server does not have this artist — it has somebody else with the same name.
                // Claiming their albums is worse than showing none, because the page presents
                // them as owned and there is nothing on screen to say they belong to another act.
                if sameName.allSatisfy({ ($0.musicBrainzArtistId?.isEmpty == false) }) {
                    return
                }
            }

            // No id to decide with on one side or the other. Fall back to the previous behaviour
            // rather than guessing differently — on a library where ~4% of artists carry an id,
            // this is still the common path and must not regress.
            if let match = sameName.first {
                self.resolvedArtistId = match.id
                self.resolvedServerArtistMBID = match.musicBrainzArtistId
            }
        } catch {
            // Non-fatal — page still renders enrichment-only.
        }
    }

    private func loadServerCatalog(using app: AppModel) async {
        guard let lib = app.activeLibrary, let id = resolvedArtistId else {
            isLoadingServerCatalog = false
            return
        }
        do {
            async let albumsTask = lib.albums(forLibraryArtistId: id, limit: 4000)
            async let tracksTask = lib.tracks(forLibraryArtistId: id, limit: 8000)
            let (albums, tracks) = try await (albumsTask, tracksTask)
            self.serverAlbums = albums.sorted { lhs, rhs in
                let l = lhs.releaseDate ?? lhs.releaseYearAsDate
                let r = rhs.releaseDate ?? rhs.releaseYearAsDate
                if let l, let r, l != r { return l > r }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            self.serverTracks = tracks
        } catch {
            self.loadError = error.localizedDescription
        }
        isLoadingServerCatalog = false
    }

    private var remoteReleasesSnapshot: [AcquisitionRelease] = []

    /// Artist portrait and bio from the active acquisition plugin.
    ///
    /// Only those two fields. The discography used to come from here as well, and that is what
    /// made it wrong: a plugin reports the releases *it* knows about — its own library, or its
    /// own fuzzy catalog search — which is not the artist's discography and is not complete.
    /// MusicBrainz owns that now. What the plugin still uniquely provides is imagery and prose,
    /// which MusicBrainz does not publish, plus the request path itself.
    private func loadPluginProfile(using app: AppModel) async {
        guard app.acquisitionConfigured else {
            pluginProfile = nil
            return
        }
        if let profile = await app.acquisition.artistProfile(named: input.displayName) {
            pluginProfile = profile
        }
    }

    private func loadAcquisitionRequestability(using app: AppModel) async {
        guard app.acquisitionConfigured, app.acquisitionCapabilities.granularity == .album else {
            canRequestViaAcquisition = true
            return
        }
        guard hasOffServerCatalogContent else {
            canRequestViaAcquisition = true
            return
        }
        canRequestViaAcquisition = await app.acquisition.canRequestArtist(named: input.displayName)
    }

    // MARK: - Section composition

    private func rebuildTopSongs(using app: AppModel) {
        topSongs = scrobbleTopSongs(using: app)
        if topSongs.isEmpty {
            topSongs = fallbackTopSongs(from: serverAlbums, tracks: serverTracks)
        }
        isLoadingTopSongs = false
    }

    private func scrobbleTopSongs(using app: AppModel) -> [ArtistTopSongRow] {
        let artistKey = LibraryTrackMatcher.normalize(input.displayName)
        guard !artistKey.isEmpty else { return [] }
        var counts: [String: (track: Track?, title: String, artist: String, count: Int)] = [:]

        func consider(trackId: String, title: String, artist: String) {
            let key = LibraryTrackMatcher.normalize(title)
            guard !key.isEmpty else { return }
            let track = app.cachedLibraryTrack(id: trackId)
                ?? serverTracks.first(where: { $0.id == trackId })
            if var existing = counts[key] {
                existing.count += 1
                if existing.track == nil { existing.track = track }
                counts[key] = existing
            } else {
                counts[key] = (track, title, artist, 1)
            }
        }

        for scrobble in app.scrobbleService.store.completed {
            let key = LibraryTrackMatcher.normalize(scrobble.artist)
            guard key == artistKey else { continue }
            consider(trackId: scrobble.trackId, title: scrobble.title, artist: scrobble.artist)
        }
        for track in app.recentlyPlayedTracks {
            let key = LibraryTrackMatcher.normalize(track.artist)
            guard key == artistKey else { continue }
            consider(trackId: track.id, title: track.title, artist: track.artist)
        }

        return counts.values
            .sorted { $0.count > $1.count }
            .prefix(10)
            .map { entry in
                if let track = entry.track {
                    return ArtistTopSongRow(
                        id: "lib-\(track.id)",
                        title: track.title,
                        artist: track.artist,
                        albumTitle: track.albumTitle.isEmpty ? nil : track.albumTitle,
                        releaseYear: track.releaseYear,
                        artworkURL: track.artworkURL,
                        libraryTrack: track,
                        playcount: entry.count
                    )
                }
                return ArtistTopSongRow(
                    id: "scrobble-\(LibraryTrackMatcher.normalize(entry.title))",
                    title: entry.title,
                    artist: entry.artist,
                    albumTitle: nil,
                    releaseYear: nil,
                    artworkURL: nil,
                    libraryTrack: nil,
                    playcount: entry.count
                )
            }
    }

    private func fallbackTopSongs(from albums: [AlbumSummary], tracks: [Track]) -> [ArtistTopSongRow] {
        let groups = Dictionary(grouping: tracks) { $0.albumId }
        var rows: [ArtistTopSongRow] = []
        for album in albums {
            guard let albumTracks = groups[album.id] else { continue }
            let leadoff = albumTracks
                .sorted { lhs, rhs in
                    if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
                    return lhs.indexNumber < rhs.indexNumber
                }
                .first
            guard let leadoff else { continue }
            rows.append(ArtistTopSongRow(
                id: "fallback-\(leadoff.id)",
                title: leadoff.title,
                artist: leadoff.artist,
                albumTitle: album.title,
                releaseYear: album.releaseYear,
                artworkURL: album.artworkURL ?? leadoff.artworkURL,
                libraryTrack: leadoff,
                playcount: 0
            ))
            if rows.count >= 10 { break }
        }
        return rows
    }

    /// Title keys for matching plugin rows to server albums. Exact normalize plus
    /// ``AlbumSummary.albumVersionBaseKey`` so "hate that i made you love me - EP"
    /// matches a server album tagged without the suffix.
    private func discographyTitleKeys(for title: String) -> [String] {
        AlbumSummary.discographyTitleKeys(for: title)
    }

    /// Release-group id for a server album: the one the server reported, or one resolved from a
    /// release id. `nil` when neither is available, which is the common case — the title keys
    /// carry the match then.
    private func musicBrainzReleaseGroupId(for album: AlbumSummary) -> String? {
        if let direct = album.musicBrainzReleaseGroupId, !direct.isEmpty { return direct }
        return resolvedReleaseGroupIdByAlbumId[album.id]
    }

    /// Release-group ids resolved from server-reported *release* ids, for this artist's albums.
    private var resolvedReleaseGroupIdByAlbumId: [String: String] = [:]

    /// Fills in release-group ids for owned albums that only carry a release id.
    ///
    /// Deliberately last, and deliberately narrow: only albums that the title keys already failed
    /// to match are looked up, so an artist page whose albums all matched spends nothing here.
    /// Each mapping is cached permanently, so the cost is paid once per album ever rather than
    /// once per page visit.
    private func resolveReleaseGroupIdsForUnmatchedAlbums(releases: [AcquisitionRelease]) async {
        guard !releases.isEmpty else { return }
        var remoteByTitleKey = Set<String>()
        for remote in releases {
            for key in discographyTitleKeys(for: remote.title) { remoteByTitleKey.insert(key) }
        }
        let knownGroupIds = Set(releases.compactMap(\.releaseGroupMBID))

        for album in serverAlbums {
            guard musicBrainzReleaseGroupId(for: album) == nil,
                  let releaseId = album.musicBrainzReleaseId, !releaseId.isEmpty
            else { continue }
            // Already matched on title — no need to spend a request confirming it.
            if discographyTitleKeys(for: album.title).contains(where: { remoteByTitleKey.contains($0) }) {
                continue
            }
            guard let groupId = await MusicBrainzService.shared.releaseGroupId(forReleaseId: releaseId),
                  knownGroupIds.contains(groupId)
            else { continue }
            resolvedReleaseGroupIdByAlbumId[album.id] = groupId
        }
    }

    /// Builds the discography as **one** list: the catalogue, with ownership marked on it.
    ///
    /// The order of these two loops is the substance, not a detail. It used to walk the server's
    /// albums first and merge the catalogue in behind them, which made the library the spine of
    /// the page and the catalogue an addendum — so an artist you own one record by rendered that
    /// one record and then rearranged when the rest arrived. Walking the catalogue instead means
    /// the shape of the list is settled the moment the catalogue answers, and ownership is an
    /// attribute of a row rather than a separate source of rows.
    private func applyDiscography(releases: [AcquisitionRelease], serverAlbums: [AlbumSummary]) {
        // Owned albums indexed for lookup — id first, since an exact identity beats any amount of
        // title normalization, with title keys as the fallback for the ~97% carrying no id.
        var ownedByReleaseGroupId: [String: AlbumSummary] = [:]
        var ownedByTitleKey: [String: AlbumSummary] = [:]
        for album in serverAlbums {
            if let rg = musicBrainzReleaseGroupId(for: album), !rg.isEmpty, ownedByReleaseGroupId[rg] == nil {
                ownedByReleaseGroupId[rg] = album
            }
            for key in discographyTitleKeys(for: album.title) where ownedByTitleKey[key] == nil {
                ownedByTitleKey[key] = album
            }
        }

        let serverTrackTitles = Set(serverTracks.flatMap { discographyTitleKeys(for: $0.title) })
        var bucketed: [ArtistDiscographyBucket: [ArtistDiscographyItem]] = [:]
        var claimedAlbumIds = Set<String>()

        // 1. The catalogue is the list. Each release is either owned — in which case it renders
        //    from the server's own copy, so it stays playable — or not, in which case it renders
        //    as requestable. One row per release either way.
        for remote in releases {
            let bucket = remote.bucket
            let owned: AlbumSummary? = {
                if let rg = remote.releaseGroupMBID, !rg.isEmpty, let hit = ownedByReleaseGroupId[rg] {
                    return hit
                }
                return discographyTitleKeys(for: remote.title)
                    .lazy.compactMap { ownedByTitleKey[$0] }.first
            }()

            if let owned {
                guard claimedAlbumIds.insert(owned.id).inserted else { continue }
                bucketed[bucket, default: []].append(ArtistDiscographyItem(
                    id: "lib-\(owned.id)",
                    title: owned.title,
                    artist: owned.artist,
                    bucket: bucket,
                    releaseYear: owned.releaseYear,
                    releaseSortDate: owned.releaseDate ?? owned.releaseYearAsDate,
                    artworkURL: owned.artworkURL,
                    source: .libraryAlbum(owned)
                ))
                continue
            }

            guard bucket == .albums || bucket == .singlesAndEPs else { continue }
            // A single already present as a track is not worth offering to request.
            if bucket == .singlesAndEPs,
               discographyTitleKeys(for: remote.title).contains(where: { serverTrackTitles.contains($0) }) {
                continue
            }
            bucketed[bucket, default: []].append(ArtistDiscographyItem(
                id: "acq-\(remote.id)",
                title: remote.title,
                artist: remote.artist.isEmpty ? input.displayName : remote.artist,
                bucket: bucket,
                releaseYear: remote.releaseYear,
                releaseSortDate: remote.releaseDate,
                artworkURL: remote.artworkURL,
                source: .remote(remote)
            ))
        }

        // 2. Then anything owned that the catalogue does not list — a bootleg, a local rip, a
        //    release MusicBrainz has not got. These are appended rather than dropped: the
        //    catalogue leads the page, but it does not get to decide that music the user
        //    demonstrably has does not exist.
        for album in serverAlbums where !claimedAlbumIds.contains(album.id) {
            let bucket = heuristicBucket(for: album)
            bucketed[bucket, default: []].append(ArtistDiscographyItem(
                id: "lib-\(album.id)",
                title: album.title,
                artist: album.artist,
                bucket: bucket,
                releaseYear: album.releaseYear,
                releaseSortDate: album.releaseDate ?? album.releaseYearAsDate,
                artworkURL: album.artworkURL,
                source: .libraryAlbum(album)
            ))
        }

        // 3. Sort every bucket newest-first. Items with no date sink to the end
        //    (sorted alphabetically among themselves) so a complete discography
        //    with a few undated re-releases still surfaces the recents at the top.
        for key in bucketed.keys {
            bucketed[key]?.sort { lhs, rhs in
                switch (lhs.releaseSortDate, rhs.releaseSortDate) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }
        }

        self.discography = bucketed
        // Derived here, from the list that was just built, so "what the menu would request" and
        // "what the shelves show as missing" are the same walk over the same array.
        self.discographyRequestPlan = makeDiscographyRequestPlan()
    }

    private func heuristicBucket(for album: AlbumSummary) -> ArtistDiscographyBucket {
        let title = album.title.lowercased()
        if title.range(of: #"\blive\b"#, options: .regularExpression) != nil { return .live }
        if title.range(of: #"\bcompilation\b|\bgreatest hits\b|\bbest of\b|\banthology\b"#, options: .regularExpression) != nil {
            return .compilations
        }
        if let n = album.trackCount {
            if n <= 3 { return .singlesAndEPs }
            if n <= 6 { return .singlesAndEPs }
        }
        return .albums
    }
}

private extension AlbumSummary {
    /// Fallback sort key: a Date from the year alone so albums with year-only metadata still sort.
    var releaseYearAsDate: Date? {
        guard let y = releaseYear else { return nil }
        var comps = DateComponents()
        comps.year = y
        comps.month = 1
        comps.day = 1
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}
