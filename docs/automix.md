# AutoMix — song-to-song blending (T630)

Apple Music's AutoMix, done on the phone, for downloaded and cached songs. When one song ends the
next one comes in beat-matched, with a bass swap, or — when the two cannot be matched — on a
smooth loudness-matched crossfade. It always transitions. Off by default (Settings → Sound &
Playback → AutoMix).

Everything below was decided or measured on the Linux box on 2026-10-09. The Mac came back the
same afternoon: the unsigned device build of this tree compiles clean (no errors, no warnings in
the new files) and bundles the compiled model; the unit tests ran on an iOS 26 simulator (counts in
the T630 report and `OPTIMIZATIONS.md`). Nothing has run on a phone yet — `build-to-phone.sh` is
the user's step. The remaining Mac checks are listed at the end.

## Shipping design: on-device, lazy, cached forever

- **No server.** The analysis runs on the phone, only for the track that is playing and the track
  queued after it, on a `.utility`-priority task, one at a time. Nothing runs while idle, nothing
  runs for the rest of the library.
- **Model:** Beat This `small0` (CPJKU), converted to Core ML. Beats + downbeats at 50 fps from a
  log-mel spectrogram, in fixed 30 s chunks (1500 × 128). Bundled in the app (4.6 MB, see below).
- **Sections:** no model. The `IntroOutroHeuristic` — RMS per bar, a 90th-percentile reference,
  leading/trailing bars under 70 % are intro/outro, capped at 32 bars. The same rule runs in the
  Linux harness so its scores apply to what ships.
- **Loudness:** BS.1770 (K-weighting, gated) in Swift, integrated + 10 s windows at the cues.
- **Cache:** `TransitionAnalysisStore`, one JSON per track under `Caches/VellumMusic/automix/`,
  keyed by track id **and** a file fingerprint (byte count + mtime), kept forever. A re-download or
  retag misses and re-analyses; a purged cache costs one re-analysis.
- **Deadline fallback:** `TransitionPlanner.plan(from:to:pending:outgoingPosition:)` never waits.
  If the incoming analysis is not here and cannot land before the cue point minus a 2 s handoff
  lead, the decision is `.defaultTransition(.analysisLate)` — the app's existing gapless
  `AVQueuePlayer` boundary, untouched. If it can land, the decision is still the default *now* and
  the engine re-plans when the coordinator reports the result.

### The style decision (never a refusal)

`TransitionPlanner.plan(from:to:)` returns one of:

| Decision | When | What plays |
|---|---|---|
| `.beatMatched(BlendPlan)` | tempo match within ±8 % after ½/×1/×2, both beat confidences ≥ 0.5, integrated loudness within 8 LU, ≥ 2 bars of material after A's mix-out and after B's mix-in, both tracks ≥ 45 s | 8-bar overlap ending on A's last downbeat (pulled earlier to the outro's first downbeat when there is one); B stretched pitch-preservingly with a **per-bar rate schedule** so each of its bars lands on A's (a constant stretch drifted 90 ms over 8 bars in the evaluation), then glided back to 1.0 over ~4 bars; equal-power crossfade; low-shelf bass swap at the midpoint; B trimmed to A's loudness (±6 dB cap) |
| `.crossfade(CrossfadePlan)` | anything else, with the reason (`tempoMismatch`, `energyMismatch`, `lowBeatConfidence`, `insufficientMaterial`, `trackTooShort`) | 8 s (≥ 3 s) equal-power fade timed to A's mix-out and B's mix-in cues, no stretch, loudness-matched, low-pass sweep closing on A (20 kHz → 800 Hz) and opening on B |
| `.defaultTransition(reason)` | analysis missing or late (`metadataMissing`, `analysisLate`) | the existing gapless transition |

Cues come out of the analysis: `mixIn` is the downbeat 8 bars before the intro ends (or the first
downbeat), `mixOut` is the outro's first downbeat (or 8 bars before the last downbeat). The planner
owns the final placement: the overlap never runs past A's last downbeat, because a beatless fade-out
is nothing to beat-match to, and a crossfade cue that leaves less than a full fade slides so the
fade fits inside both tracks.

### Playback

`AutoMixPlayerBlend` plays one transition on two `AVPlayer`s and no audio engine (T677). The
outgoing song stays on the queue player it has been playing on; its equal-power fade is the
player's `volume` and its bass hand-over and filter sweep are two extra biquads in its equalizer
tap (`EqualizerAudioTap.setTransition`). The incoming song is built through the ordinary item
path (`makePlaybackAsset` on its local file, `TapPlayerItem` with the live EQ), with its whole
gain curve — equal-power fade × loudness trim, then the trim glide — baked into its audio mix as
sample-accurate volume ramps, its time-stretch as the player's `rate` on a `.spectral` item, and
its bass/filter on its own tap. It is readied, seeked to the mix-in, pre-rolled at the opening
rate, and started with `setRate(_:time:atHostTime:)` at the host time the queue player reaches
the mix-out (measured on the simulator: starts within 2–4 ms, two players agree to 0.0 ms). The
automation runs at 50 Hz on the host clock, as before. When the overlap has completed the
outgoing is silent and `PlaybackEngine` **adopts** the incoming player as the queue player — the
item that started the overlap simply keeps playing; once the rate is back at 1.0 and the trim at
unity the ramped mix is swapped for the plain one (same tap, not re-prepared) and the blend is
over. There is no transport crossing at either end: the previous design's two 80 ms ramps
(queue player → engine at the handoff, engine → queue player at the handback) were each a
measurable gap, and the engine's cold start alone put its deck 47 ms behind the player.

The overlap start is computed once, from where the outgoing stood when the blend was armed, and
then checked: every tick of the lead-in, once the outgoing player is seen advancing, its position
is compared with the one the plan implies and the incoming start is re-scheduled on any drift
beyond 5 ms (a buffering stall, or the few hundred ms right after `play()` in which `AVPlayer`
reports rate 1 before its timebase moves — measured as a constant 300 ms offset through the whole
overlap before this). A pause stops both players and the overlap clock with them; `resume`
restarts them together at one host time (a pause in the lead-in re-schedules the incoming start
against the outgoing's position). A seek, a skip or the toggle going off abandons the blend;
after promotion the incoming player is adopted first, so the song the user is looking at is the
one that seeks.

A crossfade planned to a short outro runs to the outgoing song's last sample, so the outgoing
item ends at the very moment the overlap completes. Its end notification can then be delivered
*after* the adoption removed its observer and stopped its player (`NotificationCenter` delivers a
queued block observer even after `removeObserver`); `handleEnded` ignores an end or failure
notification for any item that is not the bound transport item, instead of reading it as the
incoming song's natural end and advancing off it (T677 c5, "sometimes the automixer kills the
song stream after its transition is over").

The blend's clock is coupled to the players (T696). A pause that does not come through the engine — an
interruption, headphones unplugged, a Bluetooth route gone — stops the players but used to leave the blend
running on the host clock, reporting playing, finishing the overlap in silence and adopting a player that had
never started. Now a `.paused` on the transport during an un-paused blend, and the interruption's `.began`,
pause the blend as a whole; `.ended` with `.shouldResume` resumes both players together. The outgoing player's
`automaticallyWaitsToMinimizeStalling` is cleared when the blend is armed, because `setRate(_:time:atHostTime:)`
raises on a player that has it set and a streamed song's queue player keeps that default. An abort that keeps the
incoming (a scrub or the toggle after promotion) swaps in the plain mix exactly as settling does, and a queue edit
that moves the blend's target out of the next slot abandons an un-promoted blend at once.

While the toggle is off, `PlaybackEngine` does not touch any of this: no coordinator calls, no
planning, no second transport. The `AVQueuePlayer` path costs exactly what it did before.

### Files

| File | Role |
|---|---|
| `Playback/AutoMix/TransitionMetadata.swift` | the per-track analysis record (Codable, schema v1) |
| `Playback/AutoMix/TransitionPlanner.swift` | style decision, thresholds, deadline rule — pure |
| `Playback/AutoMix/AutoMixAutomation.swift` | gain / rate / shelf / sweep curves and scheduling arithmetic — pure |
| `Playback/AutoMix/AutoMixAnalysisCoordinator.swift` | lazy next-track-only scheduling, cache, throughput estimate |
| `Playback/AutoMix/TransitionAnalysisStore.swift` | forever-cache on disk keyed by id + fingerprint |
| `Playback/AutoMix/TransitionAnalyzer.swift` | the Core ML analyzer: decode, features, peak picking, cues, loudness |
| `Playback/AutoMix/MelSpectrogram.swift` | log-mel front end (vDSP) matching the training preprocessing; BS.1770 meter |
| `Playback/AutoMix/CoreMLChunkRunner.swift` | chunked inference with the reference border handling |
| `Playback/AutoMix/IntroOutroHeuristic.swift` | the phone-side section rule — pure |
| `Playback/AutoMix/AutoMixPlayerBlend.swift` | one transition on two `AVPlayer`s (T677; replaced the two-deck `AVAudioEngine` transport) |
| `Playback/AutoMix/AutoMixStreamPrefetcher.swift` | early fetch of the next queued stream into the stream cache (AutoMix on only) |
| `Playback/PlaybackEngine.swift` (AutoMix extension at the end) | planning hook, handoff, promote, hand-back |
| `Resources/BeatThisSmall.mlpackage` | the converted model (SwiftPM compiles it to `BeatThisSmall.mlmodelc`) |
| `Tests/VellumMusicKitTests/TransitionPlannerTests.swift`, `AutoMixAnalysisTests.swift` | 41 tests in 5 suites (green on the Mac, iOS 26.4 simulator, inside the full 209-test scheme): guard both ways, deadline, cache hit / miss-in-time / miss-too-late, heuristic, chunking, peaks, stream prefetch with a counting URLProtocol |
| `scripts/automix/` | the Linux evaluation harness (analyze, render, bench, Core ML conversion) — not shipped |

### Streamed songs (round 2)

A streamed next track has no file to analyse until it is fetched. With AutoMix on,
`AutoMixStreamPrefetcher` fetches the next queued stream whole into the stream cache
(`StreamingMediaDiskCache.fetchAndCommit`) as soon as planning runs for a new current track; the
coordinator then analyses that file and `PlaybackEngine` plays from it (its candidate order
already prefers a cached copy over the network), so the song is downloaded once. The fetch is
cancelled when the queue changes or the toggle goes off; with AutoMix off there is no early fetch.
Lead time is "at track start": fetch (5–50 s) plus analysis (≈ 10 s) plus the 2 s handoff lead
must beat the cue point ~15 s before the end, and starting immediately leaves minutes of margin on
an ordinary song. Covered by `AutoMixStreamPrefetcherTests` with a counting `URLProtocol`: one
request, the stream's bytes, no second fetch.

**T791 (2026-10-13): early, whatever the timeline does, and never silent.** What to prepare and
what plays is decided by `AutoMixPreparation` (pure, `AutoMixPreparationTests`):

- The next stream is fetched once the playing song **plays steadily** (playing, not buffering;
  `noteAutoMixSteadinessChanged` re-plans on that change), not at the first planning pass, which
  ran before audio had started and competed with it on a slow link. Never over cellular while
  "No streaming over cellular" applies.
- The next song is analysed as soon as it is a file, even while the playing song is still a
  stream; it used to wait until it became the playing song.
- A failed analysis is remembered per file (`AutoMixAnalysisCoordinator.Status.failed`) and never
  re-run; it used to restart on every re-plan, i.e. on every seek, while the planner logged
  "waiting for analysis" until the boundary went by with no transition.
- When the beat-matched blend is not possible (the playing song is streamed, an analysis failed or
  is not in yet, or the playhead is past the analysed cue), the boundary is a **plain crossfade**
  of up to 8 s ending a second before the song does (`AutoMixPreparation.plainCrossfade`, durations
  only). Only when even that cannot be staged — the playhead within ~11 s of the end — is it the
  normal transition (`TransitionStyleReason.noTimeToPrepare`). Every fallback is one line in the
  perf log (`vellum.perf`, category `automix`, plus a `automix.fallback` event) with the playhead,
  e.g. "plain crossfade: the analysis of the playing song failed (at 183 s of 234 s)".
- Planning reads the player's live clock (`autoMixPlanningPosition`), not `playbackHead`, which the
  periodic observer had not yet refreshed when the steady-playback re-plan ran.

## Model delivery

Measured: `BeatThis-small0.mlpackage` is **4,642,069 bytes** (2,099,960 parameters, fp16 weights,
`mlprogram`, iOS 17 target). That is under the 10 MB line, so **it is bundled**: no install step,
no startup check beyond `CoreMLBeatAnalyzer.isAvailable` (a `Bundle.module` lookup on first use).
Compiled on the Mac by SwiftPM's resource step (`CoreMLModelCompile`), the `.mlmodelc` in the
built app is **4,580 KB** — still well under the line. For comparison `final0` converts too but is 40.9 MB — it would have forced the
download branch.

If the toggle is on and the model is not in the build, Settings shows "needs the analysis model"
and every boundary is the default transition.

## Measurements (c2) — analysis models on this box

Five songs (One More Time, Do I Wanna Know, HUMBLE, River Man, Hard Times; mean 4.0 min). CPU is a
Ryzen 5 9600X (6 cores); GPU an RTX 3090. "CPU best" is the best thread count measured — 12 threads
oversubscribes this chip 5–8× (recorded in papercuts).

| Model | On disk | Params | GPU s/song | CPU s/song (best, threads) | Peak host RSS | iPhone 13 verdict |
|---|---|---|---|---|---|---|
| Beat This `final0` | 81.1 MB | 20.25 M | 0.56 | 6.7 (2 thr) | 1.9 GB (torch process) | **No.** 81 MB of weights and 20 M params through 6 transformer layers at dim 512: ~1.3 s per 30 s chunk on one desktop core → ~10 s per song single-core here, roughly 15–20 s on an A15 core, and the working set would not stay small. Accuracy gain over `small0` is marginal for cueing. |
| Beat This `small0` | 8.5 MB (4.6 MB as Core ML; **4.58 MB compiled `.mlmodelc`, measured on the Mac**) | 2.10 M | 0.51 | 6.6 (1 thr) / 3.8 (2 thr) / 2.5 (6 thr) | 1.5 GB (torch process); **model working set 35 MB fp16 / 78 MB fp32 per 30 s chunk** | **Yes.** 0.75 s per 30 s chunk on one desktop core = 6 s per 4-min song single-core; projected 9–12 s on an A15 core, under 2 s on its Neural Engine if the partial-attention ops map (to verify on the Mac). Fits the 4 GB phone with 35 MB of activations. |
| madmom RNNDownBeat + DBN | 7.2 MB (8 BLSTM pickles ≈ 1.8 M float32 weights; the loader does not expose a count) | ≈ 1.8 M | — (no GPU path) | 5.2 (12 thr, BLAS) / 8.4 (2 thr) | 2.3 GB | **Borderline.** Pure numpy BLSTMs would port to Accelerate, but 8 networks + a DBN at 5–8 s/song here means 15–25 s on an A15 core, no Neural Engine path, no confidence output. Not chosen. |
| All-In-One `harmonix-all` (+ HTDemucs source separation) | 11.2 MB ensemble + 84.0 MB demucs | 2.41 M (+ demucs) | 12.5 | 72.6 (6 thr) | 3.1 GB; 1.13 GB GPU | **No.** 73 s of six desktop cores per song is minutes on a phone, Demucs is 84 MB, and it needs 1.1 GB of GPU here. Used only as the quality reference for sections (c8e). |
| librosa `beat_track` (DSP, no model) | 0 | 0 | — | 4.8 (12 thr) | 4.2 GB (full STFT in memory) | Runs anywhere but gives no downbeats and no confidence; not a candidate. |

Beat This on GPU uses 211–285 MB; the GPU was never above the 2.9 GB the LLM server already held
plus ~1.2 GB for All-In-One.

## Efficiency and battery (c7)

- **No ML while idle, none for the library.** Inference starts only from
  `PlaybackEngine.scheduleAutoMixPlanning()`, which runs when a track starts (or is promoted) and
  the toggle is on; it asks for exactly two ids and cancels anything else in flight
  (`retainOnly`). Cache hits never run the model.
- **Inference per track:** 6 s single-core on this CPU for a 4-min song (0.75 s × 8 chunks),
  3.8 s on 2 threads; projected 9–12 s on an A15 core. The coordinator learns the real figure on
  the device (`ThroughputEstimate`, EMA, seeded at 0.06 s per second of audio = 14 s for 4 min)
  and uses it for the deadline. A 1500-frame chunk is 0.77 MB in, 12 KB out; weights 4.6 MB;
  activations 35 MB fp16.
- **Deadline:** the handoff needs the plan 2 s before the mix-out, and the mix-out sits ~8 bars
  (≈ 15 s at 125 BPM) before the end. With the 14 s seed estimate, a 4-min song queued later than
  about 31 s before the end of the current one gets the default transition; with the projected
  A15 figure (≈ 10 s) that becomes ≈ 27 s. Songs queued earlier than that, or already cached, blend.
- **The second player exists only for the window.** Per transition: overlap + settle. 8 bars at
  125 BPM = 15.4 s, plus a 4-bar glide = 7.7 s → **23 s** of two-player time; a crossfade is 8 s
  plus a 2 s trim glide when the pair was loudness-matched. After the settle the incoming player
  *is* the queue player (T677); nothing extra runs until the next boundary.
- **CPU cost of one blend, operation count** (44.1 kHz stereo): two decoders (what the queue player
  already runs for gapless pre-roll, so one is new), the incoming player's `.spectral` time-pitch (T677: the player's own `rate`, the same unit the engine used) on the incoming song
  (the only new DSP of any weight: an STFT-domain stretch, ~2 FFTs of 1024 per 256-sample hop per
  channel ≈ 9 k FFT/s), two 2-band biquad EQs (10 MAC/sample/channel ≈ 0.9 M MAC/s), the mixer, and
  a 50 Hz main-actor timer setting five parameters. For a 23 s window that is ~200 k FFTs and ~20 M
  MACs — single-digit milliseconds of a performance core per second of blend. Measured offline, the
  Python rendering (librosa phase vocoder, far less efficient than the system time-pitch) takes
  about a second of desktop CPU per transition, as an upper bound.
- **Metadata:** 4,702 bytes per track mean (max 10,030) for the full record with every beat;
  439 bytes for the minimal transition-only subset. Cached on disk, read once per track per session.
- **When not blending:** `autoMixEnabled == false` short-circuits every entry point
  (`scheduleAutoMixPlanning`, `autoMixTick`), so the queue-player path is byte-for-byte the previous
  behaviour. Nothing is allocated for AutoMix until the first plan.

### On-device measurement recipe (Mac)

Signposts are already in the code: `automix.analyze` (interval, subsystem `vellum.perf`) around
every analysis, `automix.handoff` and `automix.chain` (events) at every transition.

1. Instruments → **Time Profiler + os_signpost + Energy Log** template, device attached, Release
   build. Filter signposts to subsystem `vellum.perf`.
2. Play a 10-song downloaded playlist with AutoMix **off**; note Energy Log's average "CPU" and
   "Audio" impact over 10 minutes.
3. Same playlist, AutoMix **on**, first pass (cold cache): every `automix.analyze` interval is
   one inference — read its duration (the seconds per track on this phone) and the CPU spike
   under it in Time Profiler. Second pass (warm cache): there should be **no** `automix.analyze`
   intervals, only `automix.handoff`/`chain` events, each followed by ~23 s where the audio
   thread's CPU rises by the second player's cost.
4. Compare Energy Log averages between 2 and 3 (warm). The bar is "not worse than Apple Music's
   AutoMix", which cannot be profiled, so use the by-hand A/B below for that.

### By-hand battery A/B (what the user can run)

Same phone, same 60-minute downloaded playlist in both apps (export it to Apple Music as an
album run), Low Power Mode off, Wi-Fi and Bluetooth off, brightness at 50 % with auto-brightness
off, wired headphones at the same volume, screen locked after pressing play.

| Step | Apple Music, AutoMix on | Vellum, AutoMix on (warm cache) | Vellum, AutoMix off |
|---|---|---|---|
| Battery % at start | | | |
| Battery % after 60 min | | | |
| Drop | | | |

Run each column from the same starting charge (e.g. 80 %), charging back between runs; repeat
twice and average. Vellum's cold-cache run is a fourth column if you want the analysis cost
included (it is one inference per song, then never again).

## Pricing the on-device variant (c8) — measured

- **(a) Bytes per track of analysis:** full record 4,702 B mean (10,030 max); minimal subset
  439 B. For 1k tracks: 4.7 MB / 0.44 MB. For 10k: 47 MB / 4.4 MB. The Navidrome library
  (read from a read-only copy of its database) has **95,441** tracks, 2.90 TB, 228 s mean: a
  whole-library index would be 449 MB full / 42 MB minimal — but see (d), nothing indexes the library.
- **(b) Phone model size:** Beat This `small0` converts; 4.64 MB as Core ML (source checkpoint
  8.45 MB). `final0` also converts (40.9 MB) and is not used.
- **(c) Compute per track:** 6 s single-core / 3.8 s on 2 threads here for a 4-min song, with the
  A15 caveat above (its cores are slower than a Zen 5 desktop core single-threaded — Geekbench 6
  single-core ≈ 2,200 vs ≈ 3,300 — so 9–12 s on CPU; the Neural Engine is the unknown that only the
  Mac step can settle).
- **(d) Two strategies:** indexing the whole library on the phone means downloading every song —
  **2.90 TB** for this library (the 43 evaluation clips alone are 2.04 GB, 47 MB each) — and
  ~95k × 10 s of inference ≈ 11 days of phone CPU. Not viable. The lazy strategy analyses only the
  next queued track while the current one plays, using audio the phone already has (downloads and
  the stream cache), and keeps the result forever: 5 KB and ~10 s per new track, zero afterwards.
  That is what ships.
- **(e) Heuristic vs the heavy section model:** scored on the c3 pairs below.

## Evaluation (c3 / c4 / c8e) — Linux harness, real library tracks

43 tracks copied read-only from Navidrome's music root; analysis with Beat This `final0` on GPU
(the shipping model is `small0`; `final0` was used here as the stronger reference), sections from
the shipping heuristic and, separately, from All-In-One. Rendered with `scripts/automix/render.py`
into `/mnt/smalls/vellum-automix-work/samples/`.

Scores: beat-alignment error = median |nearest A beat − B beat| over the overlap, in the output
timeline (ms); tempo stretch = |rate − 1| × 100; loudness jump = |short-term LUFS 3 s after the
overlap − 3 s before| (LU), plus the largest 1 s step across it.

**Recommended route: beat + section-aligned + bass swap + loudness match, with the per-bar rate
lock — this is `.beatMatched` as shipped.** The numbers that chose it, over the ten compatible
pairs: median beat-alignment error 5 ms (constant-stretch beat-matching 90 ms, plain crossfade
166 ms and a mean of 768 ms because two baselines landed a whole beat out), the full 8 bars of
overlap on every pair, the same stretch budget (0–6.1 %, mean 1.7 %), and a loudness jump of
3.2 LU median with the smallest 1 s step (1.2 LU). The constant-stretch variant is what a single
`AVPlayer.rate` (spectral) gives; the lock is the same unit with its rate set once per bar from
the two beat grids, which is why it costs nothing extra on the phone. On the six incompatible
pairs the smooth crossfade halves the loudness jump of the plain fade (3.4 vs 5.8 LU median) and
its worst step (2.8 vs 4.2 LU); River Man into HUMBLE goes from a 22 LU jump to 4.9 LU.

Three files to listen to:

- baseline, a whole beat out: `/mnt/smalls/vellum-automix-work/samples/calvinharris-we-found-love__dualipa-dont-start-now__1-baseline-crossfade.flac`
- recommended blend, same pair, 5 ms: `/mnt/smalls/vellum-automix-work/samples/calvinharris-we-found-love__dualipa-dont-start-now__3-section-bass-swap.flac`
- smooth crossfade for an incompatible pair: `/mnt/smalls/vellum-automix-work/samples/nickdrake-river-man__kendrick-humble__4-smooth-crossfade-tempoMismatch.flac`

### Per pair (heuristic sections = the shipping rule)

| # | Pair | Style chosen | Baseline: beat err / jump | Beat-matched: beat err / stretch / jump | Section + bass swap: beat err / stretch / jump | Crossfade: jump (max step) |
|---|---|---|---|---|---|---|
| 1 | daftpunk-one-more-time -> calvinharris-feel-so-close | beat-matched ✓ | 163 ms / 1.6 LU | 7 ms / 4.2 % / 3.8 LU | 0 ms / 4.2 % / 4.0 LU (8 bars) | — |
| 2 | calvinharris-we-found-love -> dualipa-dont-start-now | beat-matched ✓ | 2470 ms / 2.5 LU | 83 ms / 4.3 % / 3.5 LU | 5 ms / 4.3 % / 3.2 LU (8 bars) | — |
| 3 | daftpunk-hbfs -> daftpunk-digital-love | beat-matched ✓ | — ms / 2.5 LU | 70 ms / 0.0 % / 1.6 LU | 10 ms / 0.0 % / 4.0 LU (8 bars) | — |
| 4 | tameimpala-let-it-happen -> dualipa-dont-start-now | beat-matched ✓ | 67 ms / 9.0 LU | 50 ms / 0.0 % / 2.7 LU | 5 ms / 0.0 % / 2.7 LU (8 bars) | — |
| 5 | arcticmonkeys-do-i-wanna-know -> gorillaz-clint-eastwood | beat-matched ✓ | 246 ms / 3.2 LU | 217 ms / 2.9 % / 6.9 LU | 5 ms / 2.9 % / 5.1 LU (8 bars) | — |
| 6 | paramore-hard-times -> weeknd-save-your-tears | beat-matched ✓ | 165 ms / 0.5 LU | 120 ms / 0.0 % / 2.1 LU | 5 ms / 0.0 % / 3.6 LU (8 bars) | — |
| 7 | rhcp-give-it-away -> arcticmonkeys-r-u-mine | beat-matched ✓ | 1271 ms / 1.5 LU | 97 ms / 6.1 % / 1.6 LU | 6 ms / 6.1 % / 3.2 LU (8 bars) | — |
| 8 | mj-remember-the-time -> fleetfoxes-meadowlarks | beat-matched ✓ | 166 ms / 2.9 LU | 130 ms / 0.0 % / 3.1 LU | 10 ms / 0.0 % / 1.6 LU (8 bars) | — |
| 9 | 21savage-redrum -> arcticmonkeys-do-i-wanna-know | beat-matched ✓ | 100 ms / 3.9 LU | 110 ms / 0.0 % / 6.3 LU | 10 ms / 0.0 % / 1.8 LU (8 bars) | — |
| 10 | weeknd-blinding-lights -> gorillaz-clint-eastwood | beat-matched ✓ | 2266 ms / 3.4 LU | 60 ms / 0.0 % / 3.3 LU | 40 ms / 0.0 % / 1.2 LU (8 bars) | — |
| 11 | greenday-know-your-enemy -> paramore-rose-colored-boy | crossfade · tempoMismatch ✓ | 133 ms / 4.5 LU | — | — | 1.5 LU (1.3) |
| 12 | nickdrake-river-man -> kendrick-humble | crossfade · tempoMismatch ✓ | 1220 ms / 22.4 LU | — | — | 4.9 LU (2.2) |
| 13 | josegonzalez-el-invento -> travisscott-sicko-mode | crossfade · lowBeatConfidence ✓ | — ms / 3.2 LU | — | — | 5.0 LU (6.4) |
| 14 | daftpunk-one-more-time -> arcticmonkeys-do-i-wanna-know | crossfade · tempoMismatch ✓ | 137 ms / 0.2 LU | — | — | 2.6 LU (2.7) |
| 15 | boniver-22-over-soon -> calvinharris-feel-so-close | crossfade · energyMismatch ✓ | 320 ms / 7.2 LU | — | — | 3.5 LU (2.9) |
| 16 | billieeilish-ocean-eyes -> elliottsmith-everything-means-nothing | crossfade · lowBeatConfidence ✓ | — ms / 8.1 LU | — | — | 3.2 LU (7.6) |

### Aggregate over the beat-matched pairs (median / mean)

| Strategy | Beat error ms | Stretch % | Loudness jump LU | Max 1 s step LU | n |
|---|---|---|---|---|---|
| plain crossfade (no analysis) | 166 / 768 | 0.0 / 0.0 | 2.7 / 3.1 | 2.5 / 3.2 | 9 |
| beat-matched | 90 / 94 | 0.0 / 1.7 | 3.2 / 3.5 | 1.5 / 1.4 | 10 |
| beat + section-aligned + bass swap + loudness match | 5 / 10 | 0.0 / 1.7 | 3.2 / 3.0 | 1.2 / 1.4 | 10 |

### Incompatible pairs: smooth crossfade vs the plain baseline (median / mean)

| Strategy | Loudness jump LU | Max 1 s step LU | n |
|---|---|---|---|
| plain crossfade, last 8 s of A over first 8 s of B | 5.8 / 7.6 | 4.2 / 6.9 | 6 |
| smooth crossfade: cue-timed, loudness-matched, filter sweep | 3.4 / 3.5 | 2.8 / 3.8 | 6 |



**What the heavy section model would add (c8e): nothing measurable on these pairs.** With the beat
grid held the same, All-In-One's sections changed the cues on 4 of the 10 blends and left 6
identical. Where they differed, the heuristic was equal or better on loudness continuity in three
(One More Time → Feel So Close: 4.0 LU vs 9.0 LU, because All-In-One's mix-in at 0.1 s drops the
whole intro under a loud outro; Redrum → Do I Wanna Know: 1.8 vs 3.0 LU) and All-In-One's one win
(Remember the Time → Meadowlarks, 0.7 vs 1.6 LU) came from a mix-in at 99.7 s — skipping the first
minute and a half of the incoming song, which no listener would accept. On Blinding Lights →
Clint Eastwood All-In-One moved the mix-out 18 s earlier and doubled the beat error (80 vs 40 ms).
Median loudness jump is 3.2 LU either way. All-In-One costs 16.6 s of GPU per song and 90 MB of
models; the heuristic is one RMS pass over the beat grid.

### c8(e): heuristic sections vs All-In-One sections, same pairs, section strategy

| # | Pair | Heuristic: mixOut→mixIn, beat err, jump | All-In-One: mixOut→mixIn, beat err, jump | Cue delta (A / B) |
|---|---|---|---|---|
| 1 | daftpunk-one-more-time -> calvinharris-feel-so-close | 302.8→22.6, 0 ms, 4.0 LU | 302.8→0.1, 0 ms, 9.0 LU | +0.0 s / +22.5 s |
| 2 | calvinharris-we-found-love -> dualipa-dont-start-now | 195.1→2.2, 5 ms, 3.2 LU | 195.1→2.2, 5 ms, 3.2 LU | +0.0 s / +0.0 s |
| 3 | daftpunk-hbfs -> daftpunk-digital-love | 207.7→8.2, 10 ms, 4.0 LU | 207.7→8.2, 10 ms, 4.0 LU | +0.0 s / +0.0 s |
| 4 | tameimpala-let-it-happen -> dualipa-dont-start-now | 449.7→2.2, 5 ms, 2.7 LU | 449.7→2.2, 5 ms, 2.7 LU | +0.0 s / +0.0 s |
| 5 | arcticmonkeys-do-i-wanna-know -> gorillaz-clint-eastwood | 246.0→1.8, 5 ms, 5.1 LU | 246.0→1.8, 5 ms, 5.1 LU | +0.0 s / +0.0 s |
| 6 | paramore-hard-times -> weeknd-save-your-tears | 162.2→0.1, 5 ms, 3.6 LU | 162.2→0.1, 5 ms, 3.6 LU | +0.0 s / +0.0 s |
| 7 | rhcp-give-it-away -> arcticmonkeys-r-u-mine | 255.0→1.3, 6 ms, 3.2 LU | 255.0→1.3, 6 ms, 3.2 LU | +0.0 s / +0.0 s |
| 8 | mj-remember-the-time -> fleetfoxes-meadowlarks | 217.4→0.1, 10 ms, 1.6 LU | 217.4→99.7, 10 ms, 0.7 LU | +0.0 s / -99.5 s |
| 9 | 21savage-redrum -> arcticmonkeys-do-i-wanna-know | 242.9→20.1, 10 ms, 1.8 LU | 242.9→6.0, 10 ms, 3.0 LU | +0.0 s / +14.1 s |
| 10 | weeknd-blinding-lights -> gorillaz-clint-eastwood | 181.1→1.8, 40 ms, 1.2 LU | 162.9→1.8, 80 ms, 1.2 LU | +18.3 s / +0.0 s |
| 11 | greenday-know-your-enemy -> paramore-rose-colored-boy | crossfade:tempoMismatch | crossfade:tempoMismatch | — |
| 12 | nickdrake-river-man -> kendrick-humble | crossfade:tempoMismatch | crossfade:tempoMismatch | — |
| 13 | josegonzalez-el-invento -> travisscott-sicko-mode | crossfade:lowBeatConfidence | crossfade:lowBeatConfidence | — |
| 14 | daftpunk-one-more-time -> arcticmonkeys-do-i-wanna-know | crossfade:tempoMismatch | crossfade:tempoMismatch | — |
| 15 | boniver-22-over-soon -> calvinharris-feel-so-close | crossfade:energyMismatch | crossfade:energyMismatch | — |
| 16 | billieeilish-ocean-eyes -> elliottsmith-everything-means-nothing | crossfade:lowBeatConfidence | crossfade:lowBeatConfidence | — |

Median |cue delta|: mix-out 0.0 s, mix-in 0.0 s over 10 blended pairs. Median loudness jump: heuristic 3.2 LU vs All-In-One 3.2 LU.


## Mac steps (the Mac was unreachable on 2026-10-09)

1. Build + test (scratch derived data and module cache, never the shared ones):

   ```
   mkdir -p ~/agent-scratch/automix && cd ~/Lyra-Music
   xcodebuild test \
     -workspace VellumMusic.xcworkspace \
     -scheme VellumMusicKitTests \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
     -derivedDataPath ~/agent-scratch/automix/DerivedData \
     MODULE_CACHE_DIR=~/agent-scratch/automix/ModuleCache \
     CODE_SIGNING_ALLOWED=NO
   ```

   Then the app:

   ```
   xcodebuild -workspace VellumMusicHost/VellumMusicHost.xcodeproj/project.xcworkspace \
     -scheme VellumMusicHost -destination 'generic/platform=iOS' build \
     -derivedDataPath ~/agent-scratch/automix/DerivedData \
     MODULE_CACHE_DIR=~/agent-scratch/automix/ModuleCache
   ```

2. Confirm SwiftPM compiled `Resources/BeatThisSmall.mlpackage` into the kit bundle
   (`BeatThisSmall.mlmodelc`) and record its size. If SwiftPM on this Xcode does not process
   `.mlpackage`, compile it once with `xcrun coremlcompiler compile BeatThisSmall.mlpackage .`
   and check in the `.mlmodelc` instead.
3. Parity check of the Swift front end against the training preprocessing: run
   `scripts/automix/convert_coreml.py` on the Mac (it can `predict` there) with a real log-mel
   from `beat_this.preprocessing.LogMelSpect`, and compare the Core ML beat logits against the
   PyTorch ones (`max_abs_diff_beat` in its report), then compare `MelSpectrogram.logMelFrames` in
   Swift against the same torchaudio frames on one clip. The target is beat times within one
   frame (20 ms).
4. Run the Instruments recipe above once; replace the projected A15 seconds in this document and
   the `ThroughputEstimate.seed` with the measured number.
