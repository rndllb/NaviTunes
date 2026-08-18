# Vellum Music — Backend Notes

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
- **Personal library (Vellum "My Library" magic playlist)** — a per-user opaquely-named playlist (`__vellum_<sha12>`) Vellum creates on the backend. Its contents are the canonical "what *I* added" set, synced across devices:
  - Playlist tracks → `AppModel.librarySongIds: Set<String>`
  - `comment` (Subsonic) / `Overview` (Jellyfin) JSON → `LibraryMembershipPayload` → `libraryAlbumEntries` + `libraryPlaylistEntries` (each entry carries a per-item `added` date so "Recently Added (yours)" is accurate).
  - Name is deterministic from `(backend, normalized server key, user id)` in `LibraryMembership` — same user + same server URL → same playlist on every device (legacy host-only names are still discovered).
  - Resolved on sign-in by `refreshLibraryMembership()` (always find-by-name on the server, not cache-only); kept live via `startLibraryMembershipAutoSync()` (~20s poll) and `refreshLibraryMembershipIfStale()` on foreground.
  - Mutated by `addAlbumToLibrary` / `removeAlbumFromLibrary` / `toggleFavoriteTrack` etc., then persisted back to the magic playlist via `persistLibraryMembershipPayload()`.
  - Filtered out of every user-facing playlist surface by id and by name prefix (`LibraryMembership.isMagicPlaylistName`).

Rule of thumb: anything that means "things the *user* owns / has added" must read from `librarySongIds` / `libraryAlbumEntries` / `libraryPlaylistEntries`, not `libraryAlbums`. Search scopes follow the same split: the Library tab in Discovery searches **personal** state; the Discover tab is a hybrid of **server catalog** + acquisition download candidates.

## Acquisition plugins (requesting music)

All "request missing music" flows funnel through one swappable abstraction so backends are interchangeable. **Only one plugin is active at a time** (`AcquisitionManager.activePlugin`, persisted in `UserDefaults`).

- **Core** (`AcquisitionCore.swift`): `AcquisitionPluginKind` (`lidarr`, `downtify`, `droppedNeedle`), the unified `AcquisitionRequest` (artist/track/album + optional MBIDs + `requestKey`), `AcquisitionJob`(+`AcquisitionJobStatus`), `AcquisitionResult` (a concrete searchable item carrying its own request), `AcquisitionRelease` / `AcquisitionArtist` catalog rows, `AcquisitionCapabilities` (granularity track/album, `supportsTrackSearch`, `supportsReleaseCatalog`, `configFields`), and the `AcquisitionProviding` protocol (`artistReleases`, `upcomingAndWanted`, `searchArtists`, `tracks(forRelease:)`). `AcquisitionConfigStore` persists per-plugin credentials under distinct keys (`acquisition.<kind>.<field>`). `AcquisitionHTTP` is the shared REST helper for the network plugins.
- **Manager** (`AcquisitionManager.swift`, `@MainActor`): `enqueue(_:)` is the single entry point; jobs keyed by `requestKey`; a shared poll loop reconciles against `provider.activeJobs()`; `onJobFinished` fires once per terminal job. `AppModel.acquisition` owns it and forwards `objectWillChange`. Default plugin is **Lidarr**. The picker in `SettingsView` lists `AcquisitionPluginKind.allCases`, so every registered kind is user-selectable.
- **Plugins** (conform to `AcquisitionProviding`): **Lidarr** (`LidarrAcquisitionPlugin`) — album-level; MusicBrainz lookup → add + monitor → `AlbumSearch` (#5012 monitor-race fix); polls `/queue` + `/command`; catalog reads `GET /artist`, `/album?artistId=`, `/calendar`, `/wanted/missing` (`supportsReleaseCatalog`). **DroppedNeedle** (`DroppedNeedleAcquisitionPlugin`) — album-level (optional per-track when `trackTitle` is set); native `/api/v1/*` auth via session tokens from one of: `POST /api/v1/auth/login` (local account), `POST /api/v1/auth/jellyfin/login` (imported Jellyfin user), or Plex pin (`POST /api/v1/auth/plex/pin` → browser → `GET /api/v1/auth/plex/poll`); Connect Apps app passwords are **not** valid for the native API; requests via `POST /api/v1/requests/new`; polls `/api/v1/downloads`; artist discography via `/search` (no calendar). **Downtify** (`DowntifyAcquisitionPlugin`) — the only **track**-granularity plugin (`supportsTrackSearch`, no release catalog); single `baseURL` config field.
- **Call sites**: UI never touches a concrete plugin. Build an `AcquisitionRequest` and call `AppModel.requestAcquisition(_:)` (`DiscoverySearchView`, `BrowseAlbumDetailView`, `ServerPlaylistViews`, `MusicNewTabView`). Gate affordances on `app.acquisitionCapabilities` (`supportsTrackSearch`, `granularity`). Album-level plugins request the whole release for missing-track rows.
- **Settings**: `SettingsView` → Plugins → **Music Requests** (renamed from "Downloads") opens `AcquisitionPluginSettingsView` — active-plugin picker, capability-driven config fields, Test Connection (`provider.validate()`), and a unified Activity list (`acquisition.displayJobs`, includes server-side items started outside Vellum). (The offline-media "Downloads" section under Settings is a separate thing.)
- **Completion**: `AppModel.handleAcquisitionJobFinished` (backend-agnostic) triggers a server scan and retries `searchCatalog` until the new file surfaces, then adds it to the personal library.
- **Request an artist not in your library**: Discover search surfaces plugin artist matches (`AcquisitionManager.searchArtists`) when Lidarr or DroppedNeedle is configured. Settings → Following has an "Add artist" entry. Both open `ArtistPageView(input: .named(...))`, which blends the server catalog with the plugin discography.

To add a backend: add a `case` to `AcquisitionPluginKind`, write one `*AcquisitionPlugin.swift`, and register it in `AcquisitionManager.makeProvider`. No feature-code changes.

## Follow-artist completeness (subscriptions)

The "Lidarr-style brain" — keep a followed artist's discography complete — but it **lives in the app**. Canonical releases come from the active plugin (`artistReleases`); there is no iTunes/TheAudioDB floor.

- **Models/store** (`MusicSubscriptionModels.swift`): `FollowedArtist` (persisted "wanted" intent; id = MBID or normalized-name fallback; tracks `requestedReleaseIds` so re-checks don't re-enqueue), `SubscriptionReleaseStatus` (`.have`/`.requested`/`.pending` UI status), and `MusicSubscriptionStore` (JSON in `Application Support/VellumMusic/subscriptions.json`, same layout as `LibrarySnapshotStore`).
- **Engine** (`MusicSubscriptionEngine.swift`, `@MainActor`): env-injected (no `AppModel` internals) so it stays testable. `check(artistId:)` = plugin discography → diff against the connected server (`serverAlbumsForArtist`, normalized-title match, any backend) → enqueue missing albums/EPs through the **active acquisition plugin**. With no catalog plugin, completeness is server-only (have vs wishlist).
- **AppModel** owns `subscriptions` (built in `init`, forwards `objectWillChange`); `serverAlbums(forArtistName:)` is the "have it?" probe; `refreshSubscriptions()` runs a pass. The engine calls `acquisition.enqueue` directly (not `requestAcquisition`) to avoid per-album toasts.
- **UI**: `ArtistFollowButton` (bell toggle in the artist-page toolbar, always shown — following without a plugin is a valid wishlist) and `SubscriptionsView` (Settings → Plugins → **Following**: per-artist status, "Check now", unfollow; banner when no download plugin is configured).
- **Capability gating**: auto-fetch only when `acquisition.isConfigured` **and** `capabilities.granularity == .album`. Everything keys off capabilities, never a named plugin.

## Home mixes (Made for You)

- Built in `HomeMixBuilder.swift`, cached on `AppModel.homeMixes`, refreshed via `rebuildHomeMixes()` / `refreshHomeMixes()`.
- Mix types: **On Repeat**, **Favorites**, **Rediscover**, **New in Your Library** — each needs **≥ 3 tracks** or it is omitted.
- **On Repeat** / **Rediscover** read `ScrobbleService.store.completed` (successful **server** scrobbles), not `recentlyPlayedTracks` alone.
- **Favorites** intersects `favoriteTrackIds` with `discoveryLibraryTracks` (partial until discovery index finishes).
- Synthetic playlist IDs: `__vellum_home_mix:<mixId>` via `HomeMix.asPlaylistSummary()`.
- Library → Playlists surfaces mixes when `AppModel.showHomeMixesInPlaylists` is true (Settings → Library & Data).
- Mix detail: `ServerPlaylistDetailView(homeMixId:)` — album-style UI, mosaic hero, no remove-from-playlist.

## Home discovery shelves

- **Top Picks** (`homeTopPickAlbums`, 8) + **New Releases** (`homeNewReleaseAlbums`, 20) — one taste-ranked pass over a server-catalog candidate pool (`recentlyAddedAlbums`, server recently played, top-3 taste-genre albums). Ranked by `NewTabPersonalizationEngine.tasteRankedAlbumSummaries`.
- **Eligibility** — `isEligibleForHomeTopPick` excludes magic-playlist albums (`libraryAlbumEntries` + release-identity match via `catalogReleaseIdentityKey`). Does **not** use `libraryAlbumReleaseIndex` (whole server catalog).
- **Genre shelves** — session-locked `homeSelectedGenres` from `listeningTopGenres()` mapped onto server genres; 9 albums per shelf; filtered with `homeDiscoveryCatalogAlbums`.
- **UI** — `HomeTopPickCard` editorial cards (250×325, vertical color bleed via `HomeTopPickArtworkBleed` / `ArtworkVerticalBleed`).
- Rebuild hooks: `refreshHome()`, library refresh, magic-playlist membership changes (`addAlbumToLibrary` / `removeAlbumFromLibrary` / `applyMagicPlaylistFetch`).

## New tab (server + Lidarr catalog)

- **No iTunes / TheAudioDB / MusicBrainz browse.** The `ITunes*Client.swift` files still exist but are **unreferenced dead code** — don't wire them back in. `refreshNewTabBrowse()` builds a taste-ranked feed from the server catalog (recently added + albums by scrobble/follow artists) plus, when Lidarr is configured, Lidarr calendar + wanted/missing.
- `newTabBrowseBackend` is `.lidarr` or `.server`. Badge: "Based on your listening" / "From Lidarr" / "From your server".
- Hero songs are recent scrobbles / recently played tracks, not chart singles.
- Off-server album tracklists come from the active plugin (`tracks(forRelease:)`), not iTunes.

## Artist navigation & Now Playing chrome

- `ArtistNavigation.swift` / `ArtistNameButton` — programmatic artist pushes (avoids nested `NavigationLink` on album detail). “Various Artists” is not tappable.
- `ArtistNowPlayingMenuButton` — UIKit menu on iOS; uses `heroChromeSecondary` from backdrop palette when a track is playing (fixes white-on-white artist text on light artwork).
- `OverPlayerSheetPresenter` — presents `AddToPlaylistSheet` above the Now Playing `fullScreenCover` without entering SwiftUI’s sheet tree (preserves mini-player zoom transition). `RootView` mirrors `isNowPlayingCoverPresented` into `AppModel`.

## Artist page (`ArtistPageView`)

- **Hero** — stretchy portrait (`StretchyHeaderContainer`, `clipBanner: false` on artist pages). Sharp photo stays visible; a **single soft blur wash** (capped opacity, ~30pt radius) feathers in over a bottom band aligned with the play row. Bottom **seam overlap** + solid backdrop base prevent a visible clip line into the scroll content.
- **Backdrop** — `ArtworkDynamicGradient.BackdropAnalysisStyle.artistPage`: samples lower image rows, ignores near-white studio backgrounds, produces **dark charcoal** page tint (not the dominant white bucket used by album detail). Cached separately from `.detail` palettes. Respects `albumBackdropEnabled`.
- **Controls** — centered white play capsule; dark circular info / favorite side buttons; artist name above play. Toolbar uses `musicHeroAlbumNavigationChrome`.
- **Content chrome** — `ArtistPageChrome` adaptive labels on backdrop (Top Songs, discography, About, Similar).
- **Data** — `ArtistViewModel` loads the server catalog, then the active plugin's discography (`artistReleases`) when Lidarr or DroppedNeedle is configured. No TheAudioDB / Last.fm / iTunes / MusicBrainz calls. On-server artists use Navidrome/Jellyfin art (`bannerArtworkURL` = library artist image, then a server album cover). Off-server art comes from the plugin.
- **About** — Lidarr `overview` / genres when present; otherwise hidden.
- **Top songs** — scrobbles + recently played for this artist, then server-track fallback.
- **Similar artists** — hidden (no third-party related-artist fetch).

## Album detail related shelves

Footer carousels on **library album detail** (`ServerPlaylistDetailView`) and **browse/chart album detail** (`BrowseAlbumDetailView`):

- **Other Versions** — same artist + normalized title family (`AlbumSummary.albumVersionBaseKey` / `isOtherVersion(of:)`).
- **More By [Artist]** — other albums by the artist (excluding current + version siblings).
- **You Might Also Like** — taste-ranked picks from the artist catalog pool.

Implementation: `AlbumDetailRelatedSectionsView` (horizontal carousels, backdrop-adaptive shelf text). `AppModel.albumDetailShelvesFromMemory` paints instantly from `libraryAlbums`; `fetchAlbumDetailArtistCatalog` resolves artist id → `albums(forLibraryArtistId:)` with session cache (`AlbumDetailArtistCatalogCache`). Child album pushes must not clear parent navigation on forward navigation (`ServerPlaylistViews` detail lifecycle).

## Home discovery shelf stability

- `rebuildHomeDiscoveryShelves` / `stabilizeHomeDiscoveryShelf` — after first paint, Top Picks + New Releases keep visible album ids in place when the candidate pool grows (genre catalog landing no longer reshuffles the hero shelf).
- `refreshHome(forceDiscoveryReshuffle:)` — pull-to-refresh passes `forceDiscoveryReshuffle: true` for a full re-rank.
- Cold launch seeds the candidate pool from persisted `libraryAlbums` when recency sources are still empty.

## Cover art chrome

- Shared **liquid-glass hairline** on cover art via `MusicDesign.artworkSubtleBorderOverlay()` (`artworkSubtleBorderLineWidth: 0.75`) — album rows, mosaics, Home Top Picks cards, discovery shelves.

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
- **UI performance is a correctness constraint here, not a polish pass.** Every view observes the whole of `AppModel`, so any publish re-runs every visible `body`. Before adding UI, read `Rules/swiftui-body-cost.md` (no catalog scans in a body; derived lists live in `@State`; O(1) lookups via `catalogAlbum(id:)` / `libraryPlaylist(id:)` / `indexedTrack(id:)`) and `Rules/swiftui-render-cost.md` (lazy containers, render windows, pre-rasterized blur).

## Transient toast (snackbar)

iOS has no stock toast/snackbar primitive. The app ships a minimal one built from stock SwiftUI primitives (Text + Capsule + overlay + animation):

- State: `AppModel.transientToast: TransientToastContent?` plus `AppModel.showTransientToast(_:)` (String overload for plain messages; `TransientToastContent` adds optional subtitle + artwork for the Apple-Music-style "1 song added · ‹playlist›" confirmation). The helper sets the message, schedules a ~1.8 s auto-clear, and fires a soft impact haptic on iOS. Calling it again replaces an in-flight toast — rapid actions don't pile up.
- Render: `MusicTransientToastChrome` applied at the root in `RootView`, plus one deliberate copy on the Now Playing `fullScreenCover` content (the cover occludes the root overlay; the two are never visible at once). Don't add `musicTransientToastChrome()` anywhere else.
- Use for ephemeral user-action confirmations only (e.g. "Added to Queue", "Playing Next"). For anything modal/blocking (errors, destructive confirmation, choices) use `.alert` / `.confirmationDialog` — toasts are not interactive.

If you wire a new action that ends in a queue/library/playlist mutation and a user might want feedback, call `app.showTransientToast(...)` from the closure. The haptic is bundled — don't re-fire `UIImpactFeedbackGenerator` separately at the call site.

## Settings hub

`SettingsView.swift` is an iOS Settings–style **hub** (account row + `NavigationLink` sections). Detail pages live in `SettingsSections.swift` (`SettingsLibrarySectionView`, `SettingsSyncSectionView`, `SettingsOfflineSectionView`, `SettingsDownloadsSectionView`, `SettingsAppearanceView`, `SettingsPluginsView`, `SettingsAboutView`) plus existing leaf views (`SettingsPlaybackView`, `SettingsLibraryDataView`, `AcquisitionPluginSettingsView`, `SubscriptionsView`, `SettingsEqualizerView`). Subpages use `.settingsSubpageChrome()`.

- **Library** (`SettingsLibraryDataView`) — two stat groups: **Your Library** (`librarySongIds` / `libraryAlbumEntries` / `libraryPlaylistEntries`) vs **Server Catalog** (`AppModel.libraryStatistics`), plus mixes, cache, listening history, backup, and Navidrome shares. Stats refresh via `.task` on appear and when the hub appears (`refreshLibraryStatistics()`).
- **Appearance** — `accentPresetId` + `customAccentHex` tint UI chrome (`MusicDesign.accent`); `appIconPresetId` is **independent** (home-screen icon via `AppAlternateIconSync`) — changing the accent does **not** change the icon and vice versa. Login logo uses `appIconPresetId`, not accent. `launchTabPreference` chooses the landing tab after launch/sign-in (**defaults to Library**; `AppModel.loadLaunchTab`). Settings views use `MusicDesign.settingsBackground` (`systemGroupedBackground`) so light-mode cells stand out, not flat `systemBackground`.
- **Plugins** — **Music Requests** (acquisition / Lidarr or DroppedNeedle), Following (subscriptions).

**Genres** — `Library → Genres` (`LibraryGenresView`) rolls noisy server subgenres up into ~20 main genres via `GenreCanonicalizer` (e.g. "Acid Jazz" → Jazz, "Boom Bap" → Lo-Fi). Merged rows fetch albums across **all** source subgenres (`LibraryGenreAlbumsView(sourceGenres:)`), deduped. The keyword table in `GenreCanonicalizer` is first-match-wins and easy to tweak.

**Backdrop / detail performance** — album/playlist detail backdrop palettes are memoized in `ArtworkDynamicGradient` keyed by the **stable** part of the artwork URL (path + cover-id/size/tag — auth params like Subsonic salt / Jellyfin `api_key` vary per request and would otherwise miss). Styles: `.detail` (dominant cover color), `.artistPage` (dark charcoal, bottom-weighted sampling). Detail views seed the palette synchronously from that cache (no pop-in on revisit) and fade in on first compute. Album track lists hydrate instantly from `AppModel.albumTracksCache` (same as playlists).

## Sound & playback settings

User-facing settings live under **Settings → Sound & Playback** (`SettingsPlaybackView.swift`) and **Settings → Library & Data** (`SettingsLibraryDataView.swift`). Preferences persist in `UserDefaults` on `AppModel` and push to backend clients via `pushQualitySettingsToClients()`.

- **Streaming** — separate Wi‑Fi / cellular max bitrate (`StreamBitRateOption`) and format (`StreamFormatOption`). Active pair follows `prefersCellularStreamingQuality`. Navidrome sends Subsonic `format` + `maxBitRate` query params; Jellyfin maps format to progressive stream containers.
- **Downloads** — `DownloadQualityTier` + `DownloadFormatOption` (separate from streaming).
- **Stream cache** — `streamingDiskCacheEnabled` (`UserDefaults`, **off by default** — registered in `AppModel.init`; turning the EQ on flips it true). `StreamingMediaDiskCache` stores fully-fetched progressive streams under `Caches/VellumMusic/stream-cache/` (512 MB LRU). `peekCachedFileURL` for cheap candidate scans; `markAccessed` bumps LRU on actual play. `CachingResourceLoaderDelegate` can commit during AVPlayer playback when enabled (limited on current iOS — EQ prefetch is the reliable writer).
- **Equalizer** — `EqualizerSettings.swift` + `SettingsEqualizerView`. Ten ISO bands (32 Hz–16 kHz), presets (Flat, Dance, Jazz, Bass Boost, Vocal), bypass, per-band gains in `UserDefaults`. `AppModel.equalizerEnabled` syncs to `PlaybackEngine` via `syncEqualizerToEngine()`. Toggling EQ while the engine path is live bypasses/applies the EQ node in place (no track reload). Turning EQ on while streaming still reloads via `reloadForEqualizerSettingsChange()` so a cache/EQ path can take over. Live slider changes call `applyLiveEqualizerGains()` on the active EQ session only.
- **Player** — skip interval buttons, sleep timer chrome, default playback speed, lock-screen remote mode (skip track vs skip interval). Wired through `PlaybackEngine` + `syncPlaybackPreferencesToEngine()`.
- **Artist play mode** — top songs / shuffle album / full discography (`ArtistPlayMode` in settings + long-press override on artist page).
- **Album cache refresh** — `metadataRefreshThreshold` triggers `refreshAlbumTracksIfNeeded(for:)` before playback to swap stale track IDs.

## Equalizer playback path

`AVPlayer` cannot host `AVAudioUnitEQ`. When `PlaybackEngine.equalizerEnabled` is true, eligible **local** sources route through `EqualizedAudioEnginePlayer` (`AVAudioEngine` → `AVAudioPlayerNode` → `AVAudioUnitEQ` → main mixer) — HanSJin/AVAudio-Equalizer pattern.

**EQ-eligible sources** (read via `AVAudioFile`, never live HTTP decode):

1. **Offline downloads** — `OfflineDownloadManager.localFile(for:)`
2. **Committed stream-cache files** — `StreamingMediaDiskCache` under `VellumMusic/stream-cache/`

**Streams without a local file:**

- Playback starts immediately on `AVPlayer` (no EQ yet). Do **not** wait for a cache download before first audio.
- `scheduleEqualizerHandoffWhenCached` downloads the progressive stream off the main actor; when complete, `swapActiveItemToEqualizerIfNeeded` reloads at the current position through the EQ engine.
- If EQ setup/decode fails after detaching AVPlayer, restore AVPlayer on the cache file or live stream (`restorePlaybackAfterFailedEqualizerHandoff`). Never leave `isPlaying` true with no player.
- Cache hits are size-checked (`StreamingMediaDiskCache.peekCachedFileURL`); truncated/error-page files are evicted. A cache file is deleted only on decode/parse failure, never on a ready timeout.
- `equalizerEnabled` also treats stream cache as enabled for candidate ordering (`streamingDiskCacheEnabled || equalizerEnabled`).

**Failure handling:** EQ decode failure on a local file falls back to `AVPlayer` on the same URL. Decode/setup failures must **not** call `handleEnded()` — `onPlaybackFailed` pauses without advancing the queue. `loadPlayerItem` tries EQ first for eligible locals, then `loadAVPlayerItem`.

**Files:** `EqualizerSettings.swift`, `EqualizedAudioEnginePlayer.swift`, EQ branches in `PlaybackEngine.swift` (`loadEqualizedPlayerItem`, `isEqualizerEligibleLocalFile`, handoff helpers).

## Server listening history (scrobbling)

Vellum submits **server** scrobbles separately from local Recently Played shelves:

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

`VellumClientBackup` / `ClientBackupControlsView` — export/import scrobbles, scrobble exclusions, playback preferences. Does **not** include credentials, downloaded audio, or server magic-playlist contents.

## Navidrome shares

- **Create:** `NavidromeShareMenuSection` / `AppModel.createNavidromeShareAndNotify` — wired into album, track, and playlist context menus (Navidrome only). Copies URL to pasteboard + transient toast.
- **Manage:** `NavidromeSharesView` under Settings lists/deletes existing server shares.
- Chart/acquisition preview rows without a server item id omit the share action.

## Settings & disk I/O

- **Library statistics** (`SettingsLibrarySectionView`): **Your Library** counts come from personal membership state; **Server Catalog** from `AppModel.refreshLibraryStatistics()` (hub + library page). Jellyfin uses `TotalRecordCount` (lightweight). Navidrome paginates `getAlbumList2` (500/page cap) and reads `x-total-count` for album totals; artists via `libraryArtists(limit: 20_000)`; songs summed from album `trackCount` — **do not** call `allTracks(limit:)` for counts.
- **Cache row labels** (image/metadata counts in Downloads): loaded once via `AppModel.localCacheUsageSummaryAsync()` → `OfflineDiskCacheMetrics` on a background task. Never decode `LibrarySnapshotStore` or walk download folders from a SwiftUI `body`.
- **Download byte totals** — `OfflineDownloadManager.recalculateCacheBytes()` scans the downloads folder off the main actor; coalesces rapid calls via a generation counter.
- **Snapshot I/O** — prefer `LibrarySnapshotStore.loadAsync()` / `saveAsync()` for startup and background work; synchronous `load()` is for small admin tools only.

### Clearing caches actually has to clear everything

"Clear cache" looked like a no-op because deleted bytes came straight back and the row counts never moved. A cache clear has to cover all four of these or it will appear broken:

- **`URLCache.shared`** — `ArtworkURLCache.clearAll()` clears it too; `URLSession` would otherwise re-serve deleted artwork from the system HTTP cache.
- **In-flight writes** — `LibrarySnapshotStore` / `PlaylistRowsCacheStore` guard on a `writeGeneration` (bumped on clear, checked under `writeLock`) so a debounced save started before the clear can't rewrite the file after it.
- **In-memory derived caches** — `AppModel.clearMediaArtworkCaches()` is the one entry point (URL cache, `DecodedArtworkCache`, backdrop palettes, Top Pick bleeds, `MediaAuthHeaderRegistry`). Disk-only clears leave art and backdrops on screen.
- **UI counts** — bump `AppModel.localCacheRevision`; the size/count rows are `@State` loaded off-main and won't recompute on their own.

Clear entry points are `async` (`OfflineStorageBrowserViews.perform`) — never walk cache folders from a `body`.

## Known unfixed / partial issues

Document for contributors — not an exhaustive bug list:

| Issue | Notes |
|-------|--------|
| Some overflow rows | A few chart-preview action stubs remain. |
| Plain unsynced lyrics | No auto-scroll by design. |
| Jellyfin “similar tracks” | Uses `/Items/{id}/Similar` with artist-shuffle fallback. Navidrome has no equivalent. |
| Home mixes | Minimum 3 tracks per mix; still needs enough scrobble/history signal for On Repeat / Rediscover. |
| Home taste shelves | Empty until library/taste data loads; shelves omit albums already in your magic playlist. Top Picks order stabilizes after first paint (pull-to-refresh re-ranks). |
| Navidrome Settings stats | Song totals sum album `trackCount` — may differ slightly from true track count on odd tagging. Very large libraries use paginated album/artist fetches but song sum still depends on indexed album metadata. |
| EQ on live streams | Requires local cache or download; first uncached play is AVPlayer until background cache + handoff (or replay). |
| Stream cache during AVPlayer | Opportunistic `CachingResourceLoaderDelegate` commits may not write on current iOS; EQ `ensureCached` / `prefetchInBackground` is the supported cache path. |
| Search tab: separated button vs scroll-collapse | The Search `Tab(role: .search)` (the detached search button) does **not** participate in `tabBarMinimizeBehavior`, so the tab bar + mini player don't collapse on scroll under Search. Dropping `role: .search` enables the collapse but turns the tab bar into one inline pill. iOS won't give both — currently set to keep the separated button (`.tabBarMinimizeBehavior(... == .search ? .never : .onScrollDown)` in `RootView`). |
| iOS 27 alternate icon (Dark appearance) | `setAlternateIconName` succeeds but the home-screen icon's **dark** variant only refreshes on respring/reboot (light updates live). SpringBoard limitation; not app-fixable. Accent color and app icon are independent (`accentPresetId` / `appIconPresetId`). |

## Build / run

- iOS app target: `VellumMusicHost/VellumMusicHost.xcodeproj` (workspace at `VellumMusicHost/VellumMusicHost.xcodeproj/project.xcworkspace`).
- Library code lives in the SPM package at `Sources/VellumMusicKit/` (`Package.swift`).
- Standard build: `xcodebuild -workspace VellumMusicHost/VellumMusicHost.xcodeproj/project.xcworkspace -scheme VellumMusicHost -destination 'generic/platform=iOS Simulator' build`.
