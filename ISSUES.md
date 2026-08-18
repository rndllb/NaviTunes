# Known Issues

## Playlist search bar reveals on scroll-to-top (not pull-to-reveal only)

**Where:** `Sources/VellumMusicKit/ServerPlaylistViews.swift` — `ServerPlaylistDetailView`, the `.searchable(...placement: .navigationBarDrawer(displayMode: .automatic))` modifier.

**Desired behavior:**
1. Playlist opens → search bar hidden.
2. User pulls down at top → search bar appears.
3. User scrolls down → search bar hides.
4. User scrolls back to top → search bar **stays hidden**.
5. User pulls down at top again → search bar appears.

**Current behavior:** Steps 1–3 work, but step 4 fails — iOS's `UISearchController` with `hidesSearchBarWhenScrolling = true` auto-reveals the search bar whenever the scroll position settles at the natural top, regardless of how the user got there. No native `.searchable` placement or `UISearchController` flag changes this.

**Attempts that didn't work:**
- Setting initial `UIScrollView.contentOffset` past the search bar via UIKit introspection (hides on launch only; auto-reveal still happens after any scroll cycle).
- Adding a `UIScrollView` KVO controller that snaps `contentOffset` back to the hidden position after deceleration when no explicit drag-past-top was observed. The snap either didn't fire (KVO/`adjustedContentInset` timing on `.navigationBarDrawer` is fragile) or was visibly canceled by the system's own search-bar reveal animation.

**Plausible paths forward:**
- Drop `.searchable` for this view; embed a custom inline search field in the `ScrollView` content positioned above the natural top (e.g., via `safeAreaInset` with a negative inset, or `contentMargins(.top, -h)`), so the search field is only visible when overscrolled. Requires updating `PlaylistHeroOrPillsHeader` to take an explicit `isSearching` bool instead of reading `\.isSearching`.
- Wrap the whole detail view in a `UIViewController`-based representable that owns its own `UIScrollView` + non-navigation-drawer `UISearchBar` header, giving full control over the reveal behavior.
- Live with the current behavior and instead change placement to `.toolbar` so search is a tap-to-expand toolbar button (different UX but no auto-reveal).

## Search tab: detached search button vs scroll-collapse (mutually exclusive)

**Where:** `Sources/VellumMusicKit/RootView.swift` — the Search `Tab(role: .search)` and `.tabBarMinimizeBehavior(...)`.

**Limitation:** A `Tab(role: .search)` renders as a detached search button in the tab bar but does **not** participate in `tabBarMinimizeBehavior(.onScrollDown)`. So under Search the tab bar and the bottom mini-player accessory (`tabViewBottomAccessoryPlacement`, system-driven) do not collapse on scroll. Removing `role: .search` enables the collapse but collapses all five tabs into one inline pill (no detached search button). iOS provides no way to get both.

**Current choice:** keep the detached button — `.tabBarMinimizeBehavior(app.selectedTab == .search ? .never : .onScrollDown)`. The mini-player collapse can't be driven independently because its layout reads the read-only system `\.tabViewBottomAccessoryPlacement`.

**Also tried (reverted):** a custom Liquid-Glass search header that collapsed on scroll via height-squeeze — not the native `.searchable` sandwich animation, so it was reverted. A full switch to native `.searchable` + `.searchScopes` would give the exact native collapse but replaces the custom header and renders via the nav bar instead of the floating-header style the other tabs use.

## Home taste shelves

**Where:** `AppModel.applyHomeDiscoveryShelvesRanking()` / `HomeView` — Top Picks, New Releases, genre rows, New Artists Added.

**Behavior:** Shelves only show **server catalog** albums **not** in the user's magic playlist (`isEligibleForHomeTopPick`). Until `recentlyAddedAlbums`, taste genres, and/or scrobble signals load, rows can be empty or fall back to server **New Releases**. On cold launch the candidate pool can seed from persisted `libraryAlbums` until recency fetches land.

**Stabilization (2026-06):** `stabilizeHomeDiscoveryShelf` keeps visible Top Picks / New Releases cards in place when background genre-catalog enrichment expands the pool — avoids the shelf jumping after first paint. Pull-to-refresh calls `refreshHome(forceDiscoveryReshuffle: true)` for a full re-rank.

**Removed (2026-06):** MusicBrainz browse clients and Settings toggle.

**Superseded (2026-08):** there are no third-party metadata clients left on any browse path. New / Discover / Following / artist pages read the **server catalog plus the active acquisition plugin** (`artistReleases`, `tracks(forRelease:)`). Artist About comes from Lidarr's `overview` when present and is hidden otherwise; similar artists are hidden entirely. The `ITunes*Client.swift` files are still in the tree but are unreferenced dead code — they are safe to delete and should not be wired back in.

## Dead code awaiting removal

- `ITunes*Client.swift` (4 files: search / tracklist / new releases / artist) — no remaining references anywhere in `Sources/`.

## Performance is a standing constraint, not a one-off cleanup

Every view holds `@EnvironmentObject var app: AppModel`, and `AppModel` has ~100 `@Published` properties, so **any** publish re-runs **every** visible `body`. A single full-catalog scan or live `.blur` in a body path is enough to make scrolling and the mini-player transition visibly janky — this has regressed twice. Before adding UI, read `Rules/swiftui-body-cost.md` and `Rules/swiftui-render-cost.md`. `PerfLog` logs any main-actor block over 16 ms under subsystem `vellum.perf` and emits Instruments signposts; use it rather than guessing.
