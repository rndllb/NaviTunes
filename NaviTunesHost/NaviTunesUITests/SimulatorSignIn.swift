import XCTest

/// Signs the simulator in to the public Navidrome demo server.
///
/// Queries here are taken from the real `LoginView` element tree, not guessed: the server
/// field carries `.accessibilityLabel("Server URL")`, username/password are placeholder-titled
/// `TextField`/`SecureField`, the backend picker is a segmented `Picker`, and the submit button
/// is titled **LOGIN** (not "Sign In").
enum SimulatorSignIn {
    /// Public demo server — never use real credentials in tests.
    static let serverURL = "https://demo.navidrome.org"
    static let username = "demo"
    static let password = "demo"

    /// Idempotent: returns immediately if already signed in. Sign-in persists across launches,
    /// so only the first run of a fresh install pays the network cost.
    static func ensureSignedIn(_ app: XCUIApplication) {
        // The tab bar only exists once signed in.
        if app.tabBars.firstMatch.waitForExistence(timeout: 8) { return }

        let server = app.textFields["Server URL"]
        XCTAssertTrue(server.waitForExistence(timeout: 20), "Sign-in form did not appear")

        // The segmented backend picker: the demo server speaks Subsonic, so pick Navidrome.
        let navidrome = app.buttons["Navidrome"].firstMatch
        if navidrome.exists, !navidrome.isSelected {
            navidrome.tap()
        }

        replaceText(in: server, with: serverURL)
        replaceText(in: app.textFields["Username"], with: username)
        replaceText(in: app.secureTextFields["Password"], with: password)

        let login = app.buttons["LOGIN"].firstMatch
        XCTAssertTrue(login.waitForExistence(timeout: 5), "LOGIN button not found")
        login.tap()

        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 90),
            "Did not reach the signed-in shell"
        )
    }

    /// Clears whatever the field already holds before typing — a half-remembered draft from a
    /// previous run would otherwise be concatenated with the new value.
    private static func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Field \(field) not found")
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
    }
}
