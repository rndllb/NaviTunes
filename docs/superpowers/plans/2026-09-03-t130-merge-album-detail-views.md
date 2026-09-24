# T130 — Merge the search-result album page into the library album page

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** One album screen. `AcquireResultDetailView` disappears; the release it was showing opens
in `ServerPlaylistDetailView` through a fourth `LibraryDetailSource` case that carries a
MusicBrainz release-group id instead of a server album id.

**Architecture:** `LibraryDetailSource` gains `.catalogRelease(CatalogRelease)` — a release that
exists in a catalog but not (necessarily) on the user's server. The same view renders it: same
hero, same backdrop, same cover-zoom, same tracklist chrome, with the missing-track rows it already
knows how to draw now being the *whole* list. The work that makes this safe is not adding the case;
it is converting the enum's silent pattern-match accessors into ones the compiler forces you to
re-triage.

**Tech Stack:** Swift 6.2 toolchain / language mode 5, SwiftUI, iOS 26.1 deployment target, SPM
package `Sources/VellumMusicKit` built through the `VellumMusicHost` Xcode workspace.

**Spec:** `~/manager-briefs/T130.md` (the approving brief). This plan is the analysis it asked for.

---

## Global Constraints

- **Branch `dev`. No commits. No install to device.** The brief says so explicitly.
- **The gate is `xcodebuild -workspace VellumMusicHost/VellumMusicHost.xcodeproj/project.xcworkspace
  -scheme VellumMusicHost -destination 'generic/platform=iOS Simulator' build` → BUILD SUCCEEDED.**
- **There is no unit-test target.** `Package.swift` declares exactly two targets, `VellumMusicKit`
  and the `VellumMusic` executable; the only test bundle in the repo is `VellumMusicUITests`
  (XCUITest). A per-task red/green unit cycle is therefore not available, and this plan does not
  pretend otherwise. Pure-logic tasks are verified with the repo's own established substitute — a
  throwaway SPM executable under `docs/verification/harness-t130/` that symlinks the shipping
  sources in, exactly as `harness-t128` and `harness-t125` do. View-layer tasks are verified by the
  compile gate plus the named simulator check in each task.
- **Every site in this plan is addressed by SYMBOL. Line numbers are not addresses.** Where a line
  number appears it is a historical note from commit `9579592`, already wrong, and getting wronger
  while you read: terminal 12 has moved this file twice already and will move it again. Do not
  navigate by them, do not cite them back, and do not trust a match because the line looks close.
  **Run the re-resolve recipe below at write time and work from its output.** A task that edits a
  site it found by line number is a task to throw away.
- Line-length, comment density and naming follow the surrounding file. `ServerPlaylistViews.swift`
  comments explain *why*, at length, wherever a non-obvious ordering or lifecycle constraint is
  being protected. Match that.

---

## RE-RESOLVE RECIPE — run this first, every session

Regenerates a current address for every site this plan names. Run it before Task 2 and again after
any pull or after terminal 12 lands anything further.

```bash
cd ~/Lyra-Music
S=Sources/VellumMusicKit/ServerPlaylistViews.swift

# 1. The ten exhaustive switches. Each prints its enclosing member and its current line.
awk '/^ *(private )?(var|func|init)/ {member=$0; line=NR}
     /switch (source|self)/ {printf "%6d  %s\n", NR, member}' "$S"

# 2. The silent accessors and their downstream readers, with counts.
for sym in albumOrNil serverAlbum isAlbum isAlbumStyleDetail isHomeMix \
           librarySource playlistOrNil homeMixIdOrNil catalogRelease; do
  printf '%-22s %3d\n' "$sym" "$(grep -c "\b$sym\b" "$S")"
done
grep -n '\bplaylist\.\(id\|name\)\b' "$S" | wc -l   # the synthesized-fallback readers

# 3. Every site this plan sends you to, by symbol.
grep -n 'enum LibraryDetailSource\|struct ServerPlaylistDetailView\|var artworkURL\|var displayName\|var sourceId\|resolvedDetailArtworkURL\|coverZoomId\|detailOnAppear\|detailOnDisappear\|heroSubtitle\|heroSubtitleLine\|hydrateFromCacheIfNeeded\|func load()\|isPersonalLibraryAlbum\|shouldShowMergedAlbumTracklist\|shouldLoadAlbumPreviewTracks\|computeAlbumMergedRows\|loadPreviewTracksIfAlbum\|var trackRows\|actionButtonTriplet\|primaryActionButton\|missingAlbumRow\|requestMissingTrack\|acquisitionJob(forPreview\|playlistOverflowMenuContent\|detailToolbarContent\|killModeToolbarButton\|serverArtistIdForHeroArtist' "$S"
```

If a symbol in section 3 returns **no** hit, terminal 12 renamed or removed it. Stop and re-read
that region before editing — do not guess at a replacement.

The counts in section 2 are the plan's own claim of blast radius. At `9579592` they were:
`albumOrNil` 25 (23 call sites + 2 declarations), `isAlbum` 25, `isAlbumStyleDetail` 23,
`librarySource` 14, `playlist.id`/`playlist.name` 38. **If your run disagrees materially, the plan's
sizing is stale and Task 2's triage list needs regenerating before you start it**, not after.

---

## STANDALONE TASK A — `trackRows` renders "No songs" over a tracklist it already holds

**This is not part of the merge. It is registered separately so it is reviewable on its own, and it
must not be folded into any of Tasks 1-7.** It is listed first because it is the only item here
that stands whatever you decide about T130.

### The symbol

`ServerPlaylistDetailView.trackRows` — `Sources/VellumMusicKit/ServerPlaylistViews.swift`. One
computed property. Find it with `grep -n 'private var trackRows: some View'`; do not navigate by
line, per the recipe below.

### The defect

`trackRows` is an `if / else if` chain. Two of its branches are in the wrong order:

```swift
        if isLoading, rows.isEmpty {                    // spinner
        } else if let loadError, rows.isEmpty {         // error text
        } else if visible.isEmpty {                     // ← "No songs", tested FIRST
            ContentUnavailableView("No songs", systemImage: "music.note.list",
                                   description: Text(emptyDescription))
        } else if shouldShowMergedAlbumTracklist {      // ← the merged list, UNREACHABLE when empty
```

`visible` is `displayedRows`, the server-backed rows. `shouldShowMergedAlbumTracklist` is true when
the album has a plugin tracklist (`!previewTracks.isEmpty`). Those are independent — an album can
have zero of the former and a full list of the latter — but because `visible.isEmpty` is tested
first, the merged branch can never be reached in exactly the case it exists to serve.

The result: the view holds a complete requestable tracklist in `mergedRows` and draws
`"No tracks returned for this album."` instead of it.

### Reproducing it, without any part of the merge

Verified against the current working tree, not against `9579592`:

1. Open an album whose call site passes `librarySource: false` — Home, Search → Library scope, or a
   New-tab shelf. That makes `isPersonalLibraryAlbum` false, so `shouldLoadAlbumPreviewTracks` and
   `shouldShowMergedAlbumTracklist` both return `true` with no Show Complete Album gate.
2. The album needs server metadata but no server tracks, so `displayedRows` lands empty.
3. A request plugin must be configured, so `loadPreviewTracksIfAlbum` populates `previewTracks`.

Observed: `ContentUnavailableView` with `emptyDescription`'s album string, "No tracks returned for
this album." Expected: the merged list, every row a requestable `missingAlbumRow`.

Album mode has no in-page search — `playlistTrackSearchable(enabled: !isAlbumStyleDetail)` — so
`searchText` is always empty here and `visible.isEmpty` genuinely means "no server rows", never
"filtered to nothing". There is no third explanation for the empty state to protect.

### The fix

Swap the two `else if` clauses so the merged branch is tested before the empty branch:

```swift
        } else if shouldShowMergedAlbumTracklist {
            …
        } else if visible.isEmpty {
            ContentUnavailableView(…)
```

That is the whole change. It is minimal by construction: when `visible` is non-empty the
`visible.isEmpty` branch was already false and the merged branch already won, so the swap alters
exactly one case — the broken one — and no other.

Two things to confirm rather than assume, because they are what makes the swapped branch safe:

- `computeAlbumMergedRows()` with empty `libraryRows` and non-empty `previewTracks` sends every
  preview down its `else if includeMissing` path, producing an all-`.missing` list. Read it and
  check.
- `mergedRows` is still recomputed when the previews land on an album with no rows.
  `loadPreviewTracksIfAlbum` assigns `previewTracks` then calls `recomputeDisplayedRows()`, whose
  `guard next.map(\.rowId) != displayedRows.map(\.rowId)` short-circuit compares two empty arrays
  and takes the early return — **but that early return calls `recomputeAlbumMergedRows()` before
  returning**, so the merged rows do refresh. If that call is ever removed the fix goes quiet, so
  note it where it is.

### Why it is independent of the merge

It needs no fourth case, no `CatalogRelease`, no enum change, no switch triage, and no call-site
change. It is reachable today from `.album` sources only, and every input it touches — `visible`,
`shouldShowMergedAlbumTracklist`, `mergedRows` — exists and is populated on `dev` right now. If
T130 is cancelled outright this fix still stands; if T130 ships, this fix is a precondition rather
than a consequence, because the catalog case has `displayedRows` empty *by definition* and would
otherwise render "No songs" and nothing else on every single search result.

**It is independent of the merge. It is not independent of the file.** `trackRows` lives in
`ServerPlaylistViews.swift`, which terminal 12 holds, so this task blocks on the same clearance as
Tasks 2-7. Being separately reviewable does not make it separately schedulable.

### Steps

- [ ] **Step 1: Re-resolve.** `grep -n 'private var trackRows: some View\|else if visible.isEmpty\|else if shouldShowMergedAlbumTracklist' Sources/VellumMusicKit/ServerPlaylistViews.swift`.
      If the two `else if` lines no longer appear in that order, terminal 12 has already touched
      this chain — stop and re-read the property before editing.
- [ ] **Step 2: Swap the two clauses.** Move the whole `else if shouldShowMergedAlbumTracklist`
      block, with its trailing `showCompleteAlbumToggle` / `trackListFooterBlock` /
      `AlbumDetailRelatedSectionsView` children, above the `else if visible.isEmpty` block. Do not
      alter either body.
- [ ] **Step 3: Comment the ordering.** The next person to read this chain will see an empty-state
      check that is not first and assume it is a mistake. Say why it is not:
      ```swift
      // Merged first, empty second, and the order is the fix. `visible` is the server-backed rows
      // and `shouldShowMergedAlbumTracklist` is the plugin tracklist; an album can have none of the
      // first and all of the second. Tested the other way round, "No songs" won every time and the
      // requestable list this view was already holding in `mergedRows` was never drawn.
      ```
- [ ] **Step 4: Build.**
      `xcodebuild -workspace VellumMusicHost/VellumMusicHost.xcodeproj/project.xcworkspace -scheme VellumMusicHost -destination 'generic/platform=iOS Simulator' build`
      → BUILD SUCCEEDED, zero errors.
- [ ] **Step 5: Verify the fixed case and the unbroken ones.** On the simulator: an album matching
      the repro above now shows requestable rows. Then confirm no regression in the three states
      that share this chain — an album with server tracks (unchanged list), an album with neither
      server tracks nor previews (still "No songs"), and a playlist with no tracks (still "No
      songs", still `emptyDescription`'s playlist string).
- [ ] **Step 6: No commit.** Report the behaviour change: library albums with no server tracks but
      a plugin tracklist now show requestable rows where they showed "No songs".

---

## VERDICT: IS THE MERGE WORTH DOING?

**Yes — conditionally, and the condition is real enough that it should be decided before Task 2
starts rather than discovered at Task 7.**

**Worth doing if `BrowseAlbumDetailView` is also going to be absorbed. Not worth doing on its own.**

### The finding that produced the condition

The app **already ships** the dispatch the brief describes — a screen chosen by whether you hold a
server album id or a MusicBrainz id. It is in `ArtistPageView`, in the discography row's
`destination`:

```swift
    case .libraryAlbum(let album):
        ServerPlaylistDetailView(album: album, librarySource: true)
    case .remote:
        if let browseSource {
            BrowseAlbumDetailView(source: browseSource)      // albumId: album.trackLookupId → "mbid:<id>"
        }
```

`BrowseAlbumDetailView` is not a chart-preview screen any more. Its iTunes path is deleted (its own
comment says so), it decodes `mbid:` through `BrowseAlbumDetailSource.releaseGroupMBID`, it builds
requests from that id in three places, it fetches a plugin tracklist, renders owned rows and
requestable rows side by side, bridges to the server album when the release turns out to be owned,
and it now takes an `artistCredit` label separate from its matching key. It **is** the album screen
for a release identified by MBID. The search tab simply does not use it — it pushes a 212-line
poster instead.

So the honest framing of T130 is not "no such screen exists". It is "there are three album screens,
the search tab is wired to the worst one, and two of the three are near-duplicates".

### What that means for cost

There is a much cheaper way to get the user-visible outcome the brief asks for:

| | Approved merge (this plan) | Route search → `BrowseAlbumDetailView` |
|---|---|---|
| Enum change | 4th case, 10 switches | none |
| Silent sites to re-triage | ~123 | none |
| Tasks | 7 | ~1 |
| Touches `ServerPlaylistViews.swift` | yes, throughout | **no** |
| Contention with terminal 12 | total — blocks on it | **none; could land today** |
| Screens afterwards | 2 (`ServerPlaylist`, `Browse`) | 2 (`ServerPlaylist`, `Browse`) |

Note the last row. **Both paths end at two screens.** The approved merge deletes
`AcquireResultDetailView` by absorbing it; the cheap path deletes it by re-pointing its one call
site. Neither reduces the count to one, because neither touches the 1151-line duplicate that is
actually causing the drift the brief complains about.

### Why "yes, conditionally" and not "no, do the cheap thing"

The approved merge is the only one of the two that is on the path to one screen. `CatalogRelease`
is deliberately shaped so `BrowseAlbumDetailSource.chartBrowse` maps onto it — which makes phase 2
a call-site migration and a deletion, not another design. Done in that order, the sequence is
coherent: the fourth case arrives, then 1151 lines and 9 call sites collapse into it, and the app
ends with one album screen and four sources.

Done *without* phase 2, the sequence is incoherent, and this is the sharpest way to say it: **you
would be adding a fourth mode to an 1850-line view in order to delete a 212-line view, while the
1151-line duplicate stays exactly where it is.** That is the worst of the three available
orderings. It spends the whole risk budget — ~123 silent sites in the app's most
transition-sensitive view — and buys a screen count of two, which the one-line reroute also buys
for almost nothing.

### The recommendation, plainly

1. **Decide now whether `BrowseAlbumDetailView` is getting merged.** Everything else follows from
   that one answer, and it is a product call, not an engineering one.
2. **If yes:** execute this plan as written, and file the follow-up while the shape is fresh. The
   condition is satisfied and the merge is worth its cost.
3. **If no, or if you are unsure:** do the reroute instead — point `SearchNavTarget.acquire` at
   `BrowseAlbumDetailView` exactly as `ArtistPageView` already does, delete
   `AcquireResultDetailView`, and stop. It fixes the user-visible complaint, it does not touch the
   file terminal 12 is holding, and it forecloses nothing: the fourth case can still be added later,
   and `CatalogRelease` is the mapping either way.
4. **Regardless of which:** run **Standalone Task A**. An album with no server tracks but a full
   plugin tracklist renders "No songs" today while holding the list it refuses to draw. That is a
   standalone defect, it is a handful of lines, it is filed as its own task so a reviewer can see
   it on its own, and it does not depend on this decision. It does still depend on terminal 12
   clearing the file.

### What would have made the verdict a flat "no"

Recorded so the reasoning is auditable rather than a preference:

- **If the catalog case needed a different layout.** It does not. The centered 260pt poster in
  `AcquireResultDetailView` is not a requirement; it is what you build when you have no tracklist
  to put under a hero. Once there is one, the standard album hero is correct.
- **If the album paths were guarded by a server album id in a way a catalog release could not
  satisfy.** They are guarded by `albumOrNil` and by `rows.isEmpty` / `displayedRows.isEmpty`, all
  of which already have a defined "nothing here" branch. They degrade rather than crash. The one
  exception is a genuine bug, filed separately as Standalone Task A.
- **If `LibraryDetailSource` had escaped its file.** It has not — two references, both in
  `ServerPlaylistViews.swift`. Had this enum been public API across the module, the ten switches
  would have been ten files and the answer would have been no.

---

## STATE THE BRANCH TAKEN

**Taken: merge, as approved — with one shape change to the enum, and one scope finding the brief
did not ask about but needs to hear.**

### The merge is right, and the fourth case is the right shape

`AcquireResultDetailView` has **exactly one call site** (`SearchLibraryView.swift:89`, reached via
`SearchNavTarget.acquire`). It is 212 lines. It renders no tracklist, has no backdrop, no
cover-zoom, no overflow menu, no related shelves — it is a poster with a Request button. Everything
the brief says it "keeps missing" is missing because it is a second implementation that never got
the features. Deleting it is cheap and the user-visible gain is large.

`ServerPlaylistDetailView` already owns the machinery a catalog release needs: `previewTracks`,
`computeAlbumMergedRows()`, `missingAlbumRow(_:displayIndex:showsBottomDivider:)`,
`requestMissingTrack(_:)`. It already draws "a track this album has that your server does not, tap
to request". A catalog release is simply the case where *every* row is that row. The merged view is
not being taught a new concept; it is being allowed to reach a state it can already render.

### The shape change: the fourth case must be added by *breaking* the accessors, not by adding a case

This is the answer to the part of the brief that parked the task, and it inverts the usual worry.
The exhaustive-switch blast radius is **small and entirely mechanical** — ten switches, all in one
file, all caught by the compiler. The real blast radius is the enum's six `if case … return default`
helpers and their downstream reads, which number **~123 sites** and which the compiler will not
flag at all. Adding a bare fourth case compiles clean and produces a screen that is silently,
partially wrong in a hundred places.

So Task 2 deliberately **deletes `albumOrNil`** and replaces it with a name that cannot be reached
by accident. That converts 23 silent sites into 23 compile errors, each of which gets a decision.
The same treatment is applied to `librarySource` and the synthesized `playlist` fallback. This is
the difference between a merge you can review and a merge you cannot.

### The finding the brief did not ask for: there are three album views, not two

The brief names two screens. There are three.

| View | Lines | Call sites | Renders |
|---|---|---|---|
| `ServerPlaylistDetailView` (album mode) | ~1850 | ~30 | Server album |
| `BrowseAlbumDetailView` | 1151 | 9 | Off-server / chart album |
| `AcquireResultDetailView` | 212 | 1 | Search request candidate |

`BrowseAlbumDetailView` is a full parallel implementation of the album screen — its own
`heroBlock`, `actionRow`, `tracklistSection`, `browseLibraryTrackRow`,
`browseMissingCatalogTrackRow`, `browseInLibraryTrackOverflowMenu`, `footerBlock`, backdrop seeding
and cover-zoom. It is the *larger* half of the duplication the brief is complaining about, and it
is the one that actually causes "one of them keeps missing features the other has": it is 1151
lines of the same screen, not 212.

**This plan does not merge it, and that is a deliberate scope call, not an oversight.** Folding
1151 lines and 9 call sites into `ServerPlaylistViews.swift` in the same pass — in a working tree
with no branch isolation and two other agents editing — is how a tree gets shredded. The fourth
case is designed so that `BrowseAlbumDetailSource.chartBrowse` maps onto `CatalogRelease` with no
further enum work (see Task 1's `init(chartBrowse:)` note), which makes that a follow-up task of
call-site migration and dead-code deletion rather than another design.

**Nobody has approved that follow-up and nobody has said `BrowseAlbumDetailView` is being merged.**
It is an open question raised by this analysis, nothing more. Wherever this document weighs it, it
is weighing a possibility, not a plan of record. See "VERDICT" for why the answer changes whether
this task is worth doing at all.

The conditions that would have reversed this are recorded in "VERDICT", above.

---

## THE FOURTH CASE: SHAPE

New file, `Sources/VellumMusicKit/CatalogRelease.swift`:

```swift
/// A release that exists in a catalog but not necessarily on the user's server.
///
/// The identity is the MusicBrainz **release group** id, which is what a request is made by
/// (`AcquisitionRequest.releaseGroupMBID` → the plugin's `lidarr:<mbid>` exact lookup) and what a
/// track list is fetched by. A server album id is the *other* way into the same screen; this type
/// is deliberately the half that has no server id at all, so nothing downstream can mistake one
/// for the other.
struct CatalogRelease: Identifiable, Hashable, Sendable {
    /// MusicBrainz release-group id. The identity — not a display value.
    let releaseGroupMBID: String
    let title: String
    /// The **matching** artist name: one name, used to find this release on the server and to
    /// build the request. Never a credit line. Same split as
    /// ``AcquisitionResult/artists`` vs ``AcquisitionResult/artistCreditLine``.
    let artist: String
    /// The full credited line to put in front of a reader ("jayo & Citizen"), when one is known.
    let artistCreditLine: String?
    /// MusicBrainz artist id, when the row that opened this carried one. This is what makes the
    /// hero artist link exact rather than a name lookup — see the T146 section.
    let artistMBID: String?
    let artworkURL: URL?
    let year: Int?
    /// "Single" / "EP" / "Album" — `AcquisitionResult.kindLabel`, rendered verbatim.
    let kindLabel: String?
    let trackCount: Int?
    let explicit: Bool
    /// Plugin-native album id (Lidarr integer), when known, so a track-list fetch can skip the
    /// id lookup. Optional: a search hit usually has only the MBID.
    let nativeAlbumId: String?
    /// The request this screen enqueues. Carried rather than rebuilt so the Request button, the
    /// live job lookup (`AcquisitionManager.job(forKey:)`) and the search row that pushed this
    /// screen all agree on one `requestKey`.
    let request: AcquisitionRequest

    var id: String { releaseGroupMBID }

    /// The artist line to display. Never navigate by this.
    var displayArtistLine: String { … }

    /// Where tapping the artist name goes, or `nil` when the name is not a meaningful
    /// destination. Lifted verbatim from `AcquireResultDetailView.artistNavTarget` — the
    /// single-credit gate and the `ArtistNavigation.isTappable` gate both move here, so the
    /// decision is testable without a view.
    var artistPageInput: ArtistPageInput? { … }

    init?(_ result: AcquisitionResult)          // nil when the result carries no release-group MBID
    init(chartBrowse source: BrowseAlbumDetailSource)   // Task 1 note only — not built in this plan
}
```

And the case:

```swift
enum LibraryDetailSource {
    case playlist(PlaylistSummary)
    case album(AlbumSummary, librarySource: Bool)
    case homeMix(mixId: String)
    case catalogRelease(CatalogRelease)      // ← new
}
```

**Why `init?` and not `init`.** A search result with no release-group MBID cannot be opened as a
catalog release — there is no identity to request by or fetch tracks by, and the text-term path is
the one that fails through the metadata proxy. Task 6 keeps `SearchNavTarget.acquire` routable for
that residue; see its Step 3.

---

## THE EXHAUSTIVE-SWITCH BLAST RADIUS

`LibraryDetailSource` is referenced in **exactly one file**. `grep -rn "LibraryDetailSource"
Sources/` returns two hits: the declaration at `ServerPlaylistViews.swift:563` and the stored
property at `ServerPlaylistViews.swift:624`. Nothing outside `ServerPlaylistViews.swift` names the
type. That is the good news, and it is worth stating plainly because it is the thing that makes
this tractable at all.

### Compiler-caught: ten exhaustive switches, all in `ServerPlaylistViews.swift`

Each becomes non-exhaustive the instant the case is added. Each row states what the new case must
do, so Task 2 is decision-free.

All ten are in `ServerPlaylistViews.swift`. **Find each by the symbol in the Member column** —
recipe section 1 lists them in file order, which is the order below. The `@9579592` column is a
historical footnote, kept only so you can tell whether the file has been reordered as well as
shifted; it is not an address.

| # | Member (the address) | `@9579592` | What `.catalogRelease` returns |
|---|---|---|---|
| 1 | `LibraryDetailSource.artworkURL` | ~599 | `r.artworkURL` |
| 2 | `LibraryDetailSource.displayName` | ~607 | `r.title` |
| 3 | `LibraryDetailSource.sourceId` | ~615 | `"catalog-\(r.releaseGroupMBID)"` |
| 4 | `resolvedDetailArtworkURL` | ~690 | `r.artworkURL` — **not** `app.resolvedArtworkURL(for:)`, which resolves offline art by server item id and has none to key on |
| 5 | `coverZoomId` | ~955 | `"catalog-release:\(r.releaseGroupMBID)"`; the search row must mark the same id or the zoom silently falls back to a cross-fade (Task 6, Step 4) |
| 6 | `detailOnAppear` (visibility publish) | ~1162 | `break` — there is no server album id, so `currentlyVisibleAlbumId` must stay untouched. Publishing anything here would make "Go to Album" think the destination is already on screen |
| 7 | `detailOnDisappear` (visibility clear) | ~1190 | `break`, symmetric with #6 |
| 8 | `heroSubtitle` | ~1543 | kind · year · track count, joined with `·`; artist is handled by `heroSubtitleLine`, not here |
| 9 | `hydrateFromCacheIfNeeded` | ~2324 | `return` — no server rows exist to hydrate |
| 10 | `load()` | ~2361 | fetch preview tracks by MBID (Task 4); no `lib.tracks(forAlbumId:)` call |

If recipe section 1 reports **more** than ten switches over `source`/`self` inside
`ServerPlaylistDetailView`, terminal 12 added one. Triage it the same way before continuing.

### Not compiler-caught: six silent accessors and ~123 downstream reads

This is the part that matters. Every one of these compiles clean with a fourth case and returns a
default that is wrong for it.

| Accessor (the address) | Silently returns for `.catalogRelease` | Downstream reads @9579592 |
|---|---|---|
| `LibraryDetailSource.isAlbum` | `false` | 25 occurrences of `isAlbum` |
| `LibraryDetailSource.isHomeMix` | `false` | correct as-is |
| `LibraryDetailSource.albumOrNil` | `nil` | **23 call sites** — regenerate with `grep -n '\balbumOrNil\b'` |
| `LibraryDetailSource.homeMixIdOrNil` | `nil` | correct as-is |
| `LibraryDetailSource.playlistOrNil` | `nil` | 2 direct `if case .playlist(let playlist) = source` reads |
| `LibraryDetailSource.librarySource` | `false` | 14 occurrences |
| the view's `playlist` synthesized fallback | a fake `PlaylistSummary(id: "__album__")` | **38 reads** of `playlist.id` / `playlist.name` |
| `isAlbumStyleDetail` | `false` — **wrong**, must be `true` | 23 occurrences |

Task 2 turns the `albumOrNil` readers into compile errors, so the compiler enumerates them for you
and no list here can go stale. The enclosing members at `9579592`, for sizing only — expect the set
to have moved and possibly grown:

```
isPersonalLibraryAlbum          primaryActionButton (downloaded-checkmark branch)
computeAlbumMergedRows probe    deleteAlbumFromLibraryAndOffline
loadPreviewTracksIfAlbum        downloadAllTracks
detail nav / album id           toggleAlbumPinned
track list album id             hash of in-library state
trackRows related shelves (×2)  album-scoped row branch
allOrderedTracks branch         missingAlbumRow share item
isAlbumPinned                   requestMissingTrack (artist, album request, track request)
primaryActionButton (+ branch)  offline/download branch, library-source branch, album branch
```

**`isAlbumStyleDetail` is the one silent default that is outright wrong rather than merely
incomplete.** It is defined as `isAlbum || isHomeMix` and gates the *layout*: numbered rows, hero
triplet, no in-page search. A catalog release must render in album style. Left alone it would give
the merged screen a playlist layout with a searchable track field over a list of tracks the user
does not own. Task 2 Step 4 fixes it and it is the single highest-value line in that task.

---

## CAPABILITY LEDGER

### What `AcquireResultDetailView` does that `ServerPlaylistDetailView` cannot yet

| Capability | Source | Where it goes in the merged view |
|---|---|---|
| **Live request job state in the primary action** — 4 states: already-in-library / in-flight with a real progress bar and percentage / failed / Request. | `DiscoverySearchView.swift:2288`, `:2377-2445` | `primaryActionButton` (`ServerPlaylistViews.swift:1946`) gains a `catalogRelease` branch. This is the biggest genuine gain: the merged view's primary button today is only `+` / download / checkmark and renders no job state at all. **Task 3.** |
| **Job lookup by `requestKey`.** `acquisition.job(forKey: result.request.requestKey)` — exact. | `:2287` | New `catalogJob` property. Note the merged view's existing `acquisitionJob(forPreview:)` (`:2225`) matches by *normalized title* — weaker, and it stays as-is for per-track rows because a preview row has no request key of its own. **Task 3.** |
| **Artist link preferring the artist MBID**, with a single-credit gate and `ArtistNavigation.isTappable`. | `:2261-2280` | Moves into `CatalogRelease.artistPageInput` (a value, not a view), consumed by `heroSubtitleLine` (`:1614`). **Tasks 1 and 5.** |
| **"Already in your library" state** via `LibraryTrackMatcher.matchesLibrary(_:titleIndex:)`. | `:2282` | Hero primary action, catalog branch. The `.album` case answers the same question with `app.isAlbumInLibrary(album.id)`; the catalog case has no id, so it keeps the matcher. **Task 3.** |
| Inline `statusMessage` under the button. | `:2255`, `:2334` | **Deliberately not carried over.** Replaced by `app.showTransientToast(...)`, which is the app's standard confirmation mechanism per CLAUDE.md and is what every other request affordance in the app already uses. This is a real behaviour change and must be called out in the task, not slipped in. **Task 3.** |
| 260pt centered poster layout, centered title/artist/metadata. | `:2290-2330` | **Deliberately dropped.** Replaced by the standard album hero. Keeping it would mean keeping two album layouts, which is the thing being deleted. **Task 3.** |

### What `ServerPlaylistDetailView` does that `AcquireResultDetailView` cannot — i.e. the user's gain

Tracklist of any kind; requestable missing-track rows with per-row progress; backdrop palette and
`DetailNavigationChrome`; cover-zoom destination; the overflow menu (Play Next, Add to Playlist,
Favorite, Pin, Share, sort); `AlbumDetailRelatedSectionsView` shelves; the growing render window;
and the dismissal-phase hydration parking that keeps swipe-back responsive.

### Capabilities I cannot place, stated rather than dropped

Per the brief: a capability that cannot be placed is a reason to say so.

1. **Play, Shuffle, Download, Add to Library, Favorite, Add to Playlist, and the related shelves
   all require server tracks, and a catalog release has none.** Today they would render *disabled*:
   `actionButtonTriplet` (`:1887`) disables Play and Shuffle on `displayedRows.isEmpty`, and
   `primaryActionButton` disables `+` on `rows.isEmpty`. A screen showing three greyed-out buttons
   is strictly worse than the poster it replaced, which showed one clean Request capsule.
   **Placement decision: for `.catalogRelease` the triplet is replaced, not disabled** — a single
   full-width Request capsule in the same slot. Task 3 Step 3. If the release turns out to be
   matched in the library, the screen should hand off to the `.album` source rather than trying to
   be both; that hand-off is Task 3 Step 5.
2. **`AlbumDetailRelatedSectionsView` can be placed and should be.** Its `excludingAlbumId` is
   already `String?` (`AlbumDetailRelatedSectionsView.swift:9`), so `nil` is a legal argument and
   "More by this artist" works from artist + title alone. Placed in Task 4 Step 5. Flagged here
   only because it looks like it needs a server album id and does not.
3. **Kill Mode, playlist rename/edit/delete, remove-from-playlist, and the playlist sort menu have
   no meaning for a catalog release.** They are already gated behind `!isAlbumStyleDetail` or
   `source.playlistOrNil`, so once `isAlbumStyleDetail` is correct (Task 2 Step 4) they are
   correctly absent with no further work. Verified, not assumed — Task 7 Step 2 re-checks each.

---

## THE T146 GAP: `AlbumSummary` HAS NO `artistId`

**Verdict: it does not block this task, and the merge slightly shrinks its footprint.**

The gap is real and confirmed — `AlbumSummary` (`MusicLibraryProviding.swift:48-80`) carries no
artist id. The existing workaround is `serverArtistIdForHeroArtist(_:)`
(`ServerPlaylistViews.swift:1595`), which recovers an id from a loaded track that is credited to
the same name, with a normalized-name check so a compilation's first track cannot hijack the link.

For `.catalogRelease` that workaround has nothing to work with: there are no loaded track rows, so
it returns `nil` on every call. That sounds like the gap biting, and it is the reason to check.
It does not bite, because the catalog case carries a **better** identity than the one the
workaround reconstructs: `CatalogRelease.artistMBID`, taken from
`AcquisitionResult.request.artistMBID`, names exactly one artist and routes through
`ArtistPageView(input: .musicBrainzArtistId(id:name:))` — the same route `AcquireResultDetailView`
already uses today at `DiscoverySearchView.swift:2352`. The catalog path never needs a server
artist id at all.

Two consequences worth recording:

- The `.album` case is **unchanged**. T146 still bites there exactly as much as it did before; this
  task neither fixes nor worsens it.
- When a catalog release is recognised as an owned album and hands off to `.album` (Task 3 Step 5),
  the gap returns along with the case, and the existing workaround applies. That is the expected
  behaviour, not a regression introduced here.

Should T146 be fixed independently, `CatalogRelease.artistMBID` remains the preferred route for the
catalog case, because an MBID is a stronger identity than a server artist id. Nothing in this plan
needs revisiting when it lands.

---

## COORDINATION — READ BEFORE THE FIRST EDIT

The analysis above was performed against a clean tree at `9579592`. **The tree is no longer clean.**
As of writing, both other agents have started:

- **Terminal 12** (delete confirmations) holds `ServerPlaylistViews.swift`, plus a new file
  `LibraryRemovalConfirmation.swift` and edits to `LibraryCellContextMenus.swift`,
  `LibraryView.swift`, `LibrarySongsView.swift`, `RootView.swift`, `NowPlayingView.swift`,
  `AppleMusicAlbumTrackRow.swift`, `NativeUIKitActionSheet.swift`.
  At the moment this plan was written its `ServerPlaylistViews.swift` hunks sat at `@@ -733`,
  `-1051` (−10 lines), `-1813` (+9), `-2293`, `-2436`, `-2632` — recorded only to show that the
  file had already shifted twice in opposite directions before anyone started Task 2. **Those
  positions are certainly wrong by now.** Get the current picture with
  `git diff --stat` and `git diff -U1 Sources/VellumMusicKit/ServerPlaylistViews.swift | grep '^@@'`,
  then run the re-resolve recipe. Never reconcile this plan against the file by line arithmetic.
- **Terminal 11** (artist credit-line navigation) holds `DiscoverySearchView.swift`,
  `AcquisitionCore.swift`, `ArtistPageView.swift`, `MusicBrainzDiscographyMapping.swift`,
  `AppModel.swift`.

**Two live collision risks:**

1. **`ServerPlaylistViews.swift` — hard block.** Do not open it for writing until terminal 12 is
   confirmed clear. Tasks 2 through 7 all touch it. Task 1 does not, and can proceed now.
2. **`DiscoverySearchView.swift` — soft, but real.** Task 6 **deletes** `AcquireResultDetailView`,
   and terminal 11 is working on artist credit-line navigation, which is the exact subject of
   `AcquireResultDetailView.artistNavTarget` (`:2261-2280`). Terminal 11's hunks are currently all
   at or above line 1521, well clear of the view at 2251→2264, so there is no textual conflict
   *yet*. But if terminal 11 improves `artistNavTarget`, Task 6 would delete that improvement.
   **Before Task 6, diff `AcquireResultDetailView` against `9579592` and port anything terminal 11
   added into `CatalogRelease.artistPageInput` rather than dropping it.** Task 6 Step 1 does this.

**Re-resolve every file:line in this document by symbol name before editing.** The numbers here are
correct for `9579592` and for nothing since.

---

## FILE STRUCTURE

| File | Change | Responsibility |
|---|---|---|
| `Sources/VellumMusicKit/CatalogRelease.swift` | **Create** | The value type and its mappings. No SwiftUI. Kept out of `ServerPlaylistViews.swift` so it can be symlinked into a harness and reasoned about alone. |
| `Sources/VellumMusicKit/ServerPlaylistViews.swift` | Modify | The enum case, the ten switches, the accessor rename, and the catalog branches in hero / action row / tracklist. |
| `Sources/VellumMusicKit/SearchLibraryView.swift` | Modify (`:89`) | Route `SearchNavTarget.acquire` to the merged view. |
| `Sources/VellumMusicKit/DiscoverySearchView.swift` | Modify | Delete `AcquireResultDetailView` (`:2251-2462`). Mark the search row's cover-zoom source id. |
| `docs/verification/harness-t130/` | **Create** | Pure-logic verification for `CatalogRelease`, per repo convention. |

---

## Task 1: `CatalogRelease` value type

Touches no file any other agent holds. **Can start immediately.**

**Files:**
- Create: `Sources/VellumMusicKit/CatalogRelease.swift`
- Create: `docs/verification/harness-t130/Package.swift`, `README.md`, `Sources/t130/Main.swift`

**Interfaces:**
- Consumes: `AcquisitionResult`, `AcquisitionRequest` (`AcquisitionCore.swift:126`, `:184`),
  `ArtistPageInput` (`ArtistViewModel.swift:8`), `ArtistNavigation.isTappable`.
- Produces: `CatalogRelease` with stored properties `releaseGroupMBID`, `title`, `artist`,
  `artistCreditLine`, `artistMBID`, `artworkURL`, `year`, `kindLabel`, `trackCount`, `explicit`,
  `nativeAlbumId`, `request`; computed `id: String`, `displayArtistLine: String`,
  `artistPageInput: ArtistPageInput?`, `heroMetadataLine: String`; and
  `init?(_ result: AcquisitionResult)`. Tasks 2-7 rely on exactly these names.

- [ ] **Step 1: Write `CatalogRelease.swift`**

Full type per "THE FOURTH CASE: SHAPE" above. Three details that are not obvious:

`init?(_ result: AcquisitionResult)` returns `nil` unless
`result.request.releaseGroupMBID` trims to a non-empty string of at least 36 characters — the same
UUID-length guard `BrowseAlbumDetailSource.releaseGroupMBID` uses
(`BrowseAlbumDetailSource.swift:24`), for the same reason: some ids are other ids that happened to
be prefixed.

`artistPageInput` is `AcquireResultDetailView.artistNavTarget` (`DiscoverySearchView.swift:2261`)
lifted verbatim, with `SearchNavTarget` swapped for `ArtistPageInput`:

```swift
var artistPageInput: ArtistPageInput? {
    // Only navigate on a single credited artist. A multi-artist release has no one page to
    // land on, and picking the first would be a guess presented as a fact.
    let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, artistCreditLine == nil || artistIsSoleCredit,
          ArtistNavigation.isTappable(name)
    else { return nil }
    if let mbid = artistMBID?.trimmingCharacters(in: .whitespacesAndNewlines), !mbid.isEmpty {
        return .musicBrainzArtistId(id: mbid, name: name)
    }
    return .named(name)
}
```

`AcquireResultDetailView` gated on `result.artists.count == 1`. `CatalogRelease` stores one
`artist`, so carry the multi-credit signal explicitly — store `artistIsSoleCredit: Bool`, set from
`result.artists.count == 1` in the init. Do not infer it from `artistCreditLine == nil`: a source
can report a credit line identical to a single name.

`heroMetadataLine` joins the non-empty of `kindLabel`, `year`, and
`"\(n) song\(n == 1 ? "" : "s")"` with `" · "`. It replaces
`AcquireResultDetailView.metadataLine` (`:2361`), minus `albumName` — which that view included and
which is empty for a release row by construction (`AcquisitionCore.swift:496` explains why).

- [ ] **Step 2: Build the package**

```bash
xcodebuild -workspace VellumMusicHost/VellumMusicHost.xcodeproj/project.xcworkspace \
  -scheme VellumMusicHost -destination 'generic/platform=iOS Simulator' build
```
Expected: BUILD SUCCEEDED. Nothing references the type yet, so this only proves it compiles.

- [ ] **Step 3: Stand up the harness**

Follow `docs/verification/harness-t128/README.md` exactly — same `Package.swift` shape
(`swift-tools-version: 6.0`, `platforms: [.macOS(.v13)]`, one executable target,
`swiftLanguageMode(.v5)`), same symlink-the-shipping-source approach:

```bash
cd docs/verification/harness-t130
mkdir -p Sources/t130
for f in CatalogRelease AcquisitionCore; do
  ln -sf ../../../../../Sources/VellumMusicKit/$f.swift Sources/t130/$f.swift
done
```

`Sources/t130/Shims.swift` holds the minimum `ArtistNavigation.isTappable` and `ArtistPageInput`
excerpts the symlinked sources reference from UI-bearing files, lifted verbatim (harness-t128's
`Shims.swift` is the model). Do not reimplement them — the point of the convention is that the
harness exercises the shipping logic.

- [ ] **Step 4: Assert the four cases that matter, and log the run**

`Main.swift` prints a pass/fail line per case:

| Case | Input | Expected |
|---|---|---|
| No MBID | `AcquisitionResult` whose `request.releaseGroupMBID` is `nil` | `init?` returns `nil` |
| Short id | `releaseGroupMBID` = `"12345"` | `init?` returns `nil` |
| Single credit + artist MBID | `artists: ["jayo"]`, `artistMBID` set | `.musicBrainzArtistId(id:name:)` |
| Single credit, no artist MBID | `artists: ["jayo"]`, `artistMBID` nil | `.named("jayo")` |
| Multi credit | `artists: ["jayo", "Citizen"]` | `artistPageInput == nil` |
| Various Artists | `artists: ["Various Artists"]` | `artistPageInput == nil` |

```bash
swift run t130 | tee ../t130-catalogrelease.log
```
Expected: every line `PASS`. `*.log` is gitignored, so the log is local evidence, not a commit
artifact — same as every other `docs/verification/*.log`.

- [ ] **Step 5: Do not commit.** The brief forbids it. Leave the work in the tree.

---

## Task 2: Add the case and make the silent accessors compiler-visible

**BLOCKED on terminal 12 confirming `ServerPlaylistViews.swift` is clear.** Do not start otherwise.

The deliverable is deliberately behaviour-free: the case exists, everything compiles, and nothing
constructs it. That is what makes it independently reviewable — a reviewer can check the 33
triage decisions without any screen having changed.

**Files:**
- Modify: `Sources/VellumMusicKit/ServerPlaylistViews.swift` (enum at `:563`; view from `:623`)

**Interfaces:**
- Consumes: `CatalogRelease` from Task 1.
- Produces: `LibraryDetailSource.catalogRelease(CatalogRelease)`; accessors
  `LibraryDetailSource.serverAlbum: AlbumSummary?`, `LibraryDetailSource.catalogRelease:
  CatalogRelease?`, and the view-level mirrors `serverAlbum`, `catalogRelease`. **`albumOrNil` no
  longer exists** — Tasks 3-7 use `serverAlbum`.

- [ ] **Step 1: Re-resolve the line numbers**

```bash
git diff --stat Sources/VellumMusicKit/ServerPlaylistViews.swift
grep -n "enum LibraryDetailSource\|struct ServerPlaylistDetailView\|albumOrNil\|isAlbumStyleDetail" \
  Sources/VellumMusicKit/ServerPlaylistViews.swift
```
The table in this plan is anchored to `9579592`. Work from this grep, not from the table.

- [ ] **Step 2: Add the case**

```swift
    case homeMix(mixId: String)
    /// A release known by catalog identity rather than by server item id — a search hit the user
    /// does not own. See ``CatalogRelease``. Everything a server album answers with an id, this
    /// case answers with a MusicBrainz release-group id or not at all.
    case catalogRelease(CatalogRelease)
```

- [ ] **Step 3: Rename `albumOrNil` → `serverAlbum`, and add `catalogRelease`**

On the enum, replace:

```swift
    var albumOrNil: AlbumSummary? {
        if case .album(let album, _) = self { return album }
        return nil
    }
```

with:

```swift
    /// The **server** album, and only that.
    ///
    /// Renamed from `albumOrNil` deliberately. A fourth case exists that is an album to the user
    /// and has no server item id at all, and every reader of the old name assumed the two were
    /// the same thing — `app.isAlbumInLibrary(album.id)`, `lib.tracks(forAlbumId:)`,
    /// `offline.cachedTracks(forAlbumId:)`. A `nil` here means "no server album", never "no
    /// album", and the rename is what forced each of the 23 readers to say which it meant.
    var serverAlbum: AlbumSummary? {
        if case .album(let album, _) = self { return album }
        return nil
    }

    var catalogRelease: CatalogRelease? {
        if case .catalogRelease(let r) = self { return r }
        return nil
    }
```

Mirror both on the view (replacing the `albumOrNil` mirror at `:684`).

**This breaks the build in 23 places. That is the point of the step.** Do not add an `albumOrNil`
compatibility shim.

- [ ] **Step 4: Fix `isAlbumStyleDetail` — the one silent default that is actively wrong**

```swift
    /// Album detail layout (numbered rows, hero triplet, no in-page search). Also used for
    /// dynamic home mixes and for catalog releases, which are albums to the reader even though
    /// the server has never heard of them. Getting this wrong does not fail to compile: it
    /// silently renders a catalog release with playlist chrome, including an in-page track
    /// search over tracks the user does not have.
    private var isAlbumStyleDetail: Bool { isAlbum || isHomeMix || source.catalogRelease != nil }
```

Leave `isAlbum` meaning "server album". 25 sites depend on that meaning and all of them are
correct as-is.

- [ ] **Step 5: Fill the ten switches**

Work the table in "THE EXHAUSTIVE-SWITCH BLAST RADIUS" top to bottom. Every row states the return
value. No judgment calls remain at this step.

- [ ] **Step 6: Triage the 23 `serverAlbum` compile errors**

Each site gets one of three treatments, and each needs a one-line comment saying which:

- **Server-only** (`:802` `isPersonalLibraryAlbum`, `:2007` delete-from-library, `:2017`
  `downloadAllTracks`, `:2036` `toggleAlbumPinned`, `:1681` `isAlbumPinned`, `:2544`, `:2656`,
  `:2690`): keep `serverAlbum`, so `.catalogRelease` correctly returns the "no" branch.
- **Wants title/artist/artwork, not an id** (`:841` merge probe, `:2214` share item, `:2232`,
  `:2235`, `:2237` `requestMissingTrack`): read through a new
  `private var displayAlbumIdentity: (artist: String, title: String, artwork: URL?)?` that answers
  for `.album` **and** `.catalogRelease`. Note `requestMissingTrack` (`:2229`) currently builds an
  `AcquisitionRequest` from artist+title text with no `releaseGroupMBID` — for the catalog case it
  must carry `r.releaseGroupMBID`, which is the whole reason the id-based request path exists.
- **Structural / needs a catalog branch** (`:934` `loadPreviewTracksIfAlbum`, `:1337` and `:1387`
  related shelves, `:1945` and `:1997` `primaryActionButton`, `:1658`, `:2070`, `:2142`, `:995`,
  `:1263`): leave `serverAlbum` for now and add `// T130: catalog branch — Task N`. Tasks 3 and 4
  fill them.

- [ ] **Step 7: Build**

```bash
xcodebuild -workspace VellumMusicHost/VellumMusicHost.xcodeproj/project.xcworkspace \
  -scheme VellumMusicHost -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -30
```
Expected: BUILD SUCCEEDED, zero errors.

- [ ] **Step 8: Prove nothing changed**

Nothing constructs `.catalogRelease` yet, so every existing screen must behave identically.
On the iOS 26.3 iPhone 17 Pro simulator (`065F03D0…`, signed into `com.randll.lyra`), open: a
library album, a server playlist, a home mix. Confirm hero, tracklist, overflow menu and swipe-back
are unchanged. This is the regression gate for the accessor rename — the rename touched 23 live
sites and none of them may have shifted behaviour.

---

## Task 3: Hero and action row for the catalog case

**Files:** Modify `ServerPlaylistViews.swift` — `heroSubtitleLine` (`:1614`), `actionButtonTriplet`
(`:1887`), `primaryActionButton` (`:1946`).

**Interfaces:**
- Consumes: `CatalogRelease` (Task 1), `source.catalogRelease` (Task 2).
- Produces: `private var catalogJob: AcquisitionJob?`; `private var catalogRequestButton: some
  View`; `private func requestCatalogRelease() async`.

- [ ] **Step 1: Add the job binding**

```swift
    /// The live request job for a catalog release, looked up by the request's own key.
    ///
    /// Exact, unlike ``acquisitionJob(forPreview:)`` just below, which matches a per-track preview
    /// row by normalized title because a preview row carries no request of its own. A catalog
    /// release does carry one, so it gets the exact lookup.
    private var catalogJob: AcquisitionJob? {
        guard let r = source.catalogRelease else { return nil }
        return acquisition.job(forKey: r.request.requestKey)
    }
```

- [ ] **Step 2: Port the four-state button**

Lift `AcquireResultDetailView.primaryActionButton` (`DiscoverySearchView.swift:2377-2445`) into
`catalogRequestButton`, keeping all four states: already-in-library, in-flight (progress bar +
percentage when `job.progress` is non-nil, status title otherwise, plus `job.message`), failed, and
the Request capsule gated on `app.acquisitionConfigured`. Restyle from the poster's fixed 220pt bar
to `MusicDesign.albumHeroPrimaryCapsuleWidth`, matching the hero's Play capsule.

- [ ] **Step 3: Replace the triplet, do not disable it**

```swift
    private var actionButtonTriplet: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            // A catalog release has no server tracks, so Play / Shuffle / + / Download have
            // nothing to act on. Rendering them disabled would be strictly worse than the poster
            // screen this replaces, which showed one clean Request capsule and no dead controls.
            if source.catalogRelease != nil {
                catalogRequestButton
            } else {
                shuffleButton
                playButton
                primaryActionButton
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
    }
```

Extracting `shuffleButton` and `playButton` from the existing inline bodies is part of this step;
their contents are unchanged.

- [ ] **Step 4: Route the hero artist link**

In `heroSubtitleLine`, add a catalog branch before the existing `heroAlbumArtistSplit` path. Render
`r.displayArtistLine`, and make it a `Button` when `r.artistPageInput != nil`. **Do not route it
through `navigateArtist: ArtistNameNavigation`** — that type models "a name plus an optional
*server* artist id" and has no MBID field. Add a separate
`@State private var navigateCatalogArtist: ArtistPageInput?` with its own
`.navigationDestination(item:)`. Task 5 revisits this once terminal 11's work is visible.

- [ ] **Step 5: Hand off when the release turns out to be owned**

Two different questions, and they must not be conflated:

- **Is this release on the server at all?** `app.libraryAlbumReleaseIndex.firstMatch(artist:
  albumTitle:)` (`AlbumSummary+NewTabMatch.swift:226`). Per CLAUDE.md, `libraryAlbumReleaseIndex`
  is the whole **server catalog**, not the personal library — which is the right index for this
  question and the wrong one for the next.
- **Has the user added it?** `app.isAlbumInLibrary(matched.id)`, once a server album is in hand.

When `firstMatch` returns a server album, the screen must not try to be both. Render an "In your
library" / "On your server" state whose button pushes
`ServerPlaylistDetailView(album: matched, librarySource: app.isAlbumInLibrary(matched.id))` through
the existing `navigateAlbum` binding and `pushAlbumDetailNavigation` (`:551`). When `firstMatch`
returns nil, fall back to `LibraryTrackMatcher.matchesLibrary(title:artists:titleIndex:)`
(`LibraryTrackMatcher.swift:115`) for the weaker title-index answer `AcquireResultDetailView` used
(`DiscoverySearchView.swift:2282`), which reports membership but yields no album to push to.

- [ ] **Step 6: Swap `statusMessage` for the standard toast**

Delete the `statusMessage` concept. `requestCatalogRelease()` calls
`app.requestAcquisition(r.request)` then `app.showTransientToast(...)`. **Call this out in the
handoff** — it is a deliberate behaviour change from persistent inline text to a ~1.8s toast, made
because CLAUDE.md names the toast as the app's confirmation mechanism and every other request
affordance already uses it. The haptic is bundled; do not fire one separately.

- [ ] **Step 7: Build.** BUILD SUCCEEDED, zero errors. Not yet reachable from the UI.

---

## Task 4: Tracklist for the catalog case

**Files:** Modify `ServerPlaylistViews.swift` — `trackRows` (`:1293`), `loadPreviewTracksIfAlbum`
(`:934`), `shouldLoadAlbumPreviewTracks` (`:815`), `shouldShowMergedAlbumTracklist` (`:809`),
`computeAlbumMergedRows` (`:832`), `load()` (`:2361`).

- [ ] **Step 1: Confirm Standalone Task A has landed — do not re-fix it here**

The `trackRows` branch-ordering defect is registered as **Standalone Task A**, above, and is
deliberately not part of this task. It is a precondition: a catalog release has `displayedRows`
empty by definition, so until the merged branch is reachable from an empty `visible` the merged
screen renders "No songs" and nothing else on every search result.

Check it: `grep -n 'else if shouldShowMergedAlbumTracklist\|else if visible.isEmpty'
Sources/VellumMusicKit/ServerPlaylistViews.swift` — the merged clause must come first. If it does
not, stop and run Standalone Task A as its own change, with its own build and its own report, then
come back. **Do not fold that fix into this task.** It is filed separately precisely so a reviewer
can see it without reading a restructure around it.

- [ ] **Step 2: Let the gates admit a catalog release**

`shouldShowMergedAlbumTracklist` and `shouldLoadAlbumPreviewTracks` both open with
`guard isAlbum`, which is `false` for the new case. Widen both to
`guard isAlbum || source.catalogRelease != nil`. `isPersonalLibraryAlbum` stays `false` for the
catalog case, so both correctly return `true` without a Show-Complete-Album toggle.

- [ ] **Step 3: Fetch previews by MBID**

`loadPreviewTracksIfAlbum` (`:934`) currently calls
`acquisition.tracks(forBrowseAlbumId: nil, artist:title:)` — the text path. For a catalog release
pass the id: `forBrowseAlbumId: "mbid:\(r.releaseGroupMBID)"`, which
`AcquisitionManager.tracks(forBrowseAlbumId:artist:title:)` decodes at `AcquisitionManager.swift:216`
and which falls through plugin-by-id → plugin-by-title →
`AcquisitionTrackListMusicBrainzSource` (`:249`). That last fallback is the one that answers for a
release nobody owns, which is exactly this case.

While here: for `.album` sources, prefer `album.musicBrainzReleaseGroupId` when the server reported
one (it is on `AlbumSummary` as of `9579592`). Same reasoning, and it is a one-line win.

- [ ] **Step 4: Make `computeAlbumMergedRows` produce an all-missing list**

It already does, given empty `libraryRows` and non-empty `previewTracks` — every preview falls to
the `else if includeMissing` branch. The only change needed is the probe at `:841`, which reads
`albumOrNil?.artist`; point it at `displayAlbumIdentity` from Task 2 Step 6.

- [ ] **Step 5: Related shelves**

At `:1337` and `:1387`, add the catalog branch: `AlbumDetailRelatedSectionsView(artist: r.artist,
title: r.title, excludingAlbumId: nil, …)`. `excludingAlbumId` is `String?`
(`AlbumDetailRelatedSectionsView.swift:9`), so `nil` is legal and "More by this artist" works from
artist and title alone.

- [ ] **Step 6: Build.** BUILD SUCCEEDED, zero errors.

---

## Task 5: Artist navigation, reconciled with terminal 11

- [ ] **Step 1: See what terminal 11 landed**

```bash
git diff 9579592 -- Sources/VellumMusicKit/DiscoverySearchView.swift \
  Sources/VellumMusicKit/ArtistPageView.swift Sources/VellumMusicKit/AcquisitionCore.swift
```
Read `AcquireResultDetailView.artistNavTarget` and `ArtistNameNavigation` as they now stand.

- [ ] **Step 2: Port, do not drop**

If terminal 11 improved the credit-line/navigation logic, port it into
`CatalogRelease.artistPageInput` and re-run the Task 1 harness with the new cases. If terminal 11
added an MBID field to `ArtistNameNavigation`, collapse Task 3 Step 4's separate
`navigateCatalogArtist` state onto it rather than keeping two artist-navigation bindings in one
view.

- [ ] **Step 3: Build, then check on the simulator.** Open a search result, tap the artist line,
confirm the artist page header matches the credited artist and not a same-named act.

---

## Task 6: Switch the call site and delete the old view

The first task with a user-visible change.

**Files:** Modify `SearchLibraryView.swift:89`; modify `DiscoverySearchView.swift` (delete
`:2251-2462`); modify the search row that pushes `.acquire` to mark a cover-zoom source.

- [ ] **Step 1: Diff before deleting**

```bash
git diff 9579592 -- Sources/VellumMusicKit/DiscoverySearchView.swift | sed -n '/AcquireResultDetailView/,$p'
```
Anything terminal 11 added inside that view is ported in Task 5, not deleted here. Confirm it is
ported before removing the view.

- [ ] **Step 2: Re-route the destination**

```swift
        case .acquire(let result):
            if let release = CatalogRelease(result) {
                ServerPlaylistDetailView(catalogRelease: release)
            } else {
                // No release-group id, so there is nothing to request by and no track list to
                // fetch — the id-based path is the only one that resolves. Keep the row
                // non-navigable rather than opening a screen that can only fail.
                EmptyView()
            }
```

Better: gate tappability at the row so a dead row never looks tappable. Find the row that builds
`SearchNavTarget.acquire` and suppress the push when `CatalogRelease(result) == nil`. Confirm how
many live results that actually affects before choosing — if it is none in practice, the
`EmptyView` fallback is dead code and the gate is the honest fix.

- [ ] **Step 3: Add `init(catalogRelease:)`**

Beside the three existing inits (`:632`, `:642`, `:650`):

```swift
    init(catalogRelease: CatalogRelease, tracksVisibility: Bool = true) {
        self.source = .catalogRelease(catalogRelease)
        self.scrollToTrackId = nil
        self.tracksVisibility = tracksVisibility
        _backdropPalette = State(initialValue: ArtworkDynamicGradient.seededBackdrop(for: catalogRelease.artworkURL))
    }
```

- [ ] **Step 4: Match the cover-zoom id**

Task 2 set `coverZoomId` to `"catalog-release:\(r.releaseGroupMBID)"`. The search row's artwork
must carry `.coverZoomSource(id:)` with the identical string or the push silently degrades to a
cross-fade. Verify by eye, not by reading — a mismatched key fails quietly.

- [ ] **Step 5: Delete `AcquireResultDetailView`** (`DiscoverySearchView.swift:2251-2462`).

- [ ] **Step 6: Build.** BUILD SUCCEEDED, zero errors, and no "unused" warnings pointing at
orphaned helpers the deleted view was the last user of.

- [ ] **Step 7: Simulator check — the whole point of the task**

Search Discover for an album not on the server. Tap it. Confirm: album hero with backdrop; a
tracklist of requestable rows (**not** "No songs"); Request capsule instead of a greyed Play /
Shuffle / +; artist line navigates; the overflow menu is present; swipe-back is responsive; the
cover zooms rather than cross-fades.

---

## Task 7: Overflow menu and toolbar triage

**Files:** Modify `ServerPlaylistViews.swift` — `playlistOverflowMenuContent` (`:1697`),
`detailToolbarContent` (`:1427`), `killModeToolbarButton` (`:1484`).

- [ ] **Step 1: Walk every menu item in the catalog case**

For each: does it act on server tracks? If yes it must be **absent**, not disabled — same rule as
Task 3 Step 3. Play Next, Add to Playlist, Favorite, Download, Pin and the sort menu are all
`rows`-backed. Share is the exception: `ShareLink(item: title)` works with no server item and
should stay.

- [ ] **Step 2: Verify the already-correct absences**

Kill Mode is gated `!isAlbumStyleDetail`; rename / edit / delete / remove-from-playlist are gated
on `source.playlistOrNil`. After Task 2 Step 4 these should all be correctly absent for a catalog
release. **Confirm on the simulator rather than by reading** — this is exactly the class of silent
default the whole plan is built around, and a gate that looks right in source is not evidence.

- [ ] **Step 3: Build, then re-verify the untouched screens**

BUILD SUCCEEDED. Then re-open a library album, a server playlist and a home mix and confirm their
overflow menus are unchanged. Tasks 2 and 7 both edited shared menu code; this is the last chance
to catch a leak into the existing cases.

- [ ] **Step 4: Report.** No commit. Summarise: the behaviour change in Task 3 Step 6 (inline
status text → toast) and anything Task 6 Step 2 revealed about results with no MBID. Report
Standalone Task A's behaviour change separately, under its own heading — it is a separate task and
folding its report into this one would undo the point of filing it apart.

---

## Self-review notes

- **Spec coverage.** Fourth-case shape → "THE FOURTH CASE". Exhaustive-switch blast radius with
  file:line → the two tables in "BLAST RADIUS" (ten compiler-caught, plus the ~123 silent sites the
  brief's framing did not anticipate). Capability comparison both directions with placement →
  "CAPABILITY LEDGER", including three capabilities named as unplaceable-as-is with the decision
  taken for each. Branch taken → stated up front, with the two conditions that would have reversed
  it. T146 → its own section, verdict "does not block".
- **Known soft spot.** Task 2 Step 6's split of 23 sites into three treatments is the judgment call
  most likely to need revision during execution; the three-bucket rule is stated so a reviewer can
  disagree per site rather than with the whole task.
- **Naming consistency.** `serverAlbum` (not `albumOrNil`), `catalogRelease` (both the enum case
  payload accessor and the view mirror), `CatalogRelease.artistPageInput` (not `artistNavTarget`,
  since it returns `ArtistPageInput`), `catalogJob`, `catalogRequestButton`,
  `requestCatalogRelease()`, `displayAlbumIdentity`. Used identically in every task above.
