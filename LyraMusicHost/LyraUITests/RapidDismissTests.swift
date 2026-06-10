import XCTest

/// Drives the exact reported repro with real HID events: open a playlist
/// whose tracklist is still loading, edge-swipe to dismiss it a split second
/// later, then immediately try to scroll the revealed Library list.
///
/// Two tricks keep the cadence rapid (the bug vanishes if any step waits):
/// - All gestures are issued through a SpringBoard `XCUIApplication` proxy.
///   Coordinates are screen-global either way, but events targeted at the
///   busy app would block on XCUITest's wait-for-idle; SpringBoard is always
///   idle, so events fire back-to-back.
/// - Navigation marks and app-side events land in one shared timeline file
///   via the app's `DebugUIRemote` (Darwin notifications), so the test, the
///   hang watcher, and the hydration pipeline can be correlated afterwards.
///
/// Launch the run with `TEST_RUNNER_LYRA_AB=old` to disable the dismiss
/// fixes inside the app (repro run); omit it for the fixed behavior.
final class RapidDismissTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRapidSwipeDismissDuringLoad() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LYRA_DEBUG_PLAYLIST"] = "rap v3"
        // Stretch the rows fetch so it completes inside the dismissal gesture
        // window — XCUITest's slow gesture synthesis would otherwise let the
        // fetch win the race that real fingers lose on device.
        app.launchEnvironment["LYRA_DEBUG_SLOW_ROWS_MS"] = "2600"
        if ProcessInfo.processInfo.environment["LYRA_AB"] == "old" {
            app.launchEnvironment["LYRA_DEBUG_DISABLE_DISMISS_FIXES"] = "1"
        }
        app.launch()

        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        post("com.lyra.debug.hangwatch")
        post("com.lyra.debug.libraryTab")
        Thread.sleep(forTimeInterval: 1.5)

        // Real tap on the pinned "rap v3" cell — the zoom transition source.
        let pin = app.staticTexts["rap v3"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 10), "pinned playlist cell not found")
        let pinFrame = pin.frame
        let screen = app.frame
        mark("tap-pin")
        coord(board, x: pinFrame.midX / screen.width, y: pinFrame.midY / screen.height).tap()

        // Split-second later: edge swipe to dismiss while the load is in flight.
        // Parameters proven by testSwipeBackVariants (variant 1) to engage the
        // interactive pop. TEST_RUNNER_LYRA_SWIPE_DELAY_MS tunes how deep into
        // the open the swipe lands (0 + UIAnimationDragCoefficient ≈ mid-push).
        let delayMs = Double(ProcessInfo.processInfo.environment["LYRA_SWIPE_DELAY_MS"] ?? "450") ?? 450
        Thread.sleep(forTimeInterval: delayMs / 1000)
        mark("edge-swipe-begin")
        let edge = coord(board, x: 0.001, y: 0.5)
        let across = coord(board, x: 0.9, y: 0.5)
        edge.press(forDuration: 0.01, thenDragTo: across, withVelocity: .default, thenHoldForDuration: 0)
        mark("edge-swipe-end")

        // Immediately: two scroll attempts on the revealed Library list.
        let mid = coord(board, x: 0.5, y: 0.75)
        let up = coord(board, x: 0.5, y: 0.35)
        mark("scroll-1")
        mid.press(forDuration: 0.03, thenDragTo: up, withVelocity: XCUIGestureVelocity(2000), thenHoldForDuration: 0)
        mark("scroll-2")
        mid.press(forDuration: 0.03, thenDragTo: up, withVelocity: XCUIGestureVelocity(2000), thenHoldForDuration: 0)
        mark("scroll-done")

        Thread.sleep(forTimeInterval: 2.5)
        mark("test-end")
    }

    /// Finds an edge-swipe synthesis that actually engages the interactive
    /// pop (springboard-proxy edge pans are unreliable). Requires a warm rows
    /// cache so the detail is settled. Success = Library content reappears.
    @MainActor
    func testSwipeBackVariants() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LYRA_DEBUG_PLAYLIST"] = "rap v3"
        app.launch()

        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        post("com.lyra.debug.hangwatch")
        post("com.lyra.debug.libraryTab")
        Thread.sleep(forTimeInterval: 1.5)

        let pin = app.staticTexts["rap v3"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 10))
        let pinFrame = pin.frame
        let screen = app.frame
        let libraryMarker = app.staticTexts["Playlists"].firstMatch

        func openDetail() {
            coord(board, x: pinFrame.midX / screen.width, y: pinFrame.midY / screen.height).tap()
            Thread.sleep(forTimeInterval: 2.0)
        }

        func backOnLibrary() -> Bool {
            libraryMarker.waitForExistence(timeout: 2.0)
        }

        openDetail()

        // 1: springboard proxy, x≈0, instant, default velocity
        mark("variant-1")
        coord(board, x: 0.001, y: 0.5)
            .press(forDuration: 0.01, thenDragTo: coord(board, x: 0.9, y: 0.5),
                   withVelocity: .default, thenHoldForDuration: 0)
        if backOnLibrary() { mark("variant-found"); return }

        // 2: springboard proxy, slower drag from 8pt in
        mark("variant-2")
        coord(board, x: 0.02, y: 0.4)
            .press(forDuration: 0.1, thenDragTo: coord(board, x: 0.85, y: 0.4),
                   withVelocity: XCUIGestureVelocity(600), thenHoldForDuration: 0.1)
        if backOnLibrary() { mark("variant-found"); return }

        // 3: app-space coordinates (pays quiescence, but warm = idle)
        mark("variant-3")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)),
                   withVelocity: .default, thenHoldForDuration: 0)
        if backOnLibrary() { mark("variant-found"); return }

        // 4: stock swipeRight on the app
        mark("variant-4")
        app.swipeRight()
        if backOnLibrary() { mark("variant-found"); return }

        // 5: stock swipeRight on the detail's first cell area via element query
        mark("variant-5")
        app.staticTexts["rap v3"].firstMatch.swipeRight()
        if backOnLibrary() { mark("variant-found"); return }

        mark("variant-none")
        XCTFail("no swipe variant dismissed the detail")
    }

    private func coord(_ board: XCUIApplication, x: Double, y: Double) -> XCUICoordinate {
        board.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    /// Timeline marker — lands in the app's shared verification log.
    private func mark(_ label: String) {
        post("com.lyra.debug.mark." + label)
    }
}
