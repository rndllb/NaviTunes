# Custom cover-zoom transition — complete working notes

Written 2026-08-21, ~02:35, at the end of a long session. This is the single place everything
about this work lives. Read it fully before changing anything: most obvious ideas are already
eliminated below, on device, with logs.

**Branch:** this WIP lives on `cover-zoom-transition`, branched from `162e98b` on `dev`, so `dev`
keeps only the committed, known-good state.

**Files:** `Sources/VellumMusicKit/CoverZoomCustomTransition.swift` (the whole thing),
`CoverZoomSource` / `CoverZoomDestination` in `CoverZoomTransition.swift`, the call sites and
artwork anchors in `LibraryView.swift`, `heroArtwork` in `ServerPlaylistViews.swift`.

---

## 1. Vocabulary (the user's — use it)

- **Playlists list** — Library → Playlists, the list of playlists. Ordinary right-slide push in
  both directions. Must stay that way.
- **Playlist view** — one playlist's page. This is the only thing that zooms.

Conflating these caused a real bug: letting the last-pushed cover claim *any* pop on the stack
made the playlists list itself zoom.

---

## 2. Why this exists

SwiftUI's `.navigationTransition(.zoom)` gets the motion broadly right but exposes none of the
three things that were wrong. Measured frame by frame against Apple Music
(`docs/reference-apple-music-vs-vellum-dismiss.MP4`):

- **The source cell stays visible**, so two copies of the artwork are on screen and the cover
  appears to swap identity mid-flight. Apple Music empties the row for the whole transition.
  Matching the artwork URL and matching the corner radius were both tried previously and neither
  helped, because neither addressed the duplicate.
- **The navigation bar strands** — the detail's title and items linger over the revealed list for
  ~600ms after it settles. Apple's own bug, Developer Forums 774524.
- **The duration** — the zoom holds a transition coordinator for ~1.1s, and `NavigationStack`
  drops navigation requests raised while one is alive. That is the old post-dismiss soft lock.

### Two corrections to `docs/playlist-transition-and-softlock-handoff.md`

From reading the reference video at 20fps. That document is wrong on both counts:

- Apple Music does **not** move "only the cover and title". The whole page rides inside the
  flying card, exactly as ours does.
- The page behind does **not** zoom out. It holds full size and full opacity throughout.

---

## 3. What works

- Push zooms out of the tapped row's artwork, cropping outward from the cover. The user's
  verdict: "the open transition is perfect".
- Back-button pop reverses it. "The close is so good."
- **Size-independent.** 52pt playlist rows, Library *Recently Added* grid cells and Library
  *pinned* cells all animate correctly with no per-call-site numbers. The animator measures
  whatever view carries `coverZoomCellAnchor` and derives scale from `cellWidth / heroWidth`.
- Library → Playlists list is untouched and still slides.
- Tapping during an open cuts the push short so the back button responds immediately, and a back
  tap UIKit swallowed is re-issued.
- The card retargets to the row's live position while the list scrolls under it during a dismiss.

---

## 4. Open problems

### 4.1 Interactive edge-swipe dismiss — unsolved

Swiping from the left edge does not shrink the page into its row. It has variously done UIKit's
parallax slide, or nothing at all.

**Key measurement:** zero `COVERZOOM pan` callbacks from either pop recognizer, ever. A recognizer
whose delegate vetoes it goes straight to `.failed` and never notifies its targets — that is the
signature of a veto, not of a missed target.

**Two facts found late, both of which invalidate earlier reasoning:**

- There are **two** `_UIParallaxTransitionPanGestureRecognizer` instances on the navigation
  controller's view (an edge one and a full-width one). `interactivePopGestureRecognizer` vends
  only one. Code inspecting only that one reads the *idle* recognizer while the other holds the
  finger — so `panState=0 panTouches=0` looked like proof of "this was a back-button pop" when it
  may not have been. Several conclusions early in the session rest on that bad reading.
- UIKit asks for the interaction controller from inside `gestureRecognizerShouldBegin:`, while the
  recognizer is `.possible` with **zero translation**. Any test for "is a swipe under way"
  necessarily answers no there, and returning `nil` makes UIKit veto the gesture outright.

Both are fixed — all parallax recognizers are observed, and an interaction controller is always
vended for our pop with a 50ms watchdog finishing it when nothing drives it — and the swipe still
does not work. That is where the next attempt starts.

**Untested hypotheses:**
1. SwiftUI's `NavigationStack` handles the interactive pop itself and never routes it through
   `UINavigationController`'s delegate.
2. `preferredTransition` on the pushed controller wins over the delegate for interactive pops.
   Logged as `fromPreferredTransition` / `toPreferredTransition`; observed `nil` so far.
3. Something in the SwiftUI content consumes the touch before either recognizer sees it. The
   `COVERZOOM edgeTouch` line dumps every recognizer on the nav view and top VC's view at
   touch-down; extend it upward through the hierarchy.

**Ruled out on device, with logs. Do not retry:**

| Attempt | Result |
|---|---|
| Own `UIScreenEdgePanGestureRecognizer` + `popViewController` | Pops, but desyncs SwiftUI's `NavigationLink` state |
| Taking `_UIParallaxTransitionPanGestureRecognizer.delegate` and answering `shouldBegin` | Gesture recognizes, pop never armed. That delegate is UIKit's `_UINavigationInteractiveTransitionBase` — the only object that consults `UINavigationControllerDelegate` on a gesture pop |
| Setting that delegate to `nil` | Pop happens via the recognizer's target/action but bypasses our delegate → UIKit's parallax |
| Custom `UIViewControllerInteractiveTransitioning` driving progress by hand | Never scrubbed; UIKit substituted its parallax. UIKit can only scrub an animator that vends `interruptibleAnimator(using:)` |
| SwiftUI `simultaneousGesture(TapGesture())` on the cell | Ate the `NavigationLink`'s activation — nothing opened at all |
| Zero-duration `UILongPressGestureRecognizer` as touch observer | Starved the edge pan completely. Replaced by `CoverZoomTouchSpy`, which reports `touchesBegan` then immediately `.failed` |

### 4.2 Rapid open → close → open leaves the back button dead

Reproduction: open a playlist, close it quickly, open another, try to close. The back button is
visible but unpressable.

**Mechanism, from the touch log:**

```
touchDown x=125 y=208  coordinator=true  depth=1   ← tap landed while the close was still animating
PHASE didDisappear popped=true
ask op=1 → run push=true                           ← that tap started a new open inside the close
touchDown x=109 y=203  coordinator=true  depth=2   ← another tap during that open
```

Two transitions get stacked, and the wreckage leaves the stack in a state where the pop is never
requested (no `ask op=2` at all on the failing press).

**The obvious fix is off the table.** Making the list deaf during the dismiss does stop it, and was
tried — but the list staying live through the dismiss is the entire point of this work, and the
user rejected it immediately. The stacking has to be handled *without* deafening the list: most
likely by handling a push that arrives while a pop is in flight (settle or coalesce), rather than
by preventing the tap.

Guardrails already in place that did **not** fix it, all still worth keeping:
- Completion watchdog forcing any transition to finish past 2× duration + 0.3s.
- Settling any still-running animator when the next operation is requested.
- `completeImmediately()` tearing down even when the animator is not in a finishable state.
- Sweeping for orphaned `CoverZoomClipView`s on touch-down and disarming them (never fired).

### 4.3 Dismiss when the detail is scrolled past the cover

If the playlist view is scrolled so the hero artwork has left the viewport, the dismiss has no
cover to fly — the card shrinks as a page rather than as a cover returning home.

Fix direction: the pop needs a **snapshot** of the artwork taken while it was last visible,
composited into the card, rather than relying on the live hero view. This is a real change to how
the card is composed, not a tweak.

### 4.4 Navigation-bar handover

The outgoing screen's items fade (`setBarItemAlpha` in `CoverZoomTransition.swift`, now extended to
cover the system back chevron, which is owned by `UINavigationBar` and which the item-level fade
structurally could not reach). The **incoming** screen's items have no fade-in at all — they appear
whenever UIKit swaps the bar's content, which reads as an abrupt snap. The user wants a quick
blur-style fade out and in, as in `~/Downloads/ScreenRecording_08-21-2026 02-02-57_1.MP4`.

**Do not fade `UINavigationController.navigationBar` to do this.** It was tried and it soft-locked
the app: that bar is shared by every screen on the stack, so it took the playlists list's own
header buttons with it, and any transition that did not reach `finish` left them invisible and
untappable. `CoverZoomAnimator.crossFadeNavigationBar` is retained, uncalled, recording this. A
correct version drives the two `navigationItem`s' item groups independently, scoped per view
controller.

### 4.5 Cosmetic

Long-pressing the back button shows UIKit's back-history menu with blank entries, because the
detail screens set `navigationTitle("")`. Pre-existing and unrelated.

---

## 5. Settled geometry — do not re-derive

Measured on device, container 440×956:

- Cell (list row artwork) `(20, y, 52, 52)` radius 8; Library grid cells ~125pt and ~194pt square.
- Hero `(60, 124, 320, 320)` radius 14 — **identical for every playlist**, because it is
  layout-determined. Cached and persisted, which is what lets a *first* push animate at all: the
  detail's SwiftUI body has not run when UIKit asks for an animator, so the hero probe does not
  exist yet.
  - **Limitation:** the cache is global. A destination with a differently-sized hero would aim at
    the wrong rect on its first push. Favorite Songs is deliberately left on the stock zoom for
    this reason (`pinnedUsesCustomZoom`). Key the cache by destination kind before widening
    further.
- The push id must be known **before** the push, because UIKit asks for an animator before the
  pushed controller's `viewWillAppear`. It comes from `CoverZoomTouchSpy` hit-testing registered
  row rects. Reading it from the `NavigationLink`'s destination closure does **not** work: SwiftUI
  evaluates those when it builds rows, including buffered rows past the fold, which made the card
  fly in from `cell=(20, 1128, 52, 52)` on a 956pt screen.
- The card interpolates between the cover's rect and the page's rect, both anchored on the cover,
  so the crop opens outward from the artwork. Deriving it from the page alone shows the whole page
  at once; interpolating it independently makes it expand about its own centre (which reads as the
  cover "hitting the ceiling then sliding sideways").
- The cover's path is a straight line and that is correct. An early complaint about the path was
  the easing: an ease-out cubic puts half the travel into the first fifth of the time.
  `verticalLag` exists to bow the path below the straight line if ever wanted; currently 1.0.

---

## 6. Current tuning

`CoverZoomTuning`: `pushDuration` 0.50, `popDuration` 0.50, `easeOutQuint` (cubic Bézier
`0.23, 1, 0.32, 1` — the user's pick), `screenCornerRadius` 48, `verticalLag` 1.0,
`popCommitFraction` 0.33, `popCommitVelocity` 600, `barFadeOut` 0.12, `barFadeIn` 0.18.

Note the durations are also the length of the "back button does nothing" window — UIKit refuses a
pop while a transition runs — mitigated but not eliminated by the touch-interrupt.

---

## 7. Method — this matters more than any single fix

Nearly every wrong turn in this session came from reasoning ahead of the evidence, and every real
step forward came from a log line. Add `DebugUIRemote.log` (DEBUG-only), build, have the user
exercise it, and **read the log before concluding anything.**

```bash
xcrun devicectl device copy from --device 00008150-001A43E10C63401C \
  --domain-type appDataContainer --domain-identifier com.randll.vellum --user mobile \
  --source Documents/vellum-hangwatch.log --destination ./hw.log
```

Lines: `COVERZOOM ask` (push/pop decisions, nav identity, preferredTransition), `run` / `fallback`
(geometry used), `state` (card frame at both ends), `interactionAsk`, `pan`, `edgeTouch` (every
recognizer at touch-down), `touchDown` (unconditional, with hit-test), `decline`, `syncGestures`,
`watchdog`, `orphaned clip`.

---

## 8. Working constraints

- Build: `~/.claude/scripts/build-to-phone.sh VellumMusicHost VellumMusicHost`, **from the repo
  root**. The script computes its derived-data path *after* `cd`-ing, so it writes to
  `VellumMusicHost/VellumMusicHost/.build-to-phone/…` while printing
  `VellumMusicHost/.build-to-phone/…`, which holds a stale decoy bundle. **Verify the real
  binary's timestamp after every build** — a stale install cost real time here. If the shell has
  drifted out of the repo root the script fails silently.
- A locked phone fails only the launch step; the install still succeeds.
- Use the `Edit` tool for source changes — never `sed`/`perl`/`python`/heredocs.
- The user tests by hand on a physical iPhone. No automated test can reach any of this: XCUITest
  synchronises on quiescence, so its taps land well clear of these windows.
- Change one number at a time. The user has a good eye for motion and will reject animation that
  is 90% right.
- Don't "fix" a timing problem by shortening the animation. The durations are a deliberate match
  to Apple Music and are not the place to absorb a bug.
