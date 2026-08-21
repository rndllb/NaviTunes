# Custom cover-zoom: the swipe-to-dismiss problem

Written 2026-08-21. The push (open) and the back-button pop (close) both work and the user is
happy with them. **Only the interactive edge-swipe dismiss is wrong.** Read this before
touching anything — every obvious idea below has already been built, shipped to the device, and
measured.

Code: `Sources/VellumMusicKit/CoverZoomCustomTransition.swift` (all of it),
plus `CoverZoomSource` / `CoverZoomDestination` in `CoverZoomTransition.swift`,
the two `NavigationLink`s and the two artwork anchors in `LibraryView.swift`,
and `heroArtwork` in `ServerPlaylistViews.swift`.

## Vocabulary (the user's, use it)

- **Playlists list** — the list of playlists. Library → Playlists. Must stay an ordinary
  right-slide push in both directions.
- **Playlist view** — one playlist's page. This is the only screen that zooms.

## What works now

- Push zooms out of the tapped row's artwork, cropping outward from the cover.
- Back-button pop reverses it correctly. User: "the close is so good".
- Library → Playlists list is unaffected and still slides.

## The bug

Edge-swipe from the left on a playlist view performs UIKit's **parallax slide** (page slides
right unscaled, list enters from the left) instead of our shrink-into-the-row.

The user's screen recording (`~/Downloads/ScreenRecording_08-21-2026 00-55-45_1.MP4`, 3.9s)
shows it in two halves: frames 7–12 are the parallax; frames 13–16 are our correct shrink
running afterwards, as the tail. Extract with:

```bash
ffmpeg -i "$V" -vf "fps=6,scale=220:-1,tile=6x5" -frames:v 1 overview.png
```

## The decisive measurement

`DebugUIRemote.log` writes to `Documents/vellum-hangwatch.log` in the app container. Pull it:

```bash
xcrun devicectl device copy from --device 00008150-001A43E10C63401C \
  --domain-type appDataContainer --domain-identifier com.randll.vellum --user mobile \
  --source Documents/vellum-hangwatch.log --destination ./hw.log
```

For a **swipe** dismiss the log contains:

```
PHASE willDisappear
PHASE didDisappear popped=true      <- the pop definitely happened
```

and **no `COVERZOOM ask op=2`** between them, while `reclaim lines: 0` says we still held
`navigationController.delegate`. For a **back-button** dismiss on the same navigation
controller, `ask op=2` is present and our animator runs (`COVERZOOM run push=false`).

**So: a button-driven pop consults `UINavigationControllerDelegate`; a gesture-driven pop on the
same controller does not.** That is the entire remaining problem. Start here.

Untested hypotheses worth checking first:
1. SwiftUI's `NavigationStack` handles the interactive pop itself and never routes it through
   `UINavigationController`'s delegate.
2. The gesture-driven pop runs on a *different* navigation controller than the one we installed
   on (log `ObjectIdentifier` of the controller in both paths to settle it).
3. `preferredTransition` is set by SwiftUI on the pushed controller and wins over the delegate
   for interactive pops specifically.

## Ruled out, on device, with logs

Do not retry these.

| Attempt | Result |
|---|---|
| Own `UIScreenEdgePanGestureRecognizer` + `popViewController` | Pop happened; separate reopen bug; abandoned |
| Taking `_UIParallaxTransitionPanGestureRecognizer.delegate` and answering `shouldBegin` | Gesture recognises, pop is **never armed**. Six approved `shouldBegin` calls, zero pops reached the delegate |
| Leaving that delegate alone | UIKit's own delegate vetoes the gesture because we supply a custom animator — swipe does nothing |
| Setting that delegate to `nil` while our detail is on top | Gesture works, pop happens, but still bypasses our delegate (current state) |
| Custom `UIViewControllerInteractiveTransitioning` driving progress by hand | Never scrubbed; UIKit substituted its parallax |
| `interruptibleAnimator(using:)` vending a `UIViewPropertyAnimator` | **Required and now implemented** — without it UIKit cannot scrub a custom animator at all. Did not by itself fix the swipe |
| Re-asserting `navigationController.delegate` on `viewDidAppear` and on every touch-down | Fixed back-button pops. Swipe still bypasses |

## Geometry — settled, do not re-derive

Measured on device, container is 440×956:

- Cell (list row artwork): `(20, y, 52, 52)`, corner radius 8.
- Hero: `(60, 124, 320, 320)`, corner radius 14 — **identical for every playlist**, because it
  is layout-determined. `CoverZoomRegistry` caches and persists it, which is what makes a
  first push animate at all (the detail's SwiftUI body has not run when UIKit asks for the
  animator, so the hero probe does not exist yet).
- The push id must be known **before** the push. It comes from a passive touch observer
  (zero-duration `UILongPressGestureRecognizer`, `cancelsTouchesInView = false`) that hit-tests
  registered row rects. Two earlier mechanisms failed: a SwiftUI `simultaneousGesture` ate the
  `NavigationLink`'s activation so nothing opened; reading it from the link's destination
  closure named whichever row `LazyVStack` built last, including buffered rows past the fold
  (`cell=(20, 1128, 52, 52)` on a 956pt screen).

## Known-open, lower priority

The push starts very slightly high — the user reports the artwork appearing a little above the
row it came from, while the pop lands correctly. The `p=0` log line says
`card=(20, 380, 52, 52)`, exactly the row, so the first frame is right; suspect the easing or
the first committed frame rather than the geometry.

## Diagnostic values currently in the tree

`CoverZoomTuning.pushDuration` and `popDuration` are **5.0** for inspection. Restore to
0.30 / 0.25 before shipping. `verticalLag` is 1.0 (straight path); raising it bows the cover's
path below the straight diagonal.

## Working constraints

- Build: `~/.claude/scripts/build-to-phone.sh VellumMusicHost VellumMusicHost`, run from the
  repo root. Phone must be unlocked or the launch step fails (the install still succeeds).
- Use the `Edit` tool for source changes, never `sed`/`python`/heredocs.
- The user tests on device. There is no automated test that can reach this.
- Verify from the log, not from reasoning. Every wrong turn in this session came from
  reasoning ahead of the evidence.
