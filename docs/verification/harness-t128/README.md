# T128 harness — "Request Missing" decision packet

Reproduces `../t128-measurements.log`: how big the bulk request is, what including singles & EPs
costs, how much re-request risk survives the bare-suffix widening, and how many Lidarr calls the
run actually issues.

Symlink the shipping sources in before running, so it exercises the real code. The package is
grouped by feature folder (`MusicBrainz/`, `Acquisition/`, `Backends/`, `AlbumDetail/`), so resolve
each file by name rather than hardcoding its folder — that keeps the links alive across the next
restructure:

    cd harness-t128
    for f in MusicBrainzModels MusicBrainzClient MusicBrainzCacheStore MusicBrainzService \
             MusicBrainzQuery MusicBrainzDiscographyMapping MusicBrainzSearchFeed \
             AcquisitionCore LidarrAcquisitionPlugin AcquisitionTrackListCache \
             BrowseAlbumPreviewTrack VellumNetworking; do
      t=$(cd ../../.. && git ls-files "Sources/VellumMusicKit/**/$f.swift")
      ln -sfn "../../../../../$t" "Sources/t128/$f.swift"
    done
    python3 stub_lidarr_count.py 8787 &      # for the call-cost section
    swift run t128

`Sources/t128/Shims.swift` holds the two types the symlinked sources reference from UI-bearing
files — `ArtistDiscographyBucket` and the `AlbumSummary` title-key functions — lifted verbatim, so
the counts come from the shipping matcher (including the applied bare-suffix widening) rather than
a reimplementation. `Sources/t128/LTM.swift` is the `LibraryTrackMatcher.normalize` excerpt those
call.

`buildPlan` in `Measure.swift` replays `ArtistViewModel.applyDiscography` — release-group id
first, title keys second, then the live/compilation drop — outside the view, so the set can be
counted. It is the same test in the same order, not a second opinion about ownership.

Server side is the public Navidrome demo (read-only). It is a real Navidrome speaking real
Subsonic, but it holds only 1–4 albums per artist, so the duplicate count it can produce is thin
evidence. That is why the residual-risk section exists: it asks the question the other way round,
against ~2,900 real catalogue titles.

`stub_lidarr_count.py` is a counting Lidarr, deliberately separate from
`scripts/stub-lidarr/stub_lidarr.py` (a fixture for the Discover UI tests, shaped around their
catalog). `/__counters` reads the tally, `/__reset` clears it, `/__wipe` clears the tally *and*
the stub's library so the "album new to Lidarr" case really starts new.
