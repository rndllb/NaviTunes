import XCTest

/// Reproduction harness for the reported bug: with the player's queue open, dragging **down**
/// over the queue list is supposed to page up to the History section, and sometimes instead
/// dismisses the whole player.
///
/// The state is reached without tapping through the library — `DebugUIRemote`'s Darwin hooks
/// start a full album (so the queue list overflows its page) and open the cover.
final class QueueHistorySwipeTests: XCTestCase {
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

    /// Signed in, playing an album, player open, queue tab showing.
    private func openQueue(_ app: XCUIApplication) {
        app.launch()
        SimulatorSignIn.ensureSignedIn(app)

        post("com.vellum.debug.playQueue")
        // Playback has to resolve from the network before the pill exists.
        Thread.sleep(forTimeInterval: 12)
        post("com.vellum.debug.openPlayer")

        let queueButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(queueButton.waitForExistence(timeout: 20), "Player did not open")
        // Let the open transition settle — the dismiss pan refuses to start until it has.
        Thread.sleep(forTimeInterval: 2)
        queueButton.tap()
        Thread.sleep(forTimeInterval: 2)
    }

    /// The drag under test: finger down, over the middle of the queue list.
    private func dragDown(_ app: XCUIApplication, velocity: XCUIGestureVelocity) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 2)
    }

    private func assertStillInPlayer(_ app: XCUIApplication, _ label: String) {
        let stillOpen = app.buttons["list.bullet"].firstMatch.exists
        let history = app.staticTexts["History"].firstMatch.exists
        XCTAssertTrue(stillOpen, "\(label): the player was dismissed by the swipe")
        XCTAssertTrue(history, "\(label): History did not come into view")
    }

    func testSlowDragDownRevealsHistory() {
        let app = XCUIApplication()
        openQueue(app)
        dragDown(app, velocity: .slow)
        assertStillInPlayer(app, "slow drag")
    }

    func testFlickDownRevealsHistory() {
        let app = XCUIApplication()
        openQueue(app)
        dragDown(app, velocity: .default)
        assertStillInPlayer(app, "flick")
    }

    /// The dismiss itself: with no queue open there is no scroll view under the finger, so a
    /// downward drag still closes the player.
    func testDragDownWithoutQueueDismissesPlayer() {
        let app = XCUIApplication()
        openQueue(app)
        app.buttons["list.bullet"].firstMatch.tap()   // back to the plain player
        Thread.sleep(forTimeInterval: 2)
        dragDown(app, velocity: .slow)
        XCTAssertFalse(
            app.buttons["list.bullet"].firstMatch.exists,
            "the player should still close when the queue is not open"
        )
    }

    /// With the queue open the drag handle is the way out — it sits above the list, so no
    /// scroll view claims the drag.
    func testDragFromHandleDismissesPlayerWithQueueOpen() {
        let app = XCUIApplication()
        openQueue(app)
        let handle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        handle.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(
            app.buttons["list.bullet"].firstMatch.exists,
            "dragging the handle should still close the player"
        )
    }

    /// The same drag after the queue list has been scrolled down and back — the state the
    /// report says usually works.
    func testDragDownAfterScrollingQueueRevealsHistory() {
        let app = XCUIApplication()
        openQueue(app)
        let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        low.press(forDuration: 0.1, thenDragTo: high, withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 1)
        dragDown(app, velocity: .slow)
        assertStillInPlayer(app, "after scrolling the queue")
    }
}
