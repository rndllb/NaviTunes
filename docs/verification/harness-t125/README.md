# T125 alignment harness

Reproduces `../t125-alignment.log`: how the artist page's discography suppression behaves now that
external releases come from MusicBrainz rather than an acquisition plugin.

Symlink the shipping sources in before running, so it exercises the real code:

    cd harness-t125
    for f in MusicBrainzModels MusicBrainzClient MusicBrainzCacheStore MusicBrainzService \
             MusicBrainzQuery VellumNetworking; do
      t=$(cd ../../.. && git ls-files "Sources/VellumMusicKit/**/$f.swift")
      ln -sfn "../../../../../$t" "Sources/mb3/$f.swift"
    done
    swift run mb3

`Sources/mb3/MatcherExcerpt.swift` is lifted verbatim from `AlbumSummary+NewTabMatch.swift`
(lines 31-90) so the counts come from the shipping title-key functions, not a reimplementation.
`Sources/mb3/LTM.swift` is the `LibraryTrackMatcher.normalize` excerpt those functions call.

Server side is the public Navidrome demo instance (0.63.2), read-only. It stands in for a real
library because it is a real Navidrome speaking the real Subsonic API — including the MusicBrainz
id fields, which is the point of the exercise.
