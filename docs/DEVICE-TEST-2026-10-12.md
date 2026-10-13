# Device test checklist — 2026-10-12 (T643, combined build T659)

One install covers everything: the T643 fixes, the AutoMix work (T630, T633) and the three
Kill Mode / Top Songs fixes from `~/Lyra-Music` (T456, T461, T507, section 6), plus the stream-loader
removal (T662), the Recently Added infinite scroll (T664), the prefetched-file fix (T665), the
blend-path fix (T673) and the two-player blend (T677). The combined tree was compiled unsigned and tested on the Mac (T659,
rebuilt for each). Install it from Xcode on the Mac: open
`~/agent-scratch/T659/vellum/VellumMusicHost/VellumMusicHost.xcodeproj`, scheme **VellumMusicHost**,
pick the iPhone as the run destination, Run. Signing comes from that folder's
`VellumMusicHost/Config/Local.xcconfig` (identical to the one in `~/Lyra-Music`; do not edit it, the
bundle id stays `com.randll.vellum`). Nothing here writes to Navidrome except the one playlist edit
in step 4.

## 1. Library shows everything

- Open **Library → Recently Added**. Expect the same 60 items as before and **no button** under the
  grid (T664). Scroll down: the rest appear by themselves as you near the bottom, including the
  playlist **"party"** (it was #61). Nothing should repeat and nothing should be missing; the grid
  should not jump when a page lands.
- Now Playing → tap the artist name on any song whose album title sorts after "After Fillmore County"
  (for example anything by Lil Uzi Vert, Sunny Day Real Estate, Кино). Expect the artist's albums, not
  "No albums by this artist appear in your library cache yet".
- Library → Albums: all 29 of your added albums, including the eight Abandoned Pools ones.
- Watch for: a noticeably slower first Library paint after sign-in or pull-to-refresh (the catalog
  is now 13,300 albums). If it stalls, note how long; the PerfLog lines
  `refreshLibraryAlbums.fetched count=…` and `rebuildLibraryAlbumIndex.albumsOnly` carry the timings.

## 2. Streaming with AutoMix on — the one that failed on 10-10

- Settings → Sound & Playback → **AutoMix on**. Streaming format left at **Original**.
- Play the three songs that failed on 2026-10-12 (T662), from the server, not downloaded:
  **Abandoned Pools — "Goodbye Song"**, **"The Catalyst (acoustic)"**, **"Armed to the Teeth
  (acoustic)"**. Then *Eternal Atake* (Lil Uzi Vert) for a longer run.
- **Expect:** every song starts within a couple of seconds and plays through. No "Skipped … it
  wouldn't load" toast. The caching loader is no longer used for streams (T662), so the AutoMix
  diagnostic row must show **no** `candidate failed … loader=true` line at all; if any
  `candidate failed` line appears, copy it (the row is selectable). The same line is in Console.app
  under subsystem **vellum.perf**, category **playback**.
- The first boundary out of a freshly started streamed song does not blend (its file was never
  assembled on the phone); every boundary after that should, because the next song is fetched
  whole in the background. Expect `stream cache commit for a queued track; re-planning` in the
  console once per upcoming song.
- **The prefetched file now plays (T665).** On the 13:42 build every song that had been fetched
  ahead failed with `candidate failed [load] loader=false url=file:///…/stream-cache/… error=
  AVFoundationErrorDomain -11828 ← NSOSStatusErrorDomain -12847 (Cannot Open)` and the plain
  stream played instead, after a delay. Now the second and later songs of a queue should start
  instantly from the fetched file, with **no** `candidate failed` line of any kind, and the
  boundary into each of them should blend.
- **No pause at either end of a blend (T677), and the song after it sounds like the normal
  stream (T673).** Settings → Sound & Playback → Equalizer: pick a preset you can hear at once
  (Bass Boost, or draw +10 dB on the three lowest bands and +8 dB on the two highest). AutoMix on,
  format Original. Queue **Abandoned Pools — "Maybe Then Someday" → "Goodbye Song" → "The
  Catalyst (acoustic)"** and let it run across both boundaries. Listen at two places per
  boundary: **about six seconds before the blend starts** (this used to be the first "slight
  pause", when the song moved onto the mixing engine — now nothing happens there at all, the song
  just keeps playing) and **a few seconds after the old song has faded out** (the second one,
  when the new song moved back — now the player that started the new song simply keeps going).
  Expect no gap, stutter or dip at either place, the EQ colour unchanged throughout, and the new
  song at its own level a few seconds after the fade. The console shows `armed … incoming starts
  in N s` in the lead-in, `is the queue player now` when the old song is silent, and
  `blend settled` after the glide. Then scrub once during a song that was blended into: nothing
  should change in the sound.
- **The song after a blend keeps playing (T677 c5, "sometimes the automixer kills the song
  stream after its transition is over").** This happened when the crossfade ran to the outgoing
  song's very last sample (a song with a short outro), so pick songs that end abruptly or fade
  out late, and let at least five blends run without touching the phone. After each `blend
  settled` the new song must keep playing for its whole length. If a song still stops, the
  console line to look for is `ignored an end notification for an item that is no longer
  playing` (the guard firing, expected) versus an `unprepare` without a following `prepare` in
  the `TAP` log right after `blend settled` (the one case not reproduced on the simulator).
- Then switch the streaming format to **MP3 320** and play two more songs. Expect them to play as
  plain streams and the boundary between them to blend once the second song has been fetched.

- **The cover's shadow (T681).** Watch the big cover through a blend: its drop shadow must stay
  the same size and darkness from the lead-in, through the crossfade of the covers, to the new
  song. (Three covers are stacked during the crossfade; each used to cast its own shadow.) The
  title and artist crossfade in half a second and the cover does not pulse or resize at the
  switch.

## 3. AutoMix transport

- Play two **downloaded** songs back to back with AutoMix on. Expect a blend at the boundary, no
  click at the hand-off, title/artist/cover crossfading at the start of the overlap.
- **Pause during the blend** (both in-app and from the lock screen), wait ~10 s, resume. Expect the
  blend to continue from where it was; the overlap must not jump ahead or end early. (Bug A1.)
- **Pause in the six seconds before the blend starts**, wait, resume. Expect the blend to still
  start on the beat, not immediately on resume. (Bug A1.)
- During a song with AutoMix armed, use **Play Next** to insert a different song. Expect the blend
  to go into the inserted song, the cursor to follow, and no stuck state. (Bug A2.)
- **Scrub** during the arm lead and during the blend; expect playback to continue on the queue
  player and the next boundary to blend again if there is time (T633 c2).
- Skip immediately (< 1 s) after a blend has started. Expect the next song to play normally. (Bug A3.)
- A half/double-time pair, e.g. an 85 BPM song into a 170 BPM one: expect a beat-matched blend that
  stays locked over the eight bars (no audible drift by bar eight). (Bug A4.)

## 4. Playlist description

- Library → a playlist you own (e.g. **indiepunk**) → ⋯ → **Edit**. Expect the Description field to
  show the current description (empty for most; **Top 100 Everyone Knows** has one).
- Type a long description (a few hundred characters), Save, reopen Edit: it is there. No limit.
- Clear it, Save, reopen: empty.

## 5. Nothing else moved

- AutoMix **off**: stream a few songs. Expect exactly the old behaviour, no loader lines in the
  diagnostic (the row is hidden when the toggle is off), no change in start time.

## 6. Kill Mode badge, Kill Mode pill, Top Songs (T456, T507, T461)

- **Badge (T456).** A Kill Mode playlist's badge shows the real number up to 99 and **99+** above
  that. Check one at 99 or below, and one at 100, 999 and 1,085 if you have them: the badge stays a
  single small capsule and never wraps onto two lines. The count itself is unchanged; only the label
  is capped.
- **Pill (T507).** Open the Kill Mode list. **Remove All** and the **⋯** button are red at the top,
  and stay red after scrolling the list up under the bar (they used to turn white).
- **Top Songs (T461).** Artist page for **Turnover**: the songs you have played come first, by play
  count, followed by the other albums' leadoff tracks, with no title listed twice. Then an artist
  you have never played: the old per-album list, unchanged. Your call: each source keeps its own
  10-row cap, so a heavily played artist can show up to 20 rows. Say if you want one cap on the
  merged list instead.
