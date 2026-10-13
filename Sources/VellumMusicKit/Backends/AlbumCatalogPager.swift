import Foundation

/// Walks a paged server listing by offset until a short page, so the in-memory catalog holds
/// every album rather than the first page of them.
///
/// Subsonic's `getAlbumList2` caps a page at 500 rows and Jellyfin's `Items` takes `StartIndex`;
/// both are driven by the same loop. T638 measured the old single-page fetch at 500 of 13,300
/// albums, sorted by title, with everything after "After Fillmore County" absent from every
/// surface that reads the catalog.
enum AlbumCatalogPager {
    /// The Subsonic per-request ceiling.
    static let pageSize = 500

    /// Fetches pages from `offset` 0 until a page comes back shorter than asked for (or empty),
    /// or `maxItems` rows have been collected. The last page is sized to what is left under the
    /// ceiling, so the ceiling is exact. Any thrown page aborts the whole walk.
    static func fetchAll<Item>(
        pageSize: Int = pageSize,
        maxItems: Int,
        fetchPage: (_ offset: Int, _ size: Int) async throws -> [Item],
    ) async throws -> [Item] {
        let page = max(1, pageSize)
        let ceiling = max(0, maxItems)
        var collected: [Item] = []
        var offset = 0
        while collected.count < ceiling {
            let size = min(page, ceiling - collected.count)
            let rows = try await fetchPage(offset, size)
            if rows.isEmpty { break }
            collected.append(contentsOf: rows)
            offset += rows.count
            if rows.count < size { break }
        }
        return collected
    }
}
