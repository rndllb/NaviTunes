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

## Server catalog vs personal library (do not confuse these)

The app surfaces two distinct collections. The naming is a footgun — `AppModel.libraryAlbums` is the **whole server catalog**, not "your library".

- **Server catalog** — every album/track on the connected Navidrome / Jellyfin instance. Loaded via `MusicLibraryProviding.albums(limit:)` → Subsonic `getAlbumList2` / Jellyfin `Items?IncludeItemTypes=MusicAlbum`. Cached in `AppModel.libraryAlbums` / `recentlyAddedAlbums`. Server-wide search is `MusicLibraryProviding.searchCatalog(query:)` → Subsonic `search3` / Jellyfin `Items?searchTerm=…`.
- **Personal library (Lyra "My Library" magic playlist)** — a per-user opaquely-named playlist (`__lyra_<sha12>`) Lyra creates on the backend. Its contents are the canonical "what *I* added" set, synced across devices:
  - Playlist tracks → `AppModel.librarySongIds: Set<String>`
  - `comment` (Subsonic) / `Overview` (Jellyfin) JSON → `LibraryMembershipPayload` → `libraryAlbumEntries` + `libraryPlaylistEntries` (each entry carries a per-item `added` date so "Recently Added (yours)" is accurate).
  - Resolved + reconciled on sign-in by `refreshLibraryMembership()`; mutated by `addAlbumToLibrary` / `removeAlbumFromLibrary` / `toggleFavoriteTrack` etc., then persisted back to the magic playlist via `persistLibraryMembershipPayload()`.
  - Filtered out of every user-facing playlist surface by id and by name prefix (`LibraryMembership.isMagicPlaylistName`).

Rule of thumb: anything that means "things the *user* owns / has added" must read from `librarySongIds` / `libraryAlbumEntries` / `libraryPlaylistEntries`, not `libraryAlbums`. Search scopes follow the same split: the Library tab in Discovery searches **personal** state; the Downtify tab is a hybrid of **server catalog** + Downtify download candidates.

## Home mixes (Tuned In)

- Built in `HomeMixBuilder.swift`, cached on `AppModel.homeMixes`, refreshed via `rebuildHomeMixes()` / `refreshHomeMixes()`.
- Mix types: **On Repeat**, **Favorites**, **Rediscover**, **New in Your Library** — each needs **≥ 3 tracks** or it is omitted.
- **On Repeat** / **Rediscover** read `ScrobbleService.store.completed` (successful **server** scrobbles), not `recentlyPlayedTracks` alone.
- **Favorites** intersects `favoriteTrackIds` with `discoveryLibraryTracks` (partial until discovery index finishes).
- Synthetic playlist IDs: `__lyra_home_mix:<mixId>` via `HomeMix.asPlaylistSummary()`.
- Library → Playlists surfaces mixes when `AppModel.showHomeMixesInPlaylists` is true (Settings → Library & Data).
- Mix detail: `ServerPlaylistDetailView(homeMixId:)` — album-style UI, mosaic hero, no remove-from-playlist.

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

- State: `AppModel.transientToast: String?` plus `AppModel.showTransientToast(_:)`. The helper sets the message, schedules a ~1.8 s auto-clear, and fires a soft impact haptic on iOS. Calling it again replaces an in-flight toast — rapid actions don't pile up.
- Render: a single `MusicTransientToastChrome` view modifier applied at the root in `RootView`. Don't add `musicTransientToastChrome()` further down the tree; the root copy is the only one.
- Use for ephemeral user-action confirmations only (e.g. "Added to Queue", "Playing Next"). For anything modal/blocking (errors, destructive confirmation, choices) use `.alert` / `.confirmationDialog` — toasts are not interactive.

If you wire a new action that ends in a queue/library/playlist mutation and a user might want feedback, call `app.showTransientToast(...)` from the closure. The haptic is bundled — don't re-fire `UIImpactFeedbackGenerator` separately at the call site.

## Sound & playback settings

User-facing settings live under **Settings → Sound & Playback** (`SettingsPlaybackView.swift`) and **Settings → Library & Data** (`SettingsLibraryDataView.swift`). Preferences persist in `UserDefaults` on `AppModel` and push to backend clients via `pushQualitySettingsToClients()`.

- **Streaming** — separate Wi‑Fi / cellular max bitrate (`StreamBitRateOption`) and format (`StreamFormatOption`). Active pair follows `prefersCellularStreamingQuality`. Navidrome sends Subsonic `format` + `maxBitRate` query params; Jellyfin maps format to progressive stream containers.
- **Downloads** — `DownloadQualityTier` + `DownloadFormatOption` (separate from streaming).
- **Player** — skip interval buttons, sleep timer chrome, default playback speed, lock-screen remote mode (skip track vs skip interval). Wired through `PlaybackEngine` + `syncPlaybackPreferencesToEngine()`.
- **Artist play mode** — top songs / shuffle album / full discography (`ArtistPlayMode` in settings + long-press override on artist page).
- **Album cache refresh** — `metadataRefreshThreshold` triggers `refreshAlbumTracksIfNeeded(for:)` before playback to swap stale track IDs.

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
- Chart/Downtify preview rows without a server item id omit the share action.

## Settings & disk I/O

- **Library statistics** (`SettingsView` → Library section): fetched on appear via `AppModel.refreshLibraryStatistics()`, not during bootstrap. Jellyfin uses `TotalRecordCount` (lightweight). Navidrome uses `getArtists` + `getAlbumList2` and sums album `trackCount` for songs — **do not** call `allTracks(limit:)` for counts.
- **Cache row labels** (image/metadata counts in Downloads): loaded once via `AppModel.localCacheUsageSummaryAsync()` → `OfflineDiskCacheMetrics` on a background task. Never decode `LibrarySnapshotStore` or walk download folders from a SwiftUI `body`.
- **Download byte totals** — `OfflineDownloadManager.recalculateCacheBytes()` scans the downloads folder off the main actor; coalesces rapid calls via a generation counter.
- **Snapshot I/O** — prefer `LibrarySnapshotStore.loadAsync()` / `saveAsync()` for startup and background work; synchronous `load()` is for small admin tools only.

## Known unfixed / partial issues

Document for contributors — not an exhaustive bug list:

| Issue | Notes |
|-------|--------|
| Some overflow rows | Stubs remain (`Start Collaboration`, `Move to Folder`, some chart preview actions). |
| Plain unsynced lyrics | No auto-scroll by design. |
| Jellyfin “similar tracks” | Artist search shuffle, not a similarity API. |
| Home mixes | Minimum 3 tracks per mix; still needs enough scrobble/history signal for On Repeat / Rediscover. |
| Navidrome Settings stats | Song totals sum album `trackCount` — may differ slightly from true track count on odd tagging; album/artist counts cap at the fetch limit on very large libraries. |

## Build / run

- iOS app target: `LyraMusicHost/LyraMusicHost.xcodeproj` (workspace at `LyraMusicHost/LyraMusicHost.xcodeproj/project.xcworkspace`).
- Library code lives in the SPM package at `Sources/LyraMusicKit/` (`Package.swift`).
- Standard build: `xcodebuild -workspace LyraMusicHost/LyraMusicHost.xcodeproj/project.xcworkspace -scheme LyraMusicHost -destination 'generic/platform=iOS Simulator' build`.
