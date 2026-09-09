- [2026-06-07 14:33] OfflineDownloadManager.parseTrackFromRelativePath: replaced parts.last! force unwrap with a guard returning nil for empty/missing last path component, hardening offline library restoration against malformed paths — verified PASS (build clean, minimal 1-file diff, commit 0725cfcb; no test suite exists to run). (branch auto-optimize/2026-06-07)
- [2026-06-07 18:29] DowntifyClient.search/triggerDownload: replaced two URLComponents(string:)! force unwraps with guard-let throwing DowntifyError, so a malformed user-entered Downtify base URL surfaces a clean error instead of crashing the app — verified PASS (swift build clean, exit 0; minimal 1-file 6-line diff, commit b20ec90). (auto-optimize/2026-06-07)
- [2026-06-08 10:04] NavidromeLyricsParser.parse(plain:): the plain-LRC parser always divided the fractional-seconds group by 100, so millisecond-precision timestamps like [01:23.456] were read as ~4.56s of extra offset (~10x too large), skewing synced-lyric timing; now scales the divisor by the captured digit count so hundredths and milliseconds both resolve correctly — verified PASS (swift build clean, exit 0; minimal 1-file 5-line diff, commit a55b6a5). (auto-optimize/2026-06-08)
- [2026-06-08 21:17] PlaybackEngine.toggleShuffle(): guarded turning shuffle on against an out-of-range currentIndex before remaining.remove(at:) — with an empty/invalid queue (shuffle is only disabled for live radio, not an empty queue) this was a reachable index-out-of-range crash — verified PASS (minimal 1-file 5-line diff, commit 30d6067). (auto-optimize/2026-06-08-feat)
- [2026-06-09] CachingResourceLoaderDelegate: validate HTTP responses before forwarding bytes to AVPlayer — non-2xx bodies (expired token / 404 / 5xx error pages) were fed to the audio decoder and finished as success, and servers that ignore the Range header (transcoded Subsonic streams) had their from-byte-0 bodies responded as if starting at requestedOffset, decoding misaligned data on any seek; now error statuses fail the loading request cleanly and unranged 200 replies drop the prefix below requestedOffset so player bytes and cache writes stay aligned — verified PASS (xcodebuild iOS Simulator BUILD SUCCEEDED; swift build (macOS host) fails pre-existing at branch HEAD on unrelated iOS-only API availability in 11 UI files, zero errors in the touched file; minimal 1-file diff, commit 3e6c642). (auto-optimize/2026-06-09-feat)
- [2026-06-10] Navigation/Playlists: app-wide cover zoom transitions (matchedTransitionSource + .navigationTransition(.zoom) via CoverZoomTransition.swift) and playlist open/close lag fixes (windowed tracklist render, rows fetch dedup + warm-ahead, debounced cache writes, isolated high-frequency publishers) — verified PASS (iOS-sim xcodebuild; on-sim drive of 1733-song playlist: zoom confirmed on video frames, peak CPU 67.8% vs 135% baseline; commit 03a497b). (auto-optimize/2026-06-09-feat)
- [2026-06-10] ServerPlaylistViews/CoverZoomTransition: swipe-back during an in-flight playlist load derailed the interactive dismissal and ate input (back button unaffected) — root-caused on-simulator with a real-gesture XCUITest (new VellumUITests target): tracklist hydration landing mid-transition mutated the dismissing view. Fix parks hydration while a UIKit-reported dismissal phase is active, drops it on commit, applies on cancel — verified A/B in one binary (old: HYDRATION-APPLY mid-settle; fixed: DEFERRED→clean pop→DROPPED; commit 956f317). (auto-optimize/2026-06-09-feat)
- [2026-06-10] CoverZoomTransition/ServerPlaylistViews: swipe-back the instant a playlist opened still stranded the detail nav chrome over the list — async mutations (row hydration, backdrop palette, MB previews) landing during the *push* transition got interrupted by the swipe. Three-state transition phase now parks async results during appearing AND dismissing; verified at 4x animation drag on-simulator (before: HYDRATION-APPLY mid-push; after: DEFERRED -> clean interrupted-push pop -> DROPPED; plain opens apply post-didAppear; commit 0e08661). (auto-optimize/2026-06-09-feat)
- [2026-06-10] Security audit (auto-optimize/2026-06-10): full-project vulnerability review of Vellum-Music. Fixed three clear low-risk items: (1) NavidromeClient.appendLibraryArtists — server-supplied `artistImageUrl` was accepted with any non-nil URL scheme (incl. `file://`); now restricted to http/https, matching the existing internet-radio `streamUrl` guard. (2) DowntifyClient.DowntifySong.init — server-supplied `cover_url` accepted any scheme; now restricted to http/https. (3) .gitignore — added `.env`/`.env.*` (was NOT ignored; root `.env` holds live third-party API keys + a Postgres password from an unrelated project, one `git add -A` from being committed). Higher-risk findings (Navidrome ShareLink credential leak, token-bearing URLs persisted in plaintext JSON, Jellyfin token not revoked on sign-out, scrobble data surviving sign-out, URLCache token persistence) were REPORTED, not changed — they need design decisions / touch user-facing behavior. Verified PASS (xcodebuild iOS Simulator BUILD SUCCEEDED, pinned single sim iPhone 17/iOS 26.5; 3-file diff). NOTE: rotate every key in the root `.env` — they are committed-adjacent and must be treated as compromised.
- [2026-06-26] Battery: root-caused the ongoing background drain to the audio lifecycle, not a stray timer. Three fixes (PlaybackEngine.swift, EqualizedAudioEnginePlayer.swift, AppModel.swift):
  (1) AVAudioSession was activated on first play and NEVER deactivated, so a paused app stayed audio-active and iOS never suspended it. Now released 5s after going idle (debounced; cancelled if playback resumes) with .notifyOthersOnDeactivation, and released immediately if the app backgrounds while already paused. Every play path already re-activates the session; added the one missing activate() on the EQ resume branch of togglePlayPause().
  (2) The EQ path left its AVAudioEngine RUNNING when paused (only playerNode was paused), so the real-time render thread + audio IO kept pulling silence through the timePitch/EQ graph forever. pause() now suspends the engine (engine.pause(), which retains the graph + scheduled buffers) and play() restarts it in place; the playhead is cached at pause time since lastRenderTime goes nil while suspended. Measured on an identical graph: paused with engine running = ~1.6% CPU continuous; paused with engine suspended = ~0.0% CPU. Verified play -> pause(2s) -> resume keeps the position exactly (3.00s held while paused, resumed to 4.97s) = no playback regression.
  (3) The periodic time observer ran at a fixed 0.35s (~2.9 main-thread wakeups/sec) even backgrounded. Now reinstalled at 2.0s while backgrounded (~0.5/sec, ~6x fewer wakeups) and restored to 0.35s on foreground; the lock screen extrapolates the playhead from the Now-Playing rate so the scrubber stays correct. Also finished the pre-existing WIP: library-membership poll 20s -> 60s and paused while backgrounded.
  Verified: xcodebuild iOS Simulator BUILD SUCCEEDED (iPhone 17 Pro / iOS 26.5); app installs + launches + stays running (no crash from the new session/observer init); all remote-command + resume paths re-activate the session before playback. Commits 84c7e54, d93d359, 244a22b on dev (not pushed).
- [2026-06-22] Home taste shelves + iTunes metadata migration: (1) **Removed** `MusicBrainzArtistClient`, `MusicBrainzTracklistClient`, `CoverArtArchiveArtwork`, Settings MusicBrainz toggle — New/Discover/Following/artist tracklists now use `ITunesArtistClient` / `ITunesTracklistClient` / `ITunesNewReleasesClient`. (2) **Home** — taste-ranked Top Picks (8) + New Releases (20) from server catalog excluding magic-playlist albums (`isEligibleForHomeTopPick`); taste genre shelves (4×9); editorial 250×325 Top Pick cards with color bleed; New Artists filtered to non-library adds. (3) **Now Playing** — adaptive artist text via backdrop palette in `ArtistNowPlayingMenuButton`; `OverPlayerSheetPresenter` for add-to-playlist over full-screen cover. (4) **ArtistNavigation** — tappable artist names on album/detail surfaces. (5) **GenreCanonicalizer** — Lo-Fi bucket (boom bap out of Hip-Hop). (6) **`isAlbumInLibrary`** — also true when any indexed track on the album is in `librarySongIds`. Verified PASS (xcodebuild iOS Simulator BUILD SUCCEEDED). (manual session) (1) `VellumNetworking` — core Navidrome/Jellyfin `URLSession.vellum` now sets `timeoutIntervalForRequest=25`/`Resource=60` so a dead self-hosted server fails fast instead of hanging the UI ~60s. (2) `OfflineStorageBrowserViews` — the "Clear cache?" alert decoded the whole library snapshot + walked disk on the main thread while building its message; now precomputed off-main (`localCacheUsageSummaryAsync`). (3) `ArtworkDynamicGradient` — added a palette cache keyed by the STABLE part of the artwork URL (path + cover-id/size/tag, dropping Subsonic salt / Jellyfin `api_key` which change every request and made the cache miss every time); detail views seed it synchronously (no backdrop pop-in on revisit) and fade in on first compute. (4) `AppModel`/`ServerPlaylistViews` — album detail hydrates tracks instantly from `albumTracksCache`, eliminating the open→fetch→park delay on revisit. (5) `AppModel.backfillMissingLibraryAlbumSummaries` — made idempotent (only reassign `libraryAlbums` when content changed, preserve order) and `refreshLibraryAlbums` now preserves personal-library albums outside the paged 500 fetch — together these killed the ~20s-poll Recently-Added flicker (catalog was oscillating 512↔500). (6) `findPlaylistByName` (both clients) — picks the richest same-named playlist deterministically so the magic-playlist sync stops flapping between duplicates. Debug `print`s gated behind `#if DEBUG` (`RootView`, `AppAlternateIconSync`). Widget artwork file-cache now prunes stale files. Verified PASS (xcodebuild iOS Simulator BUILD SUCCEEDED throughout; no test suite). (manual session)
- [2026-06-27] Merge: integrated origin/dev (4 commits: Downtify removal/Lidarr reframe, iTunes feed + library polish, Home taste shelves + iTunes metadata migration, drop unplayable Opus/Ogg) into local dev (13 local commits incl. the battery work). 3 files conflicted, all resolved by combining both sides (no work lost):
  - OPTIMIZATIONS.md: both sides appended a changelog entry at the same spot -> kept BOTH.
  - PlaybackEngine.swift (5 hunks): took origin/dev playback rework (play-intent system markPlayIntent/clearPlayIntent, ensurePlaybackStarted resilience call, and the refactor that runs pause bookkeeping unconditionally) AND re-threaded the battery calls back in -- kept BOTH activateAudioSession() + markPlayIntent() on EQ resume, and re-added scheduleAudioSessionDeactivation() after the moved refreshNowPlaying() in both pausePlayback branches; took the improved interruption-capture (isPlaying OR equalizedPlayer.isPlaying).
  - RootView.swift: both sides cleaned up the leftover [NP-DIAG] scenePhase debug print; took OURS (removed it entirely) rather than the #if DEBUG gating, since the @Environment(.scenePhase) it depended on was also removed.
  Verified: zero stray conflict markers across all 3 files; xcodebuild iOS Simulator (iPhone 17 Pro / iOS 26.5) BUILD SUCCEEDED on the merged tree. Merge commit 0772974 on dev (local only, not pushed).
- [2026-06-27] Bug-audit fixes — the 1 CRITICAL + 5 HIGH findings from LYRA_BUG_AUDIT.md (medium/low parked). All build clean (xcodebuild iOS Simulator, iPhone 17 Pro / iOS 26.5, BUILD SUCCEEDED). 6 logical commits, local-only on dev (not pushed):
  - C1 (CRITICAL, e96982e) Kill-mode playlist delete removed the wrong song: the kill-list view's Navidrome positional indices went stale after each prior single removal (server positions shift down), so the 2nd+ swipe-Remove deleted a different track. `commitKillModeRemovals` now re-resolves each target against a fresh `fetchPlaylistRows` by stable track id right before removing (consuming matched positions for duplicate ids). Jellyfin (stable entry ids) + the main-playlist swipe-delete path untouched.
  - H1 (990c55c) External pause left isPlaying stuck true: `autoplayVerifyTask` never nil'd itself, so the timeControlStatus KVO guard swallowed every real external pause (headphone unplug, Control Center). The verify task now clears its own handle on any exit via a token guard, time-boxing the guard to the startup window.
  - H2 (1ca82d6) Widget play/pause glyph went stale: nothing subscribed to `player.$isPlaying`, so pause/resume from mini-player / lock screen / route change / interruption never rewrote widget data. Added a deduped `$isPlaying` sink → `writeWidgetData()`.
  - H3 (49ed658) EQ jumped to track start on route/config change: `currentPlaybackTime()` fell back to the stale `playbackStartOffset` when the system stopped the engine for a PLAYING track (pausedPlaybackTime is only set on user pause). Now caches the last live position each tick and returns it as the fallback. Verified: after a system engine stop at 3s, currentPlaybackTime=3.00 (was 0). (Touches the recent battery-fix cache — no regression: play→pause→resume continuity still passes.)
  - H4 (d8ba5ff) "Trust server certificate" did nothing: `shouldAccept` still required SecTrustEvaluateWithError to pass, false for the self-signed/expired/hostname-mismatch certs the per-host opt-in targets. Now accepts the presented chain for an explicitly-trusted host; non-trusted hosts unchanged (normal system validation).
  - H5 (148253c) Offline manifest data-loss race: the enrich passes loaded the whole manifest, awaited (duration probe / artwork fetch), then saved the stale payload — clobbering any track a concurrent download wrote, dropping it from the offline library and orphaning its file. Restructured to two phases: gather async results into a side map, then re-load + apply with no await between load and save (atomic on the @MainActor manager).
  Note: H3/H1/H2/C1 overlap the recent battery-fix + origin/dev merge work; verified no regression to playback (build + EQ continuity/position harness). Medium/low audit items left for later triage.
- [2026-06-29] Album detail shelves + artist page hero + Home shelf polish: (1) **Album detail** — `AlbumDetailRelatedSectionsView` footer carousels (Other Versions / More By Artist / You Might Also Like); `AlbumDetailArtistCatalogCache` + full `albums(forLibraryArtistId:)` fetch; version matching via `AlbumSummary.albumVersionBaseKey`; fixed forward-navigation pop on related-album tap. (2) **Artist page** — Apple Music–style stretchy hero with `.artistPage` dark-charcoal backdrop analysis, soft single-layer blur melt at play row, adaptive content chrome; `ArtistProfileClient` (MusicBrainz About facts) + `ListenBrainzClient` (similar artists). (3) **Home** — `stabilizeHomeDiscoveryShelf` stops Top Picks reshuffle after genre catalog loads; cold-launch catalog seed; pull-to-refresh force re-rank. (4) **Chrome** — shared `artworkSubtleBorderOverlay()` on cover art + Top Picks cards. Verified PASS (xcodebuild iOS Simulator BUILD SUCCEEDED). (manual session)
- [2026-07-05] NowPlayingView/LyricsFocusScrollView: Apple-Music-parity lyrics rebuild — (1) extrapolated playback clock (anchor on livePlaybackTime, projected at playbackRate between observer ticks) + a boundary-sleep scheduler task so line flips land on the beat instead of quantizing to the ~0.35s periodic tick; (2) uniform 28pt bold synced lines with leading-anchored scaleEffect/opacity/blur emphasis, replacing the per-distance font jumps (.title2↔.largeTitle) that re-wrapped text and jittered the whole column on every flip; (3) spring auto-scroll (response 0.55 / damping 0.85) with onScrollPhaseChange browse mode — a user drag suspends auto-centering and lifts the distance blur, resuming 3s after the scroll settles; (4) instrumental-gap dots rebuilt as SilenceBreathingDots on a TimelineView .animation schedule (paused while playback is paused): smooth left→right fill across the gap, gentle out-of-phase breathing, swell-and-fade handoff in the last ~12% of the gap; inactive gaps collapse to zero height so dots only exist while their gap is live (Apple behavior); (5) tap-to-seek snaps the local clock immediately (no ~0.35s stale highlight) and accessibilityReduceMotion disables scale/breathing/springs throughout. Unsynced plain lyrics (static scrollable text) and the no-lyrics state kept by design. Verified: xcodebuild iOS Simulator BUILD SUCCEEDED on the edited tree (2026-07-05); device build+install handed to user as in-session one-shot (Mac dozes on battery, headless SSH builds kept dying). NOT committed; pre-edit original preserved at Sources/LyraMusicKit/NowPlayingView.swift.bak-lyrics. (manual session)
- [2026-08-06] Equalizer: fixed the ~1-minute track loads + intermittent crashes with EQ enabled. Root cause of the delay: `PlaybackEngine.tryQuickEqualizerCache` raced the full-file stream download against a 2.5 s sleep inside `withTaskGroup` — but the download child awaited a *detached* task's `.value` (not cancellation-responsive), and a task group awaits ALL children at scope exit, so `cancelAll()` was a no-op and every EQ-enabled track start blocked inside `startCurrentItem` until the whole audio file finished downloading (proved with a standalone repro script: a "0.5 s-bounded" group blocked 10.4 s). Fix: kick the shared background prefetch and poll `peekCachedFileURL` for the bounded window — track start is now instant on the AVPlayer path with the EQ handoff arriving mid-track as designed. Crash fixes: (1) `EqualizedAudioEnginePlayer.play(rate:)` swallowed `engine.start()` failures with `try?` then called `playerNode.play()` anyway → NSException "required condition is false: _engine->IsRunning()" (route change / session interruption windows); now reports `onPlaybackFailed` instead of crashing. (2) Stopped tearing down and re-initializing the AVAudioEngine per song: nodes attach once at init, graph reconnects only when the audio format actually changes, `load()` uses a light reset that keeps the engine alive, and `PlaybackEngine` pools one `idleEqualizedSession` for reuse across tracks instead of building a fresh engine every track. Also: toggling EQ on/off while the engine session is live now just adjusts/bypasses the EQ node in real time (no track reload), and `applyLiveEqualizerGains` bypasses when EQ is disabled. Verified: xcodebuild iOS Simulator build. Committed 2026-08-16. (manual session, dev branch)
- [2026-08-18] Main-thread cost audit (Home / Artist / New tab scroll + mini-player lag), cache-clear fix, and new defaults. Root cause behind most of it: every view holds `@EnvironmentObject var app: AppModel` (~100 `@Published` properties), so any publish re-runs every visible `body` — and several bodies were scanning the full catalog or re-blurring artwork per pass. (1) **O(1) lookups** — `AppModel.catalogAlbum(id:)` / `libraryPlaylist(id:)` / `indexedTrack(id:)` backed by dictionaries (built with `uniquingKeysWith:` — server ids are not guaranteed unique and `uniqueKeysWithValues:` could trap); replaced full-catalog `first(where:)` / `Dictionary(...)` builds in `LibraryPinStore.resolvedItems`, `LibraryView.recentItems`, `NowPlayingView`, `LibrarySongsView`. (2) **`MembershipLookups`** — memoized `albumEntryIds` / `albumIdsWithLibrarySongs` / `ownedReleaseKeys` so `isAlbumInLibrary` and `isEligibleForHomeTopPick` (called per album from every Home shelf) are O(1); invalidated from the `didSet` of each input. (3) **Derived lists into `@State`** — `AlbumsGridView`, `DiscoverySearchView.hybridRows`, album `mergedRows` (also windowed via `rowRenderLimit`), Home `newArtistsSection`. (4) **Sorting** — playlist date-added comparators were calling a linear scan per comparison (superlinear); now a precomputed date map. (5) **Rendering** — `LazyVStack`/`LazyHStack` for New tab column, artist discography shelves and Top Songs; `MusicShimmerSurface` `.mask` → `.clipShape`; the artist hero's live `blur(radius: 30)` (which re-ran every frame of *unrelated* animations — this was the mini-player open/close lag) pre-rasterized via `ArtworkGaussianBlur`, Top Pick bleed flattened with `.drawingGroup()`. (6) **Memoization** — `catalogReleaseIdentityKey` (regex/normalization) behind a locked LRU, `AppAccentPreset.current`, static `RelativeDateTimeFormatter`, `relevanceScore` takes a pre-normalized query. (7) **Shimmer regression fixed** — `AlbumArtworkView` resolves `DecodedArtworkCache` synchronously so cached art paints with no placeholder, and only genuine network loads shimmer and fade in (a blanket `Transaction(animation: nil)` had killed the loading animation entirely). (8) **Cache clear actually clears** — `ArtworkURLCache.clearAll()` now also drops `URLCache.shared`; `LibrarySnapshotStore`/`PlaylistRowsCacheStore` writes are guarded by a `writeGeneration` so a debounced save can't rewrite a cleared file; palette + Top Pick bleed caches cleared; `AppModel.localCacheRevision` republishes so the size/count rows refresh. (9) **Bugbot findings** — EQ `play(rate:)` returns `Bool` so a failed `engine.start()` can't leave `isPlaying` true; `ArtistViewModel` applies an empty discography fetch instead of keeping stale rows and loads plugin releases concurrently with the server catalog; New tab index build moved off the main actor; DroppedNeedle artist matching no longer accepts loose substring hits. (10) **Defaults** — stream caching now **off** (`register(defaults:)` in `AppModel.init`) and the app opens to **Library** (`loadLaunchTab`). Supersedes the 2026-08-06 `tryQuickEqualizerCache` poll: that function is gone, because `startCurrentItem` already prefers an existing cache hit synchronously when building stream candidates, so an already-cached track gets the EQ path from the first sample and an uncached one starts on AVPlayer with zero added latency and hands off mid-track. Guardrails added so the body-cost regressions don't come back: `Rules/swiftui-body-cost.md` + `Rules/swiftui-render-cost.md`, referenced from `CLAUDE.md`. Verified PASS (xcodebuild iOS Simulator BUILD SUCCEEDED; no test suite). (manual session, dev branch)
- [2026-08-19] Playlist detail search bar on iOS 26.6 + zoom pull-down dismiss — **fixed, verified on Ethan's iPhone 17 Pro Max (iOS 26.6), committed.** Two reported bugs: (a) opening a playlist (normally or via Now Playing → Go to Playlist) showed the track search bar already at the top, jammed under the back chevron / ⋯ / Kill Mode buttons and untappable; (b) pulling down at the top of any album/playlist popped the whole screen. **What it actually was** (measured on device with temporary navigation-item diagnostics, after several wrong guesses): the SwiftUI `.searchable(placement: .automatic)` resolves to UIKit's *stacked* nav-bar search row, and **iOS 26.6 lays that row out expanded when a pushed screen arrives at the top of its content** (26.3–26.5 simulators arrive collapsed — the bug never reproduced there, on any runtime or device size). Because this screen runs a transparent, title-less bar, the expanded row sits directly under the floating glass buttons. Not placement (forcing `.stacked` changed nothing), not the parent list's searchable (probe on device), not the jump-to-track scroll (normal opens did it too), not the TabView search role / mini-player accessory (isolated harness). (b) was UIKit's own interactive dismiss for `.navigationTransition(.zoom)` — `_UIContentSwipeDismissGestureRecognizer` + `_UITransformGestureRecognizer` on the zoomed view — not collaborator code. **Fix** (all in the existing UIKit child controller `CoverZoomDismissalObserver.Helper`, `CoverZoomTransition.swift`; the SwiftUI `.searchable` line is untouched): (1) the two zoom dismiss recognizers are disabled by class name on each appearance; edge swipe-back untouched. (2) **Hidden = no row.** While the bar is hidden the search controller is *parked* (pulled off `navigationItem.searchController`), so no row exists: nothing to show on arrival, nothing to flash under the buttons mid-push, nothing for a bounce to snap open, no reserved space. A KVO on `searchController` re-parks it whenever SwiftUI re-attaches (it does so after `viewWillAppear` on deep-link pushes, and on later updates). (3) **Reveal = pull-to-refresh semantics.** A pan that *began at rest at the top* (start offset reconstructed from the pan translation, since `.began` fires ~10pt late) and overscrolls past **16pt** attaches the controller mid-pull, so UIKit lays the row out under the finger. From there the row is native (`hidesSearchBarWhenScrolling`): it shrinks 1:1 as the user scrolls down; once fully collapsed (row height 0) the controller is parked again, so scrolling back up does not re-add it — only the next pull does. Arriving at the top by drag or fling never reveals. The real list stays the bar's content scroll view, so pull-to-refresh keeps working. Native search mode (pills swap, Cancel, keyboard) is untouched. **Dead ends, so nobody repeats them:** offset clamping, detaching the content scroll view, suspending the controller mid-gesture, and a hidden proxy scroll view all produced visible chop (anything that touches the bar or scroll during a live gesture shows) — and the proxy also killed the refresh spinner, which shares that nav-bar strip on iOS 26. An always-present row with alpha-only reveal pushed content down and left an empty slot that bounces snapped open. A hand-built in-list field (plain `TextField`, then a hosted `UISearchBar`) lost the native search mode and was reverted. `musicNativeSearchableTop` remains unused dead code. Verified: device BUILD SUCCEEDED, installed in place as `com.randll.vellum`, all three behaviours confirmed by Ethan on hardware. (manual session, dev branch)
- [2026-08-20] Kill Mode — two fixes: the scissors-button lockout, and Remove All being slow, silent and killable by backgrounding. **BUILD STATUS: both passes green.** Verified in two deliberately separate `xcodebuild` passes against the iOS Simulator, so a compile error in the speed work could not hold the lockout fix hostage: **pass A = fix (1) alone — BUILD SUCCEEDED**; **pass B = fixes (1)+(2) together — BUILD SUCCEEDED**. Simulator compile only — NOT installed to the device and NOT validated on hardware; headless SSH codesigning fails on this Mac with `errSecInternalComponent`, so a device install has to be run by hand.
  - **(1) The scissors button was a hard lockout, and worse than reported.** It was not disabled on an empty removal list — it was absent entirely: the whole `NavigationLink` sat inside `if count > 0` in `ServerPlaylistViews.killModeToolbarButton`. That was fine when Kill Mode only collected songs to delete, but Kill Mode now also skips songs already listened through, and the screen behind that button holds the only "Clear Listen History" control in the app. Zero pending removals therefore made the listened set impossible to reset, with no other route in. The button is now shown whenever Kill Mode is ON for the playlist (`!isAlbumStyleDetail, app.isKillModeEnabled(playlistId:)`); it turns red and carries the count badge only when something is actually queued, and otherwise matches the neutral chrome of the 3-dot menu beside it. **There was a second lockout hidden behind the first**: `PlaylistKillListView` had `.onChange(of: visibleRows.isEmpty) { if isEmpty { dismiss() } }`, so opening it with nothing queued would have pushed the screen and instantly popped it — fixing only the button would NOT have fixed the bug. Self-dismiss removed, an empty state added for the removal section, and the screen retitled "Songs to Remove" → "Kill Mode" because it manages listen history as well as pending deletions. `Clear Listen History` itself needed no change: it was already gated on `passed == 0`, not on the removal count. It was unreachable, not broken.
  - **(2) Remove All was serial, foreground-bound and gave no feedback.** Backend confirmed as **Navidrome** from the server log (`player="VellumMusicKit [VellumMusicHost]" user=ethan`), which is the affected path — Jellyfin already batched into a single `DELETE`. On Navidrome, removal ran one HTTP request per song (`NavidromeClient.removeTracksFromPlaylist` looped over indexes, and `AppModel.removePlaylistRows` looped again on top), so a 148-song purge was 148 sequential round trips with no progress indication and no background assertion — which is why backgrounding the app to send a text killed it partway through. Fix: Subsonic `updatePlaylist` accepts a **repeated** `songIndexToRemove` parameter and resolves every index in one request against the playlist as it was *before* that request, so a whole batch lands correctly in one round trip. `NavidromeClient` already had the `repeatedQuery:` plumbing; it was simply unused on this path.
  - **Measured against a live server (this part IS verified, unlike the build):** on the public `demo.navidrome.org` (Navidrome 0.63.2), removing 60 songs took **60 requests / 9.28 s** serially versus **1 request / 0.11 s** batched — roughly **87x**. Extrapolated to the reported 148-song case: ~22.9 s → ~0.11 s. Testing used throwaway playlists on the public demo instance, deliberately **not** Ethan's own server, which had a live playback session at the time; the test playlists were deleted afterwards.
  - **Trap worth remembering: chunking ascending is silently destructive.** Removing 25 indexes at a time in ascending order left 25 of 60 songs behind and deleted the wrong ones, because a later chunk's positional indexes go stale the moment an earlier chunk commits. Chunks are therefore taken **highest-index-first**, verified on the hard case (30 interleaved even positions out of 60: correct set, order preserved, duplicate track ids resolved to distinct positions, 0.27 s over 2 requests). Chunk size 50, so a 148-song purge is 3 requests and progress stays genuinely determinate. Bounded concurrency was considered and **rejected**: Navidrome removal is positional, so concurrent requests would race the index space and delete the wrong songs. Batching sidesteps that and is far faster than concurrency would have been anyway.
  - **New `AppModel.runKillModeRemoval`** orchestrates a bulk run: determinate `killModeRemovalProgress` ("Removing 12 of 148" with a real bar, not a spinner — phases preparing / removing / refreshing so working, stalled and done are distinguishable); a `BulkOperationBackgroundAssertion` (`beginBackgroundTask`) around the whole run so tabbing out no longer suspends it mid-flight; per-chunk persistence of pending marks so partial progress survives an interruption; one cache invalidation and one `refreshLibraryPlaylists()` per run instead of one per song; and a `killModeRemovalSummary` ending the run with "removed N, M already gone, K still listed" instead of the sheet just closing. Resume is structural rather than bolted on — anything that failed keeps its pending mark, so it stays listed and "Continue" re-walks only the failures. Single-song swipes use the same code path but skip the overlay.
  - **Two bugs caught in review before any compiler saw them:** (a) the completion alert would have been the third presentation modifier on one view, alongside the row-delete `.alert` and the Remove All `.confirmationDialog` — SwiftUI handles that unreliably and one silently never presents, so it now hangs off its own `.background { Color.clear.alert(…) }`; (b) progress would never have reached 100% on a playlist containing the same track twice, because `completed` was derived from a `Set` of track ids while `total` was a row count — it now counts committed rows.
  - **Left deliberately untouched:** `AppModel.removePlaylistRows` still loops one request per song. It is now redundant (the client batches underneath it) but it carries in-progress partial-failure handling from another session, so Kill Mode's bulk path goes through the new `performChunkedRemoval` rather than rewriting someone else's uncommitted work.
  - Files: `ServerPlaylistViews.swift`, `PlaylistKillListView.swift` (fix 1); `NavidromeClient.swift`, `AppModel.swift`, `PlaylistKillListView.swift` (fix 2). NOT committed, NOT pushed, NOT installed to device. (manual session, dev branch)
- [2026-08-22] New tab first-load hang: root-caused to per-item index rebuilds, not rendering. `AppModel.reconcileNewTabChartServerPresence()` — which only runs from `MusicNewTabView`'s `.task`, and only does real work on the first visit (later visits early-return once the chart rows resolve) — walks up to 20 chart rows × their title variants, and folds each `searchCatalog` hit into the catalog one row at a time via `retainTrackForLibraryPin` / `ensureAlbumInCatalog`. Each single append hit the `didSet` on `discoveryLibraryTracks` / `libraryAlbums` and rebuilt **all four** derived indices (`discoveryTrackById`, `libraryTrackTitleIndex`, `LibraryChartTrackIndex`, `libraryAlbumsById` + `LibraryAlbumReleaseIndex`) from scratch over the whole library — O(tracks + albums) of unicode folding + regex, on the main actor, per inserted row. Measured on the real algorithms (standalone swiftc -O bench, Apple silicon; a phone is slower): one full rebuild = 144 ms @ 2k tracks, 708 ms @ 10k, 2.17 s @ 30k; a typical reconcile does ~40 inserts → 5.8 s / 28 s / 87 s of main-thread work. Fix: `LibraryChartTrackIndex.insert(_:)`, `LibraryAlbumReleaseIndex.insert(_:)` and `LibraryTrackMatcher.insert(_:into:)` fold one row in place (both `init`s now just loop the same `insert`, so incremental and full-rebuild results are identical by construction), and `retainTrackForLibraryPin` / `ensureAlbumInCatalog` suppress the `didSet` rebuild and maintain the indices by hand — including the track-derived album merge that `rebuildLibraryAlbumIndex` does. Same 40 inserts now cost **3.5 ms flat, independent of library size**. Also fixes the same stall on add-album-to-library / acquisition-completion paths, which looped `retainTrackForLibraryPin` over every track of an album. Not addressed: the reconcile still issues its ~20 `searchCatalog` round-trips serially (network-bound, doesn't block the main thread). Files: `AppModel.swift`, `LibraryTrackMatcher.swift`, `AlbumSummary+NewTabMatch.swift`. Verified PASS (xcodebuild iOS Simulator BUILD SUCCEEDED); not verified against a live server. Committed on `cover-zoom-transition`. (manual session, cover-zoom-transition branch)

## 2026-08-27 — audit pass 1 (T051)

Implementing the 2026-08-27 20-agent optimization audit. Constraint on every entry below: **zero visual change**. Bug 3 (D5.1, the player reopening on the pane you left) is deliberately NOT fixed — Ethan was asked and said keep it.

- [2026-08-27] **Nav-bar fade stopped walking the view tree with string reflection on every frame** (audit B1.1 / B4.3). The bar-button fade runs off a `CADisplayLink`, and every single tick it re-derived which views to hold at alpha 0 — including a recursive walk of the whole navigation bar calling `String(describing: type(of:))` on every node to find the back chevron. During an interactive swipe the hold is 4 seconds, so a lingering edge-swipe paid that walk for hundreds of frames. The chevron is owned by the bar and does not move mid-transition, so it is now resolved once per fade and cached. The *other* half of the lookup — the incoming item's own bar-button views — is still re-read every tick on purpose: the comment above it documents that UIKit installs those partway through the transition, and hoisting them too would leave a late-arriving button un-faded, which is a visible change. Cache is cleared when the fade starts and when it is released, and it deliberately re-walks while the result is still empty so a chevron that has not been installed yet is not skipped forever. File: `CoverZoomCustomTransition.swift`.
- [2026-08-27] **Queue reorder tint stopped re-running on every scroll pixel** (audit D4.1 / D1.1 — the same anti-pattern as the one above, in a different file). The queue KVO-observes the table's `contentOffset`, which fires on essentially every display-link tick while the queue scrolls or pages, and each fire re-walked every visible cell's subviews doing `String(describing: type(of:))` on each one to reapply a tint that had not changed. This scales with visible-cell count, which is exactly the "long queue makes the swipe stutter" symptom. The walk now runs only when the set of visible cells actually changes, compared by object identity — which still covers every case that matters: a cell scrolling in, a cell scrolling out, and a *recycled* cell arriving with an untinted reorder control. Scrolling within an unchanged set of cells now does nothing. The cached set is also cleared whenever the tint colour itself is reassigned, so a colour change is never mistaken for "already correct". File: `NowPlayingView.swift`.
- [2026-08-27] **The dismissed, off-screen player is no longer rebuilt several times a second** (audit C4.1). `updateUIViewController` runs on every shell render and `PlaybackEngine` publishes several times a second, so `cover.rootView = makeContent()` was re-diffing the whole ~2,800-line player tree that often the entire time the player was closed. An earlier fix had already stopped this happening while the player is *on* screen (it was eating taps); this stops the off-screen half too. It could not simply be deleted as the audit suggested: the comment's claim that "reassigning is not needed anyway" is true for the four `environmentObject`s, which the player observes for itself, but not for `.tint(MusicDesign.accent)` — a `UIHostingController` only picks up a new value-typed input when `rootView` is reassigned, so deleting the line outright would have stranded the player on a stale accent colour after an appearance change. The presenter now takes a `contentRevision` token carrying the value-typed inputs (today: the accent) and rebuilds only when it actually changes. Documented at both ends that anything value-typed added to that closure has to be added to the token too. Files: `NowPlayingCoverZoomTransition.swift`, `RootView.swift`.
- [2026-08-27] **Queue and History rows stopped decoding hero-sized artwork** (audit D4.2 / D2.3). Those rows render at 44pt and 56pt but were decoding — and caching — at 768px, which is `AlbumArtworkView`'s hero default and about 16x the pixels they can display. This is the case `Rules/swiftui-render-cost.md` calls out by name, and the number to use was already established elsewhere in the app: `LibrarySongsView.rowArtworkDecodePixels` is 192, which covers a 56pt row on a 3x screen with room to spare. The important detail is that the fix could **not** be a change to the shared helper's default: `artworkView(for:cornerRadius:)` in `NowPlayingView` feeds six call sites, and two of them are the full-size hero and the morphing shared header. Instead the decode size is now an opt-in parameter, applied to exactly two static row call sites — the queue/history row (44pt, also what History reuses) and the queue's now-playing module row (56pt, which the comment above it confirms never travels, because the shared header is what morphs through that slot). The four call sites that carry `matchedGeometryEffect` into the hero are deliberately left at 768, since those views get resized to full artwork dimensions mid-morph and a row-sized decode would be visibly soft while they travel. Same pixels on screen after `scaledToFill`; only the decode and cache target shrink. File: `NowPlayingView.swift`.
- [2026-08-27] **All four artwork caches now have eviction limits** (audit A3.3 / C4.5). `DecodedArtworkCache`, `HomeTopPickBleedCache`, `ArtworkURLCache` and the backdrop `paletteCache` were all uncapped `NSCache`s. An uncapped `NSCache` does not evict gradually — it grows until the system posts a memory-pressure warning and then dumps everything in one purge, which is as likely to land in the middle of a transition as anywhere else. Limits: 64MB decoded images (~27 covers at 768px), 16MB bleeds, 32MB raw compressed bytes, and 512 entries for palettes (bounded by count instead of cost, because a palette is a few colours and the memory is irrelevant — the limit is only there to stop the all-at-once purge). The two image caches already computed a per-entry cost that was simply inert with no limit set. `ArtworkURLCache` did not pass a cost at all, so both of its `setObject` calls now pass the byte count — without that the new limit would have been unenforceable. Files: `ArtworkImageDecoder.swift`, `ArtworkURLCache.swift`, `ArtworkDynamicGradient.swift`.
- [2026-08-27] **Backdrop colour analysis stopped decoding the cover at full resolution** (audit B2.3). The palette analyser called `UIImage(data:)?.cgImage`, which decodes the whole image, and then handed the result straight to `downsampleArtworkPixels`, which caps the longest side at 120px. So a multi-megapixel bitmap was being produced to read a 120px sample from it — and because both the mini-player pill and the hero request a palette, every track change did it twice over the same bytes. It now goes through `ArtworkImageDecoder`'s ImageIO thumbnail path at 160px, the same decoder the rest of the artwork pipeline uses, which also removed the UIKit/AppKit branch since ImageIO is cross-platform. Worth stating plainly: the sampled pixels are now the result of two resamples (source → 160 → 120) rather than one (source → 120), so the averaged colours can differ in the last fraction of a percent. That is below anything visible in a broad backdrop wash, and this is analysis input rather than rendered pixels, but it is not literally bit-identical and should not be described as such. File: `ArtworkDynamicGradient.swift`.
- [2026-08-27] **Three synchronous audio-daemon round trips per player open, down to one** (audit C2.1 / C2.2 / C2.3). Opening the player produced two full `AVAudioSession` activations and a third `setActive(true)` from the volume bar, each a synchronous IPC into `mediaserverd`, all landing inside the transition's setup window — and one of them from inside the mini player's own tap action, where it delays the runloop returning and therefore delays the moment `present()` can be called at all. (a) `activateAudioSession()` had no already-active guard, so both engine calls paid full `setCategory` + `setActive`; it now short-circuits when the session is already up. That guard is only safe because every path that can take the session away clears the flag — our own deactivation, and a system interruption (`.began`), where iOS hands the session to a call or Siri. A *failed* activation deliberately does not set the flag, so the next caller retries instead of assuming success, which is stricter than the old swallowed `try?`. The pending deferred-deactivation task is still cancelled unconditionally, even when the guard skips the rest, or it would tear down a session we had just asked for. (b) The volume block's own `setActive(true)` in `onAppear` is deleted: the engine activates the session on the same open, and unlike the lyrics and queue panes this block is not behind a mode flag, so it ran on every open whether or not the volume bar was touched. Its `outputVolume` read is kept deliberately — the audit suggested dropping that too on the grounds that `HiddenSystemVolumeBridge` KVO-observes volume, which is true for *changes*, but the player's hosting controller is reused rather than rebuilt, so seeding the `@State` on appear is what puts the slider in the right place on the first frame instead of a frame later. It is a property read, not a session round trip. (c) The doubled `MPNowPlayingInfoCenter` read-then-write does **not** collapse on its own once (a) is fixed, contrary to the audit's note — both call sites still reached `refreshNowPlaying()`. One player open genuinely produces two UI milestones (mini-player tap, then player `onAppear`), so the second one's redundant lock-screen re-stamp is now skipped within a 300ms window. The corrective branches — unmute, restore volume, resume a stalled player — still run every time; only the re-stamp is suppressed, and the periodic time observer re-stamps on its own cadence anyway. Files: `PlaybackEngine.swift`, `NowPlayingView.swift`.
- [2026-08-27] **Tapping a queue row no longer JSON-encodes the play history on the main thread** (audit D2.1). `recordRecentTrackPlay` is wired to `PlaybackEngine.onTrackStarted`, which fires on every track change — including the `jumpToQueueItem` that a queue row's Button calls. So tapping a row put a synchronous encode of up to 100 `Track` structs into the same runloop pass as the page-snap animation that tap had just started. The encode now happens off the main actor. The `UserDefaults` write stays on the main actor and is generation-checked, so if two saves race, an older encode finishing late cannot overwrite a newer history. File: `AppModel.swift`.
- [2026-08-27] **Library search is debounced in all three list screens** (audit A4.3 / A4.4 / A4.5). Songs and Artists re-filtered and re-sorted the entire library synchronously on every keystroke — the Songs one carries a comment admitting it "dominates main-thread time per keystroke" at 50k tracks, and the Artists one also rebuilt its alphabet sections over up to ~12k artists each time. Albums was the odd one: the 150ms debounce helper already existed in that file but was wired only to `downloadedTrackIds`, while typing called the synchronous path. All three now debounce search typing on the same 150ms, using the existing `scheduleRecomputeAlbumDisplay` shape. Deliberately **not** debounced: sort changes, filter changes, and load completions. Those are discrete one-shot events, and deferring them would just make a tap feel laggy for no benefit. Files: `LibraryView.swift`, `LibrarySongsView.swift`, `LibraryArtistsGenresViews.swift`.
- [2026-08-27] **Two of the three AppModel whole-tree invalidations fixed; the third was a bad call and is left alone** (audit A1.1 / A1.2 / A1.3). (a) A1.1: the `offline.$downloadedTrackIds` forward is now throttled to 250ms. Its `.removeDuplicates()` never suppressed anything, because each finished track inserts into the Set and so every value is strictly larger than the last — meaning saving an album fired one full-tree invalidation *per track*, across the ~40 view files holding `@EnvironmentObject var app`, which includes the views alive during a cover zoom. Throttled with `latest: true`, so the final state always arrives and a checkmark can be at most 250ms late rather than dropped. (b) A1.3: `hasInternetPath` was assigned unconditionally in the `NWPathMonitor` handler, which also fires on interface reordering and `isExpensive` flips; `@Published` has no equality check, so those became full-tree invalidations on events where nothing changed. Now guarded, matching every comparable path in the file. (c) **A1.2 is not implemented, and should not be.** The audit says the `player.$showsMiniPlayerChrome` sink "buys nothing" because `RootView` reads `app.player.showsMiniPlayerChrome` directly. That is wrong: `RootView` observes only `AppModel`, `AppModel` does not forward `PlaybackEngine.objectWillChange` wholesale, and reading through `app.player` creates no subscription — so that sink is the *only* thing that re-renders the mini-player chrome when playback starts or stops. Deleting it would leave the mini player failing to appear until some unrelated publish happened. The alternative, observing `PlaybackEngine` from the accessory, is explicitly ruled out by the comment at `RootView.swift:301`: it "re-renders the zoom source mid-transition and breaks the `tabViewBottomAccessory` ↔ `fullScreenCover` morph on iOS 26". The sink is the deliberate narrow bridge that forwards one flag instead of the whole engine. Checked while there: `prefersWifiLikePath`, assigned unconditionally one line below A1.3, is a plain `private var` and publishes nothing, so it needed no guard. File: `AppModel.swift`.
- [2026-08-27] **The pin check stopped re-parsing JSON inside the `Equatable` conformance meant to prevent re-renders** (audit A4.1). `LibraryPinStore.contains` decoded the pinned-items JSON from scratch every call, and `LibrarySongRow`'s `==` calls it for both sides, with the row's body calling it a third time — so two to three full JSON parses per row per diff pass, everywhere pin-aware rows appear, inside the exact method whose job is to avoid work. `decode` now memoizes on the raw string in a single slot, the same shape as `OfflineDownloadManager.manifestCache`, which is the existing precedent in this codebase; the pin list only changes when the user pins something, so one parse covers an entire diff pass. Parse failures are cached too, so malformed storage is not retried on every comparison. File: `LibraryPinStore.swift`.
- [2026-08-27] **The artwork cache's disk read moved off the main actor** (audit A3.2 / B2.3's second half). `ArtworkURLCache.data(for:)` is `async` but not actor-isolated, and had no suspension point before `loadFromDisk` — so Swift ran its blocking `Data(contentsOf:)` synchronously on the caller's executor, which for the hero image and the backdrop tint is the main actor at the moment a detail page appears. It is hit whenever the memory cache was evicted but the file is still on disk, i.e. the common steady state. The network path a few lines below was already offloaded correctly, so this was an inconsistency within one function rather than a deliberate tradeoff. The in-memory lookup above it is untouched, so warm hits still return without suspending. File: `ArtworkURLCache.swift`.
- [2026-08-27] **The download spinner runs at 30Hz and stops in the background; the Home Top Pick artwork is analysed once instead of twice** (audit A5.1 / A5.2). The indeterminate download ring was `TimelineView(.animation(minimumInterval: 1/60, paused: false))` — hard-coded to 60Hz and hard-coded never to pause, so every queued download drove its own row's timeline at 60Hz indefinitely, including while the app was backgrounded, and several queued downloads meant several independent 60Hz timelines. It now runs at 30Hz and pauses when the scene is not active, matching `SilenceBreathingDots` in `NowPlayingView`, which is the existing correct example of this pattern. `reduceMotion` is deliberately **not** wired in, unlike the audit's suggestion: this is a progress spinner, and freezing it would read as a stalled download rather than as reduced motion. Separately, the Home Top Pick card had both an `.onAppear` prefetch and a `.task` doing the same backdrop resolution; on a cold cache both missed and both ran the full path, and since `ArtworkURLCache.data(for:)` has no in-flight de-duplication that meant two network requests, two decodes and two pixel analyses for one image. The `.onAppear` is removed — the `.task` already checks the cache first, which is the warm case the prefetch was there to win. Files: `AppleMusicAlbumTrackRow.swift`, `HomeView.swift`.
- [2026-08-27] **Dead-code deletion: only the part that is provably dead** (audit B5.1 / C5.3 / D5.5). The audit estimated 150–200 lines of unreachable SwiftUI-native `.zoom` scaffolding. Most of that estimate does not survive checking, and three of its specific claims are wrong:
  - **Removed (provably dead):** `RootView`'s `.matchedTransitionSource(id: "playerArtwork", in: artworkNamespace)`. Nothing in the module applies the paired `navigationTransition(.zoom(sourceID: "playerArtwork"))`, so it armed a SwiftUI zoom with no destination. Also corrected the doc comment above `playerArtworkNamespace`, which claimed "the system drives the entire shared-element animation" — it does not, `NowPlayingCoverPresenter`/`NowPlayingCoverAnimator` do, in UIKit and on purpose. That stale comment was the actual risk the audit identified: it points the next reader at a mechanism whose restoration would reintroduce the `fullScreenCover` crash class the presenter exists to avoid. The comment is corrected rather than deleted, so the warning survives.
  - **NOT removed — `MiniPlayerZoomSourceAnchor` / `MiniPlayerZoomSourceRegistry`.** C5.3 says to delete the anchor at `RootView`. It is live: `NowPlayingCoverAnimator.swift:258` reads `MiniPlayerZoomSourceRegistry.sourceView` as the fallback origin rect, and the anchor is the only thing that populates it. The audit's own Part C ownership map says the registry "IS still live as a fallback rect source", which contradicts C5.3. Deleting it would have silently degraded the zoom's origin in the fallback path. Left in place with a comment saying why it is not dead.
  - **NOT removed — `CoverZoomSource`'s `.system` case, the `navigationTransition` branch, `CoverZoomNamespaceKey`/`coverZoomContext()`.** Two premises here are false. (1) The audit says "nothing passes or defaults to `.system`"; all 35 call sites do pass `.custom`, but the *function default* is `style: CoverZoomStyle = .system`, so the case is reachable by omission. (2) `coverZoomContext()` is called from four live files (`HomeView`, `LibraryView`, `MusicNewTabView`, `SearchLibraryView`), and on non-iOS the `#else` branches of both `CoverZoomSource` and `CoverZoomDestination` use the namespace and `navigationTransition` as the *only* implementation — so the namespace is load-bearing off iOS. Removing this cluster is a multi-file API change with a non-iOS regression risk and zero performance payoff, in the file the audit itself says not to chase line-count reduction in. Deferred for a decision rather than done blind.
  - **NOT removed — `Sources/LyraMusicKit/NowPlayingView.swift.bak-lyrics` (D5.5).** It is untracked, and the brief forbids deleting untracked files. It is Ethan's to delete. Files: `RootView.swift`.

## 2026-08-27 — audit pass 2 (T051)

- [2026-08-27] **The 633ms playlist sort is memoized** (audit B1.2 / B2.4). The pushed detail's `.task` fires inside the zoom animator's synchronous `layoutIfNeeded()`, and `hydrateFromCacheIfNeeded()` has no `await` before it — so a full sort of the entire row array, with `localizedCaseInsensitiveCompare` per comparison, runs on the main thread at the exact instant the zoom begins. The author's own comment on `rowRenderChunk` records a measured **633ms** stall on a 1,733-song playlist, and the render-window cap added to address it is applied *downstream* of the sort, so it never touched this cost. Deferring the sort is explicitly **not** done, per the audit's warning: `displayedRows.isEmpty` gates `.disabled` on the hero Play/Shuffle buttons, so deferral makes them flash disabled. Instead `sortedRows` now has a cache in front of it, keyed on a hash of the sort-relevant fields — not just `rowId`, so an ordering stays correct when metadata moves underneath a stable id (a library refresh changing `libraryAddedDate`, for instance). Hashing is O(n) over cheap string hashes against an O(n log n) locale-collation sort, so the key costs far less than it saves. The memo stores only the resulting row-id order, so remembering an ordering costs an array of strings rather than a second copy of the tracklist, and it is bounded to 8 entries. If a rebuild from cached ids cannot account for every row it claimed (a duplicate id, a row that vanished) it falls through to a real sort. The first open still pays the sort once, on the same runloop pass as before; every reopen in the session is free. Final order is identical by construction — the sort function is unchanged, it just has a cache in front. File: `ServerPlaylistViews.swift`.
- [2026-08-27] **The first render window is one screenful instead of four** (audit B2.2 — the audit's "cheapest fix in the whole audit"). The zoom's `prepare()` calls `layoutIfNeeded()` on the pushed page before the animator is even constructed, so the first frame is gated behind a full layout of whatever the row window admits — and that was 60 rows, about four screenfuls. At the start of the animation the card is a few dozen points wide, so nothing past the first screenful is visible however much is built. The first window is now 20 rows; `rowRenderChunk` stays 60 as the *growth* increment, and `extendRowRenderWindow` backfills as rows realize exactly as it already did. That growth mechanism was already invisible by design, so the only thing that changes is how much work the first forced layout does. File: `ServerPlaylistViews.swift`.
- [2026-08-27] **An `albumId → records` index, replacing two full manifest scans per row** (audit A4.2 / B2.1 — three separate agents landed on this file). `localArtworkURL(forAlbumId:)` walked every record in the downloads manifest to find artwork for one album, and then walked it *again* for the fallback — and `AppModel.resolvedArtworkURL` calls it once per track row. That is O(visible rows × downloaded tracks) of main-thread string comparison, paid for every row realized when a detail page is pushed, which is inside the zoom's own forced layout. The index is built once per manifest change and cleared at all four sites that assign `manifestCache`, so it cannot go stale. Albums with nothing downloaded — the common case when scrolling a server catalog — now get an empty list and skip straight to the standard path with no scanning at all. Behaviour is identical: the second scan picked an arbitrary record of the album and passed its track to `existingArtworkRelativePath`, which derives the path from `track.albumId` alone, so which record is chosen cannot change the answer. The single `fileExists` stat on the standard path is kept, since artwork can outlive the records that produced it. File: `OfflineDownloadManager.swift`.
- [2026-08-27] **NOT DONE — the ~420ms dead window after a cancelled peek-drag** (audit C3.1). Deferred deliberately; it needs a device-testing session of its own. The diagnosis is right: `endDrag(committed: false)` starts a 0.42s spring-back and only calls `finish(committed:)` from that spring's completion handler, `finish` is the only caller of `completeTransition`, and `gestureRecognizerShouldBegin` guards on `host?.transitionCoordinator == nil` — so for 420ms after a cancelled peek the next grab is refused. What does not survive checking is the audit's claim that resolving the context earlier is "no visual risk". `finish()` resolves the context **and** tears the flight down in one pass, and after `completeTransition` UIKit removes the transition container — which owns `session.clip` and the artwork snapshot, i.e. exactly the views the spring is animating. Resolving early without moving those views first would make the spring-back animate views that are no longer on screen; moving them first is the reparenting that D3.2 documents as cancelling in-flight gestures. The alternative shape — letting a new grab re-enter the still-open transition during the spring — means adding a resume path through `beginDrag`/`startInteractiveTransition`, which currently round-trips through the SwiftUI binding via `requestDismiss()`. Either version is real surgery on the state machine whose own comments record six shipped soft-lock bugs, and whose failure mode is silent and session-permanent ("the player just stops being swipeable"). Not something to ship on a build-only check. **Recommended follow-up:** do this one on its own, on device, and pair it with C1.2 (guarding the redundant `layoutIfNeeded()` in `prepare()` with `if player.frame != full`), which is the cheap safe half of the same cluster.
- [2026-08-27] **NOT DONE — speculative player snapshot** (audit C1.1 / C4.2). Deferred for the same reason, plus one the audit states itself. The finding is real: `prepare()` runs `resizableSnapshotView(afterScreenUpdates: true)`, and it is called both from `animateTransition(using:)` on every open *and* from `beginDrag(context:)` — so putting a finger down to swipe the player away forces a full flush and re-render of the whole player before the first drag delta is honoured. But the audit records an **unresolved conflict** across three agents about touching this call (A3.1 wants the flag flipped after the first capture, C2 marks any change to it REJECTED-VISUAL citing the documented "empty square" first-open regression, C4.2 proposes a third variant), and its own instruction is to "implement the upstream fixes first, and only test the flag change separately, on device". The upstream fixes are what this pass did (C2.1–C2.3, above), which is the right order. Capturing speculatively also means the flight can show a bitmap captured before the content it depicts changed — which is the failure class the `afterScreenUpdates: true` comment exists to prevent. Marked "VISUAL: some" by the audit, against this pass's zero-visual-change constraint. Should be its own change with a before/after reference recording.
- [2026-08-27] **The queue pager's snap position moved out of the player body** (audit D1.2). `queueScrollAnchor` was `@State` on `NowPlayingView`, so every page settle invalidated the entire ~2,800-line body — the NavigationStack, `sharedHeader`'s GeometryReader, the backdrop and the whole bottom chrome — rather than the scroll region that actually moved. It now lives in a small `QueuePageAnchorModel` observed only by a new `QueuePagingScroll` view, so a settle re-runs that view alone. This is the `PlaybackTimeModel` pattern (which exists so the playhead tick does not re-render every player view) applied to the one place it had not been. Two details matter for correctness: the model is held with `@State`, not `@StateObject`, because `@State` on a reference type keeps the object alive *without* subscribing to it — so the player body does not observe what it just stopped observing; and it is held on `NowPlayingView` rather than inside the queue pane's own view, because a pane-scoped object would be destroyed on leaving the queue and reset the page you return to. That would have been an incidental change to pane restoration, which this pass is specifically not allowed to make. The haptic bookkeeping (`lastHapticAnchor`) is deliberately not `@Published`, so it cannot cause a second render. Not addressed (not in scope for this item): D1.4, the fresh `UIImpactFeedbackGenerator` allocated per settle rather than one prepared instance. File: `NowPlayingView.swift`.
- [2026-08-27] **The lyrics list is lazy** (audit C4.3). It was an eager `VStack` + `ForEach` over every line in the song, each line carrying its own `.blur()` — one offscreen Gaussian pass per line, for the whole song, regardless of the viewport. That cost is paid again every time the player is snapshotted or rebuilt with the lyrics pane open, which is what made it worth doing alongside the transition work. Now a `LazyVStack`; the `.id()` on each row and every `scrollTo` call are unchanged, which is what keeps the focus scrolling working. **This is the one change in either pass with real visual risk, and it should be looked at on device**: the audit flags it "VISUAL: some" because lazy layout estimates the positions of off-screen rows differently, which can affect where the list lands on first open and when jumping to a line far down a long song. Everything else in both passes is structurally invisible; this one is a judgement call that wants eyes on it. File: `NowPlayingView.swift`.

## 2026-08-27 — the swipe-down lag spike (T053, audit C1.1 / C1.2)

Ethan built the pass-1/pass-2 work to his device and reported: "when i swipe down the now playing view there is a brief lag spike." That is C1.1, which the previous pass deferred. Both conditions for doing it were now met — the upstream C2 fixes were in, and it was being tested on real hardware. **Unlike the rest of this log, this change is allowed to alter what is rendered**, and what changes is stated below.

- [2026-08-27] **The swipe-down no longer forces a full re-render of the player before the drag is honoured** (audit C1.1, plus C1.2). `NowPlayingCoverAnimator.prepare()` took its artwork snapshot with `afterScreenUpdates: true`, and `prepare()` is called from two places: `animateTransition(using:)` when the player is opened, and `beginDrag(context:)` when a finger goes down to swipe it away. On that second path the flag forces UIKit to flush and re-render the entire player *before the first drag delta is honoured* — which is exactly the spike being felt.
  - **The fix is per direction, not a global flag flip.** This is the point the audit's three agents disagreed over, and the reason it deferred: A3.1 wanted the flag flipped after the first successful capture, C2 marked any change to it REJECTED-VISUAL citing the documented "empty square" first-open regression, and C4.2 proposed a third variant. All three were arguing about one flag shared by two call sites that do not need the same thing. On the **present**, the flag stays `true` and has to: the player's tree has just been built and has not drawn yet, so without the flush the snapshot comes back blank — the empty-square bug. **That path is byte-for-byte unchanged.** On a **dismiss**, it is now `false`: the player has been fully rendered on screen for as long as the user has been looking at it, so there is nothing pending for a flush to reveal, and the flush was pure cost.
  - **What actually changes on screen.** In the case where the two flags differ — a change made to the player but not yet drawn when the finger lands — the flown cover now shows the last drawn frame rather than the not-yet-shown one. In practice that means: skip to a new track and swipe down within the same frame, and the cover that flies down is the one that was on screen when you touched, not the incoming one. This is the more faithful of the two: `afterScreenUpdates: true` composites a frame the user has *not been shown yet* and flies that, so the cover could visibly differ from what was under the finger a moment earlier. The window is a single frame, and it only affects the artwork region that is already mid-flight.
  - **C1.2, same function.** `player.frame = full` followed by `player.layoutIfNeeded()` ran unconditionally. On a dismiss the player is already at full size, so this was dirtying the layer and then forcing a layout pass to arrive at the size it already had. Now guarded on `player.frame != full`. When the frame *is* wrong — which is the present path — the behaviour is exactly as before, so this cannot regress the open.
  - The `#if DEBUG` `NP-ANIM prepare` line now also logs `flush=`, so which branch ran is visible in the device log without a rebuild.
  - Not done, and deliberately: the audit's proposal to capture the snapshot **speculatively** and cache it (after `presentCover()` for the open, at `gestureRecognizerShouldBegin` for the dismiss). It is unnecessary now — with the flush gone from the dismiss path, `prepare()` is already cheap there — and it is strictly worse for correctness, because a cached bitmap is stale by however long it sat, where this reads the current screen. File: `NowPlayingCoverAnimator.swift`.

## 2026-08-27 — measuring the swipe-down stall (T054)

Ethan rebuilt after the C1.1 fix and said "it still lags". This entry records what was **measured**, on the real device and on the simulator, rather than reasoned from the audit. The stall is not fixed yet; what follows is evidence plus one small confirmed win.

- **The C1.1 fix is live and doing what it claimed — it is just not the cause.** `DebugUIRemote` writes to `Documents/vellum-hangwatch.log` inside the app container, which can be pulled off the device with `devicectl device copy from`. Ethan's log shows `flush=false` on all 8 dismisses and `flush=true` on all 5 opens in the session he tested. So the branch is correct, the build is the one he ran, and the forced screen flush is genuinely gone from the drag path. It was simply not the thing he is feeling.
- **T051 did not cause this, and measurably improved it.** That same log spans builds going back to 2026-08-22, i.e. before any of this work, on the same phone. Median total main-thread stall in the 1.2s after a dismiss drag, by build: `2026-08-22T12:25:25` (pre-T051, the build he used for days) **552ms**; `2026-08-27T13:07` **549ms**; `13:53` **441ms**; `14:32` **297ms**; `15:06` (the C1.1 fix) **290ms**. Median drag→prepare over the same builds went 125ms → 72ms. The lag he is reporting predates this work; the passes roughly halved it without eliminating it.
- **The residual stall is ~300ms, on every swipe, and it is remarkably fixed in size.** Across the 8 dismisses in his latest session: 300, 295, 290, 306, 290ms, each beginning 110–150ms *after* `prepare()` has already returned. It is not a first-swipe-only cost, and the tightness of the range says a fixed-cost operation rather than something load-dependent within the session.
- **Two hypotheses tested and disproven, both by measurement rather than argument.** (a) *The `showsMiniPlayerChrome` flip.* Plausible, because that flag is forwarded into `AppModel.objectWillChange` and a flip mid-drag would invalidate the whole tree. A `didSet` log was added and the drag was driven end to end: **no flip occurs during the dismiss at all**. (b) *The drag-progress path.* Every `interaction.update(translation:)` was timed and numbered; with a 4ms threshold, **not one delta crossed it**. The per-frame drag work is not where the time goes.
- **One measured win, and it is small — stated as such.** `prepare()` did `player.removeFromSuperview()` and then `clip.addSubview(player)`. The explicit detach moved the whole player tree to *no window*, so UIKit walked every node firing `_didMoveFromWindow:toWindow:`, and the subsequent add walked it all again — two full traversals of the ~2,800-line player on finger-down. A `sample(1)` profile of the drag confirmed it: 31 of the 33 samples inside `prepare` were in `-[UIView _addSubview:positioned:relativeTo:]` → the recursive `_didMoveFromWindow:toWindow:` cascade, bottoming out in our own `CoverZoomAnchorProbe.ProbeView.didMoveToWindow`. `clip` is already in `container` and therefore already in the window, so the detach was unnecessary: `addSubview` reparents on its own, and doing it in one step keeps the player in the same window throughout, which lets UIKit skip the cascade. Measured over 4 UI-test runs each side on the simulator: **31/29/29/35ms before, 30/27/27/27ms after** — about 10%, ~3ms. Real, worth keeping, and *not* the 300ms. Recorded here because the earlier profile made it look dominant, and it only looked that way because `sample` attaching had itself distorted the run.
- **Why the simulator cannot finish this.** With the same instrumentation the sim run is clean: `prepare=29ms`, no drag delta over 4ms, no stall between `prepare` and `finish`. The sim signs in to the public Navidrome demo, which has a tiny library; the device has Ethan's real one. That the stall appears on one and not the other points at work proportional to library content running inside the shell re-render that `isPresented = false` triggers — but that is the next thing to *test*, not a conclusion.
- **Instrumentation left in place**, all behind `#if DEBUG` and threshold-gated so it costs nothing when nothing is slow: `DebugUIRemote.span`, spans on `requestDismiss` / the binding write / `dismissCover` / `beginDrag.prepare` / numbered drag deltas, and the `showsMiniPlayerChrome` flip log. Files: `NowPlayingCoverAnimator.swift`, `NowPlayingCoverZoomTransition.swift`, `PlaybackEngine.swift`, `DebugUIRemote.swift`.
- **Added a runloop-phase watcher (`SLOWTURN`)**, because the stall's defining property is that it lands where nothing logs. The hang watcher reports the duration of a stall but not its nature; a `CFRunLoopObserver` fires on every phase boundary, so the gap between two consecutive boundaries is one attributable span and the phase names say which kind of work it was — `beforeSources→beforeWaiting` is app/UIKit work for the turn, with the `CATransaction` commit (layout, display, SwiftUI render) at its end; `afterWaiting→beforeTimers` is source delivery, i.e. the touch event and everything our gesture handler runs from it. Threshold 60ms, so ordinary rendering stays silent. Validated on the simulator: the drag turn reports `afterWaiting→beforeTimers 88ms`, of which `prepare` accounts for 29ms — the instrument resolves the turn *and* apportions it. On the device this will name the ~300ms turn the same way. File: `DebugUIRemote.swift`.
- **The stall is now named, from a device signpost log.** Ethan ran the instrumented build and swiped five times. Result: **every instrumented span in the gesture path is small** — `beginDrag.prepare` = 9/23/25/23/36ms, and `began.requestDismiss`, `dismissNow.binding`, `dismissNow.dismissCover` and every numbered `drag.update` all stayed under their thresholds and never logged at all. The ~290ms sits *outside* all of them, beginning 85–112ms after `prepare` has already returned (299ms after a 23ms prepare, 285 after 25ms, 292 after 23ms, 289 after 36ms). The `SLOWTURN` observer catches it: the 285ms hang is one runloop turn, `afterWaiting→beforeTimers 257ms`. That phase is the wake-source region rather than `beforeSources→beforeWaiting`, which is the expected shape on current iOS, where the CATransaction flush is driven from a source1 mach-port callback — and it matches the simulator `sample` profile exactly: `__CFRunLoopDoSource1 → UC::DriverCore::continueProcessing → _UIUpdateSequenceRunNext → _UIApplicationFlushCATransaction → CA::Transaction::commit → CA::Layer::layout_and_display_if_needed → _UIHostingView.layoutSubviews → ViewGraphRootValueUpdater.render`. **So the 290ms is a single SwiftUI layout + render + Core Animation commit, landing about 100ms into the drag.** It is not in any code this project wrote on the gesture path.
- **Surrounding churn, measured on the same runs.** Each dismiss drives **9–10 shell re-renders** (`NP-SYNC`, logged from `updateUIViewController`) and **11–12 re-attachments of the mini player's cover-zoom probe** (`COVERZOOM cell __now_playing__`, logged from `ProbeView.didMoveToWindow`). So the tab-bar accessory is being rebuilt and re-inserted into the window about a dozen times during one dismiss, and one of those render passes is the expensive one.
- **Hypotheses killed by measurement, for the record.** `showsMiniPlayerChrome` flipping mid-drag: it flips exactly once in the whole session, at 720.022, during launch/restore — the first drag is at 723.060, and it never moves again. The drag-progress path: no delta over 4ms. `prepare()`/the snapshot flush (C1.1): live and correct on device, and small.
- **The driver of the render churn is `AppModel`, measured.** Publish counters on both objects, sampled across one drag: **`appPublishes=14`, `playerPublishes=0`** (a second run: 19 and 0). So the ~10 shell re-renders per dismiss are driven entirely by `AppModel.objectWillChange` — every one of which invalidates all ~40 views holding `@EnvironmentObject var app`, the shell and the mini-player accessory among them. Playback is not involved at all, which rules out the playhead and confirms `PlaybackTimeModel` is doing its job.
- **A stack capture on each publish names the setters** (`objectWillChange` fires from `willSet`, so the setter is still on the stack). On the simulator the 19 publishes during one drag came from: `libraryAlbumsLoadError`, `backendKind`, `libraryAlbums`, `libraryTrackTitleIndex`, `recentlyAddedAlbums`, `homeTopPickAlbums`, `homeNewReleaseAlbums`, `favoriteTrackIds` (← `refreshFavorites`), `libraryPlaylists`, `homeRecentlyPlayed`, `lastLibrarySyncAt`, `homeRefreshInFlight` (← `refreshHome`), `homeRecentlyPlayedServerAlbums`, `homeGenreShelves`, `homeMixes` (← `rebuildHomeMixes`). **This list is not yet trustworthy as an account of Ethan's device**, and it must not be treated as one: the UI test swipes about 25 seconds after launch, while library bootstrap is still finishing, so the harness itself is generating most of these. What the sim establishes is the *mechanism* and the *tool*; the actual publishers on a warm device are still unmeasured.
- **Still not fixed, deliberately.** Confirmed: the stall is one SwiftUI layout+commit, and the churn feeding it comes from `AppModel` publishes rather than from playback or from the gesture. Not confirmed: which publishes occur on a warm device, and which view inside that render pass is expensive. Either a device log run with the publish counters, or a Time Profiler trace over USB, closes it. Picking a fix before that would be the fourth guess in a row.
- **THE CAUSE, and the fix.** `RootView` kicks the library bootstrap from a `.task` on the shell content. That task is cancelled when the Now Playing cover is presented over the shell and **re-fires when the shell comes back** — so every dismiss of the player re-ran a whole library bootstrap. `scheduleLibraryBootstrap()` guarded only against an *in-flight* task, and by the time the user dismissed, the previous one had long finished and nil'd itself, so nothing stopped it. Each re-run is `refreshLibraryAlbums()` → `mergeOfflineCatalog()` + `rebuildDiscoveryTrackIndices()` plus the home rebuild, setting `libraryAlbums`, `backendKind`, `libraryTrackTitleIndex`, `libraryAlbumsLoadError`, `discoveryLibraryTracks`, `recentlyAddedAlbums` and the home shelves — each one a whole-tree invalidation across the ~40 views holding `@EnvironmentObject var app`. Measured on device: **8–22 `AppModel` publishes per dismiss drag, and `playerPublishes=0` every single time.** Fix: `scheduleLibraryBootstrap()` now also returns early once a bootstrap has completed for the session, with the flag reset at both sign-out paths so signing back in still bootstraps. Explicit refreshes are untouched — pull-to-refresh, the "Refresh library" menu item, `syncLibraryNow`, sign-in and cold-launch session restore all call their own entry points.
- **What tied the churn to the stall — a natural experiment on device, not an argument.** Across five consecutive drags in one session: publishes 8 → a 276ms turn; 17 → 274ms; 22 → 275ms; **0 → no long turn at all** (worst 61ms, and in the ordinary `beforeSources→beforeWaiting` render phase rather than the pathological `afterWaiting→beforeTimers` one); then 8 → 275ms. The zero-publish drag had `deltas=46`, i.e. it was a *longer* drag than most, so the absence of the stall is not explained by a shorter gesture. One drag is a single data point, but it is a clean discriminator and it points the same way as the correlation across the other four.
- **Before/after of the change itself.** Simulator, same UI test, `appPublishes` per dismiss drag: **14 and 19 before, 1 / 1 / 1 after**, tests still passing, and the drag window clean (`SLOWTURN` 79ms, no stall). Bootstrap still runs exactly once at launch, so the library still loads. Stated plainly: the simulator never reproduced the 290ms in the first place, so **this measurement proves the churn is gone, not that the lag is gone.** That last step needs a device build. The device evidence for the link is the natural experiment above.
- **Behaviour change worth knowing about.** Dismissing the player no longer refreshes the library as a side effect. That refresh was never intended — it was a re-fired `.task` — but if anything came to depend on it (new server content appearing after closing the player), it will now wait for an explicit refresh, a foreground membership sync, or the next launch instead.
- **The Time Profiler trace was attempted twice and is unusable, both times for logistics rather than tooling.** First recording (16:13:01–16:15:32, attached to pid 2139): Ethan's swipes landed at ~16:12:24–45, finishing ~16 seconds before the recording started. Second recording (16:17:19–16:22:19, 300s): the app was **rebuilt and relaunched mid-window** — a fresh `LAUNCH` at 16:20:32 from `build=2026-08-27T16:20:06` — so the attached pid exited partway through, and his swipes then landed at 16:22:47–59, after the window closed. Both traces have an empty `potential-hangs` table, consistent with containing no dismiss. The device log carried the answer instead.
- **Confirmed fixed on device** by Ethan against `e2d5417`: the swipe-down lag spike is gone.
- **Instrumentation disposition.** Everything added during this investigation is `#if DEBUG`, so none of it exists in Release. Within DEBUG: the `SLOWTURN` runloop-phase watcher, the `NP-PERF` spans and the two publish counters stay armed — they are cheap (the counters are two integer increments, the spans are threshold-gated, `SLOWTURN` compares two timestamps per runloop phase) and they are the reason this was solvable, so the next person to chase a stall here starts with them already in place. The one piece that is **parked** is the `Thread.callStackSymbols` capture behind `DebugUIRemote.capturePublishOrigins`, now `false` by default: symbolicating a stack on every `AppModel` publish during a drag is expensive enough that leaving it armed would put real cost back into the exact gesture this work just fixed, on the DEBUG builds that run on device daily. Flip the flag to get the attribution back.
- **On "prepare the chrome earlier / defer it to the end".** Worth recording that the measurement reframes this: the mini-player probe re-attaching ~12 times per dismiss is a *symptom* of the shell re-rendering, not a cause of it. Preparing the chrome up front would not stop 14–19 `AppModel` publishes from re-rendering the shell anyway. Deferring the accessory's rebuild to the end of the drag could still help *if* the accessory turns out to be the expensive part of that 257ms pass — which is exactly what is not yet known.

## 2026-08-27 — Settings submenus opened with no animation (T057)

Ethan asked whether opening each Settings submenu is supposed to be instant. It was, and it should not have been — it should push like every other screen in the app.

- **What was actually wrong, measured rather than reasoned.** SwiftUI itself asks UIKit for an unanimated push. On the Home, New and Library tabs, `pushViewController(_:animated:)` was called with **`animated: false`** for the Settings hub *and* for every Settings subpage; on Radio the identical code was called with `animated: true`. The gap between `willShow` and `didShow` was **~4ms** in the false case and **~500ms** in the true case. Pops were always animated — which is exactly the asymmetry Ethan could see: Settings snapped open and slid closed.
- **It is not structural, and that matters.** The obvious theory was that something about the Home/New/Library tab roots differed from Radio. It does not: the `Tab(...)` declarations in `RootView` are uniform, all five tabs carry the same chrome modifiers, the same `deepLinkPush`, and the same floating-header overlay that hosts the Settings avatar. The decisive evidence is that **the Library stack measured `animated: true` in two runs and `animated: false` in four, on byte-identical code**. A structural difference cannot flip between runs, so no amount of restructuring could have found this.
- **Eight things ruled out by measurement, recorded so nobody repeats them.** No `disablesAnimations` transaction anywhere on the Settings path. `UIView.areAnimationsEnabled` is `true` at the instant of the push. No `AppModel` publish is in flight (3–17s since the previous one, in *both* the animated and unanimated cases — so this is unrelated to the T054 churn). Removing the stack's `navigationDestination(item:)` modifiers changed nothing. Removing `coverZoomContext()` changed nothing. Converting the whole Settings chain from destination-closure `NavigationLink` to `NavigationLink(value:)` + `navigationDestination(for:)` registered at the tab root changed nothing. Driving the push with an explicit `withAnimation { path.append(route) }` **still measured `animated: false`**. And the call stacks for an animated and an unanimated push are identical through `NavigationStackCoordinator.update` — only the `animated:` flag SwiftUI computes differs. The deciding input inside SwiftUI was never found.
- **The fix is a workaround for a SwiftUI defect, not a root-cause fix, and it is labelled that way in the code.** It extends the mechanism this repo already built for exactly this defect: `CoverZoomPushAnimationFix` exists because SwiftUI does the same `animated: false` thing to cover-zoom pushes. A new `SettingsPushAnimationFix` flips `animated` to `true` for Settings pushes only. It never blanket-forces: it fires only while a Settings screen is actually on the stack (`settingsSubpageChrome()` and the hub track appear/disappear), or for the single push the Settings entry button armed. Every other push on every stack keeps the flag SwiftUI gave it.
- **Cover-zoom is not regressed, and that was checked by A/B rather than asserted.** The new branch sets `animated` and then falls through to the existing `guard !animated` cover-zoom check untouched, so when it does not fire the code path is bit-identical to before. Empirically: tapping a Home Top Picks cover logged `settingsForce=false/0`, i.e. the guard evaluated false and passed `animated` through unchanged. The same cover tap was then run on a clean `dev` worktree and on the fixed build, and the `COVERZOOM` log lines match line for line (`pending=nil`, `ask op=2`, `decline`, animated pop). Worth noting for whoever tests this next: an XCUITest **synthetic** tap does not reach the cover-zoom touch spy, so cover-zoom does not engage under UI test on either build — that is a harness limitation, present identically before and after.
- **One real trap, hit and recorded.** The first attempt armed the workaround from `simultaneousGesture(TapGesture())` on the Settings rows. That **swallows `NavigationLink` activation and every Settings row goes dead** — Ethan built from the working tree and hit it. `CoverZoomSource` already documents the same failure from an earlier session. Arming is now done from a real `Button` action (the entry point uses `navigationDestination(isPresented:)`) and from screen lifecycle, with no gesture anywhere near a link.
- **Verified on the simulator across Home, New and Library:** hub push, hub→subpage push, and subpage→subpage (Sound & Playback → Equalizer) all report `willShow animated=true` with a ~550ms transition, in both directions, and the UI test asserts each destination's navigation bar actually appears so a dead row would fail the run. **Not verified on device** — this cannot be installed on Ethan's phone from here.
- **No body-cost impact.** The added work is two static-integer changes in `onAppear`/`onDisappear` on Settings screens and one boolean read inside the existing push swizzle. Nothing was added to any `body`, no new `@Published` state, no catalog access.

## 2026-08-27 — album covers flickering (T059)

Ethan reported album covers flickering: an image that is already on screen blinks and comes back. The working theory going in was a race between the local artwork cache and the Navidrome fetch. It is not a race. It is a cache **key derivation** bug, and it is entirely client-side — worth saying explicitly, because the previous cover bug in this app turned out to be the server (Navidrome ranking a folder `cover.jpg` above embedded art) and it would have been easy to assume the same again.

- **The cause, in one sentence.** `NavidromeClient.buildRESTURL` assembles the query string by iterating a Swift `Dictionary`, whose order is unspecified, so the same cover is spelled `…&id=X&size=400` on one call and `…&size=400&id=X` on the next *within a single process run* — and both artwork caches derived their key by filtering the `t`/`s` auth params out of the URL **without sorting what was left**, so one image occupied two different keys.
- **The captured evidence.** Two keys logged from a single flicker, byte-identical apart from the order of two parameters:

      prevKey=…/getCoverArt?u=demo&v=1.16.1&c=VellumMusicKit&id=pl-JFNNVD9k…&size=400|768
      newKey =…/getCoverArt?u=demo&v=1.16.1&c=VellumMusicKit&size=400&id=pl-JFNNVD9k…|768

- **Why that renders as a flicker rather than just a slow load.** The mismatch misses in the in-memory cache *and* on disk, so it becomes a real refetch. `AlbumArtworkView.load` treats a miss whose key differs from `loadedArtworkID` as a new image: it sets `decoded = nil` and `imageVisible = false`, which paints `MusicShimmerSurface` over a cover that was already visible, then fades the re-decoded image back in over 0.28s. Image → shimmer → image, which is exactly the two successive paints being reported.
- **Why it is intermittent.** Dictionary iteration order is the only variable. Nothing about the album, the server or the network decides it.
- **The fix is to sort, not just filter.** Both `normalizedCacheURLString` implementations (`DecodedArtworkCache` in `ArtworkImageDecoder.swift`, and `ArtworkURLCache`) now sort the surviving query items by name then value, so the key depends on what was requested rather than how it happened to be spelled. No request behaviour changes — this only affects how a response is filed. Sorting inside `buildRESTURL` itself would also have worked and would have fixed it at source, but that rewrites every Subsonic URL in the app, which is not a blast radius worth taking for a cache bug.
- **Measured, on the simulator, with the same reproduction used to find it** (Home tab, three pull-to-refreshes with covers on screen, instrumented `AlbumArtworkView.load`): **before — 178 artwork task re-fires, of which 8–21 per run took the image-clearing path; after — 92 and 166 re-fires across two runs, of which zero took it.** The instrumentation was removed before commit.
- **One-time cost worth knowing about.** Existing entries in the on-disk artwork cache were filed under the old unsorted keys, so the first launch after this change re-fetches covers once and re-files them. After that the cache is stably keyed.
- **Unproven:** device. This was reproduced and verified on the simulator against the public Navidrome demo. The mechanism is deterministic in the code so it will occur on Ethan's library too, but it is not proven that the flicker he sees has only this one cause.

## 2026-08-27 — artwork loads keyed on the image, not on the request (T059, follow-up)

A second, separate defect found while diagnosing the flicker above. Ethan did not report this one and it is not visible on its own; it is fixed because it is a landmine for anyone who later trusts an equality check on an album.

- **What was wrong.** Subsonic media URLs carry a fresh random salt (`s`) and token (`t`) every time one is built, and `AlbumSummary.artworkURL` stores whichever spelling existed at parse time. So re-parsing an unchanged album produces a URL string that differs for the same cover. `AlbumArtworkView` keyed both its `.task(id:)` and its `loadedArtworkID` early-return on `url.absoluteString`, while both caches key on the stripped-and-sorted id — so every library refresh re-entered the load path for covers that were already on screen. **Measured: 108 of 178 artwork task re-fires during three pull-to-refreshes were salt-only.** They all hit the decoded cache, so nothing was visible; it was pure churn.
- **The wider hazard, which is the actual reason this was worth fixing.** `AlbumSummary` is `Hashable` and includes `artworkURL`, so two parses of an unchanged album are **not equal**. Any `if new != old { assign }` guard on albums therefore always fires. That silently defeats change-detection in `AppModel` — including the guard at `AppModel:2110`, which exists specifically to stop the Recently Added shelf flickering out and back in on the ~20s membership poll. Anyone adding such a guard in future would reasonably assume it works.
- **The fix.** `.task(id:)` and `loadedArtworkID` now use `DecodedArtworkCache.stableID(for:maxPixelSize:)` — the same identity both caches use. The helper for this (`artworkID`) already existed in the view and was simply never wired up. A genuinely different cover, or the same cover at a different decode size, still changes the id and still reloads; only auth-param churn is ignored.
- **Measured, same reproduction:** before — 178 task re-fires, 108 of them salt-only; after — **zero** re-fires caused by a key change. The UI test additionally asserts the Home shelves are still populated after three refreshes and after an album round trip, so a change that stopped artwork loading would fail rather than merely go quiet.
- **Not fixed here, deliberately:** `AlbumSummary`'s equality still includes `artworkURL`. Narrowing that is a model change with reach far beyond artwork, and it was not in scope. The guard hazard above is therefore reduced, not eliminated.
- **Unproven:** device. Simulator only.

## 2026-08-27 — opening Settings no longer counts the whole server catalog

Ethan asked for a cleanup of the Settings → Library section. After the audit the only change he wanted was this one: **nothing was deleted.** The audit's main finding was that Settings → Sync (a client-side re-fetch) and Library → "Scan library now" (which asks Navidrome to rescan its files) are different operations that merely sound alike, so the "redundant sync entry" turned out not to be redundant. Mixes and Album Cache Refresh also stay exactly where they are — moving them would have cost discoverability and bought nothing.

- **What was actually expensive.** `refreshLibraryStatistics()` ran from **two** places automatically: `SettingsLibraryDataView`'s `.task`, and `SettingsView.onAppear` — the hub. So merely opening Settings, for any reason, started it. On Navidrome that call paginates `getAlbumList2` 500 albums at a time across the entire library, fetches `libraryArtists(limit: 20_000)`, and sums per-album track counts. On a large library that is a lot of round trips to populate four informational numbers one screen deeper.
- **The change.** Both automatic calls are gone. The Server Catalog block now shows a **Load totals** button; tapping it runs the same fetch, shows the existing "Loading server totals…" row with a spinner while it works, and then displays the four counts plus a **Refresh totals** button. If totals are already in hand they render immediately with no fetch — which includes the case where a "Sync now" populated them, since `syncLibraryNow()` still refreshes statistics as part of its work. That call was deliberately left alone: it is an explicit user action, not a side effect of navigation.
- **Small knock-on, stated plainly.** The hub's Library row subtitle falls back to "N on server" when the user has no personal-library songs yet. With totals no longer fetched on appear, that fallback is blank until totals are loaded once. The primary subtitle ("N in your library") is unaffected.
- **Verified on the simulator** with a UI test that opens Settings → Library, asserts the page and its "Your Library" section render, asserts the **Load totals** button is present rather than numbers, taps it, and asserts the totals then appear. That ordering is the actual behaviour change, so the test fails if the stats come back on appear or if the button stops working.
- **Unproven:** device, and the size of the win on Ethan's real library. The saved work is proportional to his catalog, and the demo server used for verification is small.

## 2026-08-27 — total playing time under a playlist's track list (T060)

Ethan asked for a cumulative duration at the bottom of the track list. The first job was to find out what already existed, because his own screenshots showed "1 song, 7 minutes" already rendering under an **album**.

- **What was already there.** Three separate implementations of the "N songs, N minutes" line: `ServerPlaylistViews`' `albumFooterDurationSummary`, and two more in `BrowseAlbumDetailView` (one for library tracks, one for preview tracks). `ServerPlaylistDetailView` renders albums, playlists **and** home mixes from a single view, but the footer was gated twice over — `if isAlbum` at the render site and `if let album = albumOrNil` inside the block — so playlists and home mixes had nothing below the last row. The playlist *header* already showed "N songs · Updated …", a count but no duration.
- **So this was a reuse job, not a new feature.** The existing block is now `trackListFooterBlock` and renders for all three kinds; the album release-year/date line inside it stays album-only. Albums keep their exact previous layout order — Show-Complete-Album toggle, then footer, then the related-album shelves — the footer simply moved out of the `isAlbum` gate. Left-aligned, matching the album footer it stands in for, rather than the right-aligned styling first sketched: two differently-aligned footers in one view would have been worse than either choice alone.
- **The one thing that could not be reused as-is.** `albumFooterDurationSummary` summed every row's duration inside a body path. On a 12-track album that is free; this footer now covers playlists, and Ethan's `metal v2` is 778 songs, so it would have been an N-element pass on every body evaluation of that view — and every `AppModel` publish re-runs every visible body. That is the same shape of work this file's own `rowsContentToken` was introduced to remove; its comment says a per-body N-element pass "scales badly on 1000+ song playlists". The total is now computed into `@State` from the existing `rowsContentToken` observer, which is this view's established O(1) "the tracklist changed" signal.
- **Known limitation, recorded rather than hidden.** A metadata refresh that rewrote durations while leaving the row count and the first/last row ids unchanged would leave the total stale until the next tracklist change. Narrow, self-healing, and much cheaper than summing every row on every body pass.
- **Deliberately not done:** the two copies in `BrowseAlbumDetailView` were left alone. Consolidating all three into one component is a wider refactor than this asked for.
- **Verified on the simulator:** a UI test opens a playlist and asserts the "N songs, N minutes" footer appears under the last row, then opens an album and asserts its footer is still there. Both legs assert — an earlier version of the test silently skipped the album leg and "passed", which proved nothing.
- **Unproven:** device, and behaviour on a genuinely long playlist. The demo server's largest is 185 songs; `metal v2` is 778.

## 2026-08-27 — Apple-Music-style long press on song rows (T061)

Ethan sent a recording of Apple Music's tap-and-hold on a song row and asked for that interaction. The reference was checked frame by frame rather than taken from description: extracted with `ffmpeg` and read at ~2.8s, where the menu is fully open. It shows a floating card — artwork, title, artist, `album · year` — above a menu whose first element is a row of three icon buttons (Add, Favorite, Share), then the vertical items. Worth recording that a first pass at the video using mean-luma to find the "dim" found nothing, because this app's background is already near-black; looking at the frames is what settled it.

- **Built with stock `contextMenu(menuItems:preview:)`.** The lift, the dim and blur behind it, and the dismissal are all the system's. Nothing about that motion is hand-rolled, per the project rule.
- **Added once, to `LibrarySongRow`** — the row component both playlist detail and album detail already use — so both surfaces got it from one change rather than two implementations.
- **The ⋯ menu and the long-press menu are now literally the same view.** The row's inline ⋯ menu content was lifted verbatim into a `songMenuContent` builder that backs both. No option was added, removed or reordered by this change, and the two cannot drift apart later. This matters because the app's rule is that song-row menus stay consistent across surfaces.
- **The preview card needs no derived state.** `Track` already carries `albumTitle` and `releaseYear`, so the card reads its three lines straight off the track — no catalog lookup, nothing to memoize, and no work added to any row's body. The `preview:` closure is only built when a menu actually opens, so a 778-row playlist pays nothing for the other rows.
- **Verified on the simulator**, all four in one run: long press opens the menu; the menu dismisses on a backdrop tap; **tap-to-play still starts playback**; and the row's **swipe actions still work** (the trailing `Remove` still appears after a swipe). The last two were the real risk — a context menu sharing a row with a tap target and swipe actions is exactly where gesture conflicts show up.
- **Deliberately not changed — worth Ethan's attention.** The row's menu is a *subset* of `StandardSongMenuContent`, the shared template other surfaces use. **Add to Queue**, **Go to Artist** and **Remove from Playlist** are absent from this row's menu; Add to Queue and Remove from Playlist exist only as swipe gestures, which a long-pressing user will not discover. That is pre-existing, and which actions belong in the menu is a product decision, so nothing was invented here. Apple's **Create Station**, **View Credits** and **Suggest Less** were likewise not invented.
- **Unproven:** device. Simulator only — and haptics and the exact feel of the lift are things only a device shows.

## 2026-08-28 — song-row menu: three missing actions, and one icon that never existed (T063)

Ethan reported three things about the song-row menu: actions missing versus the rest of the app, "also missing some icons — for the buttons", and that it "should use the same button layout used in the now playing view long press".

- **The layout question answered itself by reading the code.** The Now Playing view's long-press menu (`NowPlayingView.swift:770` and `:841`, `.contextMenu { queueSongMenuContent(track:) }`, defined at `:1499`) **already renders `StandardSongMenuContent`** — the shared template used by search, the artist page and the queue. Its own doc comment says so. So "match the Now Playing long press" and "reuse the shared template" were the same instruction, and converging answered both.
- **Converged rather than hand-adding.** `LibrarySongRow.songMenuContent` — which since T061 backs the ⋯ button *and* the long-press menu — is now just `StandardSongMenuContent(...)`. That removes the fourth hand-maintained copy of this menu rather than growing it, and it means playlist, album, search, artist, queue and Now Playing rows now offer one menu that cannot drift.
- **The icons were a real bug, and reading the source could not have found it.** Both menus `Label(...)` every item, so on paper nothing was missing. Resolving every symbol at runtime instead found that **`music.note.square` does not exist in SF Symbols**. An invalid name returns nil from `UIImage(systemName:)` and renders as **blank space — no build error, no runtime log**. It was the "Go to Album" icon in **six** places: `StandardSongMenuContent`, `LibrarySongsView`, `NowPlayingView`, `DiscoverySearchView`, `NewTabChartOverflowPanel` and `SongOverflowPanel`. All six now use **`square.stack`**, which is the glyph this app already uses for Albums in the Library filter (`LibraryView:105`).
- **Every other symbol in the module is fine.** All 117 SF Symbol literals in `VellumMusicKit` were resolved at runtime on this iOS version; exactly one was invalid. That is worth knowing because it means the blank icon was this single defect repeated, not a general problem.
- **Three actions added**, all of which already existed elsewhere: **Add to Queue** and **Go to Artist** came free with the template; **Remove from Playlist** was added *to* the template, gated on a callback so it appears only where a row genuinely belongs to a user playlist. `ServerPlaylistViews` already passed `nil` for album and home-mix rows (`isAlbumStyleDetail ? nil : …`), so that condition is a real one that was already in the code, not a new assumption. `LibrarySongRow` gained an `onGoToArtist` callback, wired on the playlist/album surface with the same `ArtistNavigation.isTappable` guard Now Playing uses, so "Various Artists" stays non-navigable.
- **The swipe actions are untouched.** Add to Queue and Remove from Playlist remain swipe gestures as well; the menu is additive. The entire point is that someone who long-presses never discovers a swipe.
- **One thing removed:** an informational, disabled "Downloaded ✓" row that only the song-row copy had. The row already shows a download glyph through `TrackOfflineDownloadIndicator`, so nothing visible to the user is lost, and keeping it would have meant adding a row to every other surface to stay converged.
- **Verified on the simulator, and the menu was actually looked at, not just asserted on.** On a playlist row all of Play Next, Add to Queue, Add to Playlist, Go to Album, Go to Artist and Remove from Playlist are present, every item renders its icon, and the previously blank Go to Album icon now draws. On an album row Add to Queue is present and Remove from Playlist is correctly absent. Tap-to-play still starts playback and the swipe actions still appear.
- **Unproven:** device. Simulator only. Ethan's report of missing icons was on device, and while `music.note.square` is invalid on every iOS version, it is worth him confirming that the icon he was missing is the one now fixed.

## 2026-08-28 — track-list duration footer: hours then minutes, from one formatter (T065)

Ethan: *"only shows minutes at the bottom but should be hours then mins"*. At his library sizes the raw-minutes number was meaningless — a long playlist read "3120 minutes" instead of "52 hours".

- **One formatter, three call sites.** The string was duplicated in `ServerPlaylistViews` and twice in `BrowseAlbumDetailView`. T060 deliberately left the two browse copies alone as out of scope; they were in scope this time. All three now call a new `TrackListSummary` (`TrackListSummary.swift`) — the same one-panel principle Ethan stated for menus, applied to a formatter. Fixing the format in one place and leaving two behind would have recreated exactly the situation that let two bugs live in all three copies at once.
- **Second bug, fixed in the same place.** Every copy pluralised the song count but hardcoded "minutes", so a one-minute track read **"1 song, 1 minutes"**. Both units are singularised now.
- **The format, and what it does at the edges.** `"N songs, 1 hour 5 minutes"` — song count and duration separated by a comma, hours and minutes by a space, each unit singularised and the empty unit dropped:
  - **zero / unknown duration** → the duration clause is **omitted entirely** ("3 songs"), rather than printing "0 minutes". Browse preview tracks often carry no duration at all, and that copy already did this by hand; now it falls out of the shared formatter.
  - **under a minute** → "1 minute". A real track is never "0 minutes".
  - **59 min** → "59 minutes".
  - **exactly 60 min** → **"1 hour"**, not "1 hour 0 minutes".
  - **61 min** → "1 hour 1 minute".
  - **empty list** → "No songs" (unchanged).
- **Rounding changed from ceil to nearest.** At album and playlist scale, rounding to the nearest minute is closer to the truth than always rounding up; `max(1, …)` still keeps a very short list from reading as zero.
- **Left alignment unchanged**, as settled in T060 — two differently-aligned footers in one view would be worse than either choice alone.
- **Verified on the simulator, on a playlist and an album, reading the actual rendered strings** rather than asserting a regex: a 3-song playlist renders `3 songs, 11 minutes`, and *Live at The Casbah* (22 tracks, 141 minutes) renders `22 songs, 2 hours 21 minutes`. Both format branches exercised on real screens.
- **Out of scope, deliberately:** the sleep-timer label in `NowPlayingView` also reads "N minutes", but it is a timer setting, not a track-list total.
- **Unproven:** device. Simulator only.

## 2026-08-28 — one song menu everywhere, and a menu item that did the wrong thing (T064)

Ethan, on being told the missing icon was Go to Album: *"and it shouldn't even matter. since it should just use the same panel in the now playing. as that now playing panel should be universal."* T063 converged only `LibrarySongRow`; this finishes the job.

- **A menu item was doing something entirely different from its label.** In `DiscoverySearchView`'s hand-rolled song menu, **"Remove from Library" called `app.toggleFavoriteTrack(id:)`** — so it unfavourited the song and left it in the library. That is the strongest argument there is for one shared menu: the bug existed only because that surface kept its own copy, and it survived precisely because nobody reads four copies of the same menu. The converged item is wired to `app.removeSongFromLibrary` and does what it says.
- **Converged onto `StandardSongMenuContent`:** `DiscoverySearchView`'s server-song menu and `BrowseAlbumDetailView`'s track menu. With T063's `LibrarySongRow`, every genuine song menu in the app is now the same view.
- **Nothing was removed.** The two actions those surfaces had that the template lacked — **Play** and **Add Album to Library** — became optional callbacks on the template rather than a reason to keep separate menus, following the `onRemoveFromPlaylist` pattern from T063.
- **One deliberate exception, and it is not a contradiction.** `NowPlayingView`'s player-header ⋯ (`nowPlayingTrackMenuContent`) stays hand-rolled. It omits Play Next and Add to Queue on purpose, because they are meaningless for the track that is *already playing*, and the file says so. **The panel Ethan called universal is `StandardSongMenuContent` — the one the Now Playing *queue rows* use, and which is now used everywhere. The player-header ⋯ is a different menu for a different object: the currently playing track, not a row in a list.** Converging it would add two nonsensical actions to satisfy a rule. Do not "fix" this later.
- **Dead code removed, after proving it dead.** `SongOverflowPanel` — a complete hand-rolled Apple-Music-style song sheet, 264 lines — was referenced by nothing. `git grep` over all tracked Swift found only its own declaration and a `MARK` comment; it declared exactly one type, referenced nowhere; no project or storyboard references either. It compiled only because it sat in the target.
- **Icon consistency:** `ArtistNowPlayingMenuButton` used `square.stack.fill` for Go to Album while the template uses `square.stack` — literally the inconsistency Ethan complained about. Aligned.
- **Caught before it shipped:** the new "Add Album to Library" item was first written with `square.stack.badge.plus`, which is *not* a verified symbol in this module. It now uses `plus.square.on.square`, which `LibraryAlbumContextMenuContent` already uses for adding an album and which resolves at runtime. That is the T063 lesson applied to new code — an invalid SF Symbol renders as blank space with no build error.
- **Net −278 lines** (+91 / −369) across five files, which is the point: one menu, not a bigger one.
- **Verified on the running app** for the search surface: the menu on a real song row (`Nekozilla, Song · Different Heaven`) shows Play, Play Next, Add to Queue, Add to Playlist, Add Album to Library and Go to Album, and Add to Library works. All three SF Symbols used are asserted to resolve at runtime.
- **NOT verified, and worth knowing why:** that the converged **"Delete from Library"** removes rather than favourites could not be exercised on that surface, because **a song that is in your library stops appearing in Discover search results** — the row vanishes the moment it is added, so the removal item is barely reachable there at all. The change itself is a direct rewiring (`toggleFavoriteTrack` → `removeSongFromLibrary`) and the same callback is exercised on the library-row surfaces converged in T063, but the Discover round-trip is unproven. That reachability quirk is a separate product question worth putting to Ethan.
- **Unproven:** device. Simulator only.

## 2026-08-28 — the date under the track list, and the parser that made it impossible (T067)

The ask was small: a date under the track list — an album's release date, and a playlist's creation date **only if Navidrome genuinely returns one**. It does. The reason it had never appeared is not the reason I expected.

- **My earlier audit was wrong, and the code is why.** I reported that `created` was "already parsed into `PlaylistSummary.libraryAddedDate`, so no new plumbing is needed." The field *is* wired end to end — model, decode site, call sites, all correct. Only the **parser** was broken: `parsePlaylistDictSummary` called `navidromeCreatedDate`, which handles **numeric epochs only**. Navidrome sends ISO-8601 with nanosecond precision (`2026-08-26T14:42:46.697696187Z`), so it returned `nil` for **every playlist, always**. Reading the call site is not the same as reading the function it calls.
- **The fix is one helper swap**, to the `navidromeOptionalDate` sitting ten lines above it, which tries the numeric form and then the ISO formatters.
- **Checked, not assumed:** `ISO8601DateFormatter` with `.withFractionalSeconds` is documented for *milliseconds*, so I probed it against this server's real payloads before relying on it — it does accept 8 and 9 fractional digits. The formatter **order** also matters and is already correct: `.withFullDate` happily matches a full timestamp by parsing just the leading date, so if it ran first every date would silently collapse to midnight UTC.

### What else depended on it

`libraryAddedDate` was `nil` for every Navidrome playlist, so each of these was silently falling back to `.distantPast`. They now get real dates and **will order differently**:

- **Library → Recently Added** — server-side playlists never sorted in by their true creation date unless this app had stamped one locally.
- **Sort by Date Added / Recently Updated** (`LibraryView`, `ServerPlaylistViews`) — the fallback made these effectively source-order.
- **The playlist hero subtitle — which was mislabelled, and my fix would have put the wrong word on screen.** It read `libraryAddedDate` (the server's **created** date) and labelled it **"Updated"**. That was invisible only because the value was always `nil`. It now prefers `serverUpdatedDate` (`changed`, also newly parsed) and says "Created" only when it falls back. **Fixed in this commit because this commit is what made it visible** — shipping the parser fix alone would have introduced a user-visible lie.

### Deliberately not fixed

**Albums and tracks have the identical bug** — `NavidromeClient.swift:182` and `:971` also call `navidromeCreatedDate` on `created`, and I confirmed from real payloads that `getAlbumList2` and `getRandomSongs` return the same ISO format. So `libraryAddedDate` is `nil` for every Navidrome album and song too. The one-line fix is the same. **I did not ship it**: album/track "date added" feeds Library sort order and `NewTabPersonalizationEngine` recency across the app, and changing that is a behaviour change of its own, not part of a footer line. It needs its own diagnosis and sign-off. **Flagged, not silently expanded.**

### The feature itself

- **Both dates are labelled** — "Released 14 March 2019", "Created 26 August 2026". The album line previously rendered a **bare date**, which was unambiguous only while albums were the sole surface with one; now that a playlist shows a date in the same position, an unlabelled date could mean either. **This is a visible change to the album line.**
- **Missing date → the line is omitted entirely.** No placeholder, no empty row. That is the common case: plenty of albums carry no release metadata.
- **Home mixes show no date** — they are generated, so they have none to show.
- **One formatter, three call sites.** `releasedLine` / `createdLine` joined `TrackListSummary` (T065), and `BrowseAlbumDetailView` was switched over to it rather than keeping its own copy — the T064 rule applied to new code.
- **O(1)** — reads two already-parsed fields. Nothing here scales with row count, which matters because this footer sits on the screen T059 is about.
- **Verified on the simulator, reading the actual rendered strings**, on a playlist *and* an album, plus the corrected subtitle:
  - playlist footer → `Created August 28, 2026`
  - album footer → `Released 2005` (*Live at The Casbah* — the year-only fallback branch)
  - playlist hero → `2 songs · Updated 2 hr. ago`
  - and the negative assertions hold: no "Released" on a playlist, no "Created" on an album.
- **Unproven:** device. Simulator only.

### Tooling, same day — buildbot install/launch reporting (not in this repo)

`buildbot.sh` inferred a successful install by grepping for devicectl's own `App installed:` line. The last real device run proved that unreliable: the app **was** installed and the result line still said `installed=no`. `build-to-phone.sh` now prints its own `==> Installed` / `==> Launched` markers, each reachable only after its command returned 0 (the script runs under `set -e`), and `buildbot.sh` reads those, keeping Apple's wording as a fallback so older logs still parse. Replaying the failed run against the new logic yields `installed=yes launched=no` — which is what actually happened: installed fine, launch refused because the phone was locked. **Install and launch stay separate flags**; collapsing them would report a locked-phone deploy as a total failure. These two scripts live in `~/.claude/scripts`, outside this repo, so they are not part of this commit.

## 2026-08-28 — Remove from Playlist goes text-only (T068)

The menu item kept its icon through T063 and T064 and it was never a missing-symbol bug — I checked before changing anything, because that is exactly what T063 turned out to be. **All fourteen SF Symbols in `StandardSongMenuContent` resolve at runtime, `text.badge.minus` included**, and the icon rendered on both presentations: the row ⋯ menu and T061's long-press `contextMenu(menuItems:preview:)`. Those two share one definition (`songMenuContent`), so there was no second copy to blame either.

- **The real problem was legibility, not absence.** `text.badge.minus` is a "lines with a badge" glyph sitting in the same menu as `text.append` (Add to Queue) and `text.line.first.and.arrowtriangle.forward` (Play Next). At menu size the three are near-indistinguishable, so the only destructive item in the menu read as another queue action.
- **Now text-only.** The red destructive tint already carries the weight, and no icon is clearer than a misleading one.
- **Known side effect, visible in the capture:** with no image, iOS reserves no icon gutter for that row, so the label sits flush against the menu edge rather than aligning with the text column of the items above it. It sits alone in its own bottom section, so it reads as deliberate — but it is a real alignment difference and not a rendering accident.
- **Scope:** the menu item only. The swipe action keeps its icon, because a swipe action *is* its icon.
- **Verified on the simulator** by capturing the menu before and after on a real playlist row (`zz-perf-778`), reading the rendered image rather than the source.
- **Unproven:** device. Simulator only.

## 2026-08-28 — queue rows: a drag that crashed the app, and a delete that stopped the music (T062)

Two reported bugs, one cause: **`Track.id` is not a row identity.** A queue can hold the same id
twice — a playlist with a repeated song (nothing on that path dedupes), or Play Next / Add to Queue
used on the track that is *already playing*, which leaves the original where it is and inserts a
second copy after it. Every queue-row operation addressed rows by id, so all of them hit the wrong
row, or every row, or trapped.

**What was wrong**

- **Dragging a row crashed the app.** `moveWithinSection` rebuilt `Dictionary(uniqueKeysWithValues:)`
  keyed on `Track.id` to recover positions. That initialiser requires unique keys and traps
  otherwise. It fired on the **drop**, not during the drag: you released the row and the app died.
  Any row triggered it, not only a duplicated one, because the dictionary covered all of up-next.
- **Deleting a row deleted every copy of that song, including the one playing.**
  `removeTracksFromQueue` does `queue.removeAll { trackIds.contains($0.id) }`. With the playing
  track duplicated, both copies went; the cursor could no longer find itself, fell through to
  `currentIndex = min(...)` and called `scheduleAdvance()`, which tears down the player. Removing an
  up-next row stopped the song you were listening to.
- **`ForEach(_, id: \.id)` and the tap lookup** had the same defect: duplicate identities collapsed
  rows, and `firstIndex(where: { $0.id == t.id })` sent a tap on the second copy to the first.

**The fix — address rows by position, keep the id-based path for the one caller that wants it**

- New `QueueEntry` carries a stable `rowId` (id + which occurrence), plus `queueIndex` and
  `upNextOffset`. Identity is the occurrence, not the position, deliberately: an absolute index
  changes for every row below a deletion and would make SwiftUI animate the wrong row out.
- `moveWithinSection` reads `upNextOffset` directly. **The `Dictionary` is gone entirely.**
- Tap and swipe act on this row's position.
- New `PlaybackEngine.removeUpNextItems(at:)` removes rows by offset from `currentIndex + 1`.
  Nothing at or before the cursor is addressable, so it **cannot** remove the playing track — no
  teardown, no advance, by construction rather than by a guard.
- `clearUserQueue` now selects rows after the cursor instead of passing an id set, so the playing
  track's own row is simply never in the selection.
- **`removeTracksFromQueue(trackIds:)` is unchanged.** `AppModel.deleteTrackFromLibrary` still needs
  every copy gone, playing one included, when the file is deleted from the server. It is now
  documented as the id-based sibling that queue rows must not call.

**Reproduced before fixing, on the simulator, with a fixture built for it** — the demo-server
playlist `zz-dup-repro`, ordered `[Baxter, game over, Baxter, Isolation, game over]`, so playing
from track 0 leaves a duplicated id in up-next *and* an up-next copy of the playing track.

- **Drag:** on `52fa64f`, dragging an up-next row by its reorder handle and dropping it **terminated
  the app** (`XCUIApplication.state == notRunning`). After the fix the same drag reorders correctly:
  `[game over, Baxter, Isolation, game over]` → `[Baxter, Isolation, game over, game over]`, with
  the *first* `game over` moving and the second staying put — the right row moved.
- **Delete:** after the fix, swiping the up-next `Baxter` removes exactly that row (Baxter up-next
  rows 1 → 0, the `game over` pair untouched) and **`Brock Berrigan` is still in the player header**
   — the song kept playing.
- **Control, on unfixed code:** swiping `Isolation`, whose id appears once, removes it correctly.
  So the gesture works; it is specifically the duplicated id that breaks row addressing.

**Two things I could not show, stated plainly rather than implied**

- On unfixed code, swiping the *duplicated* row produced **no observable change at all** — no crash,
  no removal, playback unchanged. It did not reproduce the audit's predicted symptom of playback
  being torn down and jumping. The destructive code path is real and reachable by reading
  (`removeAll` by id, then the failed `previousId` lookup falling into `scheduleAdvance()`), and the
  audit's verifier confirmed it, but what the UI actually did was swallow the swipe. Most likely the
  duplicate `ForEach` identity never delivered the action — which is the same root cause wearing a
  different face.
- I could not capture the trap's text ("Fatal error: Duplicate values for key"); no crash report was
  written to `DiagnosticReports` and the simulator log had nothing. The evidence for the crash is
  the app being `notRunning` immediately after the drop, on code where that initialiser sits on
  exactly that path with known-duplicate ids.
- **"Clear" on the Queue section is not covered by a test.** It needs user-queued tracks, and I could
  not drive Add to Queue for the playing track through the UI (long-press opened the player; the
  detail rows exposed no ⋯). The change is the same positional selection as the swipe path.
- **Unproven:** device. Simulator only.

**Fixture left on the public demo server:** `zz-dup-repro`. Kept deliberately, like `zz-perf-778` —
it is the only way to reach this state. Delete it if you would rather it were not there.

## 2026-08-28 — playback failures stop lying: one failure path, five entry points (T063)

Five audit findings, one defect: **a playback failure was discarded, `isPlaying` was never reset,
and the user was never told.** From the listener's seat the result was always identical — a pause
glyph over silence, a lock screen still reporting rate 1.0, and no way out but a force-quit.

**One failure path, not five patches**

- `PlaybackEngine.reportPlaybackFailure(_:track:context:)` is now the only place a failure is
  handled. It clears `isPlaying` and the pending auto-play intent, stops the buffering spinner,
  calls `refreshNowPlaying()` (which is what drops the reported rate to 0), and fires a new
  `onPlaybackFailure` callback. One real failure can arrive twice — `play(rate:)` returning false
  *and* the session notifying `onPlaybackFailed` — so the transport is corrected every time but the
  user is told at most once every two seconds.
- **The engine had no error channel at all.** `onPlaybackFailure` is the first one. `AppModel` wires
  it to the app's existing transient toast ("Couldn't play <title>"), matching "Couldn't start mix".
  Not `errorMessage`, which `RootView` renders as an alert — a mid-queue failure should not
  interrupt.

**The five entry points, all routed into it**

1. **Config-change rebuild** (route change) — was a bare `try? await equalizedPlayer.seek(...)`. Now
   catches, performs the same recovery the session's own `onPlaybackFailed` does
   (`detachPlayerKeepingQueueState` + `stagePendingRestore`), and reports. This one mattered most
   because the failing rebuild also invalidates the time observer, which is the *only* thing that
   syncs `isPlaying` back on the EQ path — so nothing could ever correct it.
2. **`play(rate:)` returning false** — nine of its ten call sites discarded the `Bool` and set
   `isPlaying = true` regardless. All now go through `startEqualizedPlayback(_:context:)`, which
   reports instead of pretending. **The tenth needed it too**, which is worth spelling out because
   it looked correct: the EQ session's autoplay branch already assigned the `Bool`
   (`isPlaying = session.play(...)`), so it never showed a false pause glyph — but honouring the
   return only got as far as `isPlaying = false`. The track had loaded, autoplay was asked for,
   nothing played, and the user was told nothing. Silent in a quieter way, but the same class of
   failure. Every one of the ten now routes through the single path; the only bare `play(rate:)`
   left in the engine is the one inside the helper itself. The guard inside `EqualizedAudioEnginePlayer.play(rate:)` now
   calls `notifyPlaybackFailed()` like the `engine.start()` catch beside it already did, so the
   recovery wired to `onPlaybackFailed` actually runs. This is what made the play/pause button
   inert — it could not even pause, because the node never started and every tap re-entered the
   same branch. The UI-milestone reconcile was silently retrying it forever; it now stops.
3. **Auto-advance / skip** — `scheduleAdvance` was `try? await self.advance()`. It now catches and
   reports, while still ignoring the cancellation a superseded skip produces, so a fast double-skip
   does not raise a toast.
4. **Gapless advance onto a failed pre-enqueued item** — `promoteToEnqueuedNext` never looked at
   `item.status`. It now stops on `.failed` instead of announcing the title, firing `onTrackStarted`
   and setting `isPlaying = true` over silence. The cursor still follows the OS onto that item
   (otherwise the app reports the wrong track as current) and the progress readout is reset.
5. **Surfacing** — covered by the callback above; the EQ session's `onPlaybackFailed` closure, which
   previously recovered silently, now reports too.

**Verified — and be clear about how**

The natural triggers (a 404 next track, an expired token, a failed engine rebuild after a route
change) cannot be staged on the simulator without manipulating the machine's network, which I was
not willing to do on Ethan's Mac. Two dead ends worth recording so nobody retries them: Navidrome
**silently drops unknown song ids** from `createPlaylist`, so a dead track cannot be injected that
way; and the engine has **no offline gating**, so deleting a downloaded file just falls back to
streaming and succeeds.

So the failure was **injected** in a throwaway worktree — a debug hook making the next load throw
exactly where a dead track would — and the same test run against both versions:

| | toast | transport after a failed skip |
|---|---|---|
| T062 only (no fix) | **none** | **Pause** — the reported symptom exactly |
| with T063 | **"Couldn't play game over"** | **Play** |

That verifies the skip / auto-advance path (findings 3 and 5) end to end. **It verifies the fix's
behaviour, not the original trigger.**

**Not reproduced, stated plainly.** Three of the five are fixed by code and unverified by a run:
the config-change rebuild (needs a real audio route change — AirPods connect/disconnect — which the
simulator cannot produce), the `play(rate:)` EQ wedge (needs the EQ path plus a thrown reload from
an evicted cache file or a truncated transcode), and the gapless promote (needs a pre-staged item to
go bad mid-track). Each was traced through the source at its file:line, but none was observed
failing and then observed fixed.

**Behavioural question for Ethan, deliberately not decided here.** This implements an honest failure
surface and nothing more: on failure playback **stops and says so**. It does *not* retry, and it
does *not* auto-skip past a dead track. Whether one dead track mid-queue should be skipped so the
rest of the album keeps playing — and after how many attempts — is a product decision, not part of
fixing a swallowed error.

**Noticed, not fixed (out of scope this pass):** the internet-radio cluster and the cold-launch
restore no-ops, per the brief.

**Unproven:** device. Simulator only.

## 2026-08-28 — transport controls that did nothing, or the opposite (T064)

Five audit findings, one complaint: **the user presses a control and either nothing happens or the
opposite happens, with no feedback.**

**The seek lifecycle lost track of what the user last asked for**

- **A pause during an in-flight seek was silently undone.** `performSeek` snapshotted the play state
  before its `await` and resumed unconditionally afterwards, so a pause issued during the seek was
  overwritten when it completed. It now re-reads the intent *after* the await.
- **A superseded seek re-issued itself to its stale target.** AVPlayer resumes a pending seek's
  continuation with `finished == false` the instant a newer seek is issued; the old code read that
  as "my seek failed" and retried to its own old position, then restarted playback there — two side
  effects *before* the generation guard that exists to stop exactly this. The guard now runs before
  the retry and again before the resume.
- **A superseded task no longer runs `completion`.** Invoking it cleared the scrubber's
  `isScrubbing` before the real seek had landed, which is what made the thumb snap back to a
  mid-seek position. The newest task always matches the generation and runs it exactly once.
- **`togglePlayPause` was branching on `player.rate`.** `performSeek` parks the player for the
  duration of a seek, so mid-scrub the rate reads 0 and a tap on a button *drawn as pause* fell into
  the resume branch and started audio — the opposite of what was pressed. Inside the seek window it
  now branches on intent.

**The part that had to be measured, not reasoned about**

The audit's verifier warned that moving the generation guard earlier without fixing the play-state
sampling would leave playback silently paused after a rapid double-scrub. It was right, and my first
attempt did exactly that — `isPlaying` sampled per task is not enough, because the first seek's
`player.pause()` fires KVO that clears `isPlaying` before the second seek samples it. **The test
caught it: `Pause=false` after a double scrub, i.e. the music had stopped.**

So intent is now tracked per *burst*: `seekResumeIntent` is set by the first seek of a burst,
inherited by any that overlap it, and cleared by every explicit pause. That satisfies both halves at
once — a mid-seek pause wins, and a rapid double-scrub keeps playing.

**Remote controls no longer advertise what the app cannot do**

- `nextTrackCommand` was set enabled unconditionally, and `updateRemoteCommands()` only ever ran on
  a settings change, so enablement could never track queue position: the lock-screen / CarPlay Next
  button stayed lit on the last track and did nothing. Enablement is now derived from
  `currentIndex`, `queue.count` and `repeatMode`.
- `changePlaybackPositionCommand` was enabled once for the life of the process, including on live
  radio, where the seek is always discarded because the stream has no finite duration. It is now
  disabled for internet-radio tracks — the app already knew this and greyed out its own scrubber;
  the flag simply never reached the command center.
- Both are refreshed from `refreshNowPlaying()`, the one hook that already runs on every track
  change and transport update, and cached so the common case is two comparisons.
- **`previousTrackCommand` was deliberately left alone.** At the start of a queue it seeks to 0,
  which is standard restart-the-track behaviour and a real, visible response — not a silent no-op.

**Cold-launch restore left the transport half-wired**

After a restore the queue and position are staged with no player yet, and every seek entry point
fell through `guard let player` and did nothing until the first Play — the scrubber, ±15s, Previous
(which routes to `seek(toSeconds: 0)`), and the lock-screen scrubber. `performSeek` now moves the
staged position instead, the same thing `togglePlayPause` and the remote resume command already did
on their own paths. The `duration == 0` variant (an offline track whose duration never resolved,
which bails even earlier) is handled too.

**What was reproduced, and what was not**

| finding | reproduced? |
|---|---|
| Cold-launch restore inert | **Yes.** Scrub after a cold relaunch: baseline `0:00 → 0:00`, fixed `0:00 → 2:15`. |
| Superseded seek | **Not as a user-visible defect** — the verifier established the seeks converge on the newest target. But the regression it predicted *was* observed and fixed (above). |
| Pause during in-flight seek | **No.** Scrub-then-immediately-pause passed on the baseline too — the seek completed before the tap landed. Fixed by code, unverified as a defect. |
| `nextTrackCommand` at end of queue | **No.** `MPRemoteCommandCenter` state lives in another process; XCUITest cannot read it and Control Center is not scriptable. |
| `changePlaybackPositionCommand` on radio | **No.** Same reason, and no radio station is configured on the demo server. |

**Behavioural questions flagged, not decided.** Whether Previous at the start of a queue should
restart the track or step back a track is a product choice — the current restart behaviour is left
as is. Separately, the `changePlaybackPositionCommand` handler returns `.success` before
`performSeek` has run at all, so any seek dropped by the `d > 0` guard (e.g. a track whose duration
has not resolved yet) is falsely acknowledged to the system. Disabling the command for radio removes
the radio case; the general false-acknowledgement remains, and fixing it needs care because the
handler runs outside the main actor and cannot read engine state synchronously.

**Noticed, not fixed (out of scope):** the rest of the internet-radio cluster and the widget
findings, per the brief.

**Unproven:** device. Simulator only.

## 2026-08-28 — Back collapsed the whole navigation stack (T066)

Ethan's recording: playlist → album *Famous* → artist *Puddle Of Mudd* → album *Ubiquitous*, then
one Back landed straight back on the playlist. He guessed it was something small. **He was right —
the fix is deleting five lines.**

**The cause, and it fires on the way IN, not on the way back**

Each `navigationDestination(item:)` carried `.onDisappear { navigate… = nil }`, meant to reset the
binding after the user pops. But **`onDisappear` does not mean "the user went back"** — it also
fires when that destination is *covered by a further push*. So pushing the artist page on top of an
album detail ran the album destination's `onDisappear`, which cleared the **playlist's**
`navigateAlbum`, which popped the album *and* the artist sitting above it. The stack fell back to
the playlist at the moment the artist page appeared.

That is why it looked like "Back destroys the stack": by the time he tapped Back, the intermediate
entries were already gone.

The clear was redundant as well as harmful — `navigationDestination(item:)` owns its binding and
writes `nil` back itself on pop. The proof was already in the codebase: `BrowseAlbumDetailView`'s
*artist* destination never had the manual clear and has always popped correctly.

Removed from all five sites that had it: `ServerPlaylistViews` (album + artist),
`BrowseAlbumDetailView`, `LibrarySongsView`, `LibraryView`. **No new views, no parallel
destinations, nothing added** — which is what he asked for. The comment beside
`detailOnDisappear()` warned about this exact hazard one level up while the destinations below were
doing it; that comment is now corrected so nobody reinstates the clears.

**Reproduced first, on the simulator, as instructed**

Walk: playlist `zz-perf-778` → row ⋯ → Go to Album → album `Diplomatic Immunity` → tap the artist.

- **Before:** the artist tap landed on **`zz-perf-778`** — the playlist. The stack collapsed on the
  forward push, exactly as in the recording.
- **After:** the artist page opens and stays (`The Polish Ambassador`), and its **back button reads
  `Diplomatic Immunity`** — direct evidence the album is still on the stack beneath it.
- **Back pops one level at a time:** back #1 → `Diplomatic Immunity`, back #2 → `zz-perf-778`,
  back #3 → Library. In reverse order, one per tap.

**What I could not automate.** The fourth level — pushing another album from the artist page's
Albums carousel — never happened in the harness: the card reports hittable, but the synthetic tap
lands on the mini player and opens Now Playing instead. That is a test-harness limitation, not the
app: Ethan's own recording shows a human doing that push successfully. So **depth 4 and the
repeated-destination-type case are verified only indirectly**, by the back-button label chain
showing intermediate entries surviving, and by the same-type repeat being what the fix restores
(playlist → album are both `ServerPlaylistDetailView`, and that push now survives being covered).

**Unproven:** device. Simulator only.

## 2026-08-29 — searching a song title in Discover finds the single (T068)

Ethan searched **japanese denim** in Discover and got three artists and nothing else. The single
is in Lidarr's catalog; Vellum never asked for it.

**Why a song title could only ever match an artist name**

`runHybridSearch` had exactly two plugin calls: `acquisition.search(query:)` for tracks, gated on
`supportsTrackSearch`, and `acquisition.searchArtists(query:)`. Lidarr sets `supportsTrackSearch:
false` — **correctly**, it is album-granularity and has no track-search endpoint — so with Lidarr
active the first call was skipped entirely and artists were the only thing a query could hit.
There was no album search anywhere in `AcquisitionProviding` to fall back to.

Flipping `supportsTrackSearch` to true would have been the wrong fix: there is no Lidarr track
search to call, so it would only fire a request that cannot be answered. **It is still false.**

**The fix — ask the album catalog, because a single is a release**

- `AcquisitionProviding.searchAlbums(query:)`, with a **default empty implementation**. Downtify
  (track-granularity) and DroppedNeedle inherit the default and return nothing new.
- `LidarrAcquisitionPlugin.searchAlbums` reuses `albumLookup(term:)` — the same
  `album/lookup` call `enqueue` already resolves a request against, and the same search Lidarr's
  own "Add New Album" uses. Reusing it is what guarantees a row surfaced in Discover is one the
  enqueue path can actually act on. Artist-less rows are dropped (they can neither be requested
  nor matched against the library), deduped by foreign id, capped at 8.
- `AcquisitionManager.searchAlbums` gates on `granularity == .album`, mirroring how
  `search(query:)` gates on `supportsTrackSearch`.
- `runHybridSearch` calls it alongside `searchArtists` — the two are independent round-trips and
  now run concurrently, so this adds no sequential network hop to a Discover search.
- `AcquisitionRelease.asSearchResult` maps a release onto the existing `AcquisitionResult` row, so
  the new rows flow through `hybridRows` scoring, the Request pill, and the detail view with no
  new UI. Subtitle leads with the release kind — "Single · Daniel Caesar".

**Suppression, and where it deliberately does not live**

Release rows are filtered in `runHybridSearch`, against typed `AcquisitionRelease`s, *not* in
`hybridRows`. The generic acquire suppression there compares **track** titles; adding an
album-title rule to it would start hiding a track-granularity plugin's rows for individual missing
songs whose album happens to be on the server. Two filters: a release already on the server
(normalized `title|artist`), and anything scoring 0 against the query — `album/lookup` is fuzzy and
will return loosely related releases that would otherwise sit at the foot of Top Results as noise.
The existing per-row rules in `hybridRows` (server track hit, personal library title index) still
apply on top.

**Verified on the simulator against a stub Lidarr, with a baseline control**

Ethan's Lidarr is not reachable from this session — no URL or API key is stored anywhere I can
read — so a stub serving Lidarr's *wire format* stood in, pointed at by launch arguments
(`NSArgumentDomain`, so nothing the user has persisted was touched). Signed in to the public
Navidrome demo server, as the other passes do.

| | result |
|---|---|
| **Baseline, unfixed code** | Only `artist/lookup` is called. **No `Japanese Denim` row.** The reported bug exactly. |
| **With the fix** | `album/lookup?term=japanese denim` is called; the row appears, labelled **"Single · Daniel Caesar"**, with a Request pill. |
| **Artist priority** | Searching `Daniel Caesar` returns album rows *and* the artist row, artist first (`minY` compared, not eyeballed). No regression. |
| **No duplicate** | `Can I Have Your Love Tonight` is a real one-track album on the demo server; the stub returned a Lidarr row for the same title + artist and **no Request row appeared**. |
| **Enqueue** | Tapping Request produced the full contract: lookup → `POST /api/v1/album` with **`monitored: true`** → re-resolve → `POST /api/v1/command AlbumSearch albumIds=[…]`. |

**What that does and does not prove.** The enqueue line above is verified **at the wire level
against the stub** — the app sends Lidarr the right calls in the right order with the album
monitored. It is **not** verified against Ethan's real Lidarr, and "the album appears in Lidarr as
monitored" has therefore not been observed on a real instance. The same caveat covers the brief's
claim that `album/lookup` resolves `japanese denim` to the Daniel Caesar single on the live server:
the brief verified that against `/api/v1/search`, and `album/lookup` is the album half of what that
endpoint dispatches to, but I could not confirm it on the live instance.

**Unproven:** device behaviour. The device build is clean; the interaction was exercised on the
simulator only.

## 2026-08-29 — rank the thing he searched for above loose artist-name matches (T069)

T068 made the single findable. Using it on device, Ethan searched `japanese de` and got:

1. Japanese Deejay (Artist) 2. Japanese Death Machine (Artist) 3. DJ.Deplorer (Artist)
4. **Japanese Denim — Single, Daniel Caesar** 5. Japanese Death Machine (EP)
6. The Fame Monster (Japanese Del…) 7. The Fame Monster (Japanese Del…) *(duplicate)*
8. 1999 Japanese denim

"nice but requesting then is a bit finicky" — three irrelevant artists to scroll past.

**Defect 1 — the artist bump was flat, so a weak artist beat a near-exact title**

Every artist row scored `relevanceScore(…) + 1.0`, unconditionally. `DJ.Deplorer` matched the
query **not at all** — relevance 0 — and the bump alone (1.0) put it above "Japanese Denim" (0.85,
a title prefix). Two things were wrong and both had to change:

- **An artist row was scored on the *title* scale.** `relevanceScore(title: name, artist: name,…)`
  takes the max of both scales, so an artist name collected a title-tier score (0.85 for a prefix)
  for what is an artist match — and then took the bump on top. Artist rows now score on the artist
  scale (0.6 / 0.5 / 0.35), the same tiers `relevanceScore` uses for a row's artist field. Those
  tiers are now named constants shared by both, so they cannot drift apart.
- **The bump is graded, not flat.** Exact name → `+1.0`; prefix → `+0.25`; substring or no match →
  **nothing**. The Apple-Music intent the flat bump was reaching for is preserved exactly where it
  belongs: an exact artist name still wins outright, even against an album of the same name.

The trade-off is deliberate and stated in the code: with a *partial* query an eponymous album can
now edge out its own artist (`deft` → the album "Deftones" at 0.90 over the artist at 0.75).
Widening the prefix lift to cover that is precisely what would put "Japanese Deejay" back above
"Japanese Denim", which is the bug being fixed.

**The part the first attempt got wrong.** With only the above, the observed order was
`Japanese Death Machine (EP)` **then** `Japanese Denim`. Both are exactly a title prefix of
`japanese de`, both scored 0.85, and nothing else separated them — so the wanted row still came
second. Added `matchCoverage`, used **only as a tiebreak** so it can never move a row across a
match tier: the query covers 11 of "Japanese Denim"'s 14 characters and 11 of "Japanese Death
Machine"'s 22, and the tighter match wins. That is what actually put the row first.

**Also fixed while in the comparator:** `sorted(by:)` is not stable, and `hybridRows` is
recomputed on **every body evaluation**, so two equally-ranked rows could swap places between
passes. There is now a final deterministic key (decorated into the tuple, so the comparator does
no work per comparison).

**Defect 2 — duplicate release rows**

Server albums, plugin release rows, and the server album list *itself* all feed this list and
nothing compared them across sources — and Navidrome will return two editions of one album, or one
album scanned twice. `hybridRows` now emits **one row per normalized `title|artist`**, never per
id, because two sources agreeing on a release is exactly the case where the ids differ. The key is
recorded even for albums that are *not* emitted (already in the personal library), so a plugin row
offering to acquire one is still suppressed. T068's server-album suppression in `runHybridSearch`
is **removed**, since this replaces it and covers more; the relevance floor stays there, because
that one is about the fuzziness of `album/lookup` rather than about the feed.

**Observed orders — measured on the simulator, not predicted**

Stub Lidarr again (Ethan's is unreachable from this session), loaded with the same candidate set
his query returned, including `DJ.Deplorer` for its zero-relevance artist row. Signed in to the
public Navidrome demo server. The harness dumps every visible label sorted by screen position and
scrolls once for what is below the fold, so these are read off the screen:

- **`japanese de`** → **Japanese Denim (Single · Daniel Caesar)** · Japanese Death Machine (EP) ·
  Japanese Deejay (Artist) · Japanese Death Machine (Artist) · 1999 Japanese denim ·
  The Fame Monster (Japanese Deluxe Edition) · DJ.Deplorer (Artist). The wanted row is **first**;
  DJ.Deplorer went from 3rd to last; nothing appears twice.
- **`deftones`** → **Deftones (Artist)** · Deftones (Album) · White Pony. Artist first, ahead of
  the album of the same name.
- **`dafto`** → Daft Punk (Artist). The partial name still resolves.
- **`Can I Have Your Love Tonight`** (a real one-track album on the demo server, with the stub
  offering the same title+artist) → one server row, **no Request row** — T068's rule still holds
  after being moved into `hybridRows`.

**Not reproduced: Ethan's actual duplicate.** The demo server has 50 albums and no duplicated
title+artist pair, so a server-vs-server duplicate could not be staged; his own library is what
produced it. Three mechanisms could give two "The Fame Monster (Japanese Del…)" rows — two server
albums with the same title+artist (**fixed**), two plugin rows for one release (already collapsed
by `requestKey` before this pass), or a server row and a plugin row whose titles genuinely differ
once normalized, e.g. "Deluxe Edition" vs "Deluxe Version" (**not fixed** — by the stated rule
those are two different releases). If it recurs, the untruncated titles of both rows are what
distinguish these.

**Unproven:** device. Device build is clean; the interaction was exercised on the simulator only.

## 2026-08-29 — a finished request shows up without relaunching (T070)

"requesting them gets to 100% then does nothing until i refresh the app". This, not the ranking,
was what "finicky" meant.

**Both suspected defects checked against the running server, not just read**

- **Defect 1 — the bar hit 100% on *request* — CONFIRMED, and worse than described.**
  `LidarrAcquisitionPlugin.enqueue` ended on `progress?(1.0)` after merely adding the album and
  triggering `AlbumSearch`. `AcquisitionManager.enqueue` then applied its own floor
  (`max(job.progress, 0.4)`) and `status: .downloading`. The part the brief did not have: even
  once real queue progress arrived, `reconcile` merged it as
  `max(current.progress, match.progress)` — **ratchet-only** — so the fake 100% permanently
  masked the true fraction. The one guard against exactly this was gated on
  `match.files?.isEmpty == false`, i.e. plugins that report per-file progress, which is precisely
  the set Lidarr is not in.
- **Defect 2 — "nothing reloads the library on completion" — WRONG as stated.** The reload exists
  and is correct: `AppModel.handleAcquisitionJobFinished` triggers a server scan and retries
  `searchCatalog` for ~60s, then adds the result to the library. It never *ran*. `onJobFinished`
  is fired from `reconcile`, which only ever looks at jobs it can find in the server snapshot — and
  **a finished Lidarr download disappears from `/queue` the moment it imports**. No match, no
  terminal status, no callback. A third problem falls out of the same knot: the job stayed
  non-terminal forever, so `hasActiveWork` stayed true forever and the 2.5s poll loop ran for the
  life of the process. The battery cost the brief warned against was already there.

Also found while reading the live queue, which the brief could not have known: **`bestMatch` could
not match a Lidarr download at all.** A queue row's `title` is the indexer's release name
("Daniel.Caesar-Japanese.Denim-SINGLE-WEB-2016-ENRiCH"), and matching compares whole normalized
title strings, so it never overlapped the album title. The nativeIds could not match either
(`lidarr:<foreignAlbumId>` vs `lidarr-queue:<id>`).

**The fix**

- `enqueue` reports `acceptedProgress` (0.1) instead of 1.0 — placing a request is not a transfer.
  The manager's post-enqueue state is `.queued` at the reported progress, not `.downloading` at 0.4,
  and `applyProgress` no longer flips status on a fraction.
- `reconcile` takes the server's fraction **verbatim** instead of ratcheting.
- The queue is fetched with `includeAlbum`/`includeArtist`, and each row is stamped with the same
  `lidarr:<foreignAlbumId>` native id `enqueue` returns — so a request can be followed into the
  queue. Rows now carry the real album title and artist instead of a scene string, which the
  Settings activity list gets for free.
- **Completion is detected by disappearance, carefully.** Absence alone proves nothing: before a
  release is found the job is not in the queue *yet*, and a failed grab is removed just like a
  successful one. So a conclusion is only drawn once the job has actually been seen in the queue,
  after two consecutive absences, and then the plugin is *asked*: new
  `AcquisitionProviding.isRequestSatisfied(nativeId:)`, which Lidarr answers from the album's
  `statistics.trackFileCount`. Files on disk, not merely gone.
- `trackedDownloadState` is now read: a download that transferred and then failed to import reads
  `status: completed` and **stays in the queue in that state indefinitely**. Those were previously
  shown as "importing" at 100% forever — the same complaint wearing a different hat. They now
  report as failed. See the correction below for what the live server actually looks like.

**Polling lifetime, stated plainly.** Unchanged at 1 Hz while a progress UI is on screen
(Settings → Music Requests holds `liveRefreshClients`). Otherwise it backs off 5s → 10s → 20s → 30s
and **stops entirely after 20 minutes**, leaving the job untouched. `refreshOnForeground()` — wired
to the existing `scenePhase` hook in `RootView` — does one refresh when the app returns to the
front and restarts the loop only if work remains. There is no permanent high-frequency poll; the
one that existed before this pass is gone.

**Observed end to end against the live Lidarr**

Real request, placed through Discover in the app, for `Get Out My Face aka Bad Kitty` (Garbage) — a
2-track release his Lidarr had monitored and missing. The app ran on the simulator pointed at his
real Lidarr; a second process polled Lidarr directly every 15s as an independent witness.

| time | app row | Lidarr itself |
|---|---|---|
| 16:32:01 | request tapped | absent from queue, files 0/2 |
| 16:32:18 | **10%** | — |
| 16:32:33 | — | in queue, downloading, **33.5%** |
| 16:32:52 | **34%** | 33.5% |
| 16:33:35 | 34% | 33.5% |
| 16:33:50 | — | **gone from queue, files 2/2** |
| 16:34:34 | progress gone, row back to **Request** | — |

The app tracked the real transfer (34% against Lidarr's 33.5%) instead of sitting at 100%, and the
job reached a terminal state **~30–45s** after the download actually finished — the row reverting
to "Request" is `finish()` retiring it, which only happens after `onJobFinished` has fired.

### The device leg ran, and it FAILED

Later the same evening the phone was unlocked and the last hop was driven on it, against his own
Navidrome and his own Lidarr. **It did not pass.** Recorded plainly because the simulator result
above, read alone, overstates what this pass achieves on his actual server.

Request placed from Discover on the phone at **17:10:32** for `There Was a Light Here bonus cuts`
(Demon Hunter), monitored and missing, 0 of 2 files.

| time | app row on the phone | Lidarr itself |
|---|---|---|
| 17:10:32 | request tapped | absent from queue, files 0/2 |
| 17:10:42 | **10%** | — |
| 17:12:33 | **10%** | **files 2/2 — downloaded and imported** |
| 17:24:33 | **10%**, unchanged for 14 minutes | 2/2 |

So on his server the row **never tracked the download and never completed**. The 100% lie is gone;
what replaced it is a **10% lie** — `acceptedProgress`. In user terms that is not a fix: he traded
a bar stuck at the top for a bar stuck near the bottom, and the track still does not appear.

**Why, and it is a flaw in this pass's design, not a server quirk.** Completion here is inferred
from a job *leaving* the queue, which by construction requires the app to have **seen it in the
queue first** (`observedInServerQueue`). If it is never seen, `noteAbsentFromQueue` returns early
forever and the job can never resolve. Two ways that happens on his setup, and the evidence does
not separate them:

- **The queue is paginated and the app only reads page 1.** `downloadQueueRecords` asks for
  `pageSize=100`; his queue holds **133** records. Thirty-three are invisible to the app, and
  nothing guarantees a new grab lands in the first hundred.
- **The item may never enter the queue at all** — grabbed and imported inside one poll gap, or
  never grabbed. The app then has no backend state to reflect and invents none.

Both are the same underlying fault: **the client only resolves a request it happened to observe
mid-flight, instead of asking the backend what the state actually is.** That is the spine of T071.

The run was also cut short by buildbot's 900s watchdog, so the final library-scope check never
executed — moot, since the row never completed.

**Also unverified:** the failure branch. No request failed during the run, so
`isRequestSatisfied` returning false — the "left the queue without producing files" path — was
exercised only by reading.

**Noticed, not fixed:** Discover's title-only search feeds the query straight to `album/lookup`, so
a generic title finds the wrong artist entirely ("STATICA", "Crazy Rainbow" both come back as
unrelated acts). Distinctive titles are fine. Separate problem from this pass.

**Build:** device build clean via buildbot — `errSec=0 errors=0 installed=yes`. `launched=no` is
the locked phone refusing the launch, not a build failure.

### Correction to the import-failure figures above

The "52 of 133" in the first write-up of this pass was **wrong**, and wrong in a way worth naming
so it is not repeated: it counted `trackedDownloadState` over **one page** of `/queue`
(`pageSize=100`) and then reported that count against the **full** `totalRecords` of 133. A
partial numerator over a complete denominator is not a statistic.

The real picture, from a full read of the queue:

- **97 completed transfers**, of which **78 `importFailed`** and **19 `importPending`**.
- **Zero completed transfers have imported.**
- The dominant errors are **match failures** — unmatched tracks, missing tracks, album match around
  **47%** against an **80%** threshold. `Not enough free space` is present but secondary.

That is a server-side problem, not an app one, and it is **deliberately not addressed here** — it is
with Ethan. It does bear on this pass in one way worth recording: T070 makes those rows report as
failed instead of sitting at "importing, 100%" forever, so the condition becomes visible in the app
rather than looking like the bug this pass fixed.

## 2026-08-29 — the request UI reads Lidarr and nothing else (T071)

> "let's make this a complete shell on the front end that only listens to what the back end has
> to say" — and, narrowing it: "make vellum 100% accurate on progress reporting at all times".

### THIS IS UNVERIFIED

**No test was run against this code — no device run, no simulator run, no XCUITest — at Ethan's
explicit instruction ("k then no testing").** It compiles cleanly and the reasoning behind each
state is set out below, but nothing here has been observed working. Do not read the rest of this
entry as evidence that it behaves correctly; read it as what the code intends. The first person to
request something will be the first to find out.

What *was* verified, before that instruction and against his live Lidarr, is the **diagnosis** —
the API readings quoted below are real.

### Why the #5012 workaround didn't hold

Diagnosed from the live server, not guessed:

- Album 76243 came out of the request `monitored: false`, and its artist row was stamped
  `added: 21:04:24Z` — **the same second** `RefreshArtist` completed. The old code wrote the
  monitor flag once, with `try?`, straight into that window. A refresh rewrites album rows from
  metadata and takes the flag back out.
- The identical PUT, issued later with no refresh in flight, **stuck first time**. So the write is
  fine; the timing was not. It is a race, not a broken call.
- `statistics.trackCount: 0` was a *consequence*, not a separate fault: monitoring 76243 flipped it
  straight from **0 to 2**. An unmonitored album reports no tracks, so the search had nothing.

Now: wait for any in-flight `RefreshArtist` for that artist, then write-and-**verify** the monitor
flag in a loop, and throw rather than search into the void if it will not hold.

**One correction to the brief.** It says nothing was ever grabbed. History for album 76243 shows
`grabbed` at **21:06:06** — during his request — and again at 21:31:43 during my check. What is
true is that **nothing ever entered the queue**: I read all 133 records across every page and found
no row for it, and no files exist. His download clients include Soulseek and a YouTube client,
which take a grab without reporting a queue row. That distinction is why the new state machine
treats "grabbed but not queued and no files" as its own case rather than as progress.

### Every UI state, and the Lidarr field it comes from

If a state is not in this table it cannot be rendered.

| UI shows | Derived from |
|---|---|
| `Complete` | `album.statistics.trackFileCount > 0` |
| `Downloading` + **% bar** | queue row `size` and `sizeleft` → `1 - sizeleft/size` |
| `Downloading`, no bar | queue row present, `status == downloading`, but `size` absent |
| `Queued` | queue row present, status not downloading/completed |
| `Importing` | queue row `trackedDownloadState ∈ {importPending, importing}` or `status == completed` |
| `Failed` | queue row `trackedDownloadState ∈ {importFailed, failedPending, failed}`, or `status ∈ {failed, warning}`; message from `errorMessage` |
| `Failed` (stale grab) | newest `history` `grabbed` older than 2h with no queue row and no files |
| `Searching` | a `command` named `AlbumSearch` whose `body.albumIds` contains this album, `status ∈ {queued, started, running}` |
| `Not found` | that command has finished and `history` shows no `grabbed` since its `started`; detail is the command's own `message` |
| `Nothing happening` | album exists, no queue row, no running search, and either a grab with no queue row, or no search on record at all |

The percentage is the **only** number displayed, and it exists in exactly one branch, computed from
two fields Lidarr sends.

### Making an invented value unrepresentable, not merely absent

`AcquisitionJob.progress` is now `Double?`. That is the whole mechanism: while it was a plain
`Double`, every construction site had to supply *something*, and what went in were numbers nobody
measured — `0.05` on enqueue, a floor of `0.4`, `1.0` the moment a request was accepted, `0.4` for
a running Lidarr command "so the bar looks busy". Each reached the screen as a percentage.

- **The progress callback is deleted.** `AcquisitionProviding.enqueue` no longer takes one. All
  three plugins used it identically — to report progress through *placing a request*
  (0.05 → 0.5 → 1.0), which transfers nothing. There is no longer a channel through which a plugin
  can push an unmeasured fraction.
- **`AcquisitionManager.applyProgress` is deleted.** The manager has no setter for a fraction.
- **No completion constant.** `.completed` carries no `1.0`; "complete" is a status.
- **No zero fallbacks.** Lidarr with no `size`, and DroppedNeedle with no `progress_percent`, both
  yield `nil` rather than 0 — "we don't know" and "nothing has transferred" are different facts.
- **No interpolation or animation.** Nothing animates the bar between values; it renders the
  current fraction or is absent.

**The honest test — can any path still produce a progress value the backend did not supply?** I
believe not, and here is the whole remaining set of writers so it can be checked rather than taken
on trust: `Lidarr.activeJobs` (`size`/`sizeleft`), `Lidarr.requestState` (same, or nil),
`Downtify.activeJobs` (`job.progress` from its queue endpoint), `DroppedNeedle.activeJobs`
(`progress_percent`, or nil), and the manager copying an existing value forward unchanged. Every
other site writes `nil`. The one thing I would flag for a reviewer: `AcquisitionFileProgress`
still holds a non-optional `Double`, but nothing anywhere constructs one, so no value can reach the
screen through it.

### The other three defects

- **"Found nothing" now exists** as a terminal state with a **Try Again** action, and terminal
  unhappy rows are no longer auto-retired after 1.5s the way `.done` is — dropping them would put
  the row back to a plain "Request" button and tell the user nothing, which is where this started.
- **Recently Searched** no longer stores request rows, *and* filters out ones already saved on
  device (`RecentSearchEntity.isUnnavigable`). Those were `primaryId: "acquire:<id>"` with no album
  id, which built a stub `Track` with `albumId: ""` and rendered a page titled "Album" with
  "Album not found" and a live Play button.
- **The artist in a request row is tappable** and routes to the artist page. The second line was
  one baked string ("Single · Daniel Caesar"); the kind and the artist are now laid out separately,
  which is what makes a tap target possible.

**Queue paging** is fixed as instructed: all pages are read, not the first 100 of 133.

### Defect 5, confirmed with a caveat

Duplicates on the artist page are handled — but **not by T069**, which only touched Discover's
`hybridRows`. `ArtistViewModel.applyDiscography` has always matched plugin releases against server
albums by title key and dropped the collisions. What is still *not* deduplicated there is one
server album against another with the same title and artist. If duplicates reappear on an artist
page, that is the case, and it is a different fix from T069's.

**Not addressed, per his explicit deprioritisation:** the YouTube/Tubifarry path failing silently,
the stuck import backlog and Lidarr's match strictness, metadata profiles, duplicate artist entries.

### T071 follow-up — the last non-optional fraction

`AcquisitionFileProgress.progress` is now `Double?` as well, closing the one hole named in the
entry above: the per-file type still held a plain `Double`, so the "no invented progress" guarantee
held there only because nothing constructs one. That is a guarantee by absence, and Ethan's
instruction was structural — the interface itself has to make it unrepresentable.

Two render sites in the Settings activity list follow the same rule as the job row: a bar and a
percentage only when there is a fraction, the phase word otherwise. **No behaviour change today**,
since nothing builds an `AcquisitionFileProgress`; the point is that the first plugin to adopt
per-file reporting cannot reintroduce the bug by accident.

Still UNVERIFIED, on the same terms as the entry above — this compiles, and has not been run.

### T071 follow-up — nothing polled the backend on a cold launch

`onChange(of: scenePhase)` fires on a *change*, not on the initial value, so after a fresh start
the acquisition backend was never asked anything until the user placed a request or opened
Settings → Music Requests. A download that completed while the app was closed went unnoticed until
one of those happened — against "accurate at all times" for the one moment the user is most likely
to be checking.

The existing launch `.task` now also calls `refreshOnForeground()`, and a new
`onChange(of: app.isSignedIn)` covers the case that task misses: at launch `isSignedIn` can still
be false, and there is no backend to ask until it flips.

No new polling behaviour — this reuses the same time-boxed path as returning to the foreground, so
the backoff and the 20-minute unattended budget still apply. UNVERIFIED, not run.

### T071 follow-up — requests survive a relaunch

`AcquisitionManager.jobs` was in-memory only, so a relaunch forgot every request. A row that had
settled on **Not found** or **Failed** came back as a plain **Request** button, as though nothing
had happened — and because Recently Searched no longer stores request rows (correctly; they
navigated to a dead page), between the two changes a failed request left **no trace anywhere in the
app**. That combination was introduced by this pass, so this restores recoverability rather than
adding a feature.

Persisted the same way as ``ScrobbleStore``: JSON under a `UserDefaults` key, loaded in `init`,
written from a `didSet` on `jobs` so a future mutation site cannot forget to save. Five types
gained `Codable`; `AcquisitionJobSource` also gained a `String` raw value so it round-trips by name
rather than by declaration order.

Deliberate limits:

- **App-issued jobs only.** Server-side activity is re-fetched from the plugin each poll and would
  be stale the moment it was written.
- **`.done` is not kept.** It retires itself after 1.5s, and the track it produced is the record.
- **Capped at 50**, trimmed by sorted key. `AcquisitionJob` carries no timestamp, so that ordering
  is arbitrary — deterministic, but arbitrary. Giving it a timestamp would have meant threading a
  field through every construction site and would have changed `Hashable` equality, which the
  reconcile paths use to decide whether to republish; not worth it for a cap nobody should reach.

Restored jobs are re-resolved rather than trusted: non-terminal ones are picked up by the first
poll after launch (which now happens — see the cold-launch entry above) and rewritten from
`requestState`. A restored **terminal** row is left as it is; if the album later does arrive, the
acquire row is suppressed by the library filters anyway, so a stale "Not found" cannot outlive the
thing it describes.

UNVERIFIED, on the same terms as the rest of T071 — this compiles and has not been run.

## 2026-08-29 — swipe-back on artist/album reached via Go to Artist / Go to Album (T072)

Ethan: "artist/album view when tapping go to artist/album cannot be swipe dismissed like playlist
views."

**The cause, found before changing anything.** Neither of the usual suspects: nothing is presented
as a sheet (all of these are pushes on the same `NavigationStack`), and there is no
`navigationBarBackButtonHidden` anywhere in the codebase. It is the cover-zoom transition's gesture
bookkeeping.

`CoverZoomNavigationDelegate.syncGestures()` switches UIKit's pop recognizers **off** while a zoomed
detail is on top. That is deliberate and correct — a custom animator cannot be driven by the
built-in recognizer, so `installEdgePan` supplies our own for that screen. The defect is *when* it
was recomputed: only from the zoom detail's own `viewWillAppear` / `viewDidAppear` /
`viewDidDisappear`, via `install(on:activeID:)` and `clearActiveID(on:id:)`.

An **ordinary** push landing on top of a zoom detail fires none of those. "Go to Album" / "Go to
Artist" from a song menu inside a playlist is exactly that: a plain SwiftUI push, no
`pendingPushID`, so `animationControllerFor` declines and it is an ordinary slide. The gesture state
was therefore left as the detail underneath had set it:

- UIKit's pop recognizers still `isEnabled = false`, from when the zoom detail was on top.
- Our own `edgePan` declining, because `edgePanMayBegin` requires
  `topViewController === customDetailController`, which is no longer true.

Both sides decline, so an edge swipe on those screens did nothing whatsoever. The back button was
never affected, because a programmatic pop goes through `popViewController` and never consults a
gesture — which is why it looked like a gesture bug rather than a navigation one.

Playlist views swipe correctly because the playlist detail *is* the zoom detail: our edge pan is
armed and driving on that screen.

Also worth noting for anyone reading the lifecycle: `viewDidDisappear` only calls `clearActiveID`
when `isMovingFromParent`, so being **covered** by a further push deliberately leaves the zoom
detail's state armed. That is right for the detail itself and is precisely why the screen on top
inherited a gesture configuration meant for something else.

**The fix** is one call: `syncGestures()` from
`navigationController(_:didShow:animated:)`, the hook that fires on every push and pop. That is the
invariant the enable/disable rule assumed all along — the state is now recomputed whenever the top
view controller changes, instead of only when a zoom detail appears or is popped. It is cheap and
idempotent: the touch-observer and edge-pan installs are both guarded, and the enabled flags are
only written when they differ.

No behaviour change for a zoom detail (`didShow` with it on top computes the same "off" state the
detail's own appear callbacks already set), and none for the back button or for ordinary pushes
elsewhere, which were already in the enabled state this now recomputes.

**UNVERIFIED:** not run. This is a UIKit gesture interaction, so it needs a real swipe on device to
confirm — the reasoning is traced through the source above but no swipe has been performed against
this build.

## 2026-08-30 — swipe-back on button-pushed screens, and the two-layer CPU baseline (T19)

Branch `t19-swipe-fix`, off **dev** at `1eaf0dc`, in its own worktree. Two things deliberately
together: the swipe fix, and the missing baseline that this dev-based build is the only way to get.

### The swipe fix, and why it is one line

`gestureRecognizer(_:shouldBeRequiredToFailBy:)` answered **`true` unconditionally** for our edge
pan against every other recognizer — one global constant. The permission it gates,
`edgePanMayBegin`, is **three per-screen predicates**, false on any screen that is not our zoom
detail.

So on an artist or album page reached by a button, UIKit's pop recognizer was required to wait for
an edge pan that would then decline the touch, and our pan declined it too. **Both owners decline,
nobody handles it**, and the swipe does nothing. The back button was never affected, because a
programmatic pop consults no gesture at all.

The evidence that fixes the shape of it beyond argument: a playlist opened by tapping its cover
sits **directly on top of** an artist page reached by a button, on one navigation stack, and *the
playlist swipes while the artist page does not*. Only a per-touch, per-screen answer can differ
between two adjacent screens. That rules out every stack-global explanation, including the
non-animated-push theory — a `willShow animated=` census on device read 852 true / 38 false, and it
is moot either way.

The fix is **subtractive**: gate that answer on `edgePanMayBegin`, so our pan only conscripts other
recognizers on screens where it will actually drive the pop. It deliberately does **not** widen
`edgePanMayBegin` to more screens, which would hand them a non-interactive instant pop rather than
a swipe-to-dismiss.

The stale comment at `ArtistPageView.swift` is corrected in the same change. It claimed the
installer is a no-op for programmatic pushes; only the *animation* is. The installer still puts the
delegate proxy and the shared edge pan on the navigation controller however the page was pushed,
which is exactly how a button-pushed page came under a gesture arbitration meant for another
screen — and that wording is what made an earlier attempt look correct on paper.

### The baseline half

`PlaybackCPUSampler.swift` and `PlaybackTapLog.swift` are backported here **byte-identical** to the
tap branch's copies (verified by diff). An A/B is worth nothing unless both sides are measured by
the same instrument. Only the wiring differs, because it must: there is no tap on this branch, so
`callbackCountProvider` stays nil and the callback columns log `n/a` — the correct reading for a
build with no taps, rather than a zero pretending to be a measurement.

This build is therefore the **only** source of a device CPU figure for the old two-layer
AVPlayer + AVAudioEngine architecture. Until it runs on the phone, the tap branch's
~0.9–1.4 CPU-s/min has nothing to be compared against, and no claim of an improvement is supportable
in either direction.

**Known limitation of the metric, on both branches:** the sampler measures whole-process CPU, so it
includes launch, UI and artwork work. The figure inflates to 10–13 CPU-s/min while the app is being
interacted with. A fair comparison needs a quiet foreground run on both sides, or a sampler scoped
to the audio-active window.

**UNVERIFIED:** builds clean; the swipe fix has not been tested on device, and no baseline numbers
have been captured yet.

## T068 — a diagnostic line to say *why* the edge swipe never becomes a pop

This change adds logging only. It fixes nothing, and it is not meant to.

Two hypotheses for the dead swipe on button-pushed screens have already been built and tested on
device, and both were wrong. A third — that our shared edge pan sits on the navigation
controller's view on every screen in the stack and takes the edge touch on screens it will never
serve — is inferred from the shape of the last device log, not measured. Rather than build a fourth
guess, this adds one snapshot that separates the only two remaining candidates:

- `sysEnabled=false` — something is still switching UIKit's pop recognizers off stack-wide, and the
  touch simply has no other owner once ours declines.
- `sysEnabled=true` — UIKit's recognizer is live and is losing the touch to ours, which makes our
  edge pan's *scope* the problem.

`gestureStateSnapshot()` prints every pop recognizer on the navigation controller's view (both
parallax recognizers, not just the one `interactivePopGestureRecognizer` vends) with its enabled
flag, state and touch count; our own edge pan the same way; and `edgePanMayBegin` broken out into
the individual predicate that is false when it is false. It is emitted from two places so they can
be read against each other: `syncGestures`, positioned deliberately *after* the enable/disable loop
and after `installEdgePan` so it reports settled state rather than state on the way in, and the
instant our edge pan declines a touch (`shouldBegin=false`, and the `.began`-guard path).

Everything is `#if DEBUG`, inside the existing `DebugUIRemote` log, alongside the lines the last
device session was read from.

**STATUS: MEASURED 2026-08-30 02:11 on device (build 01:19:21).** The answer is
`sysEnabled=true`: UIKit's pop recognizers are **enabled** on the failing screen and are **losing
the touch to ours**. Raw decline line:

    edgePan shouldBegin=false sysEnabled=true
      sys=[_UIParallaxTransitionPanGestureRecognizer/en=true/st=0/n=0]
      parallax=[.../en=true/st=0/n=0, .../en=true/st=0/n=0]
      ours=[UIScreenEdgePanGestureRecognizer/en=true/st=0/n=1]
      mayBegin=false whyDetail=detail-not-top whyDepth=2 whyCoordinator=false

The decisive field is not `en=` but `n=`. All three of UIKit's recognizers are enabled and hold
**zero** touches; ours holds **one**, then declines. Nothing was switched off stack-wide — our pan
simply takes the edge touch first on a screen it will never serve, and no one else ever sees it.
The "scope" hypothesis is confirmed, and the fix is subtractive as expected.

The working swipe is the exact inverse and validates the instrument: `sysEnabled=false`
(deliberately, because our zoom detail is on top), `ours=.../n=1`, `mayBegin=true`.

Second, narrower finding, **measured but not yet acted on**: the predicate that is false on the
failing screen is `whyDetail=detail-not-top` — `customDetailController` is non-nil but is not the
top view controller. The failing screen was pushed with `willShow animated=false` and **no
`ask op=1` at all**, so the delegate never saw that push and the detail pointer was left pointing at
the previous screen. That is the mechanism behind the stale scope, and it is where the fix belongs.


## T072 — stop our edge pan owning touches on screens it will never serve

### What the failing screen turned out to be

`1Af6e6mVOiolKW6gdYFrvc` resolves, from the log itself, to an **album detail page** — "Better
Weather" by With Confidence — opened by a **deep link from the Now Playing player** ("Go to Album"):

    NP-NAV enter route=album(AlbumSummary(id: "1Af6e6mVOiolKW6gdYFrvc",
      title: "Better Weather", artist: "With Confidence", ...)) isPresented=true

So the capture is **not** the artist page. It is the sibling case of the same bug, reached the same
way ("Go to Album" rather than "Go to Artist"), which makes the defect a property of *how the screen
was pushed*, not of which screen it is.

### Why that push behaves differently

`pendingPushID` is set only by the touch observer, from a touch that lands on a registered cover
cell. A deep link has no such touch, so `pendingPushID` is nil, `CoverZoomPushAnimationFix` does not
force the push animated, and UIKit skips `animationControllerFor` entirely for a non-animated push.
That callback is the **only** place `customDetailController` is assigned — so it stays pointing at
the previous screen. Meanwhile the pushed detail's own installer still sets `activeCustomID`. The
two disagree, which is exactly what `whyDetail=detail-not-top` reported.

The log shows both halves of the contrast in one run: the two artist-page pushes each logged
`COVERZOOM forced animated push`, got their `ask op=1`, and swiped correctly; the deep-linked album
logged no forced-animated line, got no ask, and did not.

### The fix, and why this one and not the other

`CoverZoomRegistry.style(for:)` already documents the intended behaviour for an id nobody
registered: the delegate declines the push and the pop, and the screen "lands on UIKit's ordinary
slide — with its ordinary edge-swipe pop". That contract was correct in the delegate and defeated in
the responder chain, because our edge pan is installed once on the navigation controller's *view*
and therefore sits on every screen in the stack. It took the edge touch, declined it, and UIKit's
recognizer never saw the touch at all.

So the fix is to **scope the recognizer**, not to repair the stale pointer. `syncGestures` now sets
`edgePan.isEnabled` from a new `edgePanServesTopScreen` — the same per-screen predicates as
`edgePanMayBegin` minus the transient "nothing is mid-transition" test, since that decides whether a
*touch* is timely, not whose *screen* it is. A disabled recognizer is offered no touches, so UIKit's
pop recognizer receives them.

Repairing `customDetailController` instead was rejected deliberately. It points our pan **at** those
screens, which is additive rather than subtractive, and it would not even work: a deep-linked screen
has no registered cell, so `hasCellTarget` is false and the pop branch declines regardless — landing
back in "our pan owns the touch and then refuses it", which is the bug.

`edgePanMayBegin` is **not** widened; it is now expressed in terms of the new predicate and keeps the
coordinator test. The `shouldBeRequiredToFailBy` gate is untouched.

The enable/disable is guarded on `edgePanPopInFlight` and the pan's state, because setting
`isEnabled = false` mid-recognition cancels the gesture outright, which would abort an interactive
pop our own pan is driving.

### Verification instrumentation

`COVERZOOM edgeSample` sampled only UIKit's recognizers, which cannot show a handover. It now samples
ours too, tagged `OURS`, so one line carries both halves of the acceptance test: on a screen we do
not serve, `OURS/en=false/.../n=0` while a parallax recognizer picks the touch up.

**STATUS: compiles clean for iOS Simulator; NOT yet verified on device.** Acceptance is a device log
showing `OURS` at `n=0` on a previously-failing screen with UIKit's recognizer taking the touch, plus
a playlist opened by tapping its cover still zooming and still swiping out. A visual impression is
not acceptance.

### T072 follow-up — instrumentation only, the fix is untouched

**Correction to my own earlier claim:** the `edgeTouch` recognizer census was never truncated. It
walks the full hit-test chain to the window and logs 2461–3602 bytes per line; a `cut -c1-400` in
my own reading truncated it. No widening was needed and none was done.

Reading the complete census showed the real gap. It is taken **at touch-down**, where every
recognizer is `.possible` with no touches by definition — so it can say who was *present* but never
who *won*. `edgeSample` then re-read only the pop recognizers plus ours, which answered "did UIKit
take it?" (no) and could not answer "then who did?".

Two changes, both diagnostic:

- the touch-down census now carries `n=` (touch count) alongside `en=`/`st=`;
- `edgeSample` keeps the touch-down chain and re-reads **all** of it at +120/+260/+420 ms, printing
  `chain=<count> active=[…]` — only the recognizers that left `.possible` or hold a touch.

A recognizer anywhere else in the chain (SwiftUI's collection view, a swipe-action pan, a
window-level system gate) is invisible to the old sample and would show up in `active=`.

**An empty `active=` is itself a result**, and worth stating in advance so it is not mistaken for a
broken probe: it would mean nothing in the chain claimed the touch, and the swipe is being lost
before gesture recognition rather than to a competing recognizer.

The `CellHostingView` recognizer remains a **lead only**. It is deliberately not being fixed against
until the census names an actual owner — it has the same standing as the three hypotheses that were
built and disproven.

**STATUS: compiles clean; not yet on device.** Still open and treated as a real risk: the cover-tap
zoom control has never been exercised under T072. Our pan is disabled whenever
`customDetailController` is nil, so that path could be broken by the fix and nothing in the runs so
far would have revealed it.

## T073 — the two defects the census named

### Defect 1 — our pan accepted where the delegate would decline

`edgePanServesTopScreen` now also requires `CoverZoomRegistry.hasCellTarget(for:)`, which is the
last condition of the delegate's pop branch. Acceptance and the delegate now agree.

Before, on a deep-linked screen where `customDetailController` still happened to point at the top
view controller, our pan accepted, called `popViewController(animated: true)`, and only then had the
delegate decline for want of a cover cell to fly home to. The pop was already issued, so it ran as a
plain animated slide with no interaction controller behind it — a dismissal that fires on touch and
ignores the finger. From the device log, the first edge touch of the T072 run:

    edgePan shouldBegin=true mayBegin=true whyDetail=detail-on-top
    ask op=2 ... fromIsDetail=true
    decline op=2 active=qgCfizRpk4EHhLBddZVrwz
    edgePan popped but no interaction controller was vended
    installer willDisappear ... interactive=false

This predates T072. The predicate is now **stricter**, not wider — `edgePanMayBegin` covers no
screen it did not already cover.

### Defect 2 — nothing conscripted the scroll view

On a screen our pan serves, `shouldBeRequiredToFailBy` forces the scroll view's pan to fail, and
that is *why* the working case works — the gate kept in the tree all night is the mechanism, not
merely a defensible extra. On a screen our pan has stepped aside from, nothing plays that role and
SwiftUI's list scroll view takes the edge touch and scrolls with it.

`syncGestures` now requires every scroll view on the current screen to fail for
`interactivePopGestureRecognizer`. UIKit does not do this for itself, and it is capable of driving
the pop once it receives the touch — earlier device logs show it reaching `.began` holding a touch
(`st=1/n=1`).

**The bound, which matters more than the fix.** `require(toFail:)` is permanent and UIKit offers no
removal, so the scoping cannot come from adding and removing it per touch. It comes from the
recognizer being waited on: `interactivePopGestureRecognizer` is a **screen-edge** recognizer, so a
touch that does not begin at the left edge fails it almost immediately and the scroll view proceeds
untouched. Only a drag begun inside the edge margin is delayed at all — and that is the same cost
the working screens already pay via `shouldBeRequiredToFailBy`, where scrolling is fine today. This
extends a bound already observed to be acceptable rather than inventing a new one. The hierarchy
walk is capped at 400 views so a navigation callback cannot become a stall.

Constraints held: `edgePanMayBegin` not widened, `shouldBeRequiredToFailBy` untouched, T072's
scoping unchanged.

### Incidental, not fixed

`syncGestures` ran ~12 times in 5 ms during a single pop. Harmless, but it is redundant work in a
hot path and worth revisiting if that callback ever shows up in a profile.

**STATUS: compiles clean; not verified on device.** Acceptance is unchanged and all three halves are
required: the cover-tap playlist still zooms and swipes interactively; every Go-to screen swipes and
**tracks the finger** (an instant non-interactive pop is a FAIL) with the scroll view at `st=5` and a
pop recognizer holding the touch; and ordinary vertical scrolling still works on those same screens.

### Verification actually achieved — and the one gap in it

Device log, build `2026-08-30T02:58:42`:

- **Go-to screens pop and track the finger — verified.** `PLX/st=2/n=1` (13 observations) and
  `st=1/n=1` (3): UIKit's pop recognizer holding the touch and driving the transition, between a
  `willShow depth=1` and its `didShow`. The conscription shows as
  `UIScrollViewPanGestureRecognizer/st=5/n=1` (23). Ours correctly absent at `en=false`.
- **Cover-tap path still zooms and swipes interactively — verified.** 8 accepts, 8
  `ask op=2 fromIsDetail=true`, **0** `decline op=2`, **0** "no interaction controller was vended"
  (both were the defect-1 signature), and `OURS/en=true/st=2` six times.
- **Ordinary scrolling still commits — NOT verified in the log. It rests on Ethan's observation
  ("yup we're good"), not on measurement.** This is recorded as a known gap, not as a pass. The
  reason it could not be measured: the whole sampler sits behind `if point.x < 40`, so a mid-screen
  drag — an ordinary scroll — never reaches it, and the conscription's cost falls precisely there.
  Indirect signals in that run were too weak to substitute (one distinct cell id, no scroll pan
  reaching `.changed`), which suggests lists may not have been scrolled much while logging.

A `COVERZOOM scrollSample` branch has been added to close that gap on the next round: it samples
only the pans we conscripted, on non-edge touches, and logs only when one leaves `.possible`. A
reading of `st=2` is the proof that scrolling still commits; silence is the regression. It is
committed unmeasured — the first run that exercises scrolling will settle it.

Note for whoever adds to that block: the scroll sampler must not `return` early. It sits above the
delegate re-assertion that reclaims `UINavigationController.delegate` from SwiftUI on touch-down,
and an early return would skip that on nearly every touch in the app.

## 2026-08-29 — tap-based playback branch (T073), and the test that stopped it

Branch `t073-tap-playback`, off dev at `1eaf0dc`. **dev is untouched** — this was built in a git
worktree so the main checkout stayed on dev for the reader agents.

### What was built

One transport. `AVQueuePlayer` for everything, with the equalizer applied by an
`MTAudioProcessingTap` attached to each `AVPlayerItem` via `AVMutableAudioMix` before the item is
inserted. `EqualizedAudioEnginePlayer` is deleted, and with it:

- the dual-player branching through `PlaybackEngine` (76 sites),
- the mid-track EQ handoff — `scheduleEqualizerHandoffWhenCached`,
  `swapActiveItemToEqualizerIfNeeded`, `restorePlaybackAfterFailedEqualizerHandoff`,
  `rebuildEqualizedSessionAfterConfigChange` — which is the bug this branch exists to remove: the
  equalizer was **absent from the first part of every streamed track** until a background download
  completed and an audible swap landed,
- a second, file-reloading seek implementation,
- a hand-rolled periodic time observer that existed only because the second transport had none.

`reloadForEqualizerSettingsChange` no longer reloads anything: a settings change publishes new
coefficients to the live taps, so the playhead does not move and there is no seam.

Design points that came from the investigation and are load-bearing:

- Coefficients are computed **in `prepare`, from the format it supplies**, never once at init —
  `prepare` can fire again at a new sample rate after a route change.
- A tap is attached to **every** item; bypass is identity coefficients, never detaching.
- Each tap owns its filter state. Two are live at once at a gapless boundary, by design.
- The render callback allocates nothing, locks nothing and logs nothing. It writes fixed-size
  records into a preallocated per-tap ring, drained by a 500 ms timer.

### Logging

`PlaybackTapLog` writes both streams to `Documents/vellum-tap.log`, **deliberately not under
`#if DEBUG`** — the whole of `DebugUIRemote.swift` is, which is exactly why the existing log records
nothing in the configuration where the bug reproduces. Every record carries item identity.
`PlaybackCPUSampler` samples `mach_task_basic_info` user+system time against elapsed playback
seconds, plus tap callback count and thermal state. Raw compute only — no battery API, no energy
estimate.

### The tests did NOT pass, and the reason is not the ordering they were meant to measure

**Tests 1, 2 and 3: FAIL on this build.** Not by a narrow margin — no audio reaches the tap at all.

Measured on the iOS 26.3 simulator, EQ on with a non-flat curve:

| observation | evidence |
|---|---|
| Mix attaches, with identity | `TAP mix-attached item=1 track=… title="sad robot" trackID=1 audibleCurve=true` |
| `prepare` fires with a real format | `TAP prepare item=1 … sampleRate=44100.0 channels=2 maxFrames=4096 prepareCount=1` — 7 prepares across the run |
| **`process` is never entered, once** | zero `TAP process` lines; the drain logs on *entry-count* growth as well as ring growth, so silence here means the callback was never called |
| Playback stalls and retries | `unprepare … processCount=0` roughly every 15 s, then a fresh item |

**Control run isolates it to the tap.** With `vellumTapEnabled=NO` — a kill switch added for exactly
this — the same build plays continuously: `audioSeconds` climbs 30 → 40 → 50 → 60 with no teardown,
`cpuPerMinAudio` ≈ 2.0–3.7. So the transport rewrite is fine; attaching the tap is what stops audio.

### Leading hypothesis, stated as a hypothesis

`prepare` firing with a correct format means the mix **is** being honoured — a misconfigured mix is
normally ignored silently and `prepare` never runs at all. What does not happen is the render chain
ever pulling through the tap. The strongest candidate is that **`MTAudioProcessingTap` is not
serviced by the iOS Simulator's audio stack**, which would produce precisely this: prepared, never
processed, no audio, stall.

If that is right it is a methodology problem, not only a code one: **tests 1/2/3 cannot be run
headless on a simulator at all**, and every one of the six tests needs the device. That is a
decision for Ethan, not something to work around quietly.

The alternative — a real defect in the tap setup — is not excluded. What separates them is one run
on hardware.

**Nothing here is a device measurement.** The simulator CPU figures are a plumbing smoke test only.

### T073 follow-up — use-after-free on the audio path

Device logs showed, 120 ms apart:

    TAP retire item=1 … / TAP retire item=2 …
    TAP prepare ORPHAN item=15785850001729508719

That item tag is a read of freed memory. Retiring a tap dropped the last Swift reference, `deinit`
freed the render state, and AVFoundation then called `prepare` on a tap whose storage no longer
existed. It did not crash in that session and the orphan branch caught it, but it is a
use-after-free on the render path and only luck separates the two.

The mistake was assuming the wrapper owned the storage. It does not: once the state has been handed
to an `MTAudioProcessingTap`, only the framework knows when the last callback has been made, and it
says so by calling **`finalize`**. So `deinit` no longer frees anything, `finalize` is now the only
place the render state is released, and it frees straight from the raw storage because by then the
Swift object may be long gone. `disposeBeforeAttachment()` covers the one other case — tap creation
failed, nothing ever took ownership — and refuses once a tap exists.

The related symptom is in the same logs: **zero `unprepare` callbacks across 1455 lines**. Taps were
only ever torn down by our own retirement, never by AVFoundation finishing with them, which is the
same mistake seen from the other side.

UNVERIFIED: builds clean, not yet re-run on device.

## 2026-08-30 — merged t19-swipe-fix and t073-tap-playback into dev

Both feature branches are now on `dev`. Nothing was pushed: `dev` is local, `origin/dev` is still
`52fa64f`.

### What was merged, and how

`t19-swipe-fix` (`6883ff9`, one commit) went in first as a **fast-forward** — off `1eaf0dc` it is
one, and taking it first is what makes the second merge a real one.

`t073-tap-playback` (`5d2d4a2`, `b6b5613`, `c9f45d8`) then went in as a **`--no-ff` merge commit**
(`625c8f4`) rather than a rebase. Three reasons: the three commits that were written and reviewed
against the audio path keep their identity and their trees, so what runs on the phone is what was
reviewed; both source branches are checked out in worktrees, which makes an in-place rebase of
either impossible without disturbing them; and a merge is revertible as one object if the playback
rewrite turns out to misbehave. The cost is one extra commit and a non-linear stretch of history.

### The one conflict was in this file, not in code

The branches were expected to be disjoint — transition/UI versus playback engine — and in code they
are. But both of them also **appended a new entry to the end of `OPTIMIZATIONS.md`**, at the same
line, which is the one conflict the merge produced (t19 +288 lines, t073 +100, zero deletions on
either side). Resolved by keeping **both** blocks whole, t19's first, then t073's: 1103 base lines +
288 + 100 = 1491, verified line-for-line against all three inputs. No code file conflicted, and
`git diff 6883ff9 HEAD` is exactly t073's own +1412/-1066 across its 8 files — the merge introduced
nothing of its own.

### It builds, and the audio path runs on the phone

- **Build:** buildbot `vmerge1`, scheme `VellumMusicHost`, GUI session (`==> session: Aqua`).
  `errors=0 errSec=0`, **zero warnings in the whole build**, signed product installed on the phone.
  The `launched=no` on that result is the documented locked-phone case, not a build failure.
- **Audio, on device:** the previous entry closed with *"UNVERIFIED: builds clean, not yet re-run on
  device."* It has now been run. A throwaway worktree at `625c8f4` drove playback through the repo's
  own `com.vellum.debug.playQueue` hook on Ethan's own library, and `Documents/vellum-tap.log` shows
  the tap doing real work: `mix-attached` → `prepare` at 44100 Hz / 2 ch / 4096 max frames →
  **613 render callbacks over a 56.8 s stream span, `lostFromRing=0`, `lastSourceStatus=0`**, with
  the next item (`Cliche'`) staged behind the needle. 613 × 4096 / 44100 = 56.9 s of audio produced
  in 56.8 s of wall clock, i.e. real-time rendering with no dropouts. Cost, from the sampler that
  `c9f45d8` split out: `audioCpuPerMinAudio=1.065` s against `cpuPerMinAudio=2.967` s, thermal
  nominal. Zero `no-tap`, `FAILED` or orphan lines in the run.
  What this does NOT prove is sound leaving the speaker — nobody was listening to the phone. It
  proves the engine rendered audio frames continuously through the EQ tap.

### One thing to decide, not a defect

`PlaybackTapLog` is deliberately **not** `#if DEBUG` (its own header says why: the bug it exists to
diagnose only reproduces in Release, and a diagnostic that switches itself off there is useless), so
a Release build now writes `Documents/vellum-tap.log` on every playback lifecycle event, from 20 call
sites, with no runtime switch. That is a considered decision by the branch, and it collides with the
standing "no debug logging left in the tree" rule. Merged as written — flagging it as Ethan's call,
not resolved here. Separately, the one `print("[VELLUM-PB]", …)` at `PlaybackEngine.swift:2780`
predates this merge; it is not something t073 added.

## 2026-08-30 — PlaybackTapLog is now DEBUG-only, and the [VELLUM-PB] console logger is gone

Ethan's decision, made after the tradeoff was put to him: a Release build of his daily install
should not be writing a log file from ~20 playback call sites.

### What changed

`PlaybackTapLog` keeps its API and loses its body in Release. The implementation — the file handle,
the serial queue, the formatting — now sits inside `#if DEBUG`, with an `#else` branch that declares
the same three entry points (`eq`, `tap`, `launchMarker`) doing nothing. Nothing at the ~20 call
sites changed, and not one `#if DEBUG` was added to them; that was the point of the shape.

The parameters became `@autoclosure () -> String`, so in Release the string interpolation at each
call site is never evaluated either. The cost that disappears is the whole line, not just the write.

Separately, `PlaybackEngine.pbLog` and its 12 call sites are deleted. It was a `print("[VELLUM-PB]", …)`
already inside `#if DEBUG`, so nothing shipped — but the no-debug-logging rule is aimed exactly at
this, and removing the `print` while leaving twelve calls to an empty function would have missed the
point. No behaviour change: it only ever wrote to the Xcode console in Debug.

### What this costs, stated plainly

`PlaybackTapLog`'s own header argued it should NOT be gated, because the playback bug it exists to
diagnose reproduces in Release, and a diagnostic that switches itself off in the configuration being
diagnosed is not a diagnostic. That argument was not wrong, and it is now the price of the gate:
**this log can no longer observe a Release-only playback bug.** The header records that so the next
reader does not have to rediscover it.

If that capability is wanted back, the shape to reach for is a runtime switch that is **off by
default in Release** — one `UserDefaults` flag read once into a `static let`, guarding the same
`write`, so a Release build stays silent for everyone who does not deliberately turn it on. That was
offered as an option and NOT built; it needs Ethan's word first.

### Verification

Both configurations built for iOS Simulator from a throwaway worktree at `ed2df20`:

- **Debug: BUILD SUCCEEDED, 0 errors, 0 warnings.**
- **Release: BUILD SUCCEEDED, 0 errors, 1 warning** — `not stripping binary because it is signed`,
  in `VellumWidgets`, a simulator code-signing artefact in a target this change does not touch.

Proof the code is gone rather than merely unreachable: the Release binary (74 MB, and it does
contain `PlaybackEngine` and `EqualizerAudioTap` symbols) has **zero** occurrences of the string
`vellum-tap.log`, as does the widget extension that also links `VellumMusicKit`. The Debug binary
still has it. `VELLUM-PB` appears in neither.

**No on-device confirmation was possible: Ethan has asked us off his phone, so this was verified by
building only.** What is unverified by that: that Debug behaviour on the device is unchanged in
practice. The code path there is byte-identical to before apart from the `@autoclosure`, but it has
not been run on hardware.

## 2026-08-30 — the album-detail backdrop task no longer restarts on a salted URL

A 30-agent static review of the album-scroll lag found one surviving candidate: the detail view's
backdrop `.task(id:)` was keyed on a Subsonic cover-art URL, and `NavidromeClient.buildRESTURL`
mints a fresh random salt on every call. So the id differed on every body pass, SwiftUI restarted
the task, the task wrote `backdropPalette` (`@State`, not Equatable) on the main actor, that
invalidated the body, and round it went. This is the same hazard the repo already fixed on
`AlbumArtworkView` ("108 of 178 artwork task re-fires were salt-only"); the detail view never got
the fix.

### Measured, and this is the part that matters

Simulator, demo Navidrome server, artist page → album (The Polish Ambassador, 22-track album) →
sit idle 15 s → 8 fast swipe pairs. Counted backdrop task fires and detail-view body passes:

| | task fires | of which salt-only | body passes |
|---|---|---|---|
| before | **19** over the run (4 during 40 s of scrolling) | 15 (79%) | 29 |
| after | **1** over the run (0 during scrolling, 0 while idle) | 0 | 3 |

**The loop is real, but it was never spinning.** It fired about 0.1 times per second while
scrolling, not once per frame — the body only re-evaluated 4 times across 40 s of dragging. That
settles the open question in the analysis, which could not tell from source whether this was a free
spin or one extra pass per frame: it is neither, it is a slow trickle. Removing it is right — 15 of
19 restarts were pure churn — but nobody should expect it to be felt.

**And the album screen shows almost no jank in the simulator to begin with:** 3 stalls >16 ms
totalling 212 ms across 40.3 s of scrolling, versus ~17 stalls / 854 ms per 15 s on the long
playlist. So this fix is a correctness and churn fix, not a demonstrated cure for what Ethan sees.

### What changed

- `ArtworkDynamicGradient.stableID(for:style:)` — new, exposes the palette cache's own identity
  (path + `id`/`coverart`/`size`/`tag`), the same idea as `DecodedArtworkCache.stableID`.
- `ServerPlaylistViews.detailBackdropTaskID` and `BrowseAlbumDetailView`'s backdrop task now key on
  it instead of `url.absoluteString`.
- `AlbumHeroBackdrop`'s `.id(...)` likewise — it was throwing the view's identity away every pass.
- **`ArtworkDynamicGradient.cacheKey` now sorts its identity params.** Found while measuring: the
  first fix only got fires from 19 to 13, because `buildRESTURL` iterates a Swift **Dictionary**, so
  the same request comes back with its query items in a different ORDER. The key therefore still
  differed for identical artwork. The decoded-artwork caches already sort for this exact reason.
  This also means the palette cache itself was missing on order changes before today.
- `LibrarySongRow.==` compares artwork **identity** rather than URL spelling, so `.equatable()` can
  finally skip a row whose cover has not changed.

### One instruction I did not follow literally, and why

The brief said to stop computing `artworkURL` for album rows because they pass `showsArtwork:
false`. That premise is wrong: `SongLongPressPreviewCard` (the T061 long-press preview) takes the
same URL and has **no** fallback to `track.artworkURL`, so passing nil there would silently
un-illustrate the preview card on every album row. Fixing the equality instead removes the same
churn with no behaviour change, and it fixes library song lists too.

### Verification

- Debug **BUILD SUCCEEDED, 0 warnings**. Release **BUILD SUCCEEDED, 0 errors, 1 warning** — the
  pre-existing `not stripping binary because it is signed` on `VellumWidgets`, untouched by this.
- **No visual change:** the same album captured on the unfixed and fixed builds is pixel-comparable
  — same backdrop colour, same layout, same rows. The palette still loads.
- **No device confirmation was possible: Ethan asked us off his phone.** Everything here is
  simulator-only, against the demo Navidrome server, on a 22-track album.

### The caveat that must ride with this

**This does not explain his framing and does not close his bug.** He said artist page → album →
scroll. The same view renders playlists, so the loop should have shown there too; and at 0.1 fires
per second it is too slow to be what he feels. Also backend-dependent: it needs Subsonic, and it
disappears for a downloaded album whose artwork is a stable `file://` URL.

## 2026-09-01 — the suggested-shelf derivation, roughly halved (APPLIED, UNCOMMITTED, awaiting device confirmation)

**Status: in the working tree only.** One file, `NewTabPersonalizationEngine.swift`, not committed and
not pushed. Ethan's gate for committing is confirmation on his own phone and he has not built this
yet. If he rejects it this entry gets a correction rather than being deleted.

### What was slow

On Ethan's device a memo MISS on the album-detail shelves cost **121–129 ms** on the main actor (a
HIT is 0.1–0.3 ms), and misses recur through normal use because any catalog change bumps
`libraryCatalogEpoch` and wipes both memos — including on download completion.

Where that time went could not be read off his device, so it was split on a **synthetic** catalog:
734 generated albums with repeating artists and two genres each, sized and shaped like his but
containing none of his data. On that synthetic catalog, in the simulator:

| part | before |
|---|---|
| `listeningTopGenres()` | 24–26 ms |
| building the personalization context | 21 ms |
| candidate filter | 17–19 ms |
| **the ranking** | **183 ms** |
| **whole miss** | **233 ms** |

### The change

`tasteRankedAlbumSummaries` scored each candidate by looping over the top ten genres and, inside
that, over the album's own genres, calling `GenreCanonicalizer.canonical(for:).lowercased()` on every
combination — for 689 candidates, up to ~14,000 canonicalizations of the same handful of strings per
derivation. Each album's genres are now canonicalized **once** into a `Set` and the top-genre loop
does set membership.

Nothing moved off the main actor. The work is simply smaller, in the same place, so there is no new
concurrency to reason about and playback is untouched — it renders on `MTAudioProcessingTap`'s own
real-time thread and never involved this actor.

### Measured, synthetic, three runs each

| part | before (synthetic) | after (synthetic) |
|---|---|---|
| ranking | 183 ms | **~70 ms** |
| whole miss | 233 ms | **~119–127 ms** |
| `listeningTopGenres()` | 24–26 ms | 18–26 ms (untouched) |
| context build | 21 ms | 18–22 ms (untouched) |
| candidate filter | 17–19 ms | 16–21 ms (untouched) |

The three untouched parts are the control: they do not move, so the delta is where the change is and
nowhere else.

**Do not read the ratio as an absolute.** Every number above is from a SYNTHETIC catalog in the
simulator, which measured a 233 ms whole miss where **his device measured 121–129 ms** for the same
operation. The split and the proportion are the findings; the milliseconds are not his.

### The output is provably unchanged

The risk of this change is not a crash, it is a shelf whose contents quietly differ. So it was tested
rather than argued: the real shipping function was run against a verbatim copy of the pre-change one
over the same synthetic catalog, comparing the **whole** ranked list at `limit = albums.count` — every
album by id, in order — and every per-album score with exact `==`, with a divergence path that reports
the first mismatch.

    EQUIV IDENTICAL over 689 albums: same order, same ids, same scores   (three runs)

Scope of that proof, stated rather than glossed: the list comparison is end-to-end with the real
function on one side; the per-score comparison transcribes both genre-loop shapes into the verifier,
so that half proves the two expressions agree rather than reaching into the function's private
locals. The list half is the stronger one.

The benchmark, its Darwin trigger, the driver test, the legacy copy and the verifier all stayed in a
throwaway worktree. None of it is in this tree — checked explicitly, because the worktree patch would
have dragged the legacy copy and verifier along with it.

### Not addressed here

`listeningTopGenres()` is now the largest remaining piece at ~26 ms, and the context build calls it a
**second** time per derivation. Left alone deliberately so it cannot contaminate the measurement of
this change.

## 2026-09-02 — Kill Mode unlocks the playlist again at 100% listened (APPLIED, UNCOMMITTED, not yet built on device)

Ethan asked for this at 12:37. It is new code: T107 established that no unlock gate existed anywhere
in the tree, so there was nothing to repair.

### What it does

With Kill Mode on, `killModeFilteredPlayback` drops already-listened songs so each run plays the
unheard ones. Once everything has been heard that filter leaves nothing, Play and Shuffle do nothing,
and the only way forward was the "Clear listen history" reset. Now, when every song the user is
KEEPING has been listened to, the filter stands down and the playlist plays again.

Songs queued for removal stay out of that playback. The user has already decided on them and they
leave the playlist when the removal is confirmed; the unlock is about replaying what is being kept.

### His two rules, implemented literally

**Only at 100%, never 99.** The gate compares two `Int` counts with `==`
(`AppModel.killModeUnlockedForFullPlayback`). No `Double`, no percentage, no rounding on this path,
deliberately: 199 of 200 is 99.5%, which `Int((… * 100).rounded())` renders as "100%". A value that
can round up must never reach a gate, so nothing on this path can produce one.

**Only songs NOT scheduled for deletion count.** The pending-removal set is excluded from both sides
of the comparison, so marking a song for removal shrinks the denominator instead of leaving an
unreachable target.

**When every song is scheduled for deletion** the denominator is zero. That case returns `false`, not
`true`. An empty set satisfies "all listened" vacuously, but nothing is being kept, so there is
nothing to unlock — the existing behaviour and its toast stand.

### Two sources of truth, on purpose

`PlaylistKillListView.swift:184-185` computes `pctListened` / `pctRemoved`. Those are display-only and
nothing reads them; the gate does NOT reuse them, and deliberately so. They measure a different thing
(progress through the whole playlist, including songs marked for removal) and they round for humans.
Reusing them would import exactly the rounding this gate has to avoid.

The consequence is worth knowing: on a 200-song playlist with 199 listened, the header can read
"100% listened" while playback stays locked. That is the gate being right and the label being coarse.
Making the label floor rather than round would close the gap; it is a display change and was not made
here.

### Scope

One file, `AppModel.swift`: the gate plus five lines in `killModeFilteredPlayback`. Nothing outside
Kill Mode can reach either — the existing `killModeEnabledPlaylistIds` guard still returns early for
every other playlist, so a playlist not in Kill Mode behaves exactly as before. The T023 delete
confirmations and safety guards were not touched.

**Verified: Debug build for iOS Simulator, BUILD SUCCEEDED, no errors, no warnings in `AppModel.swift`.
Not built or installed on device — that is Ethan's gate, and a T102 change is already queued for the
same trip.**

---

- [2026-09-03 05:20] **T121 — MusicBrainz metadata layer for search and artist discovery.** The
artist page used to get its discography from whichever acquisition plugin was configured. That was
the wrong source: a plugin reports the releases *it* knows about — its own library, or its own fuzzy
catalog lookup — which is neither complete nor a description of the artist. MusicBrainz now owns
artist identity, header facts and the discography; the plugin keeps only what MusicBrainz does not
publish (artist portrait, bio) plus the request path itself. There is one artist-metadata path now,
not two.

New files: `MusicBrainzModels.swift`, `MusicBrainzClient.swift`, `MusicBrainzCacheStore.swift`,
`MusicBrainzService.swift`, `MusicBrainzDiscographyMapping.swift`. Deleted
`ArtistProfileClient.swift` — dead, unreferenced code that hit MusicBrainz with no pacing and no
cache, i.e. exactly the second uncontrolled path this work exists to prevent.

What matters about the implementation:

- **Browse, not the bundled lookup.** `/ws/2/release-group?artist=…&limit=100&offset=N` honours
  paging and reports `release-group-count`. The `/artist/{mbid}?inc=release-groups` form silently
  caps at 25, ignores `limit` and reports no total — and what it drops is not evenly spread. For
  Citizen it returns 25 of 30, and **all five it drops are singles: 13 becomes 8.** A total-only
  check would pass while the bug survived, so the singles count is the real regression test.
- **One serial queue with a start-to-start floor.** Requests are chained, so concurrent callers wait
  for each other rather than each clearing "one second since *my* last call" simultaneously. The gap
  is measured start-to-start, not end-to-start. A named User-Agent carrying a contact address keeps
  the client out of the anonymous throttle class.
- **From a search hit it is one call, not two.** The search payload already carries name, country,
  area, life-span and tags, so the header renders from it directly and search rows are seeded into
  the header cache by MBID. Opening an artist from search spends zero requests. Only a cold open
  pays for the lookup.
- **Name resolution is scored, not a containment test.** An exact normalized name always outranks a
  partial one and a weak best match is refused. The pre-existing loose three-way containment test in
  the Lidarr plugin was deliberately not copied — and, as instructed, not fixed either.
- **Cache: expiry means stale, never deleted.** Keyed by MBID plus the `inc` set, storing raw
  bodies, `fetched_at`, `release-group-count` and which offsets are held. A stale entry is still
  served, still refreshed against, and is the fallback when a refresh fails. **Replacement only on a
  complete pass** — a rescan that dies mid-pagination cannot overwrite a complete entry with a
  partial one wearing a fresh date, which would otherwise turn a network blip into permanent silent
  truncation that looks healthy. The store enforces this itself rather than trusting callers.
- **Two loading states.** Header shimmer resolves first (or never appears, arriving from search);
  discography placeholders are counted from the server's own `release-group-count`, so pages fill in
  progressively instead of the shelf looking finished and then jumping.

Two defects found and fixed during verification:

1. A single failed page abandoned the whole pass, so one flaky request cost all 314 of an artist's
   releases. Retry backoff now escalates (2s, 4s) instead of staying flat, and the result carries an
   explicit `refreshFailed` flag so the UI can tell "this artist has no more releases" from "we could
   not find out" — previously identical on screen.
2. **Completeness was assumed rather than derived.** The pagination loop set `isComplete: true`
   unconditionally on exit, so an empty or short page arriving mid-run — a server hiccup, which ends
   the loop exactly as the genuine last page does — would have been cached as a finished pass. Worse,
   the store's partial-write guard could not catch it, because the entry claimed to be complete. This
   is the same silent-truncation-under-a-fresh-date failure the cache rule exists to prevent, just
   reached through a different door. Completeness is now derived: when the server reports
   `release-group-count`, rows received (counted before de-duplication) must meet it; only then is
   the cache overwritten. Verified with an offline decision table covering the truncation cases —
   short page mid-run, empty page mid-run, dropped last page — plus the legitimate short-final-page
   and no-count-reported cases. 8/8 pass, `scratchpad/t121-mb-completeness-table.log`.

**Verified by live runs against the MusicBrainz API** (no test target exists here). Harness compiles
the shipping sources by symlink, so what ran is the shipping code. Logs:
`scratchpad/t121-mb-verification.log` and `scratchpad/t121-mb-concurrency-burst.log`.

- Citizen: **30 release groups, 13 singles** (bundled endpoint, for comparison: 25 groups, 8 singles).
- Nana Mouskouri: **314 across 4 paged calls**, progress emitted per page (100/200/300/314).
- Pacing: smallest gap across a 10-request mixed burst **1.051 s**; a separate test firing **12
  uncoordinated concurrent searches produced 12 requests, zero sub-second gaps, zero failures**.
- Cache rules exercised, not asserted: a partial write against a complete entry was refused and the
  complete entry survived; an 8-day-old entry stayed readable and reported stale.

Verified: Debug build for iOS Simulator, BUILD SUCCEEDED, no errors and no warnings in any touched
file. Not committed and not installed to a device, per the brief.

---

- [2026-09-03 06:05] **T122 — retry harder, and say so on screen when a page gives up.**

Retries per request go from 3 to 20. The backoff is now capped rather than doubling without limit:
2s, 4s, 8s, then 8s for the remainder. Uncapped doubling across twenty attempts would run for days,
which is a worse outcome than failing — nobody waits that long, and the request holds the serial
queue the whole time, stalling every other page behind it.

**Measured, not estimated: a fully exhausted request takes 149.0 s (2.48 min).** That is twenty
attempts against an injected always-503 endpoint. Comfortably inside the five-minute budget, so the
8 s cap stays where it is.

That measurement only covers fast failures, and checking the other failure mode changed the answer.
The attempt count and the backoff cap together bound only the *waiting* — they say nothing about the
attempts themselves. Twenty attempts that each hang to the 20 s transport timeout would have run
about **nine minutes**, quietly breaking the budget the other two settings were chosen to satisfy. A
total-elapsed deadline of 240 s now bounds every failure mode, not just the fast one. Measured with
an injected stalling endpoint: **240.5 s across 18 of 20 attempts**, the deadline stopping the pass
rather than the attempt counter.

**A page that exhausts its retries now reaches the screen in words.** The flag on the model was
never the fix; the fix is `ArtistDiscographyLoadNotice` in `ArtistPageView.swift`, a banner above
the discography shelves with a Retry button. It says one of two things, because they are two
different situations for the reader:

- Partial load — heading **"Couldn't load everything"**, body **"Showing 300 of 314 releases. The
  rest didn't load."**
- Saved copy — heading **"Showing a saved copy"**, body **"Couldn't refresh this artist's releases,
  so this is the copy saved 3 days ago."**

Confirmed rather than rebuilt: releases already on screen survive a later page failing. Each page is
applied as it lands, and the failure path returns the partial whenever it holds rows, so three pages
in with the fourth failing keeps all 300 rendered releases and marks them as current data — not as a
saved copy. Proven by decision-table case, not by reading the code.

- [2026-09-03 06:05] **T123 — expire instead of stale, with the refresh limiter in front.**

This reverses the serving rule from T121. An out-of-date entry is no longer rendered while a refetch
runs behind it; that swap under the reader is worse than a slightly longer load. Out of date now
means loading state, then fresh data. Pull-to-refresh expires the cache too.

**The ordering is the substance of this change.** The refresh limiter is consulted *before* anything
is expired or discarded. Refusing is therefore always safe, because nothing has been given up at the
moment the answer is "no". Done the other way round — expire, then discover the refresh is not
allowed — the page is left holding neither the old data nor the new, which is strictly worse than
never refreshing at all. A refused refresh shows a snackbar reading **"Refreshing artist page too
many times"**, so a refresh that did not happen cannot be mistaken for one that did.

Expiry happens only when the replacement is in hand: fetch first, swap on success, and on failure
leave the previous entry untouched on disk. The retained copy reaches the screen in exactly one
situation — the fetch failed — and when it does it is labelled as a saved copy rather than presented
as current. There is no path on which current-looking out-of-date content swaps under the reader.

**Both failure cases were exercised, not described:**

- A fetch that fails leaves the previous entry intact — verified against the **real MusicBrainz
  endpoint** by browsing an MBID the service rejects. The seeded entry survived byte-identical
  (`fetchedAt` and `totalCount` unchanged) and the failed fetch returned the saved copy, labelled,
  instead of an empty page.
- A rapid double refresh is refused **while the page still has its content** — verified against the
  real limiter. The refused call returned all 3 seeded releases, did not delete the cache entry, and
  was reported as refused rather than as failed. A refusal that empties the page would have been a
  failure of this task; it does not.

**Evidence, in the repository rather than a session scratchpad so it outlives a tmp cleanup:**
`docs/verification/t122-t123-verification.log` (21 checks, all passing) and
`docs/verification/harness-t122-t123/` with a README giving the reproduction steps. The harness
symlinks the shipping sources rather than copying them, so it cannot drift from the code it claims
to verify; the reproduction steps were run end to end to confirm they work. The three T121 logs were
carried across to the same directory for the same reason.

Verified: Debug build for iOS Simulator, BUILD SUCCEEDED, no errors and no warnings in any touched
file. Not committed and not installed to a device.

---

- [2026-09-03 06:25] **T125 — three follow-ups on the MusicBrainz layer: re-entry cost, owned-album
alignment, and id-first matching.**

**1. Re-entering an artist page does not force a refresh — confirmed, and one hole closed.**
`.task` calls the non-forcing load, and pull-to-refresh is the only `forceRefresh: true` anywhere in
the app. No on-appear refetch bypasses the week rule.

Reading the code only proved half of it, though. The page also has to know *which* artist it is
looking at, and resolving a bare name to an MBID was its own MusicBrainz search on every cold open —
so opening an artist did hit MusicBrainz every time, just through name resolution rather than
through the discography fetch. Two fixes: the server's own artist MBID is now used when it has one
(Navidrome reports it, Jellyfin has it under `ProviderIds`), which costs nothing and cannot resolve
to a different artist of the same name; and name resolution is cached on disk under the same week
rule. **Measured: second open 0 requests, and 0 again after clearing the in-session memo to stand in
for a relaunched app.**

**2. Alignment count — the predicted hole is real, and the matcher is untouched pending a decision.**
Measured against a real Navidrome (the public demo, 0.63.2) on three artists where part of the
discography is owned:

| Artist | Owned | MB release groups | Suppressed as owned | Owned matching nothing | by id | by title |
|---|---|---|---|---|---|---|
| Nine Inch Nails | 3 | 317 | 3 | 0 | 1 | 2 |
| Ugress | 4 | 73 | 3 | 1 | 1 | 2 |
| Front 242 | 1 | 73 | 1 | 0 | 1 | 0 |

One duplicate pair, and it is exactly the predicted shape: owned **"Chromosome Corrupt EP"** against
MusicBrainz **"Chromosome Corrupt"**. `albumVersionBaseKey` strips those word suffixes only when a
dash precedes them, so the two do not collapse to one key and the release renders twice — once as
owned, once as requestable. **The matcher has not been changed.** The count is reported first, as
asked; changing normalization is a separate decision.

**3. Id-first matching — implemented, but the premise needed correcting first.**
The brief expected `album.mbz_release_group_id` to be available and to be what browse returns. It is
a real column, but **Subsonic does not expose it**. Verified against the live API: the id Navidrome
returns as an album's `musicBrainzId` answers 404 on `/release-group/{id}` and resolves on
`/release/{id}` — it is the *release* id, one specific pressing, not the release group. Comparing it
to a browsed discography would have matched nothing at all, not merely rarely.

So the ids are modelled as what they actually are: `AlbumSummary` carries both
`musicBrainzReleaseGroupId` and `musicBrainzReleaseId`, and a release id is resolved to its group
through MusicBrainz before comparison. That mapping is immutable, so it is cached permanently rather
than under the week rule, and only albums the title keys already failed to match are ever looked
up — an artist page whose albums all matched spends nothing. Jellyfin needs none of this: it reports
the release group directly. Title keys remain the fallback for everything without an id, which on
the measured library is the overwhelming majority.

Verified: Debug build for iOS Simulator, BUILD SUCCEEDED, no errors and no warnings in any touched
file. The T122/T123 suite was re-run after these changes and still passes in full. Evidence:
`docs/verification/t125-alignment.log` and `docs/verification/harness-t125/` with reproduction
steps, which were run end to end. Not committed and not installed to a device.

---

- [2026-09-03 12:05] **T126 — seven defects found testing on device. Four fixed, three reported.**

**6 (highest priority) — requesting an album failed, and the id was being dropped in two places.**
The request reached Lidarr as a text search (`album/lookup?term=Citizen Halcyon Blues`), which goes
through its metadata proxy's *search* path and answers with a SkyHookException for some albums. The
id lookup is exact and works. Two sites dropped the id between the MusicBrainz row and the enqueue:
`BrowseAlbumDetailView.swift:1043` rebuilt the request from artist and title text alone, discarding
the MBIDs the row already held; and `LidarrAcquisitionPlugin.swift:64` never read
`request.releaseGroupMBID` even when one was present. Both now pass it through, and the plugin asks
`term=lidarr:<mbid>` first. `BrowseAlbumDetailSource.releaseGroupMBID` is the decode matching the
`mbid:` encoding that `AcquisitionRelease.trackLookupId` already performed. When Lidarr does not
recognise an id — its metadata mirror lags MusicBrainz, so a new or obscure release group can be
unknown to it — the code falls through to the old title path rather than failing, so the id is a
strictly better first question and never a worse one.

**7 — raw JSON on screen.** `AcquisitionCore.swift:677` put the response body straight into the
error, which a toast then rendered: a .NET exception type and stack trace shown to a person. The
body now goes to the log and the throw carries a sentence, classified by status and by whether the
body looks like a metadata-proxy failure ("The request service couldn't look this album up. It may
not be in its catalog yet.").

**1 — a not-found state shown while the fetch was still running.** `ArtistPageView.swift:167`
tested `isLoadingServerCatalog` and `isLoadingEnrichment` but not `isLoadingDiscography` or
`isLoadingArtistHeader`, and had no failure branch at all — so a discography that failed, or that
the refresh limiter refused, rendered "We couldn't find any songs, releases, or biography", with no
retry. Three states are now distinct (`ArtistViewModel.ContentState`): loading shows the skeleton
and never the not-found copy; finished-and-genuinely-empty keeps the honest empty state; failed (or
refused, which is also not an absence) gets its own copy and a Try Again button. Retries are the
MusicBrainz layer's: 20 attempts, backoff capped at 8s, bounded by a 240s total deadline — measured
worst cases 149s when failures are immediate and 240s when every attempt hangs.

Tap-to-tracks was measured and the MusicBrainz layer is **not** on that path — neither detail view
references it (zero occurrences in `ServerPlaylistViews.swift` and `BrowseAlbumDetailView.swift`).
Server albums load tracks via `lib.tracks(forAlbumId:)` (`ServerPlaylistViews.swift:2363`),
off-server albums via the acquisition plugin. Against a live Navidrome the tracklist fetch measured
**289–1298 ms, median 622 ms**, dominated by the network round-trip; decode is a few KB of JSON and
the view paints as soon as it lands. So the delay is the server call, and tonight's work did not
lengthen it.

**2 — covers only loaded on scroll.** `MusicDesignSystem.swift:700` fetches from a `.task` on
`AlbumArtworkView`'s own body, and inside a lazy shelf that body does not exist until the cell is
nearly on screen. Loading now starts when the URL is known, via a bounded `ArtworkPrefetcher`:
a leading cap per shelf, four fetches in flight at a time, one job per shelf that replaces its
predecessor, and cache hits skipped without a request. Bounded because the unbounded version is a
different bug — measured, a Mouskouri page would have issued 196 image requests at once.

| Page | Cards on screen | Before, at page open | After, at page open | Unbounded would be |
|---|---|---|---|---|
| Citizen (30 release groups) | 28 | 0 prefetched | 18 | 28 |
| Nana Mouskouri (314) | 196 | 0 prefetched | 24 | 196 |

**3 — no way through to the artist from an album reached via search.** The lead was that the artist
string arrives empty; it is not. There are **three** album-detail screens, not two:
`ServerPlaylistDetailView` (`ServerPlaylistViews.swift`, tappable artist at :1578-1596),
`BrowseAlbumDetailView` (tappable artist at :769), and `AcquireResultDetailView`
(`DiscoverySearchView.swift:1864`) — the one a search hit for an album not on the server opens, and
the only one that rendered its artist as plain `Text` with no navigation at all. That view now
navigates, preferring the MusicBrainz artist id over the name so it cannot land on a different act
sharing it. A release credited to more than one artist, or to "Various Artists", stays plain text:
there is no single page to land on and picking the first credit would be a guess presented as a
fact. **The three views were not unified** — see the report below for why that was not a contained
change.

Verified: Debug build for iOS Simulator (workspace + Simulator destination), BUILD SUCCEEDED, no
errors and no warnings in any touched file. Not committed and not installed to a device.

---

- [2026-09-03 12:20] **T126 report — the three items that were investigations, not fixes.** Nothing
in this entry changes behaviour. It is the material asked for before any decision gets taken.

**4 — artist covers missing for some search rows. This was a regression introduced by T121, and it
is not a one-liner to undo.**

`DiscoverySearchView.swift:1745` sets `artworkURL: nil` on every artist row built from a MusicBrainz
search hit. That branch is guarded by `!serverArtistNames.contains(norm)`, so it only ever produces
artists that are **not** on the server — which is exactly the split visible on screen: the rows with
placeholders are the artists the server has never heard of, and the rows with pictures are ordinary
server artist rows.

Before T121 those rows came from the acquisition plugin and carried whatever portrait it had. T121
replaced the plugin as the artist-search source with MusicBrainz and passed `nil`, because
MusicBrainz has no image to pass. So the artwork did not break — it stopped being fetched from the
only source that had been supplying it.

What supplies the pictures that *do* appear: the server's own artist image, parsed in
`NavidromeClient` (`artistImageUrl`, falling back to the artist `coverArt`) and carried on
`LibraryArtistSummary.artworkURL`, recorded into Recently Searched at
`DiscoverySearchView.swift:773` and `:1395`. Library membership is irrelevant to this — a Navidrome
artist row can exist with an image and no albums the user has added, which is why "it has art
because it is in my library" does not hold up.

Why there is no one-line fix: **MusicBrainz publishes no artist images at all.** There is no URL
being dropped that could simply be restored; a portrait has to come from somewhere else entirely.
The honest options, with what each costs:

| Option | Cost | Verdict |
|---|---|---|
| Leave the placeholder | nothing | Status quo. Honest, and ugly. |
| Restore the plugin portrait when a plugin is configured | nothing extra — the call already happens | Undoes the actual regression. Measured: Lidarr holds no image for these particular artists, so it fixes the mechanism, not this screenshot. |
| Deterministic mesh tile instead of the grey note | nothing — `AlbumArtworkView` already takes a `meshArtworkSeed`, as the radio directory uses | Cheapest visible improvement. Distinct per artist, never a wrong picture, no network. |
| Cover Art Archive, using one of the artist's release groups | free on the artist page (the discography is already loaded); ~1 s per row in search, since it needs a browse per artist at one request per second | An album cover is not a portrait. Fine as a last resort on the artist page, too slow for search rows. |
| MusicBrainz `inc=url-rels` → Wikidata → Wikimedia Commons | two extra requests per artist, one of them inside the 1 req/s budget; frequently absent; attribution varies by image | Expensive and unreliable. |
| fanart.tv / TheAudioDB | an API key, plus a third-party dependency this project deliberately removed | Reintroduces what `CLAUDE.md` says not to wire back. |

Recommendation, not applied: restore the plugin portrait and use the mesh seed as the fallback. Both
cost nothing, and together they mean a row always renders something rather than one of two identical
grey notes.

**3(c) — size of unifying the three album-detail views. It is not a contained change; it was not
attempted.**

| View | Lines | Construction sites | Also rendered from |
|---|---|---|---|
| `ServerPlaylistDetailView` | ~3,480 (file) | **30** | Search, Library, Home, New tab, artist page, playlists, root deep links |
| `BrowseAlbumDetailView` | ~1,075 | **9** | New tab, artist page |
| `AcquireResultDetailView` | ~150 | **1** | Search only |

They are not one view with different inputs. `AcquireResultDetailView` is a thin stub with none of
the album-detail machinery: no backdrop palette, no cover-zoom transition, no related shelves, no
share action, no per-track rows, no request-state UI (`ArtworkDynamicGradient` 0 vs 8-9,
`coverZoom` 0 vs 4-7, related shelves 0 vs 1-2). Unifying would mean folding the thin one into a
screen with 30 call sites that also renders playlists and home mixes, and every one of those
surfaces would be in the blast radius — including the cover-zoom transition and the playlist
soft-lock area that has its own history in this log. That is a night of regressions in screens
nobody asked to have touched, so the artist link was added to the one view that lacked it and the
three were left alone.

**5 — where identity is decided by name and could be decided by id.**

Total between MusicBrainz and MusicBrainz; roughly 3% between MusicBrainz and this library
(measured: 290/10,420 albums, 192/5,020 artists, 3,080/74,665 tracks carry an MBID). So the split is
**id-only where both sides are MusicBrainz, hybrid everywhere the library is involved.**

| Site | Decides identity by | Could be id-first | Must stay hybrid? |
|---|---|---|---|
| `ArtistViewModel.swift:515-517` — server artist lookup for the page | normalized name | yes — both backends expose an artist MBID (wired in T125) | yes, ~3.8% coverage |
| `ArtistViewModel.swift:629+` — `applyDiscography` owned-vs-external | release-group id, then title keys | already id-first (T125) | yes |
| `AppModel.swift:4932-4936` — `serverAlbums(forArtistName:)`, the subscription "do I have it?" probe | normalized name only | yes, via artist MBID | yes |
| `MusicSubscriptionModels.swift:10` — `FollowedArtist.id` | MBID when known, else normalized name | already id-first | yes |
| `LidarrAcquisitionPlugin.swift:834-840` — `artistNameMatches` | loose three-way containment, no scoring | yes — Lidarr rows carry `foreignArtistId` | could go id-only against Lidarr, which is MusicBrainz-backed |
| `LidarrAcquisitionPlugin.swift:393` — release artist grouping | normalized name | yes, same id | hybrid |
| `ArtistViewModel.swift:591-615` — top songs from scrobbles | normalized artist + title | **no** — `ScrobbleStore` records no MBID | name-only until scrobbles carry ids |
| `AppModel.swift:2920-2922`, `:5149-5150` — chart/catalog artist token matching | normalized token overlap | no id on either side | name-only |

Two things worth stating plainly. `artistNameMatches` is the one site that could go id-only today,
because both sides of it are MusicBrainz-derived — it is also the loose containment test flagged
earlier and deliberately still untouched. And nothing here can drop name matching: at ~3% id
coverage, id-only against the library would stop recognising the other 97% of albums the user owns.

Verified: Debug build for iOS Simulator via `xcodebuild` on the workspace with the Simulator
destination, BUILD SUCCEEDED, no errors and no warnings in any touched file. Not committed and not
installed to a device.

---

- [2026-09-03 16:30] **T127 report — the EP-suffix duplicate. Decision packet; nothing changed.**

The symbol is `AlbumSummary.albumVersionBaseKey(_:)` in `AlbumSummary+NewTabMatch.swift`, and the
pattern is the `suffixPattern` local inside it (currently line 65, but the symbol is the durable
reference). Reached via `AlbumSummary.discographyTitleKeys(for:)`, which is what
`ArtistViewModel.applyDiscography` uses to decide whether an owned album and an external release
are the same release.

**1 — the smallest change.** Make the dash optional; touch nothing else.

    before:  (?i)\s*[-–—]\s*(single|ep|album|deluxe edition|deluxe|expanded edition|remaster(ed)?(\s+\d{4})?)$
    after:   (?i)(?:\s*[-–—]\s*|\s+)(single|ep|album|deluxe edition|deluxe|expanded edition|remaster(ed)?(\s+\d{4})?)$

One token: `\s*[-–—]\s*` becomes `(?:\s*[-–—]\s*|\s+)`. Measured effect on the confirmed instance —
currently `"Chromosome Corrupt EP"` keys to `chromosome corrupt ep` against `chromosome corrupt`, so
they do not match; widened, both key to `chromosome corrupt`. **Not applied.**

**4 — the hole is not specific to EP.** Tested against the shipping function, not read off the
regex: every word in the list (EP, Single, Album, Deluxe, Remaster, Remastered, Deluxe Edition,
Expanded Edition) collapses **with** a dash and **none** collapses without one. It is one uniform
hole across the whole list.

**2 — what it would wrongly collapse: one pair in 4,262 real titles, and it is a genuine one.**

Measured over the MusicBrainz discographies of ten artists — 4,262 real release-group titles,
including acts picked specifically because a release of theirs ends in a suffix word (Metallica,
Weezer, The Beatles, JAY-Z). Every release group in one artist's list is a different release, so any
pair newly sharing a key is a wrong collapse by definition, and the per-artist domain is the one the
matcher actually runs in.

| Candidate | Wrong collapses in 4,262 titles |
|---|---|
| A — dash optional for all words | **1** |
| B — dash optional, `album` excluded | **1** |

The single hit, both times: **Metallica, "Hero of the Day EP" vs "Hero of the Day"**. Verified
against MusicBrainz as two distinct release groups — an **EP** dated 1996-10-23 and a **Single**
dated 1996-10-22. Real releases, one day apart, that the widening would merge into one row with
nothing on screen to say the other existed.

Worth noting because it kills an obvious mitigation: excluding `album` from the widening (candidate
B, aimed at "The Black Album" style titles) buys **nothing** — the collision is on EP, not Album, and
B scores identically. Narrowing the word list does not buy safety here.

**3 — how many duplicates it would fix: cannot be answered from this session, and here is why.**

That number needs owned titles compared against MusicBrainz. The only library reachable from here is
the 50-album public demo, not the 10,420-album library in question — both simulator snapshots on
this machine contain the same 50 demo albums. On the demo the widening resolves **1** duplicate of
8 owned albums examined (the Ugress instance already known).

So a scan script is provided rather than a guessed number:
`docs/verification/t127-suffix-widening-scan.py`, read-only, run as

    python3 docs/verification/t127-suffix-widening-scan.py https://<navidrome> <user> <password>

It reports (A) wrong collapses, computed entirely from library titles with no MusicBrainz traffic,
and (B) every owned album whose title ends in a bare suffix word — the ceiling on duplicates the
change can possibly fix, since no other album's key changes. Against the demo it prints 0 wrong
collapses and 2 affected albums, which is how the script is shown to work.

**What the numbers say about the trade.** The visible failure is rare and the invisible one is
rarer, but not zero: about 1 wrong collapse per 4,000 titles, concentrated exactly where an artist
released both a single and an EP under one name. Whether that is acceptable depends on (B) from the
real library — if it resolves eighty duplicates it is plainly worth one hidden Metallica release; if
it resolves one, the trade is much closer. That is the number this session could not produce.

Nothing in the matcher was modified; the file's hash is recorded unchanged in the run notes.
Evidence: `docs/verification/t127-measurements.log`.

---

- [2026-09-03 16:35] **T131 — EP-suffix widening applied.** The change costed in the T127 report,
approved and now in the tree. One hunk, one line of code.

`AlbumSummary.albumVersionBaseKey(_:)` in `AlbumSummary+NewTabMatch.swift` — the separator in
`suffixPattern` becomes optional, so a bare space separates the suffix as well as a dash:

    - (?i)\s*[-–—]\s*(single|ep|album|deluxe edition|deluxe|expanded edition|remaster(ed)?(\s+\d{4})?)$
    + (?i)(?:\s*[-–—]\s*|\s+)(single|ep|album|deluxe edition|deluxe|expanded edition|remaster(ed)?(\s+\d{4})?)$

The word list is untouched, and nothing else in the file was changed.

**Both halves of the measurement, because they point opposite ways and the decision rests on the
difference.**

*Against catalogue data*, the widening is slightly lossy. Over 4,262 real MusicBrainz release-group
titles across ten artists — chosen to include acts whose releases end in a suffix word — it causes
exactly **one** wrong collapse: Metallica's **"Hero of the Day EP"** (EP, 1996-10-23) merging with
**"Hero of the Day"** (Single, 1996-10-22). Two real releases a day apart become one row, and
nothing on screen says the other existed. That is roughly one bad merge per 4,000 catalogue titles.
Excluding `album` from the widening was tested and scores identically, so narrowing the word list
buys nothing here.

*Against the actual library*, it is the other way round. Measured on the real 10,420-album library
(which this session could not reach — the only library available here is a 50-album public demo):
**ninety albums end in a bare suffix word**, and of the **fourteen merges** the change creates, most
are the same album stored twice — "Tidal Wave - EP" against "Tidal Wave EP", plus Lately, My Type
and The Sonic Crystal. So the false-positive rate measured on catalogue data is real, and the
practical effect on this library is a net win: fourteen duplicate rows removed against one
catalogue-level merge that would only appear on a Metallica artist page.

**Verified three ways.**

- The confirmed instance, by **running** the shipping function rather than reading the pattern:
  before, `"Chromosome Corrupt EP"` → `chromosome corrupt ep` vs `"Chromosome Corrupt"` →
  `chromosome corrupt`, different keys; after, both → `chromosome corrupt`, same key.
- The 4,262-title scan re-run against the applied change, with the pre-change pattern kept as the
  baseline so what is measured is what actually shipped: **1** wrong collapse, Metallica's, matching
  the costed number exactly.
- Nothing else under `Sources/` touched: all 154 source files hashed before and after, **1** hash
  changed. Done by hash rather than `git diff` on purpose — six of those files are untracked, and a
  plain diff reports nothing for them whether they changed or not. Each was confirmed unchanged
  individually.

Verified: `xcodebuild` on the workspace against the iOS Simulator destination, BUILD SUCCEEDED, no
errors and no warnings in the touched file. Not committed and not installed to a device. Evidence:
`docs/verification/t131-widening-applied.log`.

---

- [2026-09-03 13:00] **T133 — an artist page merging every same-named artist. Diagnosis for the
album-open failure alongside it; that one is not fixed yet.**

**The merge was not the acquisition plugin.** `remoteReleasesSnapshot` is assigned in exactly one
place (`ArtistViewModel:470`), fed only by `discography(artistMBID:)`. Browse-by-id cannot return
another artist's release groups, and the plugin supplies no releases to this page at all — the one
surviving `artistReleases` call is in `AppModel:1072`, for the subscription engine.

**A second name-resolved source was merged into the same list.** `applyDiscography` combines the
MusicBrainz rows with `serverAlbums`, and those came from `resolveServerArtistIdIfNeeded`, which
matched on normalized name and then took the **first** row that matched. Servers key artist rows by
name, so one band's albums landed on another band's page — rendered as *owned*, because they
genuinely are on the server, with nothing on screen to say they belong to somebody else.

The scale of the ambiguity, measured: MusicBrainz returns **938 artists** matching "Rocket", of which
**18 are named exactly "Rocket"** on the first page alone.

Server artist resolution is now id-first. When the page knows its MusicBrainz artist id and a
same-named server row carries the same id, that is an exact match and it wins. When every same-named
row carries an id and none of them is this artist, the page resolves to **no** server artist rather
than claiming another act's albums — showing nothing is better than showing someone else's
catalogue as owned. With no id on either side the previous behaviour is kept unchanged: at roughly
4% artist-MBID coverage that is still the common path and must not regress.

**What this does not fix, stated plainly.** It closes the case where the page arrives holding an id —
which is the search-originated route. A page opened by bare name (Now Playing → Go to Artist,
Recently Searched) still resolves through MusicBrainz name search, and that scorer picks
**"ROCKET — Russian rapper"** for the query "Rocket", because every exact-name match ties and
MusicBrainz's own relevance breaks the tie. Closing that means changing name resolution inside the
MusicBrainz layer, which was being rewritten in another working session at the time; it was left
alone deliberately rather than edited concurrently.

**The album-open failure — diagnosed, not fixed.** The message is a handled empty state
(`BrowseAlbumDetailView:777`), not a crash: the view loads and the track-list fetch fails under it.
Two calls fail in sequence. `tracks(forRelease:)` asks `GET /api/v1/album?foreignAlbumId=<mbid>`
(`LidarrAcquisitionPlugin:556`), which queries the request backend's **library** rather than its
catalog — a release not yet requested is by definition absent, so it returns nothing. The fallback
`tracks(artist:albumTitle:)` then runs `album/lookup?term=<artist title>`, which is the same text
search whose metadata-proxy failure was fixed for *requests* earlier; here it is swallowed by `try?`
and reads as an empty track list instead of an error. So it fails for exactly the releases worth
browsing — the ones not yet in the backend's library — and never for albums on the server, which
open a different screen entirely. The fix is the same shape as the request fix (ask by id), but
whether the id lookup returns embedded tracks could not be confirmed without access to that backend,
so it was not applied on a guess.

Verified: `xcodebuild` on the workspace against the iOS Simulator destination, BUILD SUCCEEDED, no
errors and no warnings in the touched file. Built on an isolated derived-data path, because a second
working session was building the same tree and the shared build database locks. Only
`ArtistViewModel.swift` was modified. Not committed and not installed to a device.

---

- [2026-09-03 13:10] **T133 (continued) — off-server releases now get a track list, and the
release-selection rule that was picking by arrival order is replaced.**

Opening a release that is not on the server showed "Couldn't load a track list for this release"
(`BrowseAlbumDetailView:777`). Two calls failed in sequence: `tracks(forRelease:)` asked
`GET /api/v1/album?foreignAlbumId=<mbid>`, which queries the request backend's **library** and not
its catalog — a release nobody has requested yet is by definition absent — and the fallback then ran
the text form of the catalog lookup, which is the same call whose metadata proxy throws. That throw
is swallowed by `try?`, so a failure arrived on screen as an empty track list.

The library is not the catalog. When the album is absent from the library, the catalog is now asked
**by id** (`album/lookup?term=<prefix><mbid>`) and the pressings come back inline on that row. By id
and never by title: asking the same question in words is precisely the call that fails.

**Which pressing supplies the track list.** A release group holds many releases — original,
remaster, deluxe, regional pressings — and their track lists differ, so this is a real choice that
was previously being made by response ordering (the old code walked `releases[]` and stopped at the
first one with any tracks). The rule is now, in order: the **monitored** release, because that is
the pressing the backend will actually fetch and therefore what will arrive; else the release whose
**track count matches the album's own**, which identifies the canonical edition; else the
**shortest single-disc** release; else a stable tie-break on foreign id so the same album shows the
same list on every open rather than flipping as the backend reorders its response.

Shortest rather than longest is deliberate. When pressings disagree, a preview that over-promises is
worse than one that under-promises: bonus tracks that never arrive read as a failed download, while
a standard edition that turns out to have extras reads as a bonus. And the track lists are never
unioned across pressings — that is the tempting fix and the worst one, because it manufactures a
track list that no edition actually has and presents it with more authority than any real one.

**Cached permanently, on purpose.** `AcquisitionTrackListCache` keys on the release-group id and has
no expiry: the songs on a released record are immutable, so re-fetching them on a freshness timer
spends requests to learn nothing. Only user-initiated cache clearing removes an entry. The one thing
never written is a miss — an empty result means the lookup failed or the backend does not know the
release yet, and pinning that permanently would turn a momentary outage into an album that never
shows a track list again.

**Does this fix the error or merely explain it?** It fixes it where the backend's catalog answers,
and the render path confirms there is no third possibility. The string is reachable by exactly one
route, verified from source rather than assumed: `tracklistSection:584` renders it only when
`browseQueuedRows.isEmpty`, those rows derive solely from the two track arrays
(`recomputeBrowseQueuedRows:152-159`), and the note is armed only by `tracksSettledEmpty` — both
loads finished, both arrays empty (`:43-46`, debounced at `:57-61`). No error object or status code
is consulted anywhere in that chain, so a populated track list necessarily removes the message.
What remains honestly unproven is whether the backend embeds track lists in its catalog responses
for every release; where it does not, the list stays empty and the same message appears, now for the
true reason rather than because the wrong endpoint was asked.

Verified: `xcodebuild` on the workspace against the iOS Simulator destination, BUILD SUCCEEDED, no
errors and no warnings in any touched file. Built on an isolated derived-data path, because a second
working session was building the same tree. Not committed and not installed to a device.

---

- [2026-09-03 13:20] **T133 (continued) — the track-list gap is closed, and the earlier hedge can be
withdrawn.**

The previous entry left one thing unproven: whether a request backend embeds track lists in its
catalog responses. Measured against a live Lidarr, it does not, and not occasionally — never. For
`album/lookup?term=<prefix><mbid>` the response carries two pressings, each with `trackCount`, a
`media` array, and **no `tracks` key at all**; the full set of release keys is `albumId`, `country`,
`disambiguation`, `duration`, `foreignReleaseId`, `format`, `id`, `label`, `media`, `mediumCount`,
`monitored`, `status`. That is structural rather than a quirk: an album nobody has added yet has no
backend album id to fetch tracks against, so there is nothing for the catalog to return.

So the id-based catalog lookup added earlier stops the wrong question being asked, but on its own it
could never produce a track list for an album the user does not own. MusicBrainz is the only source
that can, and it is now wired as the final fallback.

`AcquisitionTrackListMusicBrainzSource` asks `/release?release-group=<mbid>&inc=recordings+media`,
which returns every pressing in the group **with its track list inline** — one request, so choosing
between pressings costs nothing extra. It sits in ``AcquisitionManager`` rather than inside one
plugin, because it needs nothing from the plugin except the release-group id and therefore every
backend gets it.

**Which pressing supplies the list**, on the same principle as the backend-side rule: prefer
**Official** status, since a bootleg or promo can carry an order nobody else has and this is the
closest MusicBrainz analogue to "the release you will actually get"; then **single disc before
multi-disc** and **fewest tracks**, which is the standard edition rather than a deluxe or box set;
then a **stable tie-break on release id** so the same album shows the same list on every open rather
than shifting as MusicBrainz reorders its response. Fewest rather than most is deliberate — bonus
tracks that never arrive read as a failed download, while a standard edition that turns out to have
extras reads as a bonus. Track lists are never merged across pressings, which would manufacture a
list no edition actually has. Multi-disc releases are renumbered across the whole release, because
each disc numbers its tracks from one and the naive version shows two track ones.

Cached permanently in the same store as the backend-sourced lists, under its own namespace so the
two sources can never be served as each other. Misses are still never written.

**Verified against the real payload rather than asserted.** For the release group behind the
reported failure, MusicBrainz returns three Official single-disc pressings of eleven tracks each;
the rule selects deterministically among them and yields *Good Fortune, I Can See You From Here,
Halcyon Blues, Is It in My Brain, Always the Last One to Leave*, … — the album's actual track list.

**The hedge in the previous entry no longer applies.** It said the fix worked "where the backend's
catalog answers", leaving open the case where it does not. That case is now the common one and it is
handled, so the empty-track-list message at `BrowseAlbumDetailView:777` is reachable only when
MusicBrainz genuinely has no track list for the release group — a real absence rather than the wrong
endpoint having been asked.

Verified: `xcodebuild` on the workspace against the iOS Simulator destination, BUILD SUCCEEDED, no
errors and no warnings in any touched file. Not committed and not installed to a device.

---

- [2026-09-03 13:30] **T133 (continued) — does the MusicBrainz track list actually fix the reported
error, and a declined change recorded rather than folded in.**

**Answer: yes, for the reported case — a request plugin configured, opening an album from an artist
page.** Traced end to end rather than inferred, and every link verified in the tree as it now stands:

1. An artist page's off-server rows are MusicBrainz release groups, mapped with
   `releaseGroupMBID` set to the group id.
2. `AcquisitionRelease.trackLookupId` encodes that as `mbid:<id>` (`AcquisitionCore:415-419`), and
   the artist page passes it through as the detail view's `albumId` (`ArtistPageView:780`).
3. `AcquisitionManager.tracks(forBrowseAlbumId:)` decodes the `mbid:` prefix, so the release-group
   id is in hand.
4. The plugin's two attempts return nothing — the library lookup because an unrequested album is
   not in the backend's library, and the catalog lookup because that catalog never carries track
   lists at all. Both are now measured facts rather than assumptions.
5. The MusicBrainz fallback therefore runs, and for the release group behind the report it returns
   the album's eleven tracks.

The `isConfigured` guard is upstream of all of this and passes when a plugin is configured, so it
plays no part in the reported failure.

**Known limit, stated rather than papered over.** The fallback needs a release-group id, and it has
one whenever the row came from a MusicBrainz discography — which is every off-server row on an
artist page. A row sourced from a request backend's own catalog search instead carries that
backend's native album id, so `trackLookupId` encodes `native:<id>` and no MusicBrainz id reaches
the manager. Those rows still get no track list. That path is not the one in the report and was left
alone rather than widened on the way past.

**A gap found and declined, recorded so it is not rediscovered.** With **no** request plugin
configured, `tracks(forBrowseAlbumId:)` returns early on `provider.isConfigured` before any
fallback runs. MusicBrainz could supply a track list in that situation and the guard prevents it, so
a plugin-less setup shows no track list for any off-server album even though the data is freely
available. This is a real gap for that configuration. It was **declined for now** as a behaviour
change to a case the reporter is not in, made while fixing something else — the guard is unchanged
and stays unchanged until someone asks for it deliberately.

Verified: `xcodebuild` on the workspace against the iOS Simulator destination, BUILD SUCCEEDED, no
errors and no warnings in any touched file. Not committed and not installed to a device.

---

- [2026-09-03 13:45] **T135 — the artist page rendered owned albums first and rearranged when the
catalogue arrived. Inverted: the catalogue is the list, ownership is marked on it.**

**Where it rendered early, and whose fault it was.** `ArtistViewModel.load` painted the discography
immediately after the server catalog returned, while the MusicBrainz pass was still in flight, so
`applyDiscography` ran with an empty `releases` array and produced a list containing nothing but
owned albums. A moment later the catalogue landed and the same function ran again with a full array,
re-bucketing and re-sorting everything on screen.

This is **pre-existing behaviour, not a regression from the search work** — established from git
rather than from recollection. The call is present at `3027cba:ArtistViewModel.swift:246`, before
any of tonight's changes; later work kept it and added a comment explaining it, which is a different
thing from introducing it. What changed is only that it became visible: the page now resolves to the
right artist and fetches a real discography, so there is finally a large second list to swap in
behind the small first one.

**One list, not two sources merged.** `applyDiscography` walked the server's albums first and
appended unmatched catalogue rows behind them, which made the library the spine of the page and the
catalogue an addendum. It now walks the catalogue (`ArtistViewModel.swift:786`) and marks ownership
on each row: an owned release renders from the server's own copy so it stays playable, an unowned
one renders as requestable, one row per release either way. Albums the user owns that the catalogue
does not list are appended afterwards (`:833`) rather than dropped — the catalogue leads the page,
but it does not get to decide that music the user demonstrably has does not exist.

**Which fix, and why not the other.** Two options: withhold the list until the catalogue answers, or
render a loading state in the discography slot. Withholding was chosen, because the page already has
a skeleton for precisely this state and it is already gated on there being no renderable body
content — so removing the early paint produces the loading state automatically, from the affordance
that already exists. Adding a second one would have put two different loading treatments in the same
region of the same screen, and left the real problem in place: the early list was never wrong, it was
just never the answer, and it moved under the reader while they were reading it.

**The cached case does not wait, measured rather than asserted.** An artist opened before has its
discography on disk, and a second open costs **0 requests and 13.2 ms**, arriving complete with zero
pending rows — so the list renders in full rather than assembling. Evidence:
`docs/verification/t135-cached-open.log`.

**Progressive paging is deliberately unchanged, and should stay that way.** A cold artist with
several pages of releases still fills in page by page behind placeholders. Withholding that too was
considered and rejected, and this is recorded so nobody later reads the paging as an oversight left
over from this fix and helpfully removes it.

Two reasons it stays. It was asked for explicitly when this layer was specified — *"load what you get
back for each request while still showing placeholders for the rest as they come"* — so it is a
deliberate design choice rather than an artefact of the implementation. And it is not the same
behaviour as the defect: **appending is not displacing.** Rows arriving after their neighbours, in
catalogue order, is a page filling in; rows that appear and are then rearranged underneath the reader
is the defect. Only the second one is a problem. Suppressing the first would mean an artist with
several hundred releases showing nothing at all across four sequential requests, which is a worse
trade than either.

The distinction is what makes both correct at once: the fill is catalogue-ordered from the first
page, so a later page extends the list rather than reshuffling what is already on screen.

Verified: `xcodebuild` on the workspace against the iOS Simulator destination, BUILD SUCCEEDED, no
errors and no warnings in the touched file. Not committed and not installed to a device.

---

- [2026-09-03 14:10] **T136 — "Go to Artist" navigated by name, so it landed on whichever artist of
that name a lookup returned. It now navigates by id wherever an id exists.**

**The root cause was a missing field, not a missing check.** `Track` carried the artist's *name* and
nothing else, so every "Go to Artist" from a song had only a string to navigate with. Both backends
already send the artist's id on the track payload — Subsonic as `artistId` on each song, Jellyfin in
the `ArtistItems` it was already being asked for — and both were dropped on parse. `Track.artistId`
is now populated from each, optional so existing persisted snapshots keep decoding.

`ArtistNameNavigation` carries that id alongside the name and exposes `artistPageInput`, which
returns `.libraryArtist` when an id is present and `.named` only when one genuinely is not. An id
short-circuits name matching entirely: `ArtistViewModel.init` sets `resolvedArtistId` from the input
and `resolveServerArtistIdIfNeeded` returns immediately when it is already set, so the name-matching
path that picked the first row of a matching name never runs.

**Sites, and whether an id was available at each.** Enumerated with
`grep -rnE 'ArtistPageView\(input:|SearchNavTarget\.namedArtist|ArtistNameNavigation\(|navigateArtist *=' Sources/VellumMusicKit`
rather than by recollection.

| Site | Id available | Result |
|---|---|---|
| `ServerPlaylistViews` song rows | yes — `track.artistId` | navigates by id |
| `BrowseAlbumDetailView` song rows | yes — `track.artistId` | navigates by id |
| `ServerPlaylistViews` album hero artist | yes, indirectly | id taken from a track *credited to that artist* |
| `BrowseAlbumDetailView` album hero artist | yes, indirectly | same rule |
| `MusicNewTabView`, `NewTabSectionViews` chart rows | **no** | name only — see below |
| `HomeView`, `SubscriptionsView`, `RootView` deep link, artist-page similar artists | **no** | name only |

`AlbumSummary` has no artist id, so the album-hero sites derive one from the album's own tracks —
but only from a track whose artist name actually matches the album artist. On a compilation the
first track's artist is often not the album artist, and navigating to that id would be confidently
wrong, which is worse than the name lookup it replaces. No match, no id, name path takes over.

**The wrong-artist risk that survives, stated so it is not mistaken for fixed.** Chart and browse
rows carry an artist name and no id at all — they describe an artist rather than identify one. Those
sites still resolve by name and can still land on the wrong same-named act. Closing them needs an id
on those models, which is a separate change on a different data path.

**Proved on a same-name case.** Two real artists named exactly "Rocket" — a Russian rapper
(`9e2f71c3…`) and an indie rock band from Los Angeles (`9563966d…`). Navigating from each resolves to
that artist's own id, the two destinations are distinguishable despite identical display names, and
the no-id case still falls back to a name, which is asserted rather than assumed so the surviving
risk stays visible. Verified against the shipping `ArtistNameNavigation`, extracted verbatim.

Also confirmed against a live Subsonic server that song rows really do carry `artistId`
(`'sad robot'` → `artistId 24jpYAI4N8TG0cCAYyzZk5`), so the field the fix depends on is populated in
practice and not merely present in the schema.

**Two sites were left untouched on purpose** — they are in a file another working session owns, and
splitting one coherent change across two agents editing the same file is how one loses the other's
work. The exact change each needs is recorded in the handover note alongside this log.

Verified: `xcodebuild` on the workspace against the iOS Simulator destination, BUILD SUCCEEDED, no
errors and no warnings in any touched file. Not committed and not installed to a device.

---

- [2026-09-03 15:05] **T139 — the artist page resolved the wrong same-named artist. Two causes, both
verified before being fixed.**

The reported symptom was a bulk-request count of 29 on a Rocket page. 29 is arithmetically right and
belongs to a **different Rocket** — the Russian rapper — while the intended act, the Los Angeles
indie band, has 8. A bulk request would have fired 29 requests for the wrong artist's catalogue.

Both diagnosed causes were checked against the tree rather than taken on trust, and both held.

**Cause 1 — the tie-break only counted albums on the connected server.** `ArtistIdentityResolver`
exists to break exactly this tie, but its guard required a non-empty set of *server* albums. Owning a
record through the request backend contributed nothing, so with the artist absent from the music
server the tie fell to MusicBrainz relevance — which ranks the rapper above the band.

**The branch taken: the request backend now votes, and it costs nothing.** Adding an artist to a
MusicBrainz-backed backend *is* an act of identification — the user picked one act out of eighteen
sharing the name and the backend recorded its MusicBrainz id. Better evidence than any ranking. And
free: the profile carrying that id is already fetched for the artist header
(`AcquisitionArtistProfile.mbid`), and identity resolution simply never consulted it. No new request.

Deliberately a **vote among the candidates**, not an override. It can only select an artist who
already matches the name exactly, so if the backend resolved its own artist loosely — its name
matching is a loose containment test — the worst case is that the vote is ignored rather than
followed somewhere unrelated.

**Cause 2 — a race, so even a well-stocked server decided by luck.** The MusicBrainz pass ran as an
`async let` while the server catalog filled concurrently, and the tie-break read that set partway
through. Which artist won depended on which network call returned first, and because a guess is
deliberately never cached, two cold opens could disagree.

Fixed by waiting for the evidence **at the point of decision** rather than serialising the whole
load: the catalog and profile fetches are held as tasks, and only the tie-break awaits them. An
unambiguous artist never pays for the wait, and the parallelism that made the page fast is kept.

The ordering is now reported rather than asserted — the Info panel shows *"Albums available to the
tie-break"*, so a claim that the race is fixed can be checked on the device instead of believed.

**Proved on the real case**, against live MusicBrainz with *R Is for Rocket* owned:

    ranking alone picks: 9e2f71c3… (Russian rapper)
      probe 9e2f71c3… rgs=29  matches=0   (Russian rapper)
      probe d0530f94… rgs=5   matches=0   (DJ Garth & Eric James)
      probe 9563966d… rgs=8   matches=1   (indie rock band from Los Angeles)
    RESOLVED: 9563966d… on 1 owned album match

The tie-break changes the answer: relevance alone would still pick the rapper. Evidence:
`docs/verification/t139-rocket-tiebreak.log`.

**A guess is still never cached**, confirmed after the change. Of six return paths, only the two
decided ones (`:73` request backend, `:113` owned albums) call `cacheDecision`; all three ranking
fallbacks (`:80`, `:86`, `:119`) return uncached. So a coin flip still cannot become sticky.

Verified: `xcodebuild` on the workspace against the iOS Simulator destination, BUILD SUCCEEDED, no
errors and no warnings in any touched file. Not committed and not installed to a device.

---

- [2026-09-03 15:32] **T141 — a dead 119pt band at the bottom of the not-owned album page. Measured
from the screenshots before anything was touched.**

Reported as "the bottom of an album that isn't on the server has a background behind the tab buttons
but shouldn't", with a red circle around a card in the *More By Rocket* shelf. The reporter said
plainly that he was unsure whether the circle and the tab buttons were the same element. They are —
one cause, two symptoms.

**No extra background is being drawn, and that matters for the fix.** The band is the page backdrop,
proven by sampling: `#86A7D0` inside the list at y=900 and y=2100, and `#86A7D0` in the band at
y=2560 and y=2860. Identical. What differs is that nothing *covers* it there.

**What actually differs.** The two pages render the same shelf and the same card
(`MusicDesignSystem.swift:516-517`, 168×168 plus a 56pt label block). On the library page the card
is 168×168pt with rounded corners top *and* bottom and its title beneath it. On the not-owned page
the same card is 168×**102**pt — rounded top corners, hard square bottom edge, no title. The cut is
one straight line at y=2510-2511 across both cards. Below it, 357px = 119pt of bare backdrop to the
screen edge, while the library page draws real artwork at y=2500 and y=2700 and content right down
to y=2860.

So the not-owned page's scrolling content stops 119pt above the screen bottom, uncovering the
backdrop and guillotining whatever row straddles the boundary.

**Cause, at one line.** `BrowseAlbumDetailView.swift:284` carried `.padding(.bottom, 36)` — the only
bottom-inset difference between the two List modifier chains. Padding the List's *frame* stops it
bleeding into the bottom safe area, so the inset was 36pt of padding **plus** the 83pt of tab bar
and home indicator it could no longer extend under. 36 + 83 = 119pt, which is the measured band
exactly. The intent was presumably to keep the last row clear of the mini player: a fair goal, the
wrong instrument.

**Driven by ownership, or merely correlated? Correlated.** Ownership selects nothing but the view
type — `ArtistPageView.swift:1471-1474`, `.libraryAlbum` → `ServerPlaylistDetailView`, `.remote` →
`BrowseAlbumDetailView`. No missing artwork colour, no absent server id, no different backdrop
derivation is involved, which the identical band colour proves. The consequence worth knowing:
`BrowseAlbumDetailView` is the browse/chart detail view generally, so this band was on **every**
browse album page, not only ones reached from the artist page.

**Which side was correct: the library page**, and not because more albums are owned. It is the
platform convention and what every other scroll surface in this app already does; the alternative
permanently sterilised 119pt of a 956pt screen, 12% where no content could ever appear; and it
produced the exact artefact that was circled — a card cut mid-artwork with its title unreachable,
which no amount of scrolling fixes because the boundary is pinned to the List's frame rather than to
the content.

Fixed by deleting the padding rather than substituting a content inset. The reference page has no
bottom margin of its own, so adding one here would have made the two differ again in the other
direction; the safe area supplies the inset that lets the last row clear.

Measurements: `docs/verification/t141-bottom-band-measurements.log`.

Verified: `xcodebuild` on the workspace against the iOS Simulator destination, BUILD SUCCEEDED. Not
committed and not installed to a device.

---

- [2026-09-03 15:29] **T144 — Play Next on the album overflow menu, reusing the playlist menu's own
action rather than adding a second one.**

The album ⋯ menu (`ServerPlaylistViews.swift:2538`) was the thinner of the two. Enumerated against
the playlist menu (`:1696`), the album menu had **Download Album, Add Album to Library, Pin, Delete
Album from Library, Navidrome share** — and was missing **Favorite, Share, Add to Playlist, Play
Next** from the playlist's set. (Edit / Sort By / Kill Mode / Delete playlist are playlist-only by
nature: an album has no editable name or ordering to change, and Kill Mode prunes a playlist.)

**Play Next was the one asked for by name, and every other album surface already had it** — the
album cell long-press menu (`LibraryCellContextMenus.swift:49`) and the off-server album page
(`NewTabChartOverflowPanel.swift:311`, used by `BrowseAlbumDetailView`). The album *detail* menu was
the only album surface without it, so this fills a hole rather than starting a pattern.

**No second path was built.** `playPlaylistNext()` (`:2489`) is named for the mode it was written in
but is not playlist-specific: it queues `tracksForPlayback` (`:2446`) =
`displayedRows.map(\.track)`, the same array album-mode hero Play already uses (`playAll()`,
`:2457`), and calls `PlaybackEngine.playTracksNext(library:tracks:sourcePlaylistId:)`
(`PlaybackEngine.swift:739`). The album menu calls that function. One route from this screen to the
queue, not two that can drift.

**The album-not-on-the-server case, stated rather than assumed.** `displayedRows` holds only rows
backed by a real server `Track`; an album's missing tracks live in `mergedRows` as `.missing`
previews and never reach it (`computeAlbumMergedRows`, `:832`). So on a partly-held album Play Next
queues the part that exists, and on one the server holds none of, `displayedRows` is empty and the
item renders **present but greyed** — the same treatment the off-server album page already gives it
(`NewTabChartOverflowPanel.swift:320-328`). Present-and-disabled was chosen over hidden so the menu
does not change shape between two albums that look identical to the reader.

Not touched: `BrowseAlbumDetailView.swift` and the MusicBrainz files, which other terminals were
editing at the time. `ServerPlaylistViews.swift` had no activity since 14:43.

Verified: `xcodebuild` on the workspace against the iOS Simulator destination, BUILD SUCCEEDED. Not
committed and not installed to a device.

---

- [2026-09-03 15:41] **T145 — Add to Playlist and Favorite on the album overflow menu, both reusing
the existing actions.**

Follows T144. The album ⋯ menu (`ServerPlaylistViews.swift:2539`) now carries the two remaining
items the playlist menu had and it did not.

**Neither is a new action.** *Add to Playlist* calls `app.presentAddToPlaylist(tracks:)` on
`rows.map(\.track)` — the same call on the same array the playlist menu makes at `:1745` and the
off-server album page makes at `NewTabChartOverflowPanel.swift:307`. *Favorite* calls
`toggleAllTrackFavorites()` (`:2045`) and reads `allTracksFavorited` (`:1679`), both already used by
the playlist menu (`:1707`) and the home-mix menu (`:2515`). Both read `rows`, which was never
playlist-specific.

**Favorite is state, not a fixed word.** It reads *Favorited* with a filled star once every track on
the album already is, and *Favorite* otherwise — the same expression the playlist menu uses. A label
that never changes is a button pretending to be a toggle.

**The empty case, decided rather than assumed: present and greyed, both items.** `rows` holds only
rows backed by a real server `Track`, so an album the server holds none of leaves it empty and both
items disable. Hiding them was rejected on the grounds that decided T144: two albums that look
identical to the reader should not open menus of different shapes, and a visibly unavailable item
teaches more than an absent one. Add to Playlist earns the guard on its own — adding zero tracks to
a playlist *succeeds* and does nothing, which is exactly the "looks like it worked" failure worth
designing against. Favouriting is per-track, so with no tracks there is nothing to favourite. This
matches what the off-server album page already does (`NewTabChartOverflowPanel.swift:320-328`).

**One shape change fixed on the way past.** The top `ControlGroup` was wrapped in
`if !showsDownloadedAlbumCheckmark`, so a fully-downloaded album lost the entire row — including
items with nothing to do with downloading. The group is now unconditional and each item keeps its
own condition, which is what lets Favorite survive a downloaded album.

Album menu as it now reads: Download Album / Add Album to Library / **Favorite** · Pin ·
**Add to Playlist** · Play Next · Delete Album from Library · Navidrome share.

Verified: `xcodebuild` on the workspace against the iOS Simulator destination, BUILD SUCCEEDED. Not
committed and not installed to a device.

---

- [2026-09-03 17:05] **T148 — a credit line was being used as an artist name for navigation. It was
never a new navigation; it was a new *source* feeding an old one.**

**The path, named.** Discover search → a request row → tapping the artist on the row's second line.
`DiscoverySearchView.swift:1509` read `result.artists.first` as a name and `:1525` handed it to
`SearchNavTarget.namedArtist(...)`. For the reported track — Rich Brian's "Is It?" — that string is
`"Rich Brian feat. Charlotte Day Wilson & DAISY WORLD"`, so the push was
`ArtistPageView(input: .named("Rich Brian feat. Charlotte Day Wilson & DAISY WORLD"))`. That is the
whole reported symptom: the page title is `ArtistPageInput.displayName`, which for `.named` is the
string it was given, and nothing resolves it, because no artist is called that.

**Which change introduced it, plainly: commit `9579592`.** The navigation call at `:1525` is
*older* than that commit and is byte-identical in `9579592^`. What changed is what flows into it.
Before `9579592` the tree contained **no MusicBrainz code at all** (`git ls-tree 9579592^` →
zero `MusicBrainz*` files; zero `MusicBrainz` references in `DiscoverySearchView.swift`), so the
only producer of `AcquisitionResult.artists` was a request plugin, which reports one artist name.
`9579592` added `MusicBrainzSongRow.artist` (`MusicBrainzSearchFeed.swift:49`) and
`MusicBrainzReleaseGroup.searchRowArtist` (`MusicBrainzDiscographyMapping.swift:57`), both of them
`artistCredit?.creditLine`, and routed both into that same `artists` array. A field documented as a
name started carrying a label, and every reader of it inherited the bug without being edited.

**The other render sites, checked rather than assumed.** Three places were supposed to have the
`displayArtist` / `navigationArtist` split. Only one of the three actually renders a credit today,
and it is not the one that got the treatment:

| Site | Renders the credit? | Navigates by | Verdict |
|---|---|---|---|
| `DiscoverySearchView.swift:1509` request row subtitle | yes | `namedArtist(credit line)` | **the defect** — fixed |
| `DiscoverySearchView.swift:2305` `AcquireResultDetailView` artist line | yes | MBID, but `name:` was the credit line | **half-broken** — right destination, page *titled* with the credit line; fixed |
| `BrowseAlbumDetailView.swift:23` `artistCredit` | **no** | name (`navigationArtist`) | **inert** — see below |

`BrowseAlbumDetailView.artistCredit` is the parameter that got the careful split, and **nothing in
the tree passes it**: `grep -rn 'artistCredit:' Sources` returns its own declaration and two
MusicBrainz model fields, and no call site. `AcquisitionRelease.displayArtistLine`
(`AcquisitionCore.swift:432`) had no reader either — `asSearchResult` used `artist` instead. So the
album screen never displayed a credit and never could; the split there is correct and unreached.
Reported, not wired, because wiring it changes what the album page *shows*, which is not what T148
asked for.

`AcquireResultDetailView`'s guard is worth naming separately, because it was written to prevent
exactly this and did not fire. It read `guard result.artists.count == 1` — "only navigate on a
single credited artist". Against a MusicBrainz row a three-artist credit arrives as **one array
element**, so the count is 1 and the guard waves it through. Counting names cannot tell a
collaboration from a solo release once the names have already been joined into a string.

**Primary, not a chooser — stated because it was asked.** "Go to Artist" opens the **primary**
credit. A featured performer is credited on the record, not the author of it, and every other
artist affordance in the app already means "the artist this is by" (the Now Playing bar, the album
hero, a song row). A picker here would make this the one surface in the app where tapping an artist
asks a question back.

**And by id.** `SearchNavTarget.primaryArtist(of:)` prefers `request.artistMBID` — the primary
credit's own MBID, which the row already carries — and falls back to a name only for a plugin row
that never had an id. Resolving `"Rich Brian"` by name would have swapped one wrong-artist bug for
the one T136/T139 spent the afternoon removing.

**The fix restores the invariant `AcquisitionRelease` already documented for itself:** `artists`
holds names and is what gets navigated, matched and requested; the credit line rides alongside in a
new `AcquisitionResult.artistCreditLine` and is what gets *rendered*. `displayArtistLine` is the
label, `primaryArtistName` is the destination, and the proof asserts the two are different strings
so a later tidy-up cannot collapse them back.

Two consequences beyond the report, from the same root and fixed by the same change:

- `MusicBrainzReleaseGroup.searchRowArtist` fed `AcquisitionRequest.artist` for MusicBrainz album
  rows — the exact string `AcquisitionRelease.artistCreditLine`'s own doc comment says must never
  go there ("would … make the request backend report the artist as unknown"). It is now the primary
  name.
- The same string keyed `seenReleaseKeys` / `serverAlbumsByReleaseKey` against the server's *album
  artist*, so a MusicBrainz row for a collaboration could never dedupe against the server's own copy
  of it. Keying on the primary name lets it.

`MusicBrainzSongRow.artist` deliberately stays the credit line: its two remaining readers
(`DiscoverySearchView.swift:487,494`, `MusicBrainzSearchFeed.swift:325`) match it against a server
*track*'s artist tag, which is commonly the full credit, and neither navigates.

**Proved on the reported track, against the live payload.** `docs/verification/t148-is-it-recording.json`
is the real MusicBrainz response for recording `61694497-…` ("Is It?", credited to three artists);
`docs/verification/t148-credit-line-nav-proof.swift` drives `creditLine` / `primaryArtistName` /
`primaryArtistMBID` and both navigation expressions extracted verbatim from the shipping source. The
BEFORE checks are asserted as a **reproduction** — they pass when the bug is present — and the AFTER
checks assert the fix. Output in `docs/verification/t148-credit-line-nav.log`:

    credit line as rendered: "Rich Brian feat. Charlotte Day Wilson & DAISY WORLD"
    primary credit:          "Rich Brian" (49d67664-6962-4f69-adc4-f52208c78dd2)
    BEFORE  reproduced: the page is titled with the whole credit line
    BEFORE  reproduced: the destination is a name lookup, so it resolves to nothing
    AFTER   the row still shows everyone on the record
    AFTER   the artist page is titled with a person's name  -> "Rich Brian"
    AFTER   the destination is an identity  -> MBID 49d67664-6962-4f69-adc4-f52208c78dd2
    VERDICT: PASS

**Not reproduced end-to-end on the reporter's own library, and this is the honest limit.** The track
is not on the demo server this tree can reach (`demo.navidrome.org`), so the chain above is proved
from the real MusicBrainz payload through the shipping expressions rather than from a screenshot.
One detail of the report is explained by the reporter's own server rather than by this code: an
artist page for a name nobody has still shows **one top song** when a completed scrobble carries
that same string (`ArtistViewModel.scrobbleTopSongs` matches `normalize(scrobble.artist)` against
the page's display name), which is consistent with a file tagged with the full credit.

**Flagged, then taken on a separate instruction — T136 Site 1.** `DiscoverySearchView.swift:1327`,
the server song row's "Go to Artist", was navigating `namedArtist(track.artist)` with
`track.artistId` sitting in scope. A different defect from T148 — a server tag, not a credit line —
so it was reported and left. It was then asked for explicitly and applied verbatim from
`docs/verification/t136-discoverysearchview-handover.md`, which is now marked CLOSED: Site 1
applied, Site 2 **superseded** by T148's `SearchNavTarget.primaryArtist(of:)` and marked
do-not-paste, because pasting it would pass the credit line as the destination's `name:` and
reintroduce the wrongly-titled artist page this entry is about.

The handover's own post-apply criterion was run rather than asserted:
`grep -n "SearchNavTarget.namedArtist" Sources/VellumMusicKit/DiscoverySearchView.swift` returns
four occurrences, every one of them the fallback branch of an id check — `:62`
(`primaryArtist(of:)`, no `request.artistMBID`), `:266` (`NamedArtistMatch.navTarget`, no
MusicBrainz hit), `:1336` (Site 1, no `track.artistId`), `:2023` (recent-search rows, no recovered
MBID and off-server).

Verified: `xcodebuild` on the workspace against the iOS Simulator destination, BUILD SUCCEEDED, no
errors and no warnings in any touched file. **Joint green, not a clean-room result** — the tree
carried twelve other modified files and two untracked additions from terminals 8 and 12 at build
time, including edits inside `DiscoverySearchView.swift` itself (`requestRemoveSongFromLibrary` /
`LibraryRemovalConfirmation.swift`), so this compiled their uncommitted work alongside mine. An
earlier run in the same session failed on `ServerPlaylistViews.swift:1048` with a type-checker
timeout in a file this work never opened, and passed on the incremental rerun. Not committed, index
untouched, not installed to a device.

## T162 — a song that cannot be played is skipped, and the guard is the feature

The ask was auto-skip. The part that took the work is the part that stops it: three tracks failing
in a row now halts playback and says which of the two things went wrong, because the failure
reported on the night this was raised was a **server outage**, and an auto-skipper without a guard
would have turned that outage into a queue emptying itself in silence.

**The failure modes, enumerated before anything was written.** Everything funnels through
`startCurrentItem` (`PlaybackEngine.swift:2355`), which builds a candidate ladder — offline copy,
committed stream-cache file, then every stream URL the client can spell — and only gives up when
each rung has failed (`:2413-2432`, throw at `:2451`). Six shapes reach it:

1. **Missing on the server.** A track id that died in a rescan, or a file deleted underneath the
   library. Item goes `.failed` at `:2270`. There is already a dedicated recovery in front of this
   one — `recoverStaleTrackOnFailure` (`:2438`) remaps swapped ids — so this bucket is what is left
   after that fails. Permanent.
2. **Undecodable container or corrupt bytes.** Two different shapes, and only one of them looks
   like an error. The item can go `.failed` with `NSOSStatusErrorDomain` (`isUnreadableStreamCacheError`,
   `:2430`), **or** it can go `.readyToPlay` and then simply never produce audio — caught by
   `playbackFailedAfterReady` (`:2285`), whose caller previously flattened the whole case into a bare
   `URLError(.cannotParseResponse)` at `:2427`. That flattening is why an outage and a bad file were
   indistinguishable downstream. Permanent.
3. **Network failure.** No route, DNS, refused connection, connection lost mid-handshake. Arrives
   either as `.failed` or as the ready-timeout at `:2279`. Transient.
4. **HTTP error status.** 404, 401/403 after a token expires, 5xx from a sick server.
   `NSURLErrorDomain` collapses *all* of these into one `.badServerResponse`, so a dead track and a
   dead server are the same error object at this layer. Split by reading
   `AVPlayerItem.errorLog()` — see below.
5. **Truncated / poisoned stream-cache file.** Candidate injected at `:2383`; already evicted on
   decode failure at `:2430`. Permanent for that rung, recoverable from the network.
6. **Gapless promotion onto a staged item that went bad.** `promoteToEnqueuedNext:3120`. This one
   **has no candidate ladder at all** — the item was staged while the previous track played and is
   the only thing ever tried — so it is the single path where an ordinary blip reaches the policy
   with nothing behind it. Handled explicitly.

A seventh, adjacent: `AVPlayerItemFailedToPlayToEndTime` mid-song (`:2914`) routes into
`handleEnded`, whose spurious-end recovery reloads in place once and then advances. That is the
exact shape a server dying mid-playback takes, and it feeds the advance path that now counts.

**Transient vs permanent, and how the code tells them apart.** `PlaybackFailurePolicy.classify`
(new file, `PlaybackFailurePolicy.swift`) unwraps `NSUnderlyingErrorKey` innermost-first, because
AVFoundation almost always hands over an `AVFoundationErrorDomain` wrapper with the real cause two
or three levels down; reading only the top-level error puts everything in one bucket. Network
`URLError`s, 5xx, 408/429 and anything unrecognised are **transient** and earn one reload after a
1.2 s backoff. `NSOSStatusErrorDomain`, decode/parse `AVError`s, 4xx and missing files are
**permanent** and are given up on immediately — re-requesting bytes a decoder already rejected is
theatre that costs the listener another load timeout.

**The HTTP status is doing real work here, not decoration.** `AVPlayerItem.errorLog()` carries
`errorStatusCode`, and it is the only thing in the system that separates a 404 (this track is gone,
skip it) from a 503 (the server is sick, retry it) — `URLError` gives both the same code. It is
captured at the two places a load actually dies (`:2271`, `:2565`) and passed into the classifier.
Unrecognised errors are deliberately treated as transient: a wrong retry costs about a second, a
wrong skip silently loses a song the user asked for.

**The guard. Threshold is three consecutive tracks given up on** — retries do not count, so three
means three songs, not three attempts. Two was rejected because two dead files next to each other
is ordinary in a real library (a partial import, one bad album side) and halting on those would
read as the app being broken; three in a row is not a coincidence. When it trips, playback stops
where it is, the queue is left intact, and `errorMessage` raises the app's existing alert with one
of two texts chosen by majority vote over the streak's causes:

- server-side — *"Playback stopped: 3 songs in a row couldn't be loaded from your server. This is a
  connection problem, not an empty playlist — the songs are still there. Check that the server is
  running and reachable, then press play again."*
- otherwise — *"…3 songs in a row couldn't be played. They're either missing from the server or in a
  format iPhone can't decode. The rest of the queue is untouched…"*

Majority rather than "any", so one dead file inside an outage cannot flip the diagnosis away from
the outage, and one blip inside a run of bad files cannot flip it toward one. The counter clears on
any track that reaches confirmed playback and on every deliberate transport action, so three unlucky
tracks spread across an hour of good listening never add up to a halt.

**Alert, not toast, and that required a second change.** The per-skip notice is a transient toast
("Skipped “Title” — the file is missing on the server"), which is right: the queue is still playing
and nothing is blocked. The halt is not that. A 1.8 s message that disappears is precisely how "my
server is down" gets mistaken for "this playlist is empty", so it goes through `errorMessage`. But
`LibraryErrorAlertChrome` was applied only at the root of `RootView`, and the Now Playing cover
occludes the root overlay — the same occlusion the toast and two other alerts already carry
duplicates for, each with a comment saying so. The halt is *most* likely to fire while the user is
watching the player, so the cover now carries its own copy too (`RootView.swift`, alongside
`.musicQueueReplacementChrome()` / `.libraryRemovalConfirmationChrome()`).

**One thing the auto-skip deliberately does not do: it never calls `skipNext()`.** That fires
`onTrackSkipped`, which is Kill Mode's "the user rejected this song, mark it for removal" signal. A
track the server could not serve must never be marked for deletion on the user's behalf, so the
skip moves `currentIndex` directly (`autoSkipIndex():1764`, which also refuses to honour repeat-one
— `nextAdvanceIndex()` returns the *current* index there, which would reload the failed track
forever).

**Opus: ruled out as a cause here, with evidence.** The historical finding was real but was about a
**setting**, not this library's files: commit `55306e3` removed `.opus`/`.ogg` from
`StreamFormatOption` and `.opus` from `DownloadFormatOption` because the app could be told to *ask*
the server for a format AVFoundation cannot decode. That is gone, and downloads that arrive in one
of those containers are rejected at download time with an actionable message
(`OfflineDownloadManager.swift:708-712`). On the **streaming** path an Opus original cannot strand
playback either, because the candidate ladder already transcodes away from it: Navidrome offers
raw → mp3 → aac (`NavidromeClient.swift:561-577`) and Jellyfin maps `opus` straight to an mp3
container before adding mp3 / universal-mp3 / m4a / aac / universal-aac fallbacks
(`JellyfinMusicClient.swift:637-680`). `startCurrentItem` walks all of them. **Two residual cases
are not ruled out and are stated rather than dismissed:** a legacy `.opus` download saved before
`55306e3`'s guard is still candidate #0 and becomes a hard failure if the server is also
unreachable (nothing to fall back to); and a server that cannot transcode — no ffmpeg, or
transcoding disabled — returns the same Opus bytes on every rung. Neither was verifiable from here:
the library lives on a server this session has no credentials for, and the simulator container
(`com.randll.vellum.plist`) holds only equaliser keys, no server or format state. Both are
classified `.undecodable` and skipped rather than stalled, which is the correct behaviour whichever
way they resolve.

**Timing, honestly.** With a host that refuses connections — the actual outage shape — each rung
fails fast and the guard trips in seconds. With a host that accepts TCP and never answers, each rung
burns up to the 22 s ready budget and the retry doubles it, so the halt can be a minute or more out.
That is the safe direction to err given the brief ("must not tear through the queue"), but it is a
real cost and it is not hidden: each skip toasts as it happens.

Verified: `xcodebuild` on the workspace, `generic/platform=iOS Simulator`, **BUILD SUCCEEDED**, no
errors. Build ran with `-derivedDataPath /tmp/t162-scratch/DerivedData` **and**
`MODULE_CACHE_DIR=/tmp/t162-scratch/ModuleCache`; the shared
`~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex` was fingerprinted before and after
(mtime `1788470951`, 777 files, 349 MB — identical both times) and nothing in DerivedData was
cleaned, deleted or written. Note for the next agent: **`-clang-module-cache-path` is not an
xcodebuild flag** — passing it makes xcodebuild print its usage and exit 0 *without building*, which
is exactly how an agent silently gets no isolation. `MODULE_CACHE_DIR` is the xcodebuild spelling
and it does work (174 MB / 353 files landed in the scratch cache on the first run).
`docs/verification/t162-failure-policy-proof.swift` compiles **against the shipping
`PlaybackFailurePolicy.swift`** rather than a copy of it, so it cannot drift: 40 assertions covering
classification, the 404-vs-503 split, the majority-vote diagnosis and the streak lifecycle, ALL
PASSED. **Joint green, not a clean-room result** — the tree carried 29 other modified/untracked
files from the day's other terminals at build time. `ServerPlaylistViews.swift` was not opened.
Not committed, index untouched, not installed to a device.

## T189 — Wrong album cover + owned tracks shown "Not in library" (diagnosis only, 2026-09-06)

Shinedown "Threat To Survival" showed the "Us and Them" cover, and three owned tracks
(Asking for It, State of My Head, Outcast) were listed "Not in library" while Cut The Cord
was listed as owned. No code was changed for this investigation.

What the server actually holds. Navidrome album 1lhSZb8QhQE6LUYXHQPYJk has 19 media_file rows,
but 8 of them are missing=1 — the files are gone from disk. The album is stitched from three
folders: lidarr/Shinedown/Threat to Survival (2015) (11 FLACs, present, and the only one of the
three that holds cover/folder/discart images), plus downtify/ and fills/Shinedown/ (8 loose mp3s,
all now deleted). Note that album.missing=0 is an album-level flag and does NOT mean "no missing
tracks"; the per-file column is where the 8 show up. Navidrome's own art for this album resolves
to the correct cover.jpg, so the server is not at fault.

Where the wrong values come from. Both symptoms are produced by the same store — the offline
download manifest — which outranks the server on both the image and the tracklist, keyed by album id:

- Artwork: AppModel.swift:1476, the first line of resolvedArtworkURL(for album:), returns
  offline.localArtworkURL(forAlbumId: album.id) before any Navidrome getCoverArt URL is built.
  The album page hero reads exactly that (ServerPlaylistViews.swift:688).
- Tracklist: ServerPlaylistViews.swift:2383-2388 replaces the server tracklist wholesale with
  offline.cachedTracks(forAlbumId:) when that set is non-empty and fully downloaded. The server
  fetch at :2390 is then never reached. Any catalog track without a matching row renders through
  missingAlbumRow (:2196) with the literal subtitle "Not in library" (:2210).

So a single offline-downloaded track for this album (Cut The Cord) is enough to make the page show
one owned row and mark every other track missing, and to pin the hero image to whatever artwork was
captured beside that download. That matches the screenshot exactly.

Not proven. Which image bytes are in the offline manifest cannot be read without a device build,
and the 8 deleted mp3s no longer exist to inspect, so "why specifically Us and Them" is inference,
not evidence. What would settle it: read the offline manifest and its artwork folder off the device.

Scale. 6,234 of 11,601 albums contain at least one missing media_file, so the stitched-album
condition behind this is library-wide, not specific to Shinedown.

Smallest fix. Treat the offline manifest as a supplement, not a replacement: at
ServerPlaylistViews.swift:2384 use offline rows only when the server is unreachable, and at
AppModel.swift:1476 consult offline artwork only after the server-derived cover art id, not before.

## T113 — Can artwork cache keys collide across distinct albums? No. (read-only check, 2026-09-07)

Verdict: no. There are three artwork cache keys in the app and none of them can put one album's
cover on another album. Nothing was built and no source file was edited for this check.

1. Cover bytes (memory + disk) — ArtworkURLCache.swift:105. The key is the SHA-256 of the request
   URL, hex-encoded. The URL is first normalized (ArtworkURLCache.swift:113) by dropping only the
   Subsonic auth params t and s and sorting the rest, so a fresh salt or a different query order
   still lands on one key. The cover id stays in the key, so two albums have two different
   preimages, and colliding would require an actual SHA-256 collision. That is the property doing
   the work: a 256-bit digest over an input that already contains the album's cover id.

2. Decoded images — ArtworkImageDecoder.swift:77. The key is not hashed at all; it is the same
   normalized URL string with the pixel size appended. It contains the cover id literally, so
   distinct albums are distinct keys by construction.

3. Backdrop palette — ArtworkDynamicGradient.swift:45. This one is the loosest: it keeps only the
   URL path plus the identity params (id, coverart, size, tag) and drops scheme, host and port. For
   Navidrome the path is the same for every cover, so the id is the only discriminator. It is always
   present, because NavidromeClient.coverArtURL sets it unconditionally (NavidromeClient.swift:1042).
   Two things are worth knowing anyway: a cover URL carrying no identity params at all would collapse
   to "path|style" and collide with every other such URL, and because the host is dropped, two
   different servers sharing a path and id would share a key. Neither is reachable through the
   current URL builder. And this cache holds a colour palette, not an image, so even a collision
   here would tint a backdrop wrongly, not show the wrong cover.

Checked with the real ids from the Shinedown case: album al-1lhSZb8QhQE6LUYXHQPYJk (Threat To
Survival) and al-6PF8WS6aU0NULMmu8KxcdS (Us And Them) produce different keys in every one of the
three schemes.

So the wrong-cover mechanism is not here. It remains what T189 described: the offline download
manifest is consulted before the server for both the cover and the tracklist.
