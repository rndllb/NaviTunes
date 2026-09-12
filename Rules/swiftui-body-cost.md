# Cost inside SwiftUI bodies

Applies to all Swift UI code in `Sources/VellumMusicKit/`. Read together with
`Rules/swiftui-render-cost.md`.

Nearly every view holds `@EnvironmentObject var app: AppModel`, and `AppModel` has 138
`@Published` properties. **Any** publish re-runs **every** visible body. So treat a `body` —
and every computed property or method reached from one — as code that runs constantly.

## Never scan the catalog from a body path

`app.libraryAlbums` is the whole **server catalog** and `app.discoveryLibraryTracks` is the
whole **track index** (10k–100k+ items). Never `filter` / `sorted` / `contains` /
`first(where:)` / `Dictionary(...)` / `Set(...)` over them in a body, a computed property
read from a body, or a row builder.

```swift
// ❌ full-catalog scan per body pass — and per row when it's in a row builder
let album = app.libraryAlbums.first { $0.id == track.albumId }
let byId = Dictionary(uniqueKeysWithValues: app.libraryAlbums.map { ($0.id, $0) })

// ✅ prebuilt O(1) indexes
let album = app.catalogAlbum(id: track.albumId)
let playlist = app.libraryPlaylist(id: playlistId)
let track = app.indexedTrack(id: trackId)
```

Adding a new `AppModel` query that scans an array? Back it with a derived index invalidated
from the `didSet` of every input — see `membershipLookups` / `invalidateMembershipLookups()`.
`isAlbumInLibrary` and `isEligibleForHomeTopPick` are the reference cases: both are called
per-album from Home's shelves, so both must stay O(1).

## Cache derived lists in `@State`

Filter / sort / merge results belong in `@State`, recomputed explicitly when an input
changes — never in a computed property. Follow `LibrarySongsView.recomputeDisplayed` or
`AlbumsGridView.recomputeAlbumDisplay`.

## Evaluate a computed property once per pass

Referencing one N times runs it N times. Bind it to a local `let` and reuse it.

## Sorting

Decorate–sort–undecorate. Never call a function that scans an array from inside a comparator
(that turns an O(n log n) sort superlinear).

## Small things that add up

- `DateFormatter` / `RelativeDateTimeFormatter`: `static let`. Never build one in a body.
- Memoize regex/normalization-heavy derived keys (see `catalogReleaseIdentityKey`).
- `PerfLog.measure(details:)` interpolation is eager — never re-evaluate something expensive
  just to build the log string.

`PerfLog` logs any main-actor block over 16 ms to Console.app under subsystem `vellum.perf`,
and emits signposts for Instruments. Use it to confirm a suspicion instead of guessing.
