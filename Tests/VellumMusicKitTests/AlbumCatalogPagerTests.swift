import Foundation
import Testing

@testable import VellumMusicKit

/// The paging loop behind `albums(limit:)`: walk `getAlbumList2` (or Jellyfin `StartIndex`) by
/// offset until a short page, so a 13,300-album server is not cut to its first 500 titles.
/// (T643 c1 — the T638 finding was one page of 500, sorted by title, and nothing after it.)
@Suite("AlbumCatalogPager")
struct AlbumCatalogPagerTests {
    /// A fake server with `total` rows; records every (offset, size) it was asked for.
    final class FakeServer {
        let total: Int
        var requests: [(offset: Int, size: Int)] = []
        init(total: Int) { self.total = total }

        func page(offset: Int, size: Int) -> [Int] {
            requests.append((offset, size))
            guard offset < total else { return [] }
            return Array(offset ..< min(total, offset + size))
        }
    }

    @Test("an exact multiple of the page size: every row, and one empty page to prove the end")
    func exactMultiple() async throws {
        let server = FakeServer(total: 1000)
        let rows = try await AlbumCatalogPager.fetchAll(pageSize: 500, maxItems: 50_000) { offset, size in
            server.page(offset: offset, size: size)
        }
        #expect(rows == Array(0 ..< 1000))
        #expect(server.requests.map(\.offset) == [0, 500, 1000])
        #expect(server.requests.map(\.size) == [500, 500, 500])
    }

    @Test("a short last page ends the walk without an extra request")
    func shortLastPage() async throws {
        let server = FakeServer(total: 1200)
        let rows = try await AlbumCatalogPager.fetchAll(pageSize: 500, maxItems: 50_000) { offset, size in
            server.page(offset: offset, size: size)
        }
        #expect(rows.count == 1200)
        #expect(rows.last == 1199)
        #expect(server.requests.map(\.offset) == [0, 500, 1000])
    }

    @Test("an empty library: one request, no rows")
    func emptyLibrary() async throws {
        let server = FakeServer(total: 0)
        let rows = try await AlbumCatalogPager.fetchAll(pageSize: 500, maxItems: 50_000) { offset, size in
            server.page(offset: offset, size: size)
        }
        #expect(rows.isEmpty)
        #expect(server.requests.count == 1)
    }

    @Test("the ceiling is honoured: the last page is sized to what is left")
    func ceiling() async throws {
        let server = FakeServer(total: 5000)
        let rows = try await AlbumCatalogPager.fetchAll(pageSize: 500, maxItems: 700) { offset, size in
            server.page(offset: offset, size: size)
        }
        #expect(rows.count == 700)
        #expect(server.requests.map(\.size) == [500, 200])
    }

    @Test("a thrown page propagates; nothing partial is returned")
    func failurePropagates() async {
        struct Boom: Error {}
        let server = FakeServer(total: 1200)
        await #expect(throws: Boom.self) {
            _ = try await AlbumCatalogPager.fetchAll(pageSize: 500, maxItems: 50_000) { offset, size -> [Int] in
                if offset >= 500 { throw Boom() }
                return server.page(offset: offset, size: size)
            }
        }
    }
}

/// The Library tab's Recently Added grid used to be `.prefix(60)` and nothing else, so his 61st
/// item ("party", T638) was unreachable. It now grows a page at a time, by itself, as the user
/// scrolls toward the end (T664).
@Suite("LibraryRecentPaging")
struct LibraryRecentPagingTests {
    @Test("90 items, 60 shown: the next step reveals the rest")
    func growsToTotal() {
        #expect(LibraryRecentPaging.nextLimit(current: 60, total: 90) == 90)
    }

    @Test("a long list grows by one page per step")
    func growsByPage() {
        #expect(LibraryRecentPaging.nextLimit(current: 60, total: 400) == 120)
        #expect(LibraryRecentPaging.nextLimit(current: 120, total: 400) == 180)
    }

    @Test("everything already visible: no further step")
    func nothingMore() {
        #expect(LibraryRecentPaging.nextLimit(current: 60, total: 60) == nil)
        #expect(LibraryRecentPaging.nextLimit(current: 90, total: 90) == nil)
        #expect(LibraryRecentPaging.nextLimit(current: 60, total: 12) == nil)
        #expect(LibraryRecentPaging.nextLimit(current: 0, total: 0) == nil)
    }

    @Test("the first page is the old cap, so the grid looks the same until the user scrolls")
    func initialPage() {
        #expect(LibraryRecentPaging.pageSize == 60)
        #expect(LibraryRecentPaging.prefetchDistance == 12)
    }

    @Test("the trigger: the 12th-from-last visible item appearing asks for more; the 13th does not")
    func trigger() {
        #expect(!LibraryRecentPaging.shouldLoadMore(appearedIndex: 47, visible: 60, total: 90))
        #expect(LibraryRecentPaging.shouldLoadMore(appearedIndex: 48, visible: 60, total: 90))
        #expect(LibraryRecentPaging.shouldLoadMore(appearedIndex: 59, visible: 60, total: 90))
        // Nothing left: the last items of a fully shown grid never ask.
        #expect(!LibraryRecentPaging.shouldLoadMore(appearedIndex: 89, visible: 90, total: 90))
        #expect(!LibraryRecentPaging.shouldLoadMore(appearedIndex: 11, visible: 12, total: 12))
    }

    /// Walks the grid the way a scroll does: every visible item appears, in order, and an
    /// appearance near the end grows the visible count. The grid is `all.prefix(limit)`, so the
    /// items on screen are exactly the indices `0 ..< limit`; the walk records which index was
    /// revealed by which page.
    private static func scrollToEnd(total: Int) -> (pages: [Int], revealed: [Int]) {
        var visible = min(LibraryRecentPaging.pageSize, total)
        var pages = [visible]
        var revealed = Array(0 ..< visible)
        var index = 0
        while index < visible {
            if LibraryRecentPaging.shouldLoadMore(appearedIndex: index, visible: visible, total: total),
               let next = LibraryRecentPaging.nextLimit(current: visible, total: total) {
                revealed.append(contentsOf: visible ..< next)
                visible = next
                pages.append(next)
            }
            index += 1
        }
        return (pages, revealed)
    }

    @Test("scrolling to the end reveals every item exactly once, then stops", arguments: [0, 12, 60, 61, 90, 400, 1186])
    func noDuplicatesNoGaps(total: Int) {
        let (pages, revealed) = Self.scrollToEnd(total: total)
        #expect(revealed == Array(0 ..< total), "total \(total): revealed \(revealed.count), pages \(pages)")
        #expect(Set(revealed).count == total)
        #expect(pages.last == total)
        #expect(pages == pages.sorted() && Set(pages).count == pages.count, "pages must grow: \(pages)")
        #expect(LibraryRecentPaging.nextLimit(current: total, total: total) == nil)
    }

    @Test("the page sequence: 400 items take six loads, 61 take one, 60 or fewer take none")
    func pageSequence() {
        #expect(Self.scrollToEnd(total: 400).pages == [60, 120, 180, 240, 300, 360, 400])
        #expect(Self.scrollToEnd(total: 61).pages == [60, 61])
        #expect(Self.scrollToEnd(total: 60).pages == [60])
        #expect(Self.scrollToEnd(total: 12).pages == [12])
        #expect(Self.scrollToEnd(total: 1186).pages.count == 20)
    }
}
