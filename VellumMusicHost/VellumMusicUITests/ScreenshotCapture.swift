import XCTest

enum ScreenshotCapture {
    /// Attaches a full-screen screenshot to the test result, kept regardless of outcome so
    /// it can be exported and inspected by eye.
    static func capture(_ app: XCUIApplication, name: String, in testCase: XCTestCase) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}
