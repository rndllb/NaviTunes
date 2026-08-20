# Kill Mode v2 + Car Queue Counter — Design

Date: 2026-06-19
Status: Approved (design); pending spec review

Two independent features bundled in one spec because both touch `PlaybackEngine`
playback/now-playing flow.

---

## Feature 1 — Car radio queue counter

### Problem
Car head units / CarPlay show "1/1" for every track instead of "N/M". Cause:
`PlaybackEngine.updateNowPlaying(_:artwork:)` (`PlaybackEngine.swift:2864–2892`)
never sets the queue-position keys, so the head unit derives the counter from the
underlying `AVQueuePlayer`, which is fed one item at a time → count is always 1.

### Fix
Inside `updateNowPlaying`, add to the `now` dictionary before it is written back:

```swift
now[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex   // 0-based; OS shows +1
now[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
```

- `currentIndex` and `queue` are already maintained on the engine (`PlaybackEngine.swift:44–45`).
- `updateNowPlaying` is the single chokepoint for both the AVPlayer and the EQ
  (`EqualizedAudioEnginePlayer`) paths, so both get the correct counter.
- In shuffle the queue array is already in shuffled order, so `currentIndex`
  reflects the displayed position. No change to how the AVQueuePlayer is fed.

### Out of scope
Feeding the whole queue into a real `AVQueuePlayer`. The two metadata keys are
what head units read; the single-item feeding stays.

---

## Feature 2 — Kill Mode v2 (listen-once culling)

### Goal / mental model
With kill mode ON for a playlist, starting it gives a "pass" where each not-yet-heard
song plays exactly once:
- Let it **play fully to its natural end** → **green (kept)**.
- **Skip** it (forward skip) → **red (marked for removal)**.
- Either outcome marks the song **listened**; it is excluded from future runs until
  the user clears listen history.

This lets the user iteratively cull a playlist: each run surfaces only songs not yet
judged, and a "clear listen history" pass lets them re-judge the kept songs.

### State model

| Set | Meaning | Populated by | Persistence |
|---|---|---|---|
| **red** = `killModePendingRemovals[pid]` *(exists)* | skipped → removal candidates | `handleKillModeSkip` via `onTrackSkipped` (forward skip only) | existing `KillModeStore` key `lyra.killMode.pendingRemovals` |
| **green** = `killModePassedTrackIds[pid]: Set<String>` *(new)* | played fully to natural end | **new** `onTrackCompleted` callback from `handleEnded` | **new** `KillModeStore` key `lyra.killMode.passed` |
| **listened** = `red ∪ green` (derived) | blacklist for future runs | — | — |

Rules:
- Both red and green **persist across disable → re-enable** (only "Clear listen
  history" resets green; Keep/Remove manages red). Confirmed with user.
- **Skip wins over pass:** when a track is skipped, remove it from green if present,
  add to red.
- Marking is **gated on an active kill-mode session**: `player.playbackSource ==
  .playlist(p)` AND `p.id ∈ killModeEnabledPlaylistIds` — same guard as today's
  `handleKillModeSkip` (`AppModel.swift:2800–2810`).

### Behavior changes

**B1. Green marking (new `onTrackCompleted`).**
Add `PlaybackEngine.onTrackCompleted: ((Track, PlaybackSource?) -> Void)?`. Fire it in
`handleEnded(...)` (`PlaybackEngine.swift:2525–2609`) for the outgoing track when it
reached its **natural end** (not on skip — skip goes through `skipNext`). Wire in
`AppModel` (near the other player callbacks, ~`AppModel.swift:900–917`): if the source
is a kill-mode playlist, insert the track id into `killModePassedTrackIds[pid]` (unless
it is already red) and persist.
- Repeat-one edge case: kill mode + repeat-one is contradictory (it would replay a
  just-completed song). We mark green on natural end regardless; the advance guard
  (B2) prevents a listened song from replaying. Acceptable edge; documented, not
  specially handled.

**B2. Blacklist enforcement — filter at play-start (recommended approach).**
When playback starts for a `.playlist(p)` source with kill mode enabled, drop tracks
whose ids are in `listened(p)` from the track list before building the queue; adjust
the start index. An explicitly tapped listened track is honored as an override (kept as
the start; the rest are still filtered).
- Seam: the central play entry `AppModel.playAlbumOrToast(tracks:startIndex:source:)`
  (called from `ServerPlaylistViews.swift:2090`). A helper
  `killModeFilteredPlayback(tracks:startIndex:source:) -> (tracks, startIndex)` applies
  the filter when `source` is a kill-mode playlist; otherwise passes through unchanged.
- Plus a lightweight advance-time guard so repeat-all cannot resurrect a listened song
  mid-run (skip over ids in `listened(p)` during `handleEnded` slow-path advance when
  the current source is a kill-mode playlist).
- Rejected alternative: skip-on-advance only. It does not handle the Play button / tap
  cleanly and scatters the logic across every advance path.

### UI

**U1. Summary header on the "Songs to Remove" screen (`PlaylistKillListView`).**
Confirmed placement: the dedicated kill-mode review list, at the top of the `List`
(above the `ForEach(visibleRows)`, ~`PlaylistKillListView.swift:34–35`), as a
non-selectable header row/section.
- Content: `% listened` = `|red ∪ green| / total`, `% removed` = `|red| / total`,
  with counts (e.g. "18 of 40 listened · 5 to remove") and a thin two-segment progress
  bar (green = kept portion, red = removal portion).
- `total` = playlist `songCount ?? rows.count`.
- Needs the green set + total available to the view. `PlaylistKillListView` already
  receives `playlistId` and `rows`; it reads green via `app.killModePassedTrackIds`
  and red via existing `app.killModePendingOrderedTrackIds`.

**U2. "Clear listen history" button (on the same screen).**
Placed in the summary header / toolbar of `PlaylistKillListView`. Resets **green only**
(`killModePassedTrackIds[pid]`), so kept songs become eligible again next run; the red
removal queue is untouched. New `AppModel.clearKillModeListenHistory(playlistId:)` that
clears green and persists. Confirm-on-tap is unnecessary (non-destructive to the
removal queue); a transient toast confirms.

**U3. Row tints on the MAIN playlist tracklist (`ServerPlaylistViews.swift`, ~line 1176).**
Only when kill mode is on for the displayed playlist:
- red row → track id ∈ pending removals
- green row → track id ∈ passed
- normal → otherwise
- Backdrop-adjusted color: follow the existing `heroAccent` pattern
  (`palette.prefersDarkHeroChrome ? color.opacity(0.92) : color`) with a subtle
  `listRowBackground` fill, modeled on `heroBackdropSongListRowStyle`
  (`LibrarySongsView.swift:1039–1048`). The view already holds `backdropPalette`
  (`ServerPlaylistViews.swift:685`). New helper `killModeRowTint(state:palette:)`.
- Base colors: system red / green, tuned to a low background opacity so they read as a
  tint, not a fill, on both backdrop and plain surfaces.

### Persistence (`KillModeStore.swift`)
Add a third key alongside the existing two:
- `lyra.killMode.passed` → JSON `[String: [String]]` (playlistId → track ids).
- `loadPassed()` / `savePassed(_:)` mirroring `loadPending`/`savePending`; drop empty
  buckets on save. Load into a new `@Published private(set) var killModePassedTrackIds`
  at `AppModel` init (~`AppModel.swift:889–890`).

### Affected files
- `PlaybackEngine.swift` — Feature 1 keys in `updateNowPlaying`; new `onTrackCompleted`
  fired in `handleEnded`; advance-time blacklist guard.
- `AppModel.swift` — new green state + load; wire `onTrackCompleted`; green-marking;
  skip-wins-over-pass in `handleKillModeSkip`; `killModeFilteredPlayback` filter in the
  play entry; `clearKillModeListenHistory`.
- `KillModeStore.swift` — `passed` key load/save.
- `PlaylistKillListView.swift` — summary header + clear-history button.
- `ServerPlaylistViews.swift` — main tracklist row tints (`killModeRowTint`).
- `LibrarySongsView.swift` — reuse/extend row-style helper if needed.

### Testing / verification
- Build: `xcodebuild -workspace LyraMusicHost/LyraMusicHost.xcodeproj/project.xcworkspace -scheme LyraMusicHost -destination 'generic/platform=iOS Simulator' build`.
- Manual on device/sim: enable kill mode on a playlist; verify (a) a fully-played song
  turns green and is excluded next run; (b) a skipped song turns red and is excluded;
  (c) summary percentages match; (d) Clear listen history makes green songs replay while
  red queue persists; (e) toggling kill mode off/on remembers both sets; (f) car/CarPlay
  now-playing shows N/M.

### Out of scope / non-goals
- No server-side persistence of listen history (device-local `UserDefaults`, matching
  existing kill-mode storage).
- No change to the Keep/Remove commit flow for red songs.
- Summary header is not added to the main playlist view (placement chosen: review
  screen only).
