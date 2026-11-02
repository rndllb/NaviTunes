# T136 handover — the two "Go to Artist" sites in `DiscoverySearchView.swift`

## STATUS: CLOSED — 2026-09-03. Nothing here is outstanding.

Both sites are done. They were done differently, and the difference matters if you are reading this
to decide whether to paste anything:

| Site | State | How |
|---|---|---|
| 1 — `serverSongContextMenu`, the server song row's "Go to Artist" | **applied** | the snippet below, verbatim |
| 2 — `acquireRowSubtitle`, the request row's artist tap | **superseded by T148** | a different, stronger fix — see below |

**Do not paste Site 2's snippet.** It is kept for provenance and it is now the wrong change. It
would pass `result.artists.first` as the destination's `name:`, and since commit `9579592` that
string is a MusicBrainz **credit line** ("Rich Brian feat. Charlotte Day Wilson & DAISY WORLD"), not
an artist's name — so it would open an artist page correctly resolved by MBID and then *title* it
with the whole credit. That was the T148 defect. What shipped instead is
`SearchNavTarget.primaryArtist(of:)`, which does everything the snippet did and also separates the
label from the destination: the row renders `AcquisitionResult.displayArtistLine` (everyone on the
record) while the tap targets the **primary** credit's own MBID and carries that artist's real name.
Both request-row sites — the row and `AcquireResultDetailView` — now route through that one factory.

The original note follows, unchanged below this line except for the per-site status headers.

---

Both sites have an id available, so neither needs to stay a name-based navigation.

`SearchNavTarget` already has an `.artist(LibraryArtistSummary)` case and a
`.musicBrainzArtistId(id:name:)` case, so **no new enum case is required** and no coordination with
other files is needed.

---

## Site 1 — `DiscoverySearchView.swift:1294`, in `serverSongContextMenu(_ track: Track)`

**APPLIED 2026-09-03, verbatim.** Now at `DiscoverySearchView.swift:1326-1338` (the file has grown
since this note was written).

`track` is in scope, so `track.artistId` is available (populated for both backends as of T136).

**Before**

```swift
onGoToArtist: ArtistNavigation.isTappable(artist)
    ? { navigationPath.append(SearchNavTarget.namedArtist(track.artist)) }
    : nil,
```

**After**

```swift
onGoToArtist: ArtistNavigation.isTappable(artist)
    ? {
        // Navigate by the server's artist id when the track carries one. A name is not an
        // identity — there are eighteen artists named exactly "Rocket" — so the name path is
        // the fallback for rows that genuinely have no id, not the default.
        if let artistId = track.artistId, !artistId.isEmpty {
            navigationPath.append(SearchNavTarget.artist(
                LibraryArtistSummary(id: artistId, name: track.artist, artworkURL: nil)
            ))
        } else {
            navigationPath.append(SearchNavTarget.namedArtist(track.artist))
        }
    }
    : nil,
```

---

## Site 2 — `DiscoverySearchView.swift:1525`, in `acquireRowSubtitle(_ result: AcquisitionResult)`

**SUPERSEDED by T148 — do not paste this one.** See the status block at the top for why: the `name:`
it passes is a credit line, not a name. The shipped fix is `SearchNavTarget.primaryArtist(of:)`
(`DiscoverySearchView.swift:33-62`), used by both this row and `AcquireResultDetailView`.

`track` is **not** in scope here; the row is an acquisition candidate. The available id is the
MusicBrainz artist id the request already carries: `result.request.artistMBID`.

**Before**

```swift
ArtistNameButton(
    name: artist,
    font: songSubtitleFont,
    foreground: MusicDesign.secondaryLabel,
) {
    navigationPath.append(SearchNavTarget.namedArtist(artist))
}
```

**After**

```swift
ArtistNameButton(
    name: artist,
    font: songSubtitleFont,
    foreground: MusicDesign.secondaryLabel,
) {
    // The request row already holds the MusicBrainz artist id; navigating by it avoids
    // resolving the name again and landing on a different act of the same name.
    if let mbid = result.request.artistMBID?.trimmingCharacters(in: .whitespacesAndNewlines),
       !mbid.isEmpty {
        navigationPath.append(SearchNavTarget.musicBrainzArtistId(id: mbid, name: artist))
    } else {
        navigationPath.append(SearchNavTarget.namedArtist(artist))
    }
}
```

---

## Already correct, no change needed

`DiscoverySearchView.swift:1966` (recent-search artist rows) already prefers
`SearchNavTarget.musicBrainzArtistId` when the row recovered an MBID, falling back to
`.namedArtist` otherwise. That is the intended shape and was not touched.

## After applying

`grep -n "SearchNavTarget.namedArtist" Sources/VellumMusicKit/DiscoverySearchView.swift` should show
only fallback branches — every remaining occurrence should sit in the `else` of an id check.

**Run 2026-09-03, after Site 1 landed and T148 replaced Site 2 — criterion met, four occurrences,
all fallbacks:**

| Line | Where | Fallback for |
|---|---|---|
| `:62` | `SearchNavTarget.primaryArtist(of:)` | no `request.artistMBID` on the row |
| `:266` | `NamedArtistMatch.navTarget` | no MusicBrainz hit in hand |
| `:1336` | `serverSongContextMenu` — Site 1 | no `track.artistId` on the track |
| `:2023` | recent-search artist rows | no recovered MBID, and the row is off-server |
