# Playlist/album transition + post-dismiss soft lock — handoff

Written 2026-08-20 after a long session that did **not** solve the soft lock. This exists so
the next attempt starts from measurements rather than re-deriving them. Read it fully before
changing anything — most of the obvious ideas are already eliminated below, on evidence.

**Current state:** `dev` @ `b3202fe`, clean. The full UIKit port attempt is preserved on
`uikit-refactor` (@ `d0dd50e`) along with `docs/superpowers/plans/2026-08-20-uikit-navigation-port.md`
and `docs/playlist-softlock-investigation.md`.

---

## 1. The two problems

They are separate, and conflating them wasted hours.

### Problem A — the soft lock (unsolved)

Open an album/playlist, then dismiss it with the **left-edge swipe before the opening
animation finishes**. For roughly one second afterwards the revealed list will not navigate:
tapping another playlist does nothing at all. Scrolling still works.

### Problem B — the transition doesn't match Apple Music (unsolved, cosmetic)

Our dismiss scales the **entire detail page** down into the list cell. Apple Music moves only
the **cover and title**, leaving everything else to slide/disappear. Detail in §4.

---

## 2. Problem A: what is measured and certain

Every item here was verified on a physical iPhone 17 Pro, iOS 26.6, with on-device
instrumentation (a touch probe logging hit-tests, plus phase/nav-state logging). Do not
re-derive these.

| Finding | Evidence |
|---|---|
| The dead window lasts **exactly** as long as the push transition's `transitionCoordinator` is alive (~1s) | A guard keyed on `transitionCoordinator != nil` blocked interaction for *precisely* the bug's duration |
| It requires an **interrupted** push | A settled push (wait ~1.5s, then swipe) dismisses cleanly, every time. User-confirmed repeatedly |
| Duration is **fixed**, independent of content | A 12-track album locks as long as a 1700-track playlist. It is not data loading |
| The main thread is **healthy** | Longest stalls 120–280 ms, and those are `-Onone` inflated; nothing near 1s |
| Touches **are delivered** | Hit-tests resolve to real cells and covers throughout the dead window |
| Pans work, taps don't | Scrolling the revealed list works during the window (the footer chrome reacts); taps produce nothing |
| A **programmatic** pop during the push works | Device log: `_UIButtonBarButton` tapped at `tc=true` → immediate `willDisappear`. **This is the key asymmetry** |
| Removing `.navigationTransition(.zoom)` **eliminates it** | User-confirmed: "yeah that fixed it". Pop drops from ~1.1s to ~0.35s |
| Hosting navigation in `UINavigationController` **also eliminates it** | User-confirmed on the port |

**Conclusion:** SwiftUI's `NavigationStack` discards navigation requests raised while a
transition is in flight. The zoom transition keeps one in flight for ~1s. Both facts are
required to produce the bug.

## 3. Problem A: what is ruled out (do not retry)

Each of these was built, shipped to device, and tested.

- **Hit-testing / gating.** `coverZoomDetailInteractionEnabled` requiring `phase == .idle`
  was a real bug that made the *pushed detail* dead for ~0.94s — **fixed in `b3202fe`** and
  confirmed by the user. It is *not* the post-dismiss lock.
- **The morph container swallowing touches.** `_UIMorphAnimationContainerView` (a direct
  `UIWindow` subview) was genuinely intercepting touches; making it non-interactive changed
  hit-tests from `_UIMagicMorphTransformView` to real cells. **Lock survived.**
- **Hiding that container.** Removed the dismissal animation visually. **Lock survived.**
- **Push mechanism.** Destination-based `NavigationLink`, `NavigationLink(value:)`, and
  `navigationDestination(item:)` all behave identically. **Lock survived all three.**
- **Gesture driver.** Edge-swipe and drag-down dismissal behave identically. Not the driver.
- **Enabling/disabling the zoom's own dismiss gestures** (`disableZoomContentDismissGestures`).
  No effect on the lock; the user's gesture is a left-edge drag, always the parallax
  recognizer.
- **Clearing `preferredTransition` after the push.** Left the *push* unresolved and broke
  swipe-back entirely. SwiftUI owns that property and rewrites it.
- **Refusing the dismiss while `transitionCoordinator != nil`.** Blocked swipe-to-dismiss for
  *precisely* the bug's duration — useless, but it is the measurement that proved the timing.
- **Non-animated push + hand-drawn morph overlay.** Lock survived.
- **Search-controller churn, DEBUG logging, publish storms.** All eliminated analytically and
  by chronology (the search machinery post-dates the bug by 70 days).

### Also ruled out: XCUITest can gate this

XCUITest synchronises on app quiescence before every interaction, so its tap lands ~3.3s after
the swipe — well clear of the ~1s window. `-UIAnimationDragCoefficient` does not help. **There
is no automated test for this bug.** A UI test target exists (`VellumMusicUITests`, with a
demo-server sign-in helper and screenshot capture) but it cannot gate this. Verify by hand.

## 4. Problem B: the transition, frame by frame

Reference video: **`docs/reference-apple-music-vs-vellum-dismiss.MP4`** (14.3s, 26 MB —
deliberately **untracked**, too large to commit; also at
`~/Downloads/ScreenRecording_08-20-2026 22-47-43_1.MP4`). First half is Apple Music, second
half is Vellum, same gesture. It cannot be viewed directly — extract frames and read them as
images:

```bash
ffmpeg -ss 3.0 -to 6.2 -i "$V" -vf "fps=8,scale=210:-1,tile=5x5" -frames:v 1 am_dismiss.png
ffmpeg -ss 10.8 -to 14.0 -i "$V" -vf "fps=8,scale=210:-1,tile=5x5" -frames:v 1 vellum_dismiss.png
```

### Apple Music dismiss (playlist "grady"), ~3.0–6.2s

- **Start:** full-screen detail — cover, title "grady", "Add Music", "Featured Artists" row.
- **Immediately after the gesture commits:** the *playlist list* is already fully visible at
  **full size**. The detail's body (Add Music, Featured Artists, everything) is gone; it does
  not scale down as a unit.
- **The cover travels alone.** A single cover card moves from the hero position toward the
  "grady" row, shrinking as it goes. It is one continuous object — it never fades, never
  cross-dissolves, never swaps identity.
- **The destination row is empty while the cover is in flight.** In the mid-transition frames
  the "grady" row shows a *gap* where its thumbnail belongs. The source artwork is hidden until
  the travelling cover arrives, which is what sells "one object moved".
- **Top bar:** the detail's chevron/share/⋯ hand over to the list's own bar items. Both screens
  have real navigation bars, so there is something to hand over *to*.

### Vellum dismiss (playlist "metal v2"), ~10.8–14.0s

- **Start:** full-screen detail — cover, "metal v2", "1000 songs", shuffle/Play/download row,
  track list.
- **Mid-dismiss:** the **entire page** — cover, title, Play button, *and the track list* —
  shrinks as a single rounded rectangle and floats over the Library. Everything scales
  together. This is the core visual defect.
- **The Library behind stays at full size** during the drag (Apple Music's appears slightly
  scaled and settles as the pop commits).
- **The cover visibly changes identity** partway through — one image is replaced by another of
  the same artwork. Verified *not* caused by mismatched URL or corner radius (both were made
  identical; the swap persisted — see §6).
- **Top bar:** items fade in place (see §5).

## 5. Things that look like bugs but are deliberate

Do not "fix" these without reading why they exist.

- **`setBarItemAlpha(0, animated: true)` in `viewWillDisappear`** (`CoverZoomTransition.swift`).
  Removing it makes the toolbar items **sweep right with the bar**, which the user dislikes and
  has tried and failed to fix before. SwiftUI toolbar items live in the navigation item's
  leading/trailing groups; `UINavigationBar` animates those containers itself, and **alpha on
  the hosted `customView` is the only knob it leaves alone**. This is the working technique —
  it was removed once during this session and had to be restored.
- **Apple Music's button hand-over cannot be matched as-is.** Our Library root has *no*
  navigation-bar items: `libraryHeaderBar` is custom SwiftUI content inside the scroll view and
  the real bar is hidden (`musicNewTabRootHidesNavigationBar`). There is nothing to hand over
  to. Matching would mean moving that header into real bar-button items.

## 6. Dead ends specific to Problem B

- **Matching the artwork URL.** The cell used `playlist.artworkURL`; the hero used
  `app.resolvedArtworkURL(for:)` (which prefers a local download or a freshly generated server
  URL). Making them identical did **not** stop the cover swapping. Reverted.
- **Matching the corner radius.** Cell is `MusicDesign.gridAlbumCorner` (10), hero was 14.
  Making them identical did **not** stop it either. Reverted.
- **UIKit `preferredTransition = .zoom(sourceViewProvider:)`.** Resolves its source correctly
  (verified: registry returned the cell at its true 125×151 frame) but scales the *whole
  destination* out of that frame and cross-fades — visibly worse than SwiftUI's.
- **A hand-written composite animator** (content slide + background zoom + hero snapshot). User
  verdict: "the transition is bogus". The motion is the hard part, not the plumbing.

**Known Apple-side context:** `.navigationTransition(.zoom)` "animates the entire destination
view including its background," which developers have complained about; and there are open
forum reports of swipe-back-only, device-only glitches with it (stranded destination toolbars,
source items vanishing). Threads 774524, 807715, 810944, 800961. **Note:** none of these
describe our input-dead symptom — do not present them as confirmation of Problem A.

## 7. The recommended next attempt

**Build the detail presentation in pure SwiftUI, bypassing `NavigationStack`, one screen
first.** The user agreed to this scope: *"on one screen first sounds right."*

Present the detail as an overlay in a `ZStack` above the Library, animated with
`matchedGeometryEffect` and a drag gesture we own.

Why this beats the alternatives:

- `matchedGeometryEffect` is precisely the primitive the user keeps describing — **one element
  genuinely moving**, not a handoff between two views. It should fix the identity-swap in §4.
- The drag is an offset we control, so finger-tracking and the release threshold are ours.
- **No `NavigationStack` means no transition coordinator, so Problem A cannot occur** — it is
  structurally absent rather than worked around.
- **It never touches the app shell.** The tab bar, `tabViewBottomAccessory` mini player, and
  toolbars stay pure SwiftUI. This is the decisive advantage over the UIKit port, which broke
  all three (see §8).

Costs to plan for:

- The detail loses the system navigation bar; its chevron and ⋯ become views we draw. In
  practice it already uses custom hero chrome, so this is smaller than it sounds.
- Nested navigation (playlist → album → artist → album) and Now Playing deep links need a stack
  we maintain.
- Scroll position, accessibility, and the search bar on playlist detail all need checking.

**Scope the prototype to Library → Playlists only.** Everything else keeps working unchanged,
and the user can judge the motion before any wider rewrite. Throwaway if the feel isn't right.

## 8. Why the UIKit port was abandoned

It is on `uikit-refactor` and it **did fix Problem A** — that is how we know the diagnosis is
right. It was reverted because hosting navigation in UIKit while the shell stayed SwiftUI
created a seam that cost:

- SwiftUI `.toolbar` reaching the navigation bar (Kill Mode and ⋯ became unreachable) — though
  note this later turned out to work once the *shell* was also ported, so the premise was
  partly wrong;
- `tabBarMinimizeBehavior` (footer stopped contracting on scroll);
- `tabViewBottomAccessory`'s floating appearance.

Porting the shell too (`UITabBarController` + `UITabAccessory`) fixed all three, and the
chrome was verified good on device. What killed it in the end was **the transition**: neither
UIKit's `.zoom` nor a hand-written animator matched SwiftUI's matched-geometry morph, and the
user chose the animation over the fix.

If the SwiftUI overlay approach fails, that branch is a working starting point — the shell,
navigator, and 31 converted call sites are all there.

## 9. Working constraints

- **Build:** `~/.claude/scripts/build-to-phone.sh VellumMusicHost VellumMusicHost`. Do not
  hand-roll xcodebuild/devicectl. Phone must be plugged in and unlocked.
- **The user tests on device.** Simulator has no signed-in account; never look for their real
  server credentials — use `demo.navidrome.org` (demo/demo) if a simulator run is needed.
- **Use the `Edit` tool for source changes.** Not `sed`, `perl -pi`, `python`, or heredocs.
- **Commit on the checked-out branch**, no side branches.
- **Do not credit Claude/AI in commit messages.**
- The user has a good eye for motion and will reject animation that is 90% right. Expect
  several build-look-adjust cycles, and prefer changing one number at a time.

## 10. If you take one thing from this document

The soft lock is **not** in our code. Two independent interventions eliminate it — removing
the zoom transition, and moving navigation off `NavigationStack` — and nothing else does,
across roughly a dozen attempts. Do not spend time auditing our view code for it again.
