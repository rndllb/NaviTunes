import XCTest

/// End-to-end verification of the Apple-Music-style add-to-playlist sheet:
/// chrome (X / centered title / sort menu), "Find in Playlists" search, the
/// five sort options, multi-select mode, create-playlist-from-flow seeding,
/// and the Recents section with its "Song already in playlist" subtitle.
///
/// Creates one scratch playlist ("lyra ui test …") on the connected server and
/// deletes it again through the app's debug remote at the end.
final class AddToPlaylistSheetTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAddToPlaylistSheetFlow() throws {
        let app = XCUIApplication()
        app.launch()
        Thread.sleep(forTimeInterval: 4)

        // Open the sheet via the debug remote (any resolvable track).
        post("com.lyra.debug.addToPlaylist")

        XCTAssertTrue(app.navigationBars["Add to Playlist"].waitForExistence(timeout: 10), "sheet did not open")
        XCTAssertTrue(app.searchFields["Find in Playlists"].waitForExistence(timeout: 5), "search prompt missing")
        XCTAssertTrue(app.staticTexts["All Playlists"].waitForExistence(timeout: 5), "All Playlists header missing")
        XCTAssertTrue(app.buttons["Close"].exists, "X close button missing")
        shot(app, "01-sheet-open")

        // Sort menu: five options.
        app.buttons["Sort playlists"].tap()
        for option in ["Title", "Date Added", "Last Played", "Updated Date", "Playlist Type"] {
            XCTAssertTrue(app.buttons[option].waitForExistence(timeout: 3), "missing sort option \(option)")
        }
        shot(app, "02-sort-menu")
        app.buttons["Title"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        app.buttons["Sort playlists"].tap()
        XCTAssertTrue(app.buttons["Playlist Type"].waitForExistence(timeout: 3))
        app.buttons["Playlist Type"].tap()
        Thread.sleep(forTimeInterval: 0.6)

        // Multi-select mode: Add appears top-right, rows become selectable.
        app.buttons["Select multiple playlists"].tap()
        let addButton = app.buttons["Add to selected playlists"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 3), "Add button missing in multi-select mode")
        XCTAssertFalse(addButton.isEnabled, "Add should be disabled with nothing selected")
        let firstCell = app.cells.element(boundBy: 0)
        let secondCell = app.cells.element(boundBy: 1)
        XCTAssertTrue(firstCell.waitForExistence(timeout: 3))
        firstCell.tap()
        secondCell.tap()
        XCTAssertTrue(addButton.isEnabled, "Add should enable once playlists are selected")
        shot(app, "03-multi-select")
        // Leave selection mode without committing (no server mutation here).
        app.buttons["Stop selecting playlists"].tap()
        Thread.sleep(forTimeInterval: 0.4)

        // Create a playlist from the + menu — the pending song must be seeded.
        let scratchName = "lyra ui test \(Int.random(in: 1000...9999))"
        app.buttons["New playlist or folder"].tap()
        XCTAssertTrue(app.buttons["New Folder"].waitForExistence(timeout: 3), "New Folder menu item missing")
        XCTAssertTrue(app.buttons["New Playlist"].waitForExistence(timeout: 3), "New Playlist menu item missing")
        shot(app, "04-plus-menu")
        app.buttons["New Playlist"].tap()

        let nameField = app.textFields["Playlist name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "create sheet did not open")
        nameField.tap()
        nameField.typeText(scratchName)
        shot(app, "05-new-playlist")
        app.buttons["Done"].tap()

        // Both sheets close on success. (The 1.8s confirmation toast is verified
        // separately via the com.lyra.debug.toast hook — XCUITest's AX polling
        // is too slow to reliably catch it mid sheet-dismissal animation.)
        let dismissed = NSPredicate(format: "exists == false")
        let gone = expectation(for: dismissed, evaluatedWith: app.navigationBars["Add to Playlist"])
        wait(for: [gone], timeout: 15)
        shot(app, "06-after-create")

        // Reopen: the scratch playlist now leads Recents, marked already-added.
        Thread.sleep(forTimeInterval: 2)
        post("com.lyra.debug.addToPlaylist")
        XCTAssertTrue(app.navigationBars["Add to Playlist"].waitForExistence(timeout: 10), "sheet did not reopen")
        XCTAssertTrue(app.staticTexts["Recents"].waitForExistence(timeout: 5), "Recents section missing")
        XCTAssertTrue(app.staticTexts[scratchName].waitForExistence(timeout: 5), "scratch playlist missing from Recents")
        XCTAssertTrue(
            app.staticTexts["Song already in playlist"].waitForExistence(timeout: 8),
            "already-in-playlist subtitle missing"
        )
        shot(app, "07-recents")

        // Tapping it again must dedupe (cached rows short-circuit the add) and
        // dismiss the sheet.
        app.staticTexts[scratchName].firstMatch.tap()
        let dedupeGone = expectation(for: dismissed, evaluatedWith: app.navigationBars["Add to Playlist"])
        wait(for: [dedupeGone], timeout: 15)
        shot(app, "08-after-dedupe-tap")

        // Cleanup: remove the scratch playlist from the server.
        post("com.lyra.debug.deleteUITestPlaylists")
        Thread.sleep(forTimeInterval: 3)
    }

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
