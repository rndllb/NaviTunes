# Mini player → Now Playing transition — handoff

Written 2026-08-22 after a long session. The transition itself is **done and committed**; one
symptom remains unexplained and this exists so the next attempt starts from measurements rather
than re-deriving them. Everything below was taken on a physical iPhone 17 Pro, iOS 26.6.

**Current state:** `c0cf1df` is the good commit (open, interactive close, pill hand-off). The
working tree adds a 14-line interaction fix plus DEBUG instrumentation, all listed in §5.

---

## 1. What was fixed, and why it was broken

Opening the player and immediately swiping it down left the whole app unresponsive, and
sometimes killed it. Two distinct causes, both now gone:

**The crash.** Both `.ips` files end in the same place:

    SwiftUI.SheetBridge.preferencesDidChange
      → -[UIViewController dismissViewControllerAnimated:completion:]
        → _dismissViewControllerWithAnimationController:interactionController:…
          → objc_exception_throw

`fullScreenCover` dismisses the instant the binding changes, including on top of a present that
has not finished. No animator can make that safe — the presentation had to move to
`NowPlayingCoverPresenter`, which owns `present`/`dismiss` and can refuse them while UIKit is busy.

**The soft lock.** The survivable version of the same collision: an on-device touch probe caught
taps resolving to real views (`UIKitTabBarBottomAccessory`, the list) that did nothing, with
`UITransitionView` — the modal presentation container — still standing over the app seconds after
the cover had animated away. An interrupted system zoom does not finish tearing its presentation
down.

## 2. The animation

`NowPlayingCoverAnimator`, measured off Apple Music at 30fps (frames 25–32 of
`ScreenRecording_08-21-2026 23-57-23_1.MP4`). Four independent parts:

1. a rounded card whose top edge grows out of the pill, bottom staying put;
2. the pill fading out at the top of that card as it stretches;
3. the cover travelling between the pill's artwork and the player's hero rect;
4. the player's content sliding with the card, revealed by the crop, never scaled.

Things that look arbitrary and are not:

- **The cover that flies is the player's, not the pill's.** Flying the pill's 28pt thumbnail up
  to 296pt arrived soft and visibly lower-bitrate, then swapped for the crisp one on arrival.
- **The cover is a sibling of the card, not a child.** On the way down the card becomes smaller
  than the cover, and a cover parented inside it is clipped away exactly when it should be seen.
- **The drag is a pure translation; the morph happens only on release.** Scrubbing the morph with
  the drag makes the cover reassemble under the finger, which Apple Music does not do.
- **Drag translation is a `CGAffineTransform`.** Re-laying the card out per frame means setting
  the player's frame per frame, which invalidates SwiftUI's layout for the whole player.
- **The pan lives on the window.** `prepare` reparents the player, and removing a view from its
  superview cancels the recognizers attached to it — mid-`prepare`, before the animator was
  marked as dragging, so nothing completed the transition and the card stranded on screen.
- **The close reads geometry recorded by the open** (`NowPlayingCoverGeometryCache`). A
  full-screen presentation takes the accessory off-window, so `cellRect` and the pill anchor both
  return nil and the close falls back to a cross-fade.
- **The card fades out over the last 22% of a close.** It is a pill-sized window onto the
  player's transport row by then, and removing it swapped that for the real pill in one frame.

## 3. The unexplained symptom

**After the player opens, its controls do not respond for roughly two seconds.** Not the app
behind it — the player's own buttons. Reproduces every time.

Every layer measures healthy:

| Measurement | Result | Rules out |
|---|---|---|
| `NP-FLAGS` | `window=true container=true player=true alpha=1.00 coordinator=false` from +0ms | UIKit interaction gating |
| `NP-PROBE[OPEN]` | taps hit `_UIHostingView<…NowPlayingGestureHost…>` | wrong view / stranded overlay |
| `NP-DRAG` | 2 `began` in a whole run, both real swipes | the dismiss gesture eating taps |
| `NP-SWIFTUI` | `tap recognised` 0.33s after open, repeatedly | touches not reaching SwiftUI |
| `NP-MAINTHREAD` | worst gap 86–190ms over 3s | main-thread saturation |
| `NP-BODY` | 1–9 body evaluations per second | rebuild churn losing touch-down/up |

So the touch reaches SwiftUI's gesture system, SwiftUI recognises it, the tree is not being
rebuilt, and the control still does not fire.

**Hypotheses already killed by measurement** (do not retry):

- UIKit leaving the container or window non-interactive after the transition.
- The window-level pan recognizer cancelling touches.
- `cover.rootView` reassignment on every shell render rebuilding the tree under the tap. This was
  real and was fixed — the presenter now only refreshes while the cover is off screen — but it is
  not this symptom.
- Main thread too busy to process touches.

**Not yet tested, in rough order of promise:**

1. Whether the controls are firing and their *effect* is what is delayed. Nothing has confirmed a
   button action failing to run — only that the user sees no response. Log inside one button's
   action closure and settle it.
2. Whether SwiftUI's hit-test resolves to the control or to something above it. UIKit's chain
   stops at `HostingView`; SwiftUI's internal hit-testing is invisible to it. A `Self._printChanges`
   or an overlay probe inside the player would show which view actually takes the tap.
3. Whether the presented `UIHostingController` needs its safe-area/layout re-run after the
   animator reparents its view back into the container.

## 4. Interruption (open/close cannot cut each other short)

Also unresolved, and separate. UIKit will not begin a dismiss while a present is in flight, so a
swipe during the open is queued behind it.

- Cutting the in-flight transition short and starting a fresh one **regressed hard** (attempt 20):
  two animators on the same views in one frame, the second snapshotting while the first tore down.
- Presenting `animated: false` and running the animation ourselves **worked** (attempt 22) —
  open/close interruption confirmed on device — but brought frame flashes at the hand-off points
  and left the underlying view not taking taps after a close. Reverted at the user's request.

If this is picked up again, attempt 22's design is the right direction, and the two open questions
are narrow: which hand-off flashes, and why the app underneath stops taking taps after an
unanimated dismiss. Both are answerable with the instrumentation below.

## 5. Instrumentation (DEBUG only)

All of it writes to `Documents/vellum-hangwatch.log`, readable with:

```bash
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
  --domain-identifier com.randll.vellum --source Documents/vellum-hangwatch.log --destination ./hw.log
grep -n "===== LAUNCH" hw.log | tail -1   # read only past the last launch marker
```

| Tag | Where | What |
|---|---|---|
| `NP-ANIM` | `NowPlayingCoverAnimator` | resolved rects per flight, and every `finish` |
| `NP-PROBE[OPEN\|CLOSE]` | `NowPlayingTouchProbe` | hit-test chain for 8s after an open or close |
| `NP-FLAGS` | ditto | interaction flags at 0/200/600/1200/2500ms after an open |
| `NP-MAINTHREAD` | ditto | worst runloop gap over 3s after an open |
| `NP-DRAG` | `NowPlayingCoverZoomController` | every `shouldBegin` with each gate's value |
| `NP-SWIFTUI` | `NowPlayingGestureHost` | taps SwiftUI's own recogniser accepts |
| `NP-BODY` | `NowPlayingView` | body evaluations per second |

Crash reports pull the same way with `--domain-type systemCrashLogs`.

## 6. The one lesson worth carrying

Every time this was measured, the answer was something not on the list of suspects; every time it
was reasoned about, the fix was wrong and usually made something else worse. Three separate
regressions in this session came from bundling several changes into one attempt — when one of them
broke something, nothing pointed at which. One change per build.
