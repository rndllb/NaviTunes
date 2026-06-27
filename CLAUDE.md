# Lyra Music — Backend Notes

This app talks to two pluggable music backends. The active one is chosen at login via `BackendKind` (`AppModel.swift`). Both implement `MusicLibraryProviding` (`MusicLibraryProviding.swift`) so feature code stays backend-agnostic; reach for the concrete client only when an endpoint or capability differs.

## Clients

- **Jellyfin** — `JellyfinMusicClient.swift`. Native Jellyfin REST API. Auth = `X-Emby-Token` + `userId`. Media URLs carry `api_key` query auth for `AVURLAsset` compatibility.
- **Navidrome (Subsonic API)** — `NavidromeClient.swift`. Speaks the Subsonic protocol (`/rest/<endpoint>.view?...`). Salted token auth. Client id must NOT match Navidrome's `Subsonic.MinimalClients` — minimal payloads drop `albumId` and break favorites.

## Capability differences that matter

| Concern | Jellyfin | Navidrome / Subsonic |
|---|---|---|
| Favorite a track | `POST/DELETE Users/{uid}/FavoriteItems/{id}` | `star` / `unstar` |
| User-add timestamp | **None** — `UserData.IsFavorite` is bool only | **Yes** — `getStarred2` returns a per-item `starred` date |
| List favorites | `Items?Filters=IsFavorite` | `getStarred2` (songs + albums + artists) |
| Playlist `DateCreated` | Present on `Playlists` items | Present on `getPlaylists` entries |
| Album `DateCreated` | Server scan/upload time | Server scan/upload time |
| Recently-added albums | `Items?SortBy=DateCreated&IncludeItemTypes=MusicAlbum` | `getAlbumList2?type=newest` |
| Lyrics | `/Audio/{id}/Lyrics` JSON (ticks / 1e7) | `getLyricsBySongId` structured + `getLyrics` plain fallback |
| Share links | — | `createShare` / list / delete; create from item context menus |
| Library scan | — | `startScan` / status |

`libraryAddedDate` on `AlbumSummary` / `Track` / `PlaylistSummary` (`MusicLibraryProviding.swift`, `PlaylistModels.swift`) is **server-side** — it's when the server scanned/created the item, not when the current user added it to their library. Be careful when surfacing this as "Recently Added" in user-facing UI.

## Tracking "added to MY library"

There is no single backend field for this. The accurate approach is hybrid:

- **Subsonic backends:** trust the `starred` timestamp from `getStarred2`.
- **Jellyfin:** no timestamp from server. Stamp locally (e.g., a small persistent store keyed by `(backend, serverId, itemId) → date`) at the moment the user favorites/creates from this app. Fall back to playlist `DateCreated` for user-owned playlists.

Limitation of the local-stamp path: actions taken outside this app (Jellyfin web UI, other clients) won't appear with an accurate "added" date until the user touches them here.

`isAlbumInLibrary(_:)` returns true when the album is in `libraryAlbumEntries` **or** any indexed track on that album is in `librarySongIds`.

## Server catalog vs personal library (do not confuse these)

The app surfaces two distinct collections. The naming is a footgun — `AppModel.libraryAlbums` is the **whole server catalog**, not "your library".

- **Server catalog** — every album/track on the connected Navidrome / Jellyfin instance. Loaded via `MusicLibraryProviding.albums(limit:)` → Subsonic `getAlbumList2` / Jellyfin `Items?IncludeItemTypes=MusicAlbum`. Cached in `AppModel.libraryAlbums` / `recentlyAddedAlbums`. Server-wide search is `MusicLibraryProviding.searchCatalog(query:)` → Subsonic `search3` / Jellyfin `Items?searchTerm=…`.
- **Home discovery shelves** (Top Picks, New Releases, genre rows, New Artists Added) surface **server catalog only** — albums the user has **not** added to their magic playlist (`AppModel.isEligibleForHomeTopPick`). Top Picks + New Releases are taste-ranked via `NewTabPersonalizationEngine.tasteRankedAlbumSummaries`; genre rows use `listeningTopGenres()`.
- **Personal library (Lyra "My Library" magic playlist)** — a per-user opaquely-named playlist (`__lyra_<sha12>`) Lyra creates on the backend. Its contents are the canonical "what *I* added" set, synced across devices:
  - Playlist tracks → `AppModel.librarySongIds: Set<String>`
  - `comment` (Subsonic) / `Overview` (Jellyfin) JSON → `LibraryMembershipPayload` → `libraryAlbumEntries` + `libraryPlaylistEntries` (each entry carries a per-item `added` date so "Recently Added (yours)" is accurate).
  - Name is deterministic from `(backend, normalized server key, user id)` in `LibraryMembership` — same user + same server URL → same playlist on every device (legacy host-only names are still discovered).
  - Resolved on sign-in by `refreshLibraryMembership()` (always find-by-name on the server, not cache-only); kept live via `startLibraryMembershipAutoSync()` (~20s poll) and `refreshLibraryMembershipIfStale()` on foreground.
  - Mutated by `addAlbumToLibrary` / `removeAlbumFromLibrary` / `toggleFavoriteTrack` etc., then persisted back to the magic playlist via `persistLibraryMembershipPayload()`.
  - Filtered out of every user-facing playlist surface by id and by name prefix (`LibraryMembership.isMagicPlaylistName`).

Rule of thumb: anything that means "things the *user* owns / has added" must read from `librarySongIds` / `libraryAlbumEntries` / `libraryPlaylistEntries`, not `libraryAlbums`. Search scopes follow the same split: the Library tab in Discovery searches **personal** state; the Discover tab is a hybrid of **server catalog** + acquisition download candidates.

## Acquisition plugins (requesting music)

All "request missing music" flows funnel through one swappable abstraction so backends are interchangeable. **Only one plugin is active at a time** (`AcquisitionManager.activePlugin`, persisted in `UserDefaults`).

- **Core** (`AcquisitionCore.swift`): `AcquisitionPluginKind` (currently just `lidarr` — Downtify was removed), the unified `AcquisitionRequest` (artist/track/album + optional MBIDs + `requestKey`), `AcquisitionJob`(+`AcquisitionJobStatus`), `AcquisitionResult` (a concrete searchable item carrying its own request), `AcquisitionCapabilities` (granularity track/album, `supportsTrackSearch`, `configFields`), and the `AcquisitionProviding` protocol. `AcquisitionConfigStore` persists per-plugin credentials under distinct keys (`acquisition.<kind>.<field>`). `AcquisitionHTTP` is the shared REST helper for the network plugins.
- **Manager** (`AcquisitionManager.swift`, `@MainActor`): `enqueue(_:)` is the single entry point; jobs keyed by `requestKey`; a shared poll loop reconciles against `provider.activeJobs()`; `onJobFinished` fires once per terminal job. `AppModel.acquisition` owns it and forwards `objectWillChange`. Default plugin is **Lidarr**; an old persisted `"downtify"` value no longer decodes and falls back to Lidarr.
- **Plugin** (conforms to `AcquisitionProviding`): `LidarrAcquisitionPlugin` (album; MusicBrainz → add with full artist profiles → force-monitor → `AlbumSearch`, the #5012 monitor-race fix; polls `/queue` + `/command`). Described to users as a **music collection manager**, not a downloader. The former Downtify plugin/client were deleted; the only surviving piece is `MatchableSong` (`MatchableSong.swift`, renamed from `DowntifySong`) — a generic fuzzy-match descriptor used by `LibraryTrackMatcher` / `BrowseAlbumDetailView`, unrelated to the plugin.
- **Call sites**: UI never touches a concrete plugin. Build an `AcquisitionRequest` and call `AppModel.requestAcquisition(_:)` (`DiscoverySearchView`, `BrowseAlbumDetailView`, `ServerPlaylistViews`, `MusicNewTabView`). Gate affordances on `app.acquisitionCapabilities` (`supportsTrackSearch`, `granularity`). Album-level plugins request the whole release for missing-track rows.
- **Settings**: `SettingsView` → Plugins → **Music Requests** (renamed from "Downloads") opens `AcquisitionPluginSettingsView` — active-plugin picker, capability-driven config fields, Test Connection (`provider.validate()`), and a unified Activity list (`acquisition.displayJobs`, includes server-side items started outside Lyra). (The offline-media "Downloads" section under Settings is a separate thing.)
- **Completion**: `AppModel.handleAcquisitionJobFinished` (backend-agnostic) triggers a server scan and retries `searchCatalog` until the new file surfaces, then adds it to the personal library.
- **Request an artist not in your library**: Discover search surfaces iTunes artist matches as normal artist rows (`ITunesArtistClient.searchArtists`), and Settings → Following has an "Add artist" entry. Both open `ArtistPageView(input: .named(...))`, which resolves the discography via iTunes and lets you request individual albums.

To add a backend: add a `case` to `AcquisitionPluginKind`, write one `*AcquisitionPlugin.swift`, and register it in `AcquisitionManager.makeProvider`. No feature-code changes.

## Follow-artist completeness (subscriptions)

The "Lidarr-style brain" — keep a followed artist's discography complete — but it **lives in the app**, so it works with *any* subset of plugins. The only hard dependency is the always-available iTunes Search API floor (`ITunesArtistClient`); acquisition/library backends are optional accelerators.

- **Models/store** (`MusicSubscriptionModels.swift`): `FollowedArtist` (persisted "wanted" intent; id = MBID or normalized-name fallback; tracks `requestedReleaseIds` so re-checks don't re-enqueue), `SubscriptionReleaseStatus` (`.have`/`.requested`/`.pending` UI status), and `MusicSubscriptionStore` (JSON in `Application Support/LyraMusic/subscriptions.json`, same layout as `LibrarySnapshotStore`).
- **Engine** (`MusicSubscriptionEngine.swift`, `@MainActor`): env-injected (no `AppModel` internals) so it stays testable. `check(artistId:)` = canonical discography (iTunes) → diff against the connected server (`serverAlbumsForArtist`, normalized-title match, any backend) → enqueue missing albums/EPs through the **active acquisition plugin**. Graceful degradation: with no plugin (or a track-only one that can't pull whole albums) missing releases become `.pending` (wishlist) instead of disabling the feature. `checkAll()` paces iTunes artist fetches.
- **AppModel** owns `subscriptions` (built in `init`, forwards `objectWillChange`); `serverAlbums(forArtistName:)` is the "have it?" probe; `refreshSubscriptions()` runs a pass. The engine calls `acquisition.enqueue` directly (not `requestAcquisition`) to avoid per-album toasts.
- **UI**: `ArtistFollowButton` (bell toggle in the artist-page toolbar, always shown — following without a plugin is a valid wishlist) and `SubscriptionsView` (Settings → Plugins → **Following**: per-artist status, "Check now", unfollow; banner when no download plugin is configured).
- **Capability gating**: auto-fetch only when `acquisition.isConfigured` **and** `capabilities.granularity == .album`. Everything keys off capabilities, never a named plugin.

## Home mixes (Tuned In)

- Built in `HomeMixBuilder.swift`, cached on `AppModel.homeMixes`, refreshed via `rebuildHomeMixes()` / `refreshHomeMixes()`.
- Mix types: **On Repeat**, **Favorites**, **Rediscover**, **New in Your Library** — each needs **≥ 3 tracks** or it is omitted.
- **On Repeat** / **Rediscover** read `ScrobbleService.store.completed` (successful **server** scrobbles), not `recentlyPlayedTracks` alone.
- **Favorites** intersects `favoriteTrackIds` with `discoveryLibraryTracks` (partial until discovery index finishes).
- Synthetic playlist IDs: `__lyra_home_mix:<mixId>` via `HomeMix.asPlaylistSummary()`.
- Library → Playlists surfaces mixes when `AppModel.showHomeMixesInPlaylists` is true (Settings → Library & Data).
- Mix detail: `ServerPlaylistDetailView(homeMixId:)` — album-style UI, mosaic hero, no remove-from-playlist.

## Home discovery shelves

- **Top Picks** (`homeTopPickAlbums`, 8) + **New Releases** (`homeNewReleaseAlbums`, 20) — one taste-ranked pass over a server-catalog candidate pool (`recentlyAddedAlbums`, server recently played, top-3 taste-genre albums). Ranked by `NewTabPersonalizationEngine.tasteRankedAlbumSummaries`.
- **Eligibility** — `isEligibleForHomeTopPick` excludes magic-playlist albums (`libraryAlbumEntries` + release-identity match via `catalogReleaseIdentityKey`). Does **not** use `libraryAlbumReleaseIndex` (whole server catalog).
- **Genre shelves** — session-locked `homeSelectedGenres` from `listeningTopGenres()` mapped onto server genres; 9 albums per shelf; filtered with `homeDiscoveryCatalogAlbums`.
- **UI** — `HomeTopPickCard` editorial cards (250×325, vertical color bleed via `HomeTopPickArtworkBleed` / `ArtworkVerticalBleed`).
- Rebuild hooks: `refreshHome()`, library refresh, magic-playlist membership changes (`addAlbumToLibrary` / `removeAlbumFromLibrary` / `applyMagicPlaylistFetch`).

## New tab (iTunes browse)

- **No MusicBrainz browse** — `refreshNewTabBrowse()` builds from `ITunesNewReleasesClient` + `NewTabPersonalizationEngine` only. `musicBrainzEnabled` and `MusicBrainzArtistClient` / `MusicBrainzTracklistClient` were removed.
- `newTabBrowseBackend` is `.appleMusic` (iTunes) on success.
- Off-server album rows use `ITunesTracklistClient`; artist pages use `ITunesArtistClient.discography`.

## Artist navigation & Now Playing chrome

- `ArtistNavigation.swift` / `ArtistNameButton` — programmatic artist pushes (avoids nested `NavigationLink` on album detail). “Various Artists” is not tappable.
- `ArtistNowPlayingMenuButton` — UIKit menu on iOS; uses `heroChromeSecondary` from backdrop palette when a track is playing (fixes white-on-white artist text on light artwork).
- `OverPlayerSheetPresenter` — presents `AddToPlaylistSheet` above the Now Playing `fullScreenCover` without entering SwiftUI’s sheet tree (preserves mini-player zoom transition). `RootView` mirrors `isNowPlayingCoverPresented` into `AppModel`.

## Genres

`GenreCanonicalizer` rolls server subgenres into ~20 main genres. **Lo-Fi** is its own bucket (includes boom bap / chillhop keywords); boom bap was removed from Hip-Hop.

## Lyrics

- Loaded in `PlaybackEngine.loadLyrics()` → `MusicLibraryProviding.lyrics(for:)`. Assignment is guarded by playback epoch + track id to avoid races on fast skip.
- **Navidrome:** `getLyricsBySongId` structured blocks preferred; merges with `getLyrics` plain text and picks best synced candidate (`NavidromeClient.lyrics`). Parser in `NavidromeLyricsParser`:
  - LRC `[offset:±ms]` uses **add-to-start** semantics (Navidrome stores LRC offset verbatim).
  - Detects seconds vs milliseconds when structured `start` values are ≤ 600.
  - Re-parses row `value` text as embedded LRC when timestamps are inline.
- **Jellyfin:** `JellyfinLyricsParser` — .NET ticks / 1e7.
- **UI:** `LyricsFocusScrollView` in `NowPlayingView.swift`. Sync enabled when `[LyricLine].lyricsAppearSynced` (≥ 2 distinct timestamps). Unsynced plain text: larger static type, no scroll/highlight/tap-to-seek.

## Stale track IDs

After server rescans, media file ids can change. `AppModel.recoverStaleTrackIfNeeded` + `StaleSongMatching.buildSwapMap` remap queue, downloads, favorites, and personal library ids via `applyTrackIDSwaps`, which also rewrites the magic playlist on the server when library membership was affected.

## Conventions

- Nothing custom, prioritize using apple library stuff first. Reach for stock SwiftUI / UIKit / system APIs (`.contextMenu(menuItems:preview:)`, `ShareLink`, `NavigationStack`, `.searchable`, etc.) before building bespoke chrome or gestures.
- New backend-facing features should extend `MusicLibraryProviding` rather than branching on `BackendKind` in feature code. Branch in the client implementations.
- Track/Album/Playlist models are `Codable` and persisted to disk via `LibrarySnapshotStore.swift` — adding non-optional fields needs a migration story.
- Media URLs may be embedded in `AVURLAsset`; query-auth (not headers) is required so the player can reach them without a custom resource loader.
- All UI-facing models cross main actor boundaries. New `Observable` view-state types should be `@MainActor`.

## Transient toast (snackbar)

iOS has no stock toast/snackbar primitive. The app ships a minimal one built from stock SwiftUI primitives (Text + Capsule + overlay + animation):

- State: `AppModel.transientToast: TransientToastContent?` plus `AppModel.showTransientToast(_:)` (String overload for plain messages; `TransientToastContent` adds optional subtitle + artwork for the Apple-Music-style "1 song added · ‹playlist›" confirmation). The helper sets the message, schedules a ~1.8 s auto-clear, and fires a soft impact haptic on iOS. Calling it again replaces an in-flight toast — rapid actions don't pile up.
- Render: `MusicTransientToastChrome` applied at the root in `RootView`, plus one deliberate copy on the Now Playing `fullScreenCover` content (the cover occludes the root overlay; the two are never visible at once). Don't add `musicTransientToastChrome()` anywhere else.
- Use for ephemeral user-action confirmations only (e.g. "Added to Queue", "Playing Next"). For anything modal/blocking (errors, destructive confirmation, choices) use `.alert` / `.confirmationDialog` — toasts are not interactive.

If you wire a new action that ends in a queue/library/playlist mutation and a user might want feedback, call `app.showTransientToast(...)` from the closure. The haptic is bundled — don't re-fire `UIImpactFeedbackGenerator` separately at the call site.

## Settings hub

`SettingsView.swift` is an iOS Settings–style **hub** (account row + `NavigationLink` sections). Detail pages live in `SettingsSections.swift` (`SettingsLibrarySectionView`, `SettingsSyncSectionView`, `SettingsOfflineSectionView`, `SettingsDownloadsSectionView`, `SettingsAppearanceView`, `SettingsPluginsView`, `SettingsAboutView`) plus existing leaf views (`SettingsPlaybackView`, `SettingsLibraryDataView`, `AcquisitionPluginSettingsView`, `SubscriptionsView`, `SettingsEqualizerView`). Subpages use `.settingsSubpageChrome()`.

- **Library** (`SettingsLibrarySectionView`) — two stat groups: **Your Library** (`librarySongIds` / `libraryAlbumEntries` / `libraryPlaylistEntries`) vs **Server Catalog** (`AppModel.libraryStatistics`). Stats refresh via `.task` on appear and when the hub appears (`refreshLibraryStatistics()`).
- **Appearance** — `accentPresetId` + `customAccentHex` tint UI chrome (`MusicDesign.accent`); `appIconPresetId` is **independent** (home-screen icon via `AppAlternateIconSync`) — changing the accent does **not** change the icon and vice versa. Login logo uses `appIconPresetId`, not accent. Settings views use `MusicDesign.settingsBackground` (`systemGroupedBackground`) so light-mode cells stand out, not flat `systemBackground`.
- **Plugins** — **Music Requests** (acquisition / Lidarr), Following (subscriptions).

**Genres** — `Library → Genres` (`LibraryGenresView`) rolls noisy server subgenres up into ~20 main genres via `GenreCanonicalizer` (e.g. "Acid Jazz" → Jazz, "Boom Bap" → Lo-Fi). Merged rows fetch albums across **all** source subgenres (`LibraryGenreAlbumsView(sourceGenres:)`), deduped. The keyword table in `GenreCanonicalizer` is first-match-wins and easy to tweak.

**Backdrop / detail performance** — album/playlist detail backdrop palettes are memoized in `ArtworkDynamicGradient` keyed by the **stable** part of the artwork URL (path + cover-id/size/tag — auth params like Subsonic salt / Jellyfin `api_key` vary per request and would otherwise miss). Detail views seed the palette synchronously from that cache (no pop-in on revisit) and fade in on first compute. Album track lists hydrate instantly from `AppModel.albumTracksCache` (same as playlists).

## Sound & playback settings

User-facing settings live under **Settings → Sound & Playback** (`SettingsPlaybackView.swift`) and **Settings → Library & Data** (`SettingsLibraryDataView.swift`). Preferences persist in `UserDefaults` on `AppModel` and push to backend clients via `pushQualitySettingsToClients()`.

- **Streaming** — separate Wi‑Fi / cellular max bitrate (`StreamBitRateOption`) and format (`StreamFormatOption`). Active pair follows `prefersCellularStreamingQuality`. Navidrome sends Subsonic `format` + `maxBitRate` query params; Jellyfin maps format to progressive stream containers.
- **Downloads** — `DownloadQualityTier` + `DownloadFormatOption` (separate from streaming).
- **Stream cache** — `streamingDiskCacheEnabled` (`UserDefaults`). `StreamingMediaDiskCache` stores fully-fetched progressive streams under `Caches/LyraMusic/stream-cache/` (512 MB LRU). `peekCachedFileURL` for cheap candidate scans; `markAccessed` bumps LRU on actual play. `CachingResourceLoaderDelegate` can commit during AVPlayer playback when enabled (limited on current iOS — EQ prefetch is the reliable writer).
- **Equalizer** — `EqualizerSettings.swift` + `SettingsEqualizerView`. Ten ISO bands (32 Hz–16 kHz), presets (Flat, Dance, Jazz, Bass Boost, Vocal), bypass, per-band gains in `UserDefaults`. `AppModel.equalizerEnabled` syncs to `PlaybackEngine` via `syncEqualizerToEngine()`; toggling enabled reloads the current item (`reloadForEqualizerSettingsChange()`). Live slider changes call `applyLiveEqualizerGains()` on the active EQ session only.
- **Player** — skip interval buttons, sleep timer chrome, default playback speed, lock-screen remote mode (skip track vs skip interval). Wired through `PlaybackEngine` + `syncPlaybackPreferencesToEngine()`.
- **Artist play mode** — top songs / shuffle album / full discography (`ArtistPlayMode` in settings + long-press override on artist page).
- **Album cache refresh** — `metadataRefreshThreshold` triggers `refreshAlbumTracksIfNeeded(for:)` before playback to swap stale track IDs.

## Equalizer playback path

`AVPlayer` cannot host `AVAudioUnitEQ`. When `PlaybackEngine.equalizerEnabled` is true, eligible **local** sources route through `EqualizedAudioEnginePlayer` (`AVAudioEngine` → `AVAudioPlayerNode` → `AVAudioUnitEQ` → main mixer) — HanSJin/AVAudio-Equalizer pattern.

**EQ-eligible sources** (read via `AVAudioFile`, never live HTTP decode):

1. **Offline downloads** — `OfflineDownloadManager.localFile(for:)`
2. **Committed stream-cache files** — `StreamingMediaDiskCache` under `LyraMusic/stream-cache/`

**Streams without a local file:**

- Playback starts immediately on `AVPlayer` (no EQ yet).
- `prefetchInBackground` + `scheduleEqualizerHandoffWhenCached` download the progressive stream off the main actor; when complete, `swapActiveItemToEqualizerIfNeeded` reloads at the current position through the EQ engine.
- `tryQuickEqualizerCache` (≤2.5 s off-main wait) inserts a cache candidate when the network is fast enough for EQ on first play.
- `equalizerEnabled` also treats stream cache as enabled for candidate ordering (`streamingDiskCacheEnabled || equalizerEnabled`).

**Failure handling:** EQ decode failure on a local file falls back to `AVPlayer` on the same URL. Decode/setup failures must **not** call `handleEnded()` — `onPlaybackFailed` pauses without advancing the queue. `loadPlayerItem` tries EQ first for eligible locals, then `loadAVPlayerItem`.

**Files:** `EqualizerSettings.swift`, `EqualizedAudioEnginePlayer.swift`, EQ branches in `PlaybackEngine.swift` (`loadEqualizedPlayerItem`, `isEqualizerEligibleLocalFile`, handoff helpers).

## Server listening history (scrobbling)

Lyra submits **server** scrobbles separately from local Recently Played shelves:

- `PlaybackEngine.maybeScrobble` → `AppModel.recordRecentPlay` (local) **and** `ScrobbleService.recordCompletedScrobble` (server queue).
- `PlaybackEngine.onTrackStarted` → `ScrobbleService.sendNowPlaying` (Subsonic `scrobble?submission=false`; Jellyfin `Sessions/Playing`).
- Pending scrobbles persist in `ScrobbleStore`; `ScrobbleService.processPendingScrobbles()` drains on submit, periodic timer, and network restore. Failures skip individual items (queue continues). Blocked when `AppModel.effectiveOfflineMode`.
- Exclusions: album/artist/playlist ids in `ScrobbleStore.exclusions`; manage under Library & Data or via Now Playing track menu.
- **My Listening** (`MyListeningView`) — analytics from completed scrobbles only.

## Offline modes

- **Manual offline** (`AppModel.offlineMode`) — user toggle.
- **Auto-offline** (`AppModel.autoOfflineActive`) — non-Wi‑Fi and/or away from configured home SSID (`AutoOfflineHelper`, may need location for SSID).
- **`effectiveOfflineMode`** — union of both; used for Discovery search gating and scrobble suppression.
- Auto-offline Settings copy: limits Discovery search to downloaded content; Home/Library browsing and streaming are not fully offline-gated.

## Client backup

`LyraClientBackup` / `ClientBackupControlsView` — export/import scrobbles, scrobble exclusions, playback preferences. Does **not** include credentials, downloaded audio, or server magic-playlist contents.

## Navidrome shares

- **Create:** `NavidromeShareMenuSection` / `AppModel.createNavidromeShareAndNotify` — wired into album, track, and playlist context menus (Navidrome only). Copies URL to pasteboard + transient toast.
- **Manage:** `NavidromeSharesView` under Settings lists/deletes existing server shares.
- Chart/acquisition preview rows without a server item id omit the share action.

## Settings & disk I/O

- **Library statistics** (`SettingsLibrarySectionView`): **Your Library** counts come from personal membership state; **Server Catalog** from `AppModel.refreshLibraryStatistics()` (hub + library page). Jellyfin uses `TotalRecordCount` (lightweight). Navidrome paginates `getAlbumList2` (500/page cap) and reads `x-total-count` for album totals; artists via `libraryArtists(limit: 20_000)`; songs summed from album `trackCount` — **do not** call `allTracks(limit:)` for counts.
- **Cache row labels** (image/metadata counts in Downloads): loaded once via `AppModel.localCacheUsageSummaryAsync()` → `OfflineDiskCacheMetrics` on a background task. Never decode `LibrarySnapshotStore` or walk download folders from a SwiftUI `body`.
- **Download byte totals** — `OfflineDownloadManager.recalculateCacheBytes()` scans the downloads folder off the main actor; coalesces rapid calls via a generation counter.
- **Snapshot I/O** — prefer `LibrarySnapshotStore.loadAsync()` / `saveAsync()` for startup and background work; synchronous `load()` is for small admin tools only.

## Known unfixed / partial issues

Document for contributors — not an exhaustive bug list:

| Issue | Notes |
|-------|--------|
| Some overflow rows | A few chart-preview action stubs remain. |
| Plain unsynced lyrics | No auto-scroll by design. |
| Jellyfin “similar tracks” | Uses `/Items/{id}/Similar` with artist-shuffle fallback. Navidrome has no equivalent. |
| Home mixes | Minimum 3 tracks per mix; still needs enough scrobble/history signal for On Repeat / Rediscover. |
| Home taste shelves | Empty until library/taste data loads; shelves omit albums already in your magic playlist. |
| Navidrome Settings stats | Song totals sum album `trackCount` — may differ slightly from true track count on odd tagging. Very large libraries use paginated album/artist fetches but song sum still depends on indexed album metadata. |
| EQ on live streams | Requires local cache or download; first uncached play is AVPlayer until background cache + handoff (or replay). |
| Stream cache during AVPlayer | Opportunistic `CachingResourceLoaderDelegate` commits may not write on current iOS; EQ `ensureCached` / `prefetchInBackground` is the supported cache path. |
| Search tab: separated button vs scroll-collapse | The Search `Tab(role: .search)` (the detached search button) does **not** participate in `tabBarMinimizeBehavior`, so the tab bar + mini player don't collapse on scroll under Search. Dropping `role: .search` enables the collapse but turns the tab bar into one inline pill. iOS won't give both — currently set to keep the separated button (`.tabBarMinimizeBehavior(... == .search ? .never : .onScrollDown)` in `RootView`). |
| iOS 27 alternate icon (Dark appearance) | `setAlternateIconName` succeeds but the home-screen icon's **dark** variant only refreshes on respring/reboot (light updates live). SpringBoard limitation; not app-fixable. Accent color and app icon are independent (`accentPresetId` / `appIconPresetId`). |

## Build / run

- iOS app target: `LyraMusicHost/LyraMusicHost.xcodeproj` (workspace at `LyraMusicHost/LyraMusicHost.xcodeproj/project.xcworkspace`).
- Library code lives in the SPM package at `Sources/LyraMusicKit/` (`Package.swift`).
- Standard build: `xcodebuild -workspace LyraMusicHost/LyraMusicHost.xcodeproj/project.xcworkspace -scheme LyraMusicHost -destination 'generic/platform=iOS Simulator' build`.
