# Decisions pending

Everything on the `Vellums release` board that I could not close without you, in one place. Each
entry: what is actually wrong, the options, and what I would do. Reply "yes" or pick a letter.

Nothing here is pushed. `origin/dev` is at `83eb50b`; there are 23 local commits on `dev`.

---

## A. Product decisions — one answer each

### #22 — the search mic button does nothing
It is a plain `Image(systemName: "microphone.fill")`, not a `Button`, in two places
(`Discovery/SearchLibraryView.swift`, `DesignSystem/MusicDesignSystem.swift`).

- **a)** Delete it.
- **b)** Build real dictation (Speech framework, two Info.plist permissions, audio-session
  negotiation against the player).

**I would delete it.** The system keyboard already has a dictation key, so (b) spends permissions
and audio-session risk on something the OS gives you for free one tap later.

### #21 — swipe-to-dismiss doesn't work in Kill Mode
Every row has a **leading** `swipeActions(allowsFullSwipe: true)` ("Keep"), which competes with the
interactive pop. That is the only candidate I could find by reading; I could not separate it from a
zoom-transition interaction without running it.

- **a)** Move "Keep" to the trailing edge alongside "Remove", freeing the leading edge.
- **b)** Keep the green leading swipe; Kill Mode exits by the back button only.

**I would move Keep to the trailing edge.** Back-swipe is a system-wide expectation and its absence
reads as a bug on every screen; a second trailing action is merely less pretty.

### #41 — "Featured On"
Two things block it: `ArtistDiscographyBucket` is `CaseIterable` and "Request Missing" walks
`allCases`, so a new bucket would offer to download every guest appearance; and primary-vs-featured
needs release-level artist credits.

- **a)** Add the shelf from MusicBrainz artist-credit, and exclude it from Request Missing.
- **b)** Add it and include it in Request Missing.
- **c)** Not now.

**I would do (a).** "Keep this artist's discography complete" does not mean downloading every record
they guested on, and the exclusion is a one-line guard.

### #6 — share links "not fully implemented"
Create/list/delete are wired into 8 surfaces. The gaps are: pasteboard copy with no system share
sheet, no expiry or download-limit options, and Navidrome-only.

- **a)** Add a system share sheet (`ShareLink`) instead of silent pasteboard copy.
- **b)** Add expiry / max-download options.
- **c)** Jellyfin support.

**I would do (a), and not (c).** Copying to the clipboard and showing a toast is the actual
complaint — you can't send the link anywhere from where you are — and Jellyfin has no share API to
build (c) on.

### #8 — category list in DiscoverySearchView
Titled as a decision already.

**I would remove it** in favour of `hybridRecentlySearchedList`. The MusicBrainz entity tabs
(All / Artists / Albums / Songs) superseded browse-by-category, so it is now a second, worse way in.

### #18 — Following system: remove or finish
`MusicSubscriptionEngine`, `MusicSubscriptionModels`, `SubscriptionsView` and the artist-page bell
all exist and work.

**I would finish it.** Following without a download plugin is still a valid wishlist, the engine is
already written and tested against the plugin abstraction, and deleting it throws away the only
feature that makes the follow button mean anything.

### #11 — Sync section has one button and one row
- **a)** Fold the button and "Last synced" into the main Settings view; delete the section.
- **b)** Move Library Sync into the Sync view.

**I would do (a).** They are different operations — Settings → Sync is a client-side re-fetch,
Library → "Scan library now" asks Navidrome to rescan its own files — so (b) merges two things that
only sound alike, which CLAUDE.md already warns about.

### #12 — offline mode
Auto-offline needs a home SSID typed in by hand, with an unfinished location path that never
prompts. Manual offline is a plain toggle.

- **a)** Drop auto-offline entirely; keep the manual toggle; add "don't stream over cellular" to
  Sound & Playback.
- **b)** Finish auto-offline, including the location permission prompt.
- **c)** Drop both toggles.

**I would do (a).** The real want behind auto-offline is "don't burn cellular data", and a cellular
setting delivers that directly without asking for location permission or an SSID.

### #5 — Backup & Restore, and the library counts
Confirmed by reading: `VellumClientBackup` carries completed scrobbles, scrobble exclusions and
playback settings. It does **not** reference `KillModeStore` or `LibraryPinStore` — so your Kill
Mode history and pinned items really are lost on a clean install, exactly as you found.

- **a)** Expand the backup to cover Kill Mode history and pins; keep the section.
- **b)** Drop Backup & Restore entirely.

**I would do (a).** That data exists nowhere else — the backends have no idea about pins or kill
history — so (b) makes the loss permanent rather than fixing it, and the additions are two small
`Codable` stores.

### #7 — "Total plays" is capped at 500
Confirmed: `ScrobbleService.completedCap = 500`, and `totalPlays` is `plays.count` over that capped
array. Every other stat — top artists, top tracks, the streak — is computed over the same 500-item
window, which is why the rest looked doubtful too.

- **a)** Keep a lifetime counter alongside the capped list. Exact from the day it ships; a floor for
  history already trimmed.
- **b)** Source play counts from the backend (Navidrome/Jellyfin both expose them).
- **c)** Relabel the row to "Recent plays" and leave the cap.

**I would do (a), and separately drop the streak** until it can be computed over data that isn't
trimmed. (b) sounds more correct but the two backends count differently and neither guarantees
retention, so it trades a known-wrong number for an unpredictable one. A streak read off a truncated
window is wrong in a way no label can fix.

### #17 — "Validate Plugins system" *(issue body is empty — this is my proposal, correct me)*
I read it as: for each of Lidarr / Downtify / DroppedNeedle, confirm Test Connection actually
validates credentials, the required-field copy names where each value comes from, and the Activity
list reflects real server-side jobs.

**I would scope it to that checklist** and treat interface polish as a separate pass, since
`AcquisitionPluginSettingsView` is already capability-driven and the risk is in the three plugins
disagreeing about what "configured" means.

### #19 — "Expand the About section" *(issue body is empty — this is my proposal, correct me)*
I read it as: version and build, the connected backend and server, open-source acknowledgements,
and licences.

**I would include a Radio Browser attribution specifically** — that dataset's terms ask for
credit, and the app ships 57k of their stations — plus MusicBrainz. Those two are obligations, not
decoration.

### #4 — "Update Settings layout" *(issue body is empty)*
**I would close this as covered** by #5, #11, #12, #13 and #17 rather than keep it as a separate
task. The hub is already an iOS-Settings-style structure; what is actually wrong with it is
enumerated in those five.

### #14 remainder
Two items are done (`27a164c`). The rest are questions:

- **Bypass toggle** — **I would remove it.** `equalizerEnabled` already gates the whole path, so
  bypass is a second off switch with a different name.
- **Enhancement / Tools / Calibration sections** — need your ears before deciding; see section C.
- **Consolidating Bands + Draw EQ so Response is the single source of truth** — **I would do it**,
  but only after you have used the new Edit Curve button, since it assumes that flow is right.

---

## B. Needs your eye — a look, not a decision

### #29 (2 of 4 remaining)
- Unowned releases are **invisible** when no acquisition plugin is configured:
  `showsRequestBadge = item.needsRequest && canRequest`, so ownership is gated on request
  capability. The bug is objective; the fix is a visual treatment, which is yours.
- The shimmer placeholder overlaps the top song. **Capture:** a screen recording of opening a cold
  artist page.

### #26 — header moves between lyrics and queue
The compact header renders `if compact && !inQueue`; in queue mode `containerHeight` collapses to
zero and the queue list supplies its own now-playing row. Holding those elements still means taking
that row away from the queue, which touches the morph, `queueArtworkHandedOff`, and the cover-zoom
hero anchor.

**Capture:** a screen recording of the lyrics → queue transition, so the fix can be checked against
what you actually see rather than against my reading of the layout.

---

## C. Needs your device

| Issue | What to capture |
|---|---|
| **#24** | The crash log. Xcode → Window → Devices and Simulators → View Device Logs, after reproducing (swipe down to dismiss the player while viewing the empty history list). No report exists on this machine and the transition path has no force-unwraps, so guessing would move the crash rather than fix it. |
| **#10** | A screen recording plus, ideally, a Time Profiler trace while scrolling a ~20-song playlist so the tab bar collapses and expands. Needs your library — the demo server is too small to reproduce. |
| **#15** | Your hands: "responsiveness" of the Now Playing pills is a feel judgement. |
| **#20, #33–#38** | Instruments traces on your device against your library, one per tab. OPTIMIZATIONS.md records that the simulator cannot reproduce these — the stall is proportional to library content. |
| **#27, #16** | Already committed (`b29c3a1`, `ddc9214`) but both are tuning values — the swipe-down cone/thresholds and the mini-player flick handling. Confirm they feel right; they are one-line changes to adjust. |

---

## D. Closed by you, recorded so they don't get re-raised

- **#28** — you said "we got it". The mechanism was fixed by `9579592` (artist resolution now needs
  exact normalised equality plus MBID disambiguation), and `880bb9c` pins the name-matching rules
  with tests so it cannot regress silently.
- **#9** — you said to ignore it. For the record, the two `ArtistNowPlayingMenuButton` hits are
  `#if canImport(UIKit)` / `#else` and mutually exclusive; the real duplication is across two
  different menus on one screen, which Apple Music also does.
- **#39** — already implemented. `ArtistViewModel` stops asking the plugin for discography
  ("the plugin is still asked for the artist portrait and bio — MusicBrainz publishes neither — but
  no longer for the discography") and runs the two in parallel. **The board still shows it In
  Progress**; that is a board edit, not code.
- **#32** — left deliberately. It is the consolidation half of the restructure and needs a verified
  duplication list, which Terminal 21's sweep is producing.

---

## E. Untracked files in the working tree — your call, nothing touched

None of this is in git. I have not moved or deleted any of it.

| Path | Size | Note |
|---|---|---|
| `Sources/LyraMusicKit/NowPlayingView.swift.bak-lyrics` | 110 KB | A backup file inside the source tree. OPTIMIZATIONS.md already records it as yours to delete. |
| `LyraMusicHost/` | 56 KB | Pre-rename host project. |
| `LyraMusic.xcworkspace/` | 0 B | Empty pre-rename workspace. It is one of the two workspaces that makes bare `xcodebuild` ambiguous at the repo root. |
| `addtoplaylistinterface.MP4` | 114 MB | Reference recording. |
| `watchthis.MP4` | 20 MB | Reference recording. |
| `docs/reference-apple-music-vs-vellum-dismiss.MP4` | 25 MB | Reference recording. |
| `apple-player.png`, `asdf.png`, `lyra-player.png` | 4.5 MB | Reference screenshots. |

**≈138 MB at the repo root, ≈163 MB including the `docs/` video.** If any of it is worth keeping,
it wants a home outside the repo or in `.gitignore` — a 114 MB file one `git add -A` away from the
history is the risk, not the disk.
