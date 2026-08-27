import XCTest

final class VellumMusicUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    }

    func testSignInReachesLibrary() {
        let app = XCUIApplication()
        app.launch()
        SimulatorSignIn.ensureSignedIn(app)
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
    }
}
