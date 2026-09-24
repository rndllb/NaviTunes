# T344 pilot batch — what was picked and why

Corpus parsed from `docs/CODE_SWEEP.md`: **307 findings**, matching the header's claim exactly.
Verdict split, taken from each finding's own metadata line (not a raw grep, which over-counts
because the words appear in prose too): **218 CONFIRMED / 76 REINFORCED / 13 DENIED**.

**DENIED share = 13/307 = 4.2% by volume — but that was the wrong measure, and the first version of
this file drew the wrong conclusion from it.** What matters is whether the label is reliable: **5 of
the 13 denials are recorded by the sweep's own T238 re-verification as `Denial: DOES NOT HOLD`** (C135,
L11 (high), P01, P21, P27). Every one attacks the finding's rhetoric rather than its defect. In this
pilot, 2 of the 3 DENIED probes (P01, P27) reproduced at runtime, and the third (C135) carries a real
surviving defect. Per the 2026-09-16 contract amendment a DENIED verdict is never a filter; entries still
travel as `source_verdict: "DENIED"` so they stay distinguishable.

Severity split: 66 high / 144 medium / 97 low.

## How these 17 were chosen

Not at random, and not the easiest 17. Four bands, each chosen to stress a different way the
harness could be wrong:

1. **Visual, on-screen (7)** — the `Presentation` section is where a screen recording is the
   natural evidence. These prove the recording path produces something a human can rule on.
2. **Systemic (4)** — state, concurrency and payload-shape defects that a recording alone
   cannot show. These prove the harness degrades honestly into `cannot_test` rather than
   faking a video.
3. **DENIED probes (3)** — findings a verifier already refuted. If one of these reproduces
   anyway, the sweep's verification pass has a hole, and that is worth knowing before
   commissioning 307.
4. **`already_fixed` candidates (3)** — findings whose defect is named by a commit that landed
   *after* the sweep. This is the status the contract added on 2026-09-15, and it is the one
   most likely to be faked by a lazy run, so the pilot deliberately loads up on it.

`already_fixed` is only claimed where a commit names the finding id or describes its exact
defect **and** the current source shows the fix. Where the simulator merely fails to show the
problem, the status is `not_reproduced` with the divergence written out — per the contract, an
agent that cannot tell which it is must not guess `already_fixed`.

## The batch

| # | id | source_verdict | sev | band | why this one |
|---|----|----|----|----|----|
| 1 | P03 | CONFIRMED | med | visual | Every Top Pick card captioned "New Release" — single screen, unambiguous |
| 2 | P04 | CONFIRMED | med | visual | New tab labels an album shelf "Trending Songs" |
| 3 | P05 | CONFIRMED | med | visual | Home fallback shelf "Your Library" shows the server catalog — the catalog/library footgun in CLAUDE.md |
| 4 | P08 | CONFIRMED | med | visual | Toast offset is a magic number, dark-on-dark |
| 5 | P11 | CONFIRMED | med | visual | Nav chevron hard-coded light-mode grey — needs a dark-mode pass |
| 6 | P06 | REINFORCED | med | visual | Play/Shuffle swap position between Favorites and every other list |
| 7 | P13 | REINFORCED | low | visual | Copy references features that no longer exist — also a staleness probe |
| 8 | C12 | CONFIRMED | high | systemic | Membership payload sent as GET query string, caps library at ~100 albums |
| 9 | C13 | CONFIRMED | high | systemic | Acquisition secrets in plaintext `UserDefaults` — inspectable without the UI |
| 10 | C16 | CONFIRMED | high | systemic | Membership poll clobbers an in-flight add |
| 11 | C11 | CONFIRMED | high | systemic | Jellyfin magic-playlist read caps at 5,000 rows — Navidrome-only rig, likely `cannot_test` |
| 12 | P01 | DENIED | med | denied-probe | Now Playing transport unlabeled for VoiceOver — checkable with the accessibility inspector |
| 13 | P27 | DENIED | low | denied-probe | A–Z scrubbers expose 27 inert letters |
| 14 | C135 | DENIED | low | denied-probe | `autoOfflineActive` not published, offline indicators render stale |
| 15 | C10 | CONFIRMED | high | already_fixed? | Named by commit `8fd35ba` ("Thread artistId through the Track copy constructors (C10)") |
| 16 | C15 | REINFORCED | high | already_fixed? | Named by commit `f39eae7` ("Refuse to write library membership we could not read (C15, C78)") |
| 17 | ISSUES-01 | n/a | — | already_fixed? | Playlist search bar reveal. Ethan stated directly this is fixed and now works as intended; `ISSUES.md` still documents it as broken. The known-stale datapoint that motivated the status. |

### Classification corrections made during the run

- **P05 and C16** were first filed `cannot_test` "for want of a populated library". Wrong premise: the
  account had 500 catalog albums loaded but an empty *personal* library, and the two were conflated.
  P05 is most likely to trigger on an empty account; C16's race is ordering, not volume. Both were
  attempted with the driver (P05 `not_reproduced`, C16 `confirmed` on its cross-device half).
- **P06** needed a few starred tracks, not bulk seeding — five were starred via Subsonic `star`.
- **C12** was thought to need ~100 albums seeded. Its verbatim excerpt shows the cap only bites **behind a
  reverse proxy**; bare Navidrome accepted a 475 KB request line. It is `cannot_test` for rig topology, not
  data.
- **C11** landed `cannot_test` as predicted: Jellyfin-only, and the rig has no Jellyfin.
- **ISSUES-01** stayed `already_fixed`, but its original evidence ("modifier removed") was wrong — see
  CONTRACT_DEVIATIONS.md.

Seventeen rather than fifteen, because the three DENIED probes and the `already_fixed` band are
the two that actually decide whether a 307-run is worth commissioning, and I did not want to
buy them by dropping visual coverage.
