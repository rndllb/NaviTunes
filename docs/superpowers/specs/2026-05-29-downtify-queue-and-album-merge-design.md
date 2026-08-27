# Downtify queue polling + album track merge — design

Date: 2026-05-29
Branch: dev

## Problem

Two related complaints, sharing one root cause (no honest signal about server-side Downtify state):

1. **Search-row download looks broken.** Tapping Download on a Downtify search result shows
   progress jump to ~8% then reset to "Download" within a second. The download actually fires
   server-side, but the UI never confirms it. Cause: `DowntifyClient.downloadSong` POSTs to
   `/api/download/url`, gets a fast 200 (job *accepted*, not *finished* — real yt-dlp runs after),
   reports a fake `progress?(1.0)`, then the caller's `defer` block removes the row's progress
   entry. The fake progress callback never reflected the real server-side download.

2. **Album page only shows the one track you own.** When the connected Navidrome/Jellyfin server
   holds only some tracks of an album (e.g. one song requested earlier via Downtify), opening that
   album shows only those tracks. There is no way to see / request the rest of the album in place.
   The merge already exists for *browse* albums (`BrowseAlbumDetailView`) but not for *library*
   albums (`ServerPlaylistDetailView` album mode).

## Goals

- Honest, persistent download state for every Downtify request, surviving navigation.
- Album pages fill in missing tracks from MusicBrainz and let the user Request them per-row.
- A finished download auto-refreshes the catalog and auto-adds the track to the personal library.

## Non-goals

- Cancelling an in-flight Downtify job (no known cancel endpoint).
- Reconciling Downtify queue state across app relaunch (server queue persists; we don't rehydrate
  in-flight UI on cold start in V1).
- Changing offline (on-device) download behavior — that's `OfflineDownloadManager`, untouched.

## Downtify server facts

FastAPI app, auto-docs at `/docs`. Relevant endpoints:

- `GET /api/songs/search?query=` — search (already used).
- `POST /api/download/url?url=&client_id=` — enqueue a download (already used).
- `GET /api/queue` — **per-song state**: `status` (`done`, `downloading`, `failed`, etc.),
  progress %, `message`, `filename`. This is the real "what's happening" feed. A failed job shows
  `status: "failed"` with a `message` (e.g. youtube bot-block error).
- `GET /api/version`, `/api/settings`, `/api/check_update` — not needed here.

Matching strategy: we identify our queue entry by the **submitted YouTube URL** (we always have it
after search/pickBest). Fallback if `/api/queue` does not echo the source URL: normalized
title+artist match. Confirm exact `/api/queue` JSON shape against the live server during
implementation.

## Architecture

One new shared piece — `DowntifyDownloadManager` — modeled on `OfflineDownloadManager`, held as an
`@EnvironmentObject` at the root. Every existing Downtify call site drops its local
`downloadingIds` / `*DownloadFraction` state and reads from this manager. That collapses ~4
duplicate state bags (DiscoverySearchView rows, DowntifySongDetailView, BrowseAlbumDetailView
row+bulk) into one and adds the new ServerPlaylistDetailView call sites.

The album-merge feature is then a localized addition to `ServerPlaylistDetailView`: fetch the
MusicBrainz tracklist, splice in "missing" rows, render them with a Request control that calls the
same manager.

## Component 1 — DowntifyClient changes (`DowntifyClient.swift`)

- `struct DowntifyJob: Decodable` decoded from `/api/queue`. Captured fields: identifier, `status`
  (mapped to an enum `queued`/`downloading`/`done`/`failed`/`unknown`), `progress` normalized to
  `0...1` (server may emit 0–100 or 0–1; normalize), `message`, `filename`, source `url`, song
  name/artists for matching.
- `static func queue() async throws -> [DowntifyJob]` — `GET /api/queue`.
- `triggerDownload` returns the identity we match on (submitted `url`, plus any job id present in
  the POST response).

Status mapping is a pure function — unit-tested. Progress normalization is a pure function —
unit-tested. JSON decode of a representative `/api/queue` payload — unit-tested.

## Component 2 — DowntifyDownloadManager (`DowntifyDownloadManager.swift`)

`@MainActor final class DowntifyDownloadManager: ObservableObject`:

```
@Published private(set) var jobs: [String: DowntifyJob]   // keyed by submitted URL

func enqueue(song: DowntifySong) async                      // direct .url path
func enqueue(artist: String, title: String, displayName: String) async  // search-by-term path

func job(forURL url: String) -> DowntifyJob?
func isActive(url: String) -> Bool

var onJobFinished: ((DowntifyJob) -> Void)?                 // set by AppModel at wire-up
```

Behavior:
- `enqueue(song:)` debounces (no-op if URL already active), POSTs, inserts a synthetic `queued`
  job immediately (instant UI feedback), then ensures the poll loop runs.
- `enqueue(artist:title:displayName:)` runs `DowntifyClient.search` + `pickBest` first (as
  `download(artist:title:)` does today), then funnels into the same URL-keyed flow.
- One shared poll `Task`: while any job is non-terminal, `GET /api/queue` every ~2s, reconcile by
  URL, publish. On `done`/`failed` → call `onJobFinished`, keep visible ~1.5s, then drop.
- POST failure → surface error, remove the synthetic job.

Wire-up: instantiate in `AppModel` (or alongside `offline` in `RootView`), inject as
`@EnvironmentObject`. `onJobFinished` for a `done` job → refresh server catalog → resolve the new
track on backend → `addSongToLibrary` → `showTransientToast("Added <title>")`. Resolution retries
a few times; if the track never resolves, flip to Play if it appears else leave completed-not-added
with a single toast. No infinite polling. `failed` → no auto-add; row shows error.

## Component 3 — Album merge (`ServerPlaylistDetailView.swift`)

- On album-mode load (`albumOrNil != nil`), fetch MusicBrainz tracklist in parallel with server
  `load()`: `findReleaseGroupId(artist:albumTitle:)` → `tracksForReleaseGroup(...)` →
  `[BrowseAlbumPreviewTrack]`, into new `@State previewTracks`. Cache by album id (no refetch on
  back-nav).
- Extend album-mode row building (parallel to `BrowseAlbumDetailView.recomputeBrowseQueuedRows`):
  for each preview in track order, match a server row (reuse title-matching). Matched → library
  row (plays). Unmatched → missing row (MusicBrainz-only). Append server orphans (live/bonus tracks
  MB omitted) at the end.
- Row representation: a small enum `.library(Track)` / `.missing(BrowseAlbumPreviewTrack)` for
  album mode — do NOT fabricate fake `Track`s. The existing playlist path is untouched; only
  album-mode rendering branches.
- Fallback: MusicBrainz empty/unmatched → today's server-only behavior exactly (zero regression
  offline).
- Coexist with the existing "Show Complete Album" toggle (a *different* axis: server-has-more-than-
  personal-library). Missing rows always show; the toggle keeps governing server-vs-personal
  filtering only. The two must not double-hide.

Merge/match is a pure function — unit-tested (preview↔server matching, orphan handling).

## Component 4 — Row UI, top button, errors

**Missing-track row** (album mode): `LibrarySongRow` rhythm, greyed title, no play affordance,
trailing control bound to the manager:
- idle → `arrow.down.circle` Request (disabled if `!app.downtifyConfigured`).
- active → real `ProgressView(value:)` + percent from `manager.job(forURL:)`.
- failed → red exclamation; tap shows the Downtify `message` (toast).
- done → row auto-flips to a normal library row once the catalog refresh resolves the track.

**Top button** (chosen: *Request All Missing*): in the play/shuffle header area, when
`missingCount > 0` show a **Request** pill that bulk-enqueues every missing row (skipping active
ones). When `missingCount == 0`, the normal Play/Shuffle row — no change for complete albums.
Per-row Play stays on each library row.

**Bulk feedback:** toast `Requested N tracks` immediately; rows then show their own progress.
Downtify parallelism governs concurrency; we just submit.

**Errors:**
- Not configured → Request disabled + tappable hint toast (match `BrowseAlbumDetailView` copy).
- POST fails → toast with HTTP error; job removed.
- Queue `failed` → red row state + message; no auto-add.
- MusicBrainz fail/empty → silent fallback to server-only rows.

## Migration of existing call sites

Replace direct `DowntifyClient.downloadSong` / `DowntifyClient.download(artist:title:)` UI calls +
their local progress state with `DowntifyDownloadManager` reads in:
- `DiscoverySearchView` (downtify rows + `DowntifySongDetailView`)
- `BrowseAlbumDetailView` (per-row request + bulk request)
- `ServerPlaylistDetailView` (new: per-row request + bulk request)

## Testing

- Unit: `/api/queue` JSON decode, status mapping, progress normalization, preview↔server merge/
  match + orphan handling.
- Manual (run app against live Downtify + a partial album): search-row download shows real progress
  → done → auto-added; partial album shows merged tracklist; per-row Request and Request-All work;
  failed job shows error. SwiftUI row states verified visually (not unit-tested).

## Out of scope / follow-ups

- The separate "can't move playback from the lock screen" issue (tracked separately).
- Cold-start rehydration of in-flight Downtify jobs.
- Job cancellation.
