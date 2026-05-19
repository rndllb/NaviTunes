# Known Issues

## Playlist search bar reveals on scroll-to-top (not pull-to-reveal only)

**Where:** `Sources/LyraMusicKit/ServerPlaylistViews.swift` — `ServerPlaylistDetailView`, the `.searchable(...placement: .navigationBarDrawer(displayMode: .automatic))` modifier.

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
