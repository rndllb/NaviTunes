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
  tap UIKit swallowed is re-issued. A tap during a *close* now settles that close the same way,
  which is what stops two transitions stacking (§4.2).
- The card retargets to the row's live position while the list scrolls under it during a dismiss.
- A dismiss from a page scrolled past its cover dissolves onto the row instead of arriving empty
  (§4.3), and the incoming screen's bar buttons fade in rather than snapping (§4.4).

---

## 4. Open problems

> **Update, 2026-08-21 (second session).** The device log was pulled off the phone before anything
> was changed (`Documents/vellum-hangwatch.log`, 20 403 lines, spanning several builds). Reading it
> settled four of the five items below and corrected one claim that this document asserted as
> measured. Each subsection now records what the log actually showed and what changed. **Read the
> "what the log showed" paragraphs before re-opening any of these** — several earlier conclusions
> were drawn from log regions belonging to *older builds*, which is easy to do because the file is
> append-only across installs and has no launch marker.

### 4.1 Interactive edge-swipe dismiss — still unverified, no longer "measured dead"

Swiping from the left edge does not shrink the page into its row. It has variously done UIKit's
parallax slide, or nothing at all.

**Correction — the key measurement was wrong.** This document said "zero `COVERZOOM pan` callbacks
from either pop recognizer, ever". `grep -c "COVERZOOM pan "` over the whole log is indeed 0 — but
the *current* build's region of the log (everything after the first unconditional `COVERZOOM
touchDown` line) contains **no genuine edge-swipe attempt at all**. Every left-side touch in it is
a back-*button* tap: `x≈31–38, y≈76–102, hit=_UIButtonBarButton`. The 83 `edgeTouch` lines that do
sit near x≈4–11 all belong to builds that predate both the "observe every parallax recognizer" and
"always vend an interaction controller" fixes. So the swipe has not been exercised since those
landed, and "still does not work" is an assumption, not a measurement.

A recognizer whose delegate vetoes it does go straight to `.failed` without notifying its targets,
so silence from `handleSystemPan` genuinely cannot tell a veto apart from a missed target. That
ambiguity is now removed rather than reasoned around — see the three diagnostics below.

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
vended for our pop.

**What changed this session.**

- **`wantsInteractiveStart` now distinguishes the two kinds of pop.** Vending an interaction
  controller for *every* pop made every back-button press start paused at 0% and wait for
  `scheduleInteractionWatchdog` to notice nobody was driving it — the log confirms
  `COVERZOOM interaction watchdog — nothing drove it, finishing` fired on **171** pops, i.e. all of
  them, ~50–60 ms after each one started. The distinction that *is* decidable at
  `interactionControllerFor:` time is whether a finger is down: an edge swipe is asked from
  `gestureRecognizerShouldBegin:` with the pan holding touches, a back button raises its pop on
  touch *up* with `panTouches=0` (visible on every `interactionAsk` line in the log). So
  `wantsInteractiveStart = observedPans.contains { $0.numberOfTouches > 0 }`. Non-nil is still
  always returned, so the veto this document warns about cannot come back. Translation is still
  not consulted — it is zero at that instant, and testing it is what used to return `nil`.
- **The completion watchdog no longer kills a swipe in progress.** It was a flat "2× duration +
  0.3 s then force it", which would tear the screen away from a finger still dragging. It now
  extends its deadline while `fractionComplete` is still moving, up to three times.

**Diagnostics added — one device round-trip should now settle it:**

- `COVERZOOM shouldBegin …` — `CoverZoomPanDelegateSpy` sits in front of UIKit's own
  `_UINavigationInteractiveTransitionBase` on each pop recognizer and *forwards everything*,
  reading the `gestureRecognizerShouldBegin:` answer on the way past. This is not the same as the
  two attempts in the "ruled out" table: UIKit's object is still the delegate that does the work,
  so the arming path is untouched. DEBUG only.
- `COVERZOOM edgeSample +Nms […]` — samples both pop recognizers' `state` and `numberOfTouches` at
  +120/+260/+420 ms after an edge touch. Answers "did either recognizer ever leave `.possible`?"
  without depending on a target callback that a vetoed recognizer will never make.
- `COVERZOOM edgeTouch` now walks the **whole chain from the hit-test view up to the window**,
  listing every recognizer at every level, instead of guessing at the nav view and top VC's view.
  This is hypothesis 3's requested extension.

**Result of the first round-trip (device, 2026-08-21 14:xx).** Three genuine edge swipes on a
custom-zoomed detail — `touchDown x=2 / 4 / 0, depth=2, hit=CellHostingView`. Every one:

```
edgeSample +120ms [ParallaxPan/st=0/n=0, ParallaxPan/st=0/n=0]
edgeSample +260ms [ParallaxPan/st=0/n=0, ParallaxPan/st=0/n=0]
edgeSample +420ms [ParallaxPan/st=0/n=0, ParallaxPan/st=0/n=0]
```

and **no `shouldBegin` line at all**. The full `edgeTouch` chain shows both pop recognizers
sitting on `UILayoutContainerView`, squarely in the touch's path, with nothing above them but
`HostingView`s and the window's system gates. So:

- It is **not a veto** — `gestureRecognizerShouldBegin:` was never reached.
- It is **not a missed target** — the recognizers are in the chain and enabled.
- `numberOfTouches == 0` with the finger still down 420 ms later means the touch was **never
  delivered** to them. The only thing between "in the chain" and "received the touch" is the
  delegate's `gestureRecognizer(_:shouldReceive:)` gate, which runs one step *before*
  `shouldBegin` and which `_UINavigationInteractiveTransition` implements.

That gate is where the answer is. `CoverZoomPanDelegateSpy` now logs its verdict
(`COVERZOOM shouldReceiveTouch … answer=…`, plus `shouldReceiveEvent` when false), and the
`edgeTouch` line now dumps everything the gate is known to consult on the top controller's
`navigationItem` — `hidesBack`, `leftItems` / `leftSupplement` / `leadingGroups`, `backMode`,
`backItem`, `barHidden`, `coordinator`, `modal`, `panDelegate`. The detail only has *trailing*
toolbar items (checked in `detailToolbarContent`), so the classic "leading item disables the
pop gesture" rule is not it on its face; the dump will say what is.

**Read the next log like this:** `shouldReceiveTouch answer=false` ⇒ UIKit's gate refused, and
the nav-item fields on the same swipe's `edgeTouch` line name the rule. `answer=true` but still
`n=0` ⇒ the touch is being intercepted between delegate approval and delivery, which would point
at the window-level `_UISystemGestureGateGestureRecognizer`s. No `shouldReceiveTouch` line at all
⇒ UIKit is not even asking, and the spy's `responds(to:)` is the first thing to check.

**Untested hypotheses that remain:**
1. SwiftUI's `NavigationStack` handles the interactive pop itself and never routes it through
   `UINavigationController`'s delegate. (Weakened: the touch is being refused at the recognizer,
   before any delegate question arises.)
2. `preferredTransition` on the pushed controller wins over the delegate for interactive pops.
   Logged as `fromPreferredTransition` / `toPreferredTransition`; observed `nil` on every line of
   the log, in every build.

**Ruled out on device, with logs. Do not retry:**

| Attempt | Result |
|---|---|
| Own `UIScreenEdgePanGestureRecognizer` + `popViewController` | Pops, but desyncs SwiftUI's `NavigationLink` state |
| Taking `_UIParallaxTransitionPanGestureRecognizer.delegate` and answering `shouldBegin` | Gesture recognizes, pop never armed. That delegate is UIKit's `_UINavigationInteractiveTransitionBase` — the only object that consults `UINavigationControllerDelegate` on a gesture pop |
| Setting that delegate to `nil` | Pop happens via the recognizer's target/action but bypasses our delegate → UIKit's parallax |
| Custom `UIViewControllerInteractiveTransitioning` driving progress by hand | Never scrubbed; UIKit substituted its parallax. UIKit can only scrub an animator that vends `interruptibleAnimator(using:)` |
| SwiftUI `simultaneousGesture(TapGesture())` on the cell | Ate the `NavigationLink`'s activation — nothing opened at all |
| Zero-duration `UILongPressGestureRecognizer` as touch observer | Starved the edge pan completely. Replaced by `CoverZoomTouchSpy`, which reports `touchesBegan` then immediately `.failed` |

### 4.2 Rapid open → close → open leaves the back button dead — fixed (two separate bugs)

Reproduction: open a playlist, close it quickly, open another, try to close. The back button is
visible but unpressable.

**Mechanism, confirmed in the log** (timestamps 808986563.4 → 564.6, current build):

```
563.396 touchDown x=102 y=362  coordinator=false depth=1   ← open
563.894 touchDown x=42  y=81   coordinator=true  depth=2   ← back tap during the open
        touch during push — completing it now
        back tap was swallowed by the push — popping
564.006 interaction watchdog — nothing drove it, finishing
564.363 touchDown x=125 y=208  coordinator=true  depth=1   ← tap landed inside the close
564.512 PHASE didDisappear popped=true
564.519 ask op=1 → run push=true                           ← push started inside the pop
564.605 touchDown x=109 y=203  coordinator=true  depth=2   ← and another inside that
564.606 PHASE didAppear
        (nothing, ever again — no ask op=2 on any subsequent press)
```

**Fix 1 — settle a running dismiss on touch-down.** The tap that wedges it is the one at 564.363:
a push raised while the pop's transition is still live. `noteTouchDown` already cut a running
*push* short for exactly this reason; it now does the same for a running *pop*. Touches are
delivered before the tap's action fires, so by the time SwiftUI activates the link the stack has
settled and the push is an ordinary one. This does **not** deafen the list — the tap still works,
the close just snaps to done first. Skipped while a pop gesture is genuinely being dragged.

**Fix 2 — the fallback path leaked a disabled list.** Independent, and almost certainly the cause
of the reports where the app looks completely normal and ignores every tap. `prepare` switches the
list off for the length of a push (`suspendedList`), and both restore paths (`finish`,
`animationEnded`) key off a `Session`. The geometry `guard` that falls through to the cross-fade
returns **before** a `Session` exists — so every cross-faded push left the playlists list
permanently, silently deaf. The log has 21 `COVERZOOM fallback` lines. It now re-enables the list
on that path.

**Fix 3 — hardened the list on the way back in.** A pop sets the revealed list's frame from
`context.finalFrame(for:)`, which is documented to return `.zero` when UIKit does not consider the
controller part of the transition; a zero-sized list is invisible *and* untouchable, which reads
exactly like "the list is dead during the dismiss". It now falls back to `container.bounds` and
explicitly asserts `isUserInteractionEnabled` / `alpha` / `isHidden` / `transform` — the log has
taps during a dismiss landing on `hit=UIViewControllerWrapperView` (i.e. past the list entirely)
rather than on the list's own SwiftUI content, which is what a live list gives
(`hit=PortalGroupMarkerView` / `PlatformGroupContainer`).

Guardrails already in place, all still worth keeping:
- Completion watchdog forcing any transition to finish past 2× duration + 0.3s (now extends its
  deadline while the animation is still moving, so it cannot cut a live swipe short).
- Settling any still-running animator when the next operation is requested.
- `completeImmediately()` tearing down even when the animator is not in a finishable state.
- Sweeping for orphaned `CoverZoomClipView`s on touch-down and disarming them (never fired).

### 4.3 Dismiss when the detail is scrolled past the cover — fixed

If the playlist view is scrolled so the hero artwork has left the viewport, the dismiss has no
cover to fly.

**Why, precisely:** the hero probe is *not* gone — the hero is a scroll view's content, not a lazy
row — so it keeps resolving, to a rect above the top of the screen. The animator's arithmetic
stays correct; it is the *pixels* that are missing, clipped away by the detail's own scroll view.
So the card flies home carrying an empty square.

**Fix, and it needs no snapshot.** `CoverZoomRegistry.heroIsOnScreen(for:in:)` asks whether the
measured hero is (>92%) inside the container. When it is not, `prepare` sets
`Session.dissolvesOntoCell`, which does two things: the source row's artwork is **left visible**
(no `beginFlight`), and the card dissolves over the tail of the travel onto it. The shrink is still
the motion; the hand-over happens as the card arrives. `CoverZoomTuning.dissolveDelayFactor`
(0.55) is the knob.

The dissolve is a second `addAnimations(_:delayFactor:)` block on the property animator rather than
an alpha written in `applyState`. That matters: `applyState` runs **exactly twice** (once per end
state) — `UIViewPropertyAnimator` interpolates between the two values it is given — so an alpha
set there would fade across the whole transition instead of the tail of it. As a delay factor it
also scrubs correctly under an interactive pop.

**Bonus fix, same cause.** `recordHero` had no sanity check, so a hero measured while scrolled off
screen was persisted as *the* prediction for every future first push. The log caught it:

```
COVERZOOM run push=false hero=(-97.3, 77.3, 320.0, 320.3)
```

It now only records a rect that is inside the container. The measurement is still *used* for that
transition; it just never becomes the cached answer.

### 4.4 Navigation-bar handover — implemented

The outgoing screen's items fade (`setBarItemAlpha` in `CoverZoomTransition.swift`, extended to
cover the system back chevron, which is owned by `UINavigationBar` and which the item-level fade
structurally could not reach). The **incoming** screen had no fade-in at all — its buttons appeared
whenever UIKit swapped the bar's content, over a card still the size of a playlist row.

`CoverZoomAnimator.startBarItemFadeIn` now handles the arriving side, scoped to **one**
`UINavigationItem`: the detail's on a push, the list's on a pop, plus the back chevron on a push
only (on a pop the chevron in the bar still belongs to the screen leaving, which
`setBarItemAlpha` is already fading out).

**Do not fade `UINavigationController.navigationBar` to do this** — that bar is shared by every
screen on the stack, so it takes the list's own header buttons with it. The dead
`crossFadeNavigationBar` that recorded this is gone, replaced by the scoped version.

Two implementation details that are not optional:

- **Held at zero on a display link, not set once.** UIKit installs the incoming item's views
  partway through the transition, so a single write at `prepare` time misses them — the same
  reason `applyMorphPassthrough` re-applies each frame.
- **Four independent restores.** A bar button left at alpha 0 is invisible *and* untappable (UIKit
  skips near-transparent views when hit testing), which is the soft lock the earlier attempt
  shipped. Alpha is restored by `barFadeTick` reaching its deadline, by `finish`, by
  `animationEnded`, and by a `Task` watchdog that strong-captures the zeroed views so it holds even
  if the animator has been deallocated.

The fade starts at `duration − barFadeIn − 0.06` so it is over before the pushed detail's
`viewDidAppear` writes its own items back to full alpha — that call is not animated and would
otherwise cut the fade off at its brightest point.

### 4.5 Cosmetic — fixed

Long-pressing the back button showed UIKit's back-history menu with blank entries, because the
hero screens set `navigationTitle("")` and UIKit builds that menu from each stack entry's
`backButtonTitle` / `title`.

`musicBackHistoryTitle(_:)` (`MusicDesignSystem.swift`) sets `navigationItem.backButtonTitle` and
pins `backButtonDisplayMode = .minimal`, so the menu is populated while the visible back button
stays a bare chevron. Applied to the three pushed hero screens: Favorite Songs, playlist/album
detail, browse album detail. The modal sheet that also uses `navigationTitle("")` is left alone —
it is not on a navigation stack.

**The Library root is deliberately still blank in that menu.** `backButtonTitle` does double duty:
it names the screen in the history *and* supplies the visible label on the back button of anything
pushed from it. Only a screen that also opts into `backButtonDisplayMode = .minimal` can carry one
without changing what the user sees, and the root pushes plenty of screens that don't (Genres,
Artists, Settings…) — naming it would turn every one of their bare chevrons into "‹ Library".
Fixing the last blank row means auditing those screens, not changing this one.

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
`dissolveDelayFactor` 0.55, `popCommitFraction` 0.33, `popCommitVelocity` 600, `barFadeOut` 0.12,
`barFadeIn` 0.18.

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
(geometry used, plus `heroOnScreen`), `state` (card frame at both ends), `interactionAsk`, `pan`,
`shouldBegin` (UIKit's own verdict on the swipe), `edgeTouch` (full recognizer chain from the
hit-test view to the window), `edgeSample` (recognizer states a few frames into a swipe),
`touchDown` (unconditional, with hit-test), `decline`, `syncGestures`, `watchdog`,
`orphaned clip`.

**The log is append-only across installs and has no launch marker.** This cost a whole round of
wrong conclusions: §4.1's "measured" claim about the swipe was read out of a region belonging to
two builds earlier. Before concluding anything, find where the *current* build starts — the
easiest anchor is the first line carrying a field only this build emits — and read only past it.
`grep -c` over the whole file answers a question nobody asked.

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
