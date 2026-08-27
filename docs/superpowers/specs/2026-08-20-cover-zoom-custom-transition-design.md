# A local `navigationTransition(.zoom)` — design

Written 2026-08-20. Supersedes §4 and §7 of `docs/playlist-transition-and-softlock-handoff.md`
(see "Corrections" below — that document describes the target motion incorrectly).

## Goal

Replace SwiftUI's `.navigationTransition(.zoom)` on album/playlist detail with an animator we
own, so that we control the three things the stock transition will not expose:

1. whether the **source cell's artwork is hidden** while the transition runs,
2. how the **navigation bar items** hand over,
3. the **duration** of the transition — which is also the duration of the post-dismiss input
   dead window (the "soft lock").

## Corrections to the handoff document

Both were established by reading `docs/reference-apple-music-vs-vellum-dismiss.MP4` frame by
frame at 20 fps. Re-extract with:

```bash
V=docs/reference-apple-music-vs-vellum-dismiss.MP4
ffmpeg -ss 4.30 -to 4.95 -i "$V" -vf "fps=20,scale=300:-1,tile=4x3" -frames:v 1 am_push.png
ffmpeg -ss 3.40 -to 3.95 -i "$V" -vf "fps=20,scale=300:-1,tile=4x3" -frames:v 1 am_dismiss.png
ffmpeg -ss 12.75 -to 13.35 -i "$V" -vf "fps=20,scale=300:-1,tile=4x3" -frames:v 1 vellum_bar.png
```

**Correction 1 — Apple Music does not move "only the cover and title".** The handoff doc §4
says the detail body "is gone; it does not scale down as a unit". That is wrong. In the push
frames (t=4.40–4.60 s) the flying element is a rounded card containing the *entire* detail
page — cover, title, "Add Music", "Featured Artists" and its avatar row — from the very first
frame. The card grows from the source row's thumbnail rect to full screen and the content
inside is **scaled**, not merely revealed by a crop: at t=4.50 s the cover measures 93 % of its
final width while the card is 81 % of screen width. The content zooms about the cover.

Mechanically this is the same thing our current `.zoom` does.

**Correction 2 — the page behind does not zoom out.** It sits at 100 % size and 100 % opacity
for the whole transition, in both directions.

## What actually differs

| | Apple Music | Vellum today |
|---|---|---|
| Source cell during flight | Row is **completely empty** — no thumbnail, no title, only its chevron — for the whole flight, repopulating in the final ~50 ms | Cell artwork stays visible, so the eye catches one cover being replaced by another: the reported "cover swaps objects" |
| Navigation bar | Hands over cleanly | **Strands**: at 12.75–13.35 s the Library is fully settled while the bar still reads "‹ rary" with the detail's scissors / ⋯ items, for ~600 ms |
| Duration | ~250 ms push, ~200 ms post-release pop | ~1.1 s, which is exactly the measured input-dead window |

Source-hiding is the fix for the identity swap. Handoff §6 records that matching the artwork
URL and matching the corner radius both failed to stop it — neither addressed the actual cause,
which is that two covers are on screen at once.

## Architecture

Six pieces. All new code lands in `Sources/VellumMusicKit/CoverZoomTransition.swift` unless
noted.

### 1. `CoverZoomRegistry`

`@MainActor final class`, one shared instance. Maps `id -> CoverZoomAnchor`, where an anchor
carries a weak probe `UIView`, and derives `frameInWindow` and `cornerRadius` on demand.

Two registrants:

- `coverZoomSource(id:)` — already applied at ~30 call sites. It **stops calling
  `matchedTransitionSource`** and instead installs a non-interactive probe in `.background`.
  The probe reports the artwork's window frame. (Reaching UIKit from a SwiftUI leaf this way is
  the same technique `CoverZoomDismissalObserver` already uses.)
- `coverZoomHero(id:)` — new, applied to the detail's hero artwork
  (`ServerPlaylistViews.swift:1707`, inside `heroBlock`). Same probe.

If either anchor is missing when a transition begins, the animator returns `nil` and UIKit
falls back to the standard slide. Deep links and "Go to Playlist" therefore keep working with
no special-casing, exactly as the current namespace-optional path does.

### 2. `CoverZoomFlight`

A tiny `ObservableObject` with `hiddenID: String?`. Only the source marker and the hero read
it, via `@ObservedObject` inside those two modifiers — deliberately **not** on `AppModel`,
whose publishes re-run every visible `body` (`Rules/swiftui-body-cost.md`).

Set to the transiting id for the full flight; cleared in the animator's completion block,
including on a cancelled interactive pop.

### 3. `CoverZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning`

Constructed with a direction (`.push` / `.pop`) and the id.

```
transitionDuration -> 0.30 (push) / 0.25 (pop)

animateTransition(using:):
  1. add the incoming view to containerView at its final frame; layoutIfNeeded()
  2. read sourceRect (cell anchor) and heroRect (hero anchor) in container coords
  3. wrap the detail view in a clip container
  4. progress p in 0...1:
       clip.frame       = lerp(sourceRect, containerBounds, p)
       clip.cornerRadius= lerp(cellRadius, screenRadius, p)
       detail.transform = zoomAboutHero(p)     // maps heroRect onto sourceRect at p = 0
     push animates p 0 -> 1, pop animates p 1 -> 0
  5. list view stays untouched at full size and full opacity
  6. completion: clear CoverZoomFlight.hiddenID, unwrap, completeTransition(...)
```

`zoomAboutHero(p)` is `scale = lerp(sourceRect.width / heroRect.width, 1, p)` with the
translation that keeps `heroRect.center` pinned to `lerp(sourceRect.center, heroRect.center, p)`.

### 4. `CoverZoomInteractivePop: UIPercentDrivenInteractiveTransition`

Driven by our own `UIScreenEdgePanGestureRecognizer` installed on the detail's view. Progress
is `translation.x / view.bounds.width`; commit above 0.33 or on a rightward velocity over
600 pt/s, otherwise cancel.

### 5. `CoverZoomNavigationDelegate`

An `NSObject` set as the `UINavigationController`'s `delegate`, reached through the probe's
`parent?.navigationController`. It implements only:

- `navigationController(_:animationControllerFor:from:to:)`
- `navigationController(_:interactionControllerFor:)`

and forwards **everything else** to SwiftUI's original delegate via `forwardingTarget(for:)` +
`responds(to:)`, holding it weakly. Re-asserted on each `viewWillAppear` in case SwiftUI
reclaims the property.

`.navigationTransition(.zoom(sourceID:in:))` is removed from `CoverZoomDestination`. This is
required, not optional: while `preferredTransition` is set to `.zoom`, UIKit runs its own zoom
machinery and never consults the delegate. Note that handoff §3 records an attempt to *clear*
`preferredTransition` after the push, which broke swipe-back — that failed because the property
was still being set in the first place. Never setting it is a different thing.

### 6. Navigation-bar handover

Replaces the `setBarItemAlpha(0, animated: true)` call in `viewWillDisappear`. That hack exists
because `UINavigationBar` animates its own leading/trailing groups and alpha on the hosted
`customView` was the only knob left (handoff §5) — with our own animator we drive the bar's
timeline directly, so the items can cross-fade on the same curve as the card.

Keep the existing behaviour as the fallback if the handover proves worse; do not remove
`setBarItemAlpha` until the replacement is confirmed better on device.

## Scope

**This spec covers Library → Playlists only.**

- `LibraryView.swift:787` (grid) and `:800` (list) rows → `ServerPlaylistDetailView`.
- The other ~29 `coverZoomSource` call sites keep the stock `.zoom` behind a flag
  (`CoverZoomTransition.usesCustomAnimator`) until the motion is approved on device.

Widening afterwards is a matter of flipping the flag, because every call site already goes
through the same two modifiers.

## Verification

**By hand, on the physical iPhone.** Handoff §3 established that XCUITest cannot gate this:
it synchronises on app quiescence, so its tap lands ~3.3 s after the swipe, well clear of the
window, and `-UIAnimationDragCoefficient` does not help.

Acceptance, in the user's own formulation:

1. Open a playlist, **immediately** swipe out from the left edge. Can you tap another playlist
   at once? (This is the whole bug. Nothing else counts.)
2. On push, the cover moves and resizes without ever fading or being replaced.
3. On dismiss, the destination row stays empty until the card lands there.
4. The navigation bar does not strand the detail's title or items over the list.
5. Kill Mode and ⋯ remain present in playlist detail; the tab bar still shrinks on scroll and
   the mini player still floats. (These regressed in the abandoned UIKit port; nothing here
   touches the shell, so they must not move.)

Build with `~/.claude/scripts/build-to-phone.sh VellumMusicHost VellumMusicHost`.

## Risks

| Risk | Mitigation |
|---|---|
| SwiftUI reclaims `navigationController.delegate` | Proxy forwards all unhandled selectors; re-assert on every appearance |
| Hero frame unreadable before the destination lays out | `layoutIfNeeded()` before reading; missing anchor → return `nil` → stock slide |
| The motion still reads wrong | Every number (duration, curve, commit threshold, radius) is a constant in one file. Change one at a time — the user rejects animation that is 90 % right |
| Soft lock survives a 0.30 s coordinator | Then the dead window is at worst as short as the plain slide, which the user already accepted |

## Non-goals

- No UIKit shell port. No `UITabBarController`, no `UITabAccessory`, no converted call sites.
  That attempt is preserved on `uikit-refactor` and was rejected on the motion, not the fix.
- No parallax. Explicitly rejected by the user, repeatedly.
- No change to the pull-to-reveal search machinery in `CoverZoomDismissalObserver`.
