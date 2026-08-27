import XCTest

/// Reported: lyrics do not load for a song started from the player's History list.
///
/// The demo server has lyrics for exactly one easy-to-find track — pornophonique's
/// "lemmings in love" — so the seeded history entry and the assertion both key off it.
final class HistoryPlaybackLyricsTests: XCTestCase {
    private let lyricLine = "sometimes i fear the reaper"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    /// Baseline: the same track, played the ordinary way, does show its lyrics. If this
    /// fails the server or the whole lyrics path is at fault, not the history row.
    func testLyricsLoadForATrackPlayedNormally() {
        let app = XCUIApplication()
        app.launch()
        SimulatorSignIn.ensureSignedIn(app)
        post("com.vellum.debug.playHistoryQuery")
        Thread.sleep(forTimeInterval: 14)
        post("com.vellum.debug.openPlayer")
        openLyrics(app)
        XCTAssertTrue(
            app.staticTexts[lyricLine].waitForExistence(timeout: 20),
            "lyrics did not load for a normally-played track"
        )
    }

    /// The everyday case: the history entry is still sitting in the queue you are playing, so
    /// the row jumps within the queue instead of starting a fresh one. Playing the album the
    /// lyrics track belongs to puts it at index 2 while track 1 plays.
    func testLyricsLoadForAHistoryTrackStillInTheQueue() {
        let app = XCUIApplication()
        app.launchEnvironment["VELLUM_DEBUG_ALBUM_QUERY"] = "8-bit lagerfeuer"
        app.launch()
        SimulatorSignIn.ensureSignedIn(app)

        post("com.vellum.debug.seedHistory")
        post("com.vellum.debug.playQueue")
        Thread.sleep(forTimeInterval: 14)
        post("com.vellum.debug.openPlayer")
        openHistory(app)

        let row = app.staticTexts["lemmings in love"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded history row not found")
        row.tap()
        Thread.sleep(forTimeInterval: 12)

        openLyrics(app)
        XCTAssertTrue(
            app.staticTexts[lyricLine].waitForExistence(timeout: 20),
            "lyrics did not load for a history track that was still in the queue"
        )
    }

    func testLyricsLoadForATrackPlayedFromHistory() {
        let app = XCUIApplication()
        app.launch()
        SimulatorSignIn.ensureSignedIn(app)

        post("com.vellum.debug.seedHistory")
        post("com.vellum.debug.playQueue")
        Thread.sleep(forTimeInterval: 14)
        post("com.vellum.debug.openPlayer")

        openHistory(app)

        let row = app.staticTexts["lemmings in love"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded history row not found")
        row.tap()
        Thread.sleep(forTimeInterval: 12)

        openLyrics(app)
        XCTAssertTrue(
            app.staticTexts[lyricLine].waitForExistence(timeout: 20),
            "lyrics did not load for a track played from History"
        )
    }

    /// Opens the queue and pages up to the History section.
    private func openHistory(_ app: XCUIApplication) {
        let queueButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(queueButton.waitForExistence(timeout: 20), "player did not open")
        Thread.sleep(forTimeInterval: 2)
        queueButton.tap()
        Thread.sleep(forTimeInterval: 2)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 2)
    }

    /// Leaves the queue (if it is showing) and switches the player to lyrics.
    private func openLyrics(_ app: XCUIApplication) {
        let queueButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(queueButton.waitForExistence(timeout: 20), "player is not open")
        let lyricsButton = app.buttons["quote.bubble"].firstMatch
        if lyricsButton.exists {
            lyricsButton.tap()
        } else {
            app.buttons["quote.bubble.fill"].firstMatch.tap()
        }
        Thread.sleep(forTimeInterval: 2)
    }
}
