import XCTest

/// Signs the simulator in to the T344 triage server as `vellum-test`.
///
/// Deliberately separate from ``SimulatorSignIn``, which is pinned to
/// `demo.navidrome.org`. The triage run must not touch that host: it is a third
/// party's public instance, and writing to it falls outside T344's destructive
/// boundary, which permits the throwaway account's own data and nothing else.
///
/// Credentials come from the test-runner environment, never from this file — the
/// repository has a remote, and a working password in tracked source would
/// outlive the run. Inject them with xcodebuild's `TEST_RUNNER_` passthrough,
/// which strips the prefix before handing the variable to the runner process:
///
///     xcodebuild test-without-building \
///       -workspace VellumMusicHost/VellumMusicHost.xcodeproj/project.xcworkspace \
///       -scheme VellumMusicHost \
///       -destination 'id=<udid>' \
///       -only-testing:VellumMusicUITests/VellumTestSignInTests \
///       TEST_RUNNER_VELLUM_TEST_SERVER=http://host:4533 \
///       TEST_RUNNER_VELLUM_TEST_USER=vellum-test \
///       TEST_RUNNER_VELLUM_TEST_PASSWORD=...
enum VellumTestSignIn {
    enum MissingCredential: Error, CustomStringConvertible {
        case unset(String)

        var description: String {
            switch self {
            case .unset(let name):
                return """
                \(name) is not set in the test-runner environment. Pass it as \
                TEST_RUNNER_\(name)=<value> on the xcodebuild command line. This \
                helper never hardcodes credentials.
                """
            }
        }
    }

    private static func required(_ name: String) throws -> String {
        let value = ProcessInfo.processInfo.environment[name] ?? ""
        guard !value.isEmpty else { throw MissingCredential.unset(name) }
        return value
    }

    static func serverURL() throws -> String { try required("VELLUM_TEST_SERVER") }
    static func username() throws -> String { try required("VELLUM_TEST_USER") }
    static func password() throws -> String { try required("VELLUM_TEST_PASSWORD") }

    /// Drives the login form. Unlike ``SimulatorSignIn/ensureSignedIn(_:)`` this does
    /// **not** return early when a tab bar already exists: an existing session may be
    /// the wrong account, and silently keeping it is how a run ends up reproducing
    /// findings against the wrong server. Callers reset the simulator keychain first.
    static func signIn(_ app: XCUIApplication) throws {
        let server = app.textFields["Server URL"]
        XCTAssertTrue(
            server.waitForExistence(timeout: 30),
            "Login form did not appear — is a previous session still signed in? "
                + "Run `xcrun simctl keychain <udid> reset` before this test."
        )

        // The picker defaults to Jellyfin; the triage server speaks Subsonic.
        let navidrome = app.buttons["Navidrome"].firstMatch
        if navidrome.exists, !navidrome.isSelected {
            navidrome.tap()
        }

        try replaceText(in: server, with: serverURL())
        try replaceText(in: app.textFields["Username"], with: username())
        try replaceText(in: app.secureTextFields["Password"], with: password())

        let login = app.buttons["LOGIN"].firstMatch
        XCTAssertTrue(login.waitForExistence(timeout: 5), "LOGIN button not found")
        login.tap()

        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 120),
            "Did not reach the signed-in shell within 120s"
        )
    }

    /// Clears the field before typing; a half-remembered draft would otherwise be
    /// concatenated with the new value.
    private static func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Field \(field) not found")
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
    }
}

final class VellumTestSignInTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// c1: reach the signed-in shell against the triage server, with the library loaded.
    func testSignsInToTriageServer() throws {
        let app = XCUIApplication()
        app.launch()
        try VellumTestSignIn.signIn(app)

        XCTAssertTrue(
            app.tabBars.buttons["Library"].waitForExistence(timeout: 30),
            "Library tab never appeared"
        )
        app.tabBars.buttons["Library"].tap()
    }

    /// Drives a named surface so an external `simctl io recordVideo` capture has real
    /// motion *showing the finding*.
    ///
    /// Why this exists: `DebugUIRemote` has thirteen hooks but only one tab hook
    /// (`libraryTab`, hard-wired to `.library`), no Home/New/Settings hook, and
    /// `openPlayer` is inert with nothing playing. Notification-driven capture
    /// therefore films either the wrong screen or a static one — both of which pass
    /// a frame-count check while being useless as evidence. Scrolling needs touch,
    /// so it needs XCUITest.
    ///
    /// The steps are read from the runner environment rather than hardcoded, so one
    /// compiled bundle serves every finding — a new finding is a new step string, not a
    /// rebuild. Steps are separated by `;`, and each is `verb` or `verb:argument`:
    ///
    ///     TEST_RUNNER_VELLUM_DRIVE_STEPS='tab:Library;tap:Artists;wait:3;dump:artists'
    ///
    /// Verbs:
    /// - `tab:<name>` taps a tab-bar button.
    /// - `tap:<label>` taps the first hittable element whose label or identifier equals
    ///   `<label>`; `tapContains:<text>` matches a label substring instead.
    /// - `longPress:<label>` / `longPressContains:<text>` hold for 1.2 s.
    /// - `swipeUp` / `swipeDown` / `swipeLeft` / `swipeRight`, optionally `:<count>`.
    /// - `wait:<seconds>`; `waitFor:<label>` blocks up to 30 s for a label to exist.
    /// - `typeInto:<field label>=<text>` replaces the text of a text field.
    /// - `tapField:<label>` taps a search field (not the Search tab of the same name).
    /// - `back` taps the navigation bar's first button.
    /// - `home` backgrounds the app; `activate` foregrounds it; `relaunch` terminates
    ///   and launches.
    /// - `dump:<name>` prints the accessibility hierarchy between greppable markers,
    ///   which is how a finding about labels or traits gets runtime evidence.
    /// - `shot:<name>` attaches a full-screen screenshot.
    ///
    /// A step that cannot find its element fails the test loudly rather than skipping,
    /// so a recording can never silently show the wrong screen.
    func testDriveSurface() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 60),
            "Not signed in — the driver expects an established session"
        )

        let script = ProcessInfo.processInfo.environment["VELLUM_DRIVE_STEPS"] ?? ""
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertFalse(steps.isEmpty, "VELLUM_DRIVE_STEPS is empty")

        for (index, step) in steps.enumerated() where !step.isEmpty {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let verb = parts[0]
            let arg = parts.count > 1 ? parts[1] : ""
            print("VELLUM_STEP \(index) \(step) t=\(Date().timeIntervalSince1970)")
            try perform(verb: verb, arg: arg, in: app)
        }
        print("VELLUM_STEPS_DONE t=\(Date().timeIntervalSince1970)")
    }

    private func perform(verb: String, arg: String, in app: XCUIApplication) throws {
        switch verb {
        case "tab":
            let tab = app.tabBars.buttons[arg]
            XCTAssertTrue(tab.waitForExistence(timeout: 20), "tab '\(arg)' not found")
            tab.tap()
        case "tap":
            try element(labelled: arg, in: app).tap()
        case "tapContains":
            try element(containing: arg, in: app).tap()
        case "longPress":
            try element(labelled: arg, in: app).press(forDuration: 1.2)
        case "longPressContains":
            try element(containing: arg, in: app).press(forDuration: 1.2)
        case "swipeUp", "swipeDown", "swipeLeft", "swipeRight":
            for _ in 0..<(Int(arg) ?? 1) {
                switch verb {
                case "swipeUp": app.swipeUp()
                case "swipeDown": app.swipeDown()
                case "swipeLeft": app.swipeLeft()
                default: app.swipeRight()
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        case "wait":
            Thread.sleep(forTimeInterval: Double(arg) ?? 1)
        case "waitFor":
            _ = try element(labelled: arg, in: app, timeout: 30)
        case "typeInto":
            let pair = arg.split(separator: "=", maxSplits: 1).map(String.init)
            XCTAssertEqual(pair.count, 2, "typeInto expects <field>=<text>")
            let field = app.descendants(matching: .any)
                .matching(NSPredicate(format: "(elementType == %d OR elementType == %d) AND (label == %@ OR placeholderValue == %@ OR identifier == %@)",
                                      XCUIElement.ElementType.textField.rawValue,
                                      XCUIElement.ElementType.secureTextField.rawValue,
                                      pair[0], pair[0], pair[0]))
                .firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 15), "field '\(pair[0])' not found")
            field.tap()
            if let existing = field.value as? String, !existing.isEmpty, existing != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
            }
            field.typeText(pair[1])
        case "tapField":
            // A search field and the Search tab share the label "Search"; matching by
            // element type is the only way to hit the in-page field.
            let field = app.descendants(matching: .any)
                .matching(NSPredicate(format: "(elementType == %d OR elementType == %d) AND (label == %@ OR placeholderValue == %@)",
                                      XCUIElement.ElementType.searchField.rawValue,
                                      XCUIElement.ElementType.textField.rawValue,
                                      arg, arg))
                .firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 15), "search field '\(arg)' not found")
            field.tap()
        case "back":
            let back = app.navigationBars.buttons["BackButton"].exists
                ? app.navigationBars.buttons["BackButton"]
                : app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 10), "no navigation back button")
            back.tap()
        case "home":
            XCUIDevice.shared.press(.home)
        case "activate":
            app.activate()
        case "relaunch":
            app.terminate()
            app.launch()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60), "relaunch lost the session")
        case "dump":
            print("VELLUM_DUMP_BEGIN \(arg)")
            print(app.debugDescription)
            print("VELLUM_DUMP_END \(arg)")
        case "shot":
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = arg
            shot.lifetime = .keepAlways
            add(shot)
        default:
            XCTFail("unknown drive verb '\(verb)'")
        }
    }

    private func element(labelled label: String, in app: XCUIApplication, timeout: TimeInterval = 20) throws -> XCUIElement {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
        return try firstHittable(match, description: "'\(label)'", timeout: timeout)
    }

    private func element(containing text: String, in app: XCUIApplication) throws -> XCUIElement {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
        return try firstHittable(match, description: "containing '\(text)'", timeout: 20)
    }

    /// Prefers a hittable match: SwiftUI often exposes the same label on a container and
    /// its button, and tapping an off-screen twin films nothing.
    private func firstHittable(_ query: XCUIElementQuery, description: String, timeout: TimeInterval) throws -> XCUIElement {
        let first = query.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: timeout), "element \(description) not found")
        for candidate in query.allElementsBoundByIndex.prefix(12) where candidate.isHittable {
            return candidate
        }
        return first
    }

    /// c2: the session survives a relaunch with no credentials re-entered.
    func testSessionPersistsAcrossRelaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // No sign-in call here on purpose: if the session did not persist, the login
        // form appears and this fails, which is exactly the claim under test.
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 60),
            "Session did not persist across relaunch — login form returned"
        )
        XCTAssertFalse(
            app.textFields["Server URL"].exists,
            "Login form is present, so the session did not persist"
        )
    }
}
