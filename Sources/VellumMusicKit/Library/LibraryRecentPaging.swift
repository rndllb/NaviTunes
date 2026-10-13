import Foundation

/// The Library tab's Recently Added grid shows one page of items and loads the next page by
/// itself as the user scrolls toward the end (T664: "it should just infinite scroll paginate").
/// It used to be a hard `.prefix(60)`: with 29 albums and 61 playlists the 61st item was
/// unreachable from anywhere in the app (T638 issue 1). T643 put a "Show More" button under the
/// grid; the owner asked for the button to go.
enum LibraryRecentPaging {
    /// Items shown on open — the old cap, so the grid looks the same until the user scrolls.
    static let pageSize = 60

    /// How far from the end of the visible grid the next page is requested: when an item this
    /// many positions or fewer before the last visible one appears. Twelve is six rows of the
    /// two-column grid, about two screens on an iPhone, so the page lands before the user gets
    /// there.
    static let prefetchDistance = 12

    /// The next visible-count, or `nil` when everything is already visible.
    static func nextLimit(current: Int, total: Int, step: Int = pageSize) -> Int? {
        guard total > current else { return nil }
        return min(total, current + max(1, step))
    }

    /// Whether the item at `index` appearing on screen should load the next page: it is within
    /// `prefetchDistance` of the end of what is visible, and there is more to show.
    static func shouldLoadMore(
        appearedIndex index: Int,
        visible: Int,
        total: Int,
        prefetchDistance: Int = prefetchDistance,
    ) -> Bool {
        guard total > visible else { return false }
        return index >= visible - max(1, prefetchDistance)
    }
}
