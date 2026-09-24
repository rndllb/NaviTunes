# T344 pilot — contract status and evidence outstanding

The earlier version of this file listed three deviations. The contract amendment of 2026-09-16
(md5 `32c56d39c6254d7d69f938f99f6cce2e`) turned two of them into contract, and this run closed the third:

| was a deviation | now |
|---|---|
| `already_fixed` findings with `video: null` | Contract. `video: null` is legal for any status when `no_video_reason` says why. C10 and C15 carry one. |
| A static defect has no motion to record | Contract. `image` is sufficient when the whole defect sits in one frame. P03 carries one. |
| `confirmed` findings whose recording was outstanding | Closed. P11, P27 now have video; C13 has runtime evidence with a `no_video_reason`. |

`validate_findings.py` enforces the pinned names: exactly one of `video` / `image`, `no_video_reason`
required when neither is set, `surviving_defect` shape and severity, every evidence path present on disk,
and near-miss spellings (`screenshot`, `survivingDefect`, …) rejected as errors. It passes all 17 files and
was negative-tested against deliberately malformed copies (near-miss key, both evidence fields, bare null,
bad severity, missing file) — each one fails.

## Two contract rules, recorded here as the rulings asked

1. **A prior DENIED verdict is never a filter.** All three DENIED probes were attempted on their own
   evidence. P01 and P27 reproduced at runtime; C135's headline did not, and its real narrow defect travels
   as `surviving_defect`.
2. **`not_reproduced` never swallows a real defect.** C135 and P05 both carry `surviving_defect` (low).

## Evidence outstanding — what this batch did not capture, and what would

Nothing below is hidden inside a status. Each item is also written into its finding's `notes`.

| id | not captured | what it needs |
|---|---|---|
| C16 | The single-device in-flight interleave (half a) and the no-retry-after-failed-write path. The cross-device lost update WAS reproduced. | Latency between app and Navidrome (a throttling proxy) so the 9–32 ms fetch outlasts an add; a forced write failure. |
| C12 | The 414 itself. Bare Navidrome accepted a 475 KB request line. | A stock nginx (`large_client_header_buffers 4 8k`) in front of Navidrome, a fresh sign-in through it, ~85 albums added. |
| C11 | Everything — Jellyfin-only defect. | A Jellyfin server with a >5,000-track magic playlist. |
| P08 | Dark-on-dark pill (both captured surfaces had a grey artwork backdrop); the in-tab toast position. | A toast raised from a screen with no artwork backdrop in dark mode. |
| P01 | The buffering-state play/pause `Button` (transient). | A throttled stream so the buffering control persists long enough to dump. |
| P01, P27, P08 | Anything VoiceOver actually speaks. VoiceOver does not run in the iOS Simulator. | A physical device, or accept the XCUITest accessibility tree as the proxy (as this batch does). |
| P05 | Any render of the fallback shelf. Two launch states tried; neither opens the window. | A state where the catalog is loaded but every catalog album is ineligible for Top Picks — not practical on an 11.5k-album server. |
| P06 | The "hero triplet hand-built three times" half is source-structure only. | Nothing further; it has no screen behaviour. |

## A correction this batch made to its own earlier evidence

ISSUES-01 was first recorded as `already_fixed` because "the `.searchable` modifier was removed" — a
conclusion from a literal grep. The modifier was not removed; it is applied through the
`playlistTrackSearchable` → `musicNativeSearchable` wrapper, which a literal grep cannot see. The status
survives on stronger evidence (ISSUES.md's failing step filmed working), but the reasoning was wrong and the
JSON says so. For a full run: verify absence claims by symbol and wrapper, never by literal grep.

## Foreign files in `findings/`

Files prefixed `ZZ-` belong to other tasks (T348 wrote `ZZ-T348-PROBE.json` to test its scheduler). The
validator skips them and they are excluded from counts; this run never deletes them. None is present now.
