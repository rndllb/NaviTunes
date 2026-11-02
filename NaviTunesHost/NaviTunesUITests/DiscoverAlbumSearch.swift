import XCTest

/// The stub Lidarr these tests run against — `scripts/stub-lidarr/README.md`.
///
/// It runs on the **host**, not the simulator. The simulator shares the Mac's loopback, so
/// `127.0.0.1` reaches it from inside the app.
enum StubLidarr {
    static let baseURL = "http://127.0.0.1:8686"

    /// Launch arguments that point the app at the stub. `-key value` lands in `NSArgumentDomain`,
    /// which `UserDefaults.standard` consults — so `AcquisitionConfigStore` reads these without
    /// anything being written to the user's persisted settings.
    static let launchArguments = [
        "-acquisition.activePlugin", "lidarr",
        "-acquisition.lidarr.baseURL", baseURL,
        "-acquisition.lidarr.apiKey", "uitest",
    ]

    /// Skips the test — rather than failing it — when the stub is not up, so a plain
    /// `xcodebuild test` without the harness running does not report false failures.
    static func skipUnlessRunning() throws {
        let ready = XCTestExpectation(description: "stub Lidarr reachable")
        var reachable = false
        var request = URLRequest(url: URL(string: "\(baseURL)/api/v1/system/status")!)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            ready.fulfill()
        }.resume()
        _ = XCTWaiter().wait(for: [ready], timeout: 5)
        try XCTSkipUnless(
            reachable,
            "Stub Lidarr is not running on \(baseURL). Start it with "
                + "`python3 scripts/stub-lidarr/stub_lidarr.py` — see that folder's README."
        )
    }
}

/// T068 — Discover search has to reach the active plugin's **album** catalog, so a single
/// searched by its own title becomes a requestable row.
///
/// Lidarr is album-granularity and has no track search, so before the fix a song-title query
/// could only ever match an artist name. These tests point the app at a stub Lidarr running on
/// the host (the simulator shares the Mac's loopback) using `-key value` launch arguments, which
/// land in `NSArgumentDomain` and are therefore read by `AcquisitionConfigStore` without touching
/// anything the user has persisted.
///
/// The stub serves Lidarr's *wire format*, not its behaviour — the plugin only parses JSON.
final class DiscoverAlbumSearchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() throws -> XCUIApplication {
        try StubLidarr.skipUnlessRunning()
        let app = XCUIApplication()
        app.launchArguments += StubLidarr.launchArguments
        app.launch()
        SimulatorSignIn.ensureSignedIn(app)
        return app
    }

    /// Types a query into the Search tab and waits out the debounce plus both round-trips
    /// (server catalog, then the plugin).
    private func search(_ app: XCUIApplication, _ query: String) {
        let searchTab = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(searchTab.waitForExistence(timeout: 30), "Search tab never appeared")
        searchTab.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Search field never appeared")
        field.tap()
        field.typeText(query)
        Thread.sleep(forTimeInterval: 8)
    }

    /// The reported case: "japanese denim" must produce a requestable row for the single.
    func testSingleTitleSurfacesRequestableAlbumRow() throws {
        let app = try launch()
        search(app, "japanese denim")

        let title = app.staticTexts["Japanese Denim"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 25), "No 'Japanese Denim' row in Discover results")
        XCTAssertTrue(
            app.staticTexts["Single · Daniel Caesar"].firstMatch.exists,
            "Row is not labelled as the single by Daniel Caesar"
        )
        XCTAssertTrue(app.buttons["Request"].firstMatch.exists, "Row has no Request affordance")
    }

    /// Tapping Request drives the normal Lidarr enqueue path. The assertions on what Lidarr
    /// actually received are made against the stub's request log, on the host.
    func testRequestingTheSingleEnqueues() throws {
        let app = try launch()
        search(app, "japanese denim")

        let request = app.buttons["Request"].firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 25), "No Request button to tap")
        request.tap()
        // add + monitor + AlbumSearch, with the plugin's own retry sleeps in between.
        Thread.sleep(forTimeInterval: 12)
    }

    /// No regression to artist priority: an artist query still puts the artist row first, even
    /// though the same query now also returns album rows.
    func testArtistRowStillOutranksAlbumRows() throws {
        let app = try launch()
        search(app, "Daniel Caesar")

        let artistRow = app.staticTexts["Daniel Caesar"].firstMatch
        let albumRow = app.staticTexts["Japanese Denim"].firstMatch
        XCTAssertTrue(artistRow.waitForExistence(timeout: 25), "No artist row for 'Daniel Caesar'")
        XCTAssertTrue(albumRow.waitForExistence(timeout: 25), "No album row for 'Daniel Caesar'")
        XCTAssertLessThan(
            artistRow.frame.minY,
            albumRow.frame.minY,
            "An album row was placed above the artist row"
        )
    }

    /// A release the Navidrome server already has must not also appear as something to request.
    /// `Can I Have Your Love Tonight` is a real one-track album on the public demo server, and
    /// the stub returns a Lidarr row for the same title + artist.
    func testReleaseAlreadyOnTheServerProducesNoRequestRow() throws {
        let app = try launch()
        search(app, "Can I Have Your Love Tonight")

        XCTAssertTrue(
            app.staticTexts["Can I Have Your Love Tonight"].firstMatch.waitForExistence(timeout: 25),
            "Server result for the demo-server single never appeared"
        )
        XCTAssertFalse(
            app.buttons["Request"].firstMatch.exists,
            "A release already on the server produced a duplicate acquire row"
        )
    }
}

/// T069 — what order the Discover feed actually comes back in.
///
/// These tests **dump the observed order** rather than asserting a hand-written one, so the
/// report can quote what the app did instead of what it was expected to do. Each row renders a
/// title and a subtitle, so the dump reads title / subtitle / title / subtitle down the screen.
final class DiscoverSearchOrderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() throws -> XCUIApplication {
        try StubLidarr.skipUnlessRunning()
        let app = XCUIApplication()
        app.launchArguments += StubLidarr.launchArguments
        app.launch()
        SimulatorSignIn.ensureSignedIn(app)
        return app
    }

    private func search(_ app: XCUIApplication, _ query: String) {
        let searchTab = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(searchTab.waitForExistence(timeout: 30), "Search tab never appeared")
        searchTab.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Search field never appeared")
        field.tap()
        field.typeText(query)
        Thread.sleep(forTimeInterval: 9)
    }

    /// Every visible result label, top to bottom. Screen order, not tree order — the element
    /// tree does not promise to match layout, and layout is the thing under test.
    @discardableResult
    private func dumpOrder(_ app: XCUIApplication, _ label: String) -> [String] {
        struct Cell {
            let y: CGFloat
            let x: CGFloat
            let text: String
        }
        var cells: [Cell] = []
        for element in app.staticTexts.allElementsBoundByIndex {
            guard element.exists, element.isHittable else { continue }
            let text = element.label
            guard !text.isEmpty else { continue }
            let frame = element.frame
            cells.append(Cell(y: frame.minY, x: frame.minX, text: text))
        }
        cells.sort { lhs, rhs in
            lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
        }
        let rows = cells.map(\.text)
        print("OBSERVED-ORDER [\(label)] BEGIN")
        for (i, row) in rows.enumerated() { print(String(format: "OBSERVED %02d %@", i, row)) }
        print("OBSERVED-ORDER [\(label)] END")
        return rows
    }

    /// The feed is a lazy list, so anything below the fold is simply not in the element tree.
    /// Scroll once and dump again — printed raw, as its own pass, rather than merged, so a
    /// duplicate that straddles the fold is still visible in the report instead of being
    /// deduplicated by the harness that is supposed to be looking for duplicates.
    private func dumpBelowTheFold(_ app: XCUIApplication, _ label: String) {
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.5)
        dumpOrder(app, "\(label) — after scroll")
    }

    func testOrderForJapaneseDe() throws {
        let app = try launch()
        search(app, "japanese de")
        let rows = dumpOrder(app, "japanese de")

        // A title alone is ambiguous — "Japanese Death Machine" is both an EP and an artist here,
        // which is exactly the trap the first version of this test fell into. An artist row is the
        // one whose following line reads "Artist".
        func indexOfArtistRow(_ name: String) -> Int? {
            rows.indices.first { rows[$0] == name && $0 + 1 < rows.count && rows[$0 + 1] == "Artist" }
        }
        func indexOfReleaseRow(_ title: String) -> Int? {
            rows.indices.first { rows[$0] == title && $0 + 1 < rows.count && rows[$0 + 1] != "Artist" }
        }
        guard let denim = indexOfReleaseRow("Japanese Denim") else {
            return XCTFail("No 'Japanese Denim' release row at all. Observed: \(rows)")
        }
        for artist in ["Japanese Deejay", "Japanese Death Machine", "DJ.Deplorer"] {
            if let i = indexOfArtistRow(artist) {
                XCTAssertLessThan(denim, i, "'Japanese Denim' is below the artist '\(artist)'")
            }
        }
        // Defect 2: no release may appear twice. Chrome repeats legitimately ("Request" once per
        // row, "Artist" once per artist row), as do subtitles, so only title lines are counted —
        // and a title that is genuinely both an artist and a release is counted once each.
        let chrome: Set<String> = ["Request", "Artist", "Top Results"]
        var titleCounts: [String: Int] = [:]
        for (i, row) in rows.enumerated() {
            guard !chrome.contains(row), !row.contains(" · ") else { continue }
            guard i + 1 < rows.count else { continue }
            let kind = rows[i + 1] == "Artist" ? "artist" : "release"
            titleCounts["\(kind): \(row)", default: 0] += 1
        }
        let duplicated = titleCounts.filter { $0.value > 1 }.keys.sorted()
        XCTAssertTrue(duplicated.isEmpty, "Duplicated rows: \(duplicated). Observed: \(rows)")

        dumpBelowTheFold(app, "japanese de")
    }

    func testOrderForDeftones() throws {
        let app = try launch()
        search(app, "deftones")
        let rows = dumpOrder(app, "deftones")
        guard let first = rows.firstIndex(where: { $0 == "Deftones" }) else {
            return XCTFail("No 'Deftones' row at all. Observed: \(rows)")
        }
        // The artist row's subtitle is "Artist"; the eponymous album's is "Album · Deftones".
        // Whichever "Deftones" comes first, the row under it says which kind it is.
        XCTAssertLessThan(first, rows.count - 1, "Nothing under the first Deftones row")
        XCTAssertEqual(rows[first + 1], "Artist", "The first 'Deftones' row is not the artist")
    }

    func testOrderForPartialArtistName() throws {
        let app = try launch()
        search(app, "dafto")
        dumpOrder(app, "dafto")
    }

    /// Regression guard for T068: the release-already-on-the-server rule still holds after
    /// being moved from `runHybridSearch` into `hybridRows`.
    func testServerReleaseStillProducesNoRequestRow() throws {
        let app = try launch()
        search(app, "Can I Have Your Love Tonight")
        let rows = dumpOrder(app, "Can I Have Your Love Tonight")
        XCTAssertFalse(
            app.buttons["Request"].firstMatch.exists,
            "A release already on the server produced an acquire row. Observed: \(rows)"
        )
    }
}
