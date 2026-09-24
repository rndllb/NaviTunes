# T122 / T123 verification harness

Reproduces the checks in `../t122-t123-verification.log`.

The MusicBrainz sources are intentionally **not** copied here. Symlink them in before running, so
the harness always exercises the shipping code rather than a snapshot that can drift:

    cd harness-t122-t123
    for f in MusicBrainzModels MusicBrainzClient MusicBrainzCacheStore MusicBrainzService \
             MusicBrainzQuery VellumNetworking; do
      t=$(cd ../../.. && git ls-files "Sources/VellumMusicKit/**/$f.swift")
      ln -sfn "../../../../../$t" "Sources/mb2/$f.swift"
    done
    swift run mb2

`Sources/mb2/LTM.swift` is an excerpt of `LibraryTrackMatcher.normalize` (the only part the layer
uses) so the harness can compile without the whole app module.

Failure injection, per case:

- **Exhausted retries (fast)** — `URLProtocol` stub answering HTTP 503 to every attempt.
- **Exhausted retries (hanging)** — `URLProtocol` stub that stalls, then fails with a timeout.
  The per-attempt stall is scaled down from the real 20s transport timeout so the case finishes
  in reasonable wall-clock; the deadline logic being tested does not depend on that number.
- **Failed fetch leaves the cache intact** — real MusicBrainz endpoint, browsing an MBID the
  service rejects.
- **Refresh refusal** — the real limiter; the refused call needs no network at all.
