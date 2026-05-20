# Lyra Music — Backend Notes

This app talks to two pluggable music backends. The active one is chosen at login via `BackendKind` (`AppModel.swift`). Both implement `MusicLibraryProviding` (`MusicLibraryProviding.swift`) so feature code stays backend-agnostic; reach for the concrete client only when an endpoint or capability differs.

## Clients

- **Jellyfin** — `JellyfinMusicClient.swift`. Native Jellyfin REST API. Auth = `X-Emby-Token` + `userId`. Media URLs carry `api_key` query auth for `AVURLAsset` compatibility.
- **Navidrome (Subsonic API)** — `NavidromeClient.swift`. Speaks the Subsonic protocol (`/rest/<endpoint>.view?...`). Salted token auth. Client id must NOT match Navidrome's `Subsonic.MinimalClients` — minimal payloads drop `albumId` and break favorites.

## Capability differences that matter

| Concern | Jellyfin | Navidrome / Subsonic |
|---|---|---|
| Favorite a track | `POST/DELETE Users/{uid}/FavoriteItems/{id}` | `star` / `unstar` |
| User-add timestamp | **None** — `UserData.IsFavorite` is bool only | **Yes** — `getStarred2` returns a per-item `starred` date |
| List favorites | `Items?Filters=IsFavorite` | `getStarred2` (songs + albums + artists) |
| Playlist `DateCreated` | Present on `Playlists` items | Present on `getPlaylists` entries |
| Album `DateCreated` | Server scan/upload time | Server scan/upload time |
| Recently-added albums | `Items?SortBy=DateCreated&IncludeItemTypes=MusicAlbum` | `getAlbumList2?type=newest` |

`libraryAddedDate` on `AlbumSummary` / `Track` / `PlaylistSummary` (`MusicLibraryProviding.swift`, `PlaylistModels.swift`) is **server-side** — it's when the server scanned/created the item, not when the current user added it to their library. Be careful when surfacing this as "Recently Added" in user-facing UI.

## Tracking "added to MY library"

There is no single backend field for this. The accurate approach is hybrid:

- **Subsonic backends:** trust the `starred` timestamp from `getStarred2`.
- **Jellyfin:** no timestamp from server. Stamp locally (e.g., a small persistent store keyed by `(backend, serverId, itemId) → date`) at the moment the user favorites/creates from this app. Fall back to playlist `DateCreated` for user-owned playlists.

Limitation of the local-stamp path: actions taken outside this app (Jellyfin web UI, other clients) won't appear with an accurate "added" date until the user touches them here.

## Server catalog vs personal library (do not confuse these)

The app surfaces two distinct collections. The naming is a footgun — `AppModel.libraryAlbums` is the **whole server catalog**, not "your library".

- **Server catalog** — every album/track on the connected Navidrome / Jellyfin instance. Loaded via `MusicLibraryProviding.albums(limit:)` → Subsonic `getAlbumList2` / Jellyfin `Items?IncludeItemTypes=MusicAlbum`. Cached in `AppModel.libraryAlbums` / `recentlyAddedAlbums`. Server-wide search is `MusicLibraryProviding.searchCatalog(query:)` → Subsonic `search3` / Jellyfin `Items?searchTerm=…`.
- **Personal library (Lyra "My Library" magic playlist)** — a per-user opaquely-named playlist (`__lyra_<sha12>`) Lyra creates on the backend. Its contents are the canonical "what *I* added" set, synced across devices:
  - Playlist tracks → `AppModel.librarySongIds: Set<String>`
  - `comment` (Subsonic) / `Overview` (Jellyfin) JSON → `LibraryMembershipPayload` → `libraryAlbumEntries` + `libraryPlaylistEntries` (each entry carries a per-item `added` date so "Recently Added (yours)" is accurate).
  - Resolved + reconciled on sign-in by `refreshLibraryMembership()`; mutated by `addAlbumToLibrary` / `removeAlbumFromLibrary` / `toggleFavoriteTrack` etc., then persisted back to the magic playlist via `persistLibraryMembershipPayload()`.
  - Filtered out of every user-facing playlist surface by id and by name prefix (`LibraryMembership.isMagicPlaylistName`).

Rule of thumb: anything that means "things the *user* owns / has added" must read from `librarySongIds` / `libraryAlbumEntries` / `libraryPlaylistEntries`, not `libraryAlbums`. Search scopes follow the same split: the Library tab in Discovery searches **personal** state; the Downtify tab is a hybrid of **server catalog** + Downtify download candidates.

## Conventions

- Nothing custom, prioritize using apple library stuff first. Reach for stock SwiftUI / UIKit / system APIs (`.contextMenu(menuItems:preview:)`, `ShareLink`, `NavigationStack`, `.searchable`, etc.) before building bespoke chrome or gestures.
- New backend-facing features should extend `MusicLibraryProviding` rather than branching on `BackendKind` in feature code. Branch in the client implementations.
- Track/Album/Playlist models are `Codable` and persisted to disk via `LibrarySnapshotStore.swift` — adding non-optional fields needs a migration story.
- Media URLs may be embedded in `AVURLAsset`; query-auth (not headers) is required so the player can reach them without a custom resource loader.
- All UI-facing models cross main actor boundaries. New `Observable` view-state types should be `@MainActor`.

## Build / run

- iOS app target: `LyraMusicHost/LyraMusicHost.xcodeproj` (workspace at `LyraMusicHost/LyraMusicHost.xcodeproj/project.xcworkspace`).
- Library code lives in the SPM package at `Sources/LyraMusicKit/` (`Package.swift`).
- Standard build: `xcodebuild -workspace LyraMusicHost/LyraMusicHost.xcodeproj/project.xcworkspace -scheme LyraMusicHost -destination 'generic/platform=iOS Simulator' build`.
