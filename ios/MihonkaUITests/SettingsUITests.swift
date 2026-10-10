import XCTest

/// Enters a real server in Settings and waits for the connection status. Skipped unless
/// `TEST_RUNNER_KAVITA_LIVE_URL` and `TEST_RUNNER_KAVITA_LIVE_KEY` are set. A screenshot is
/// written to `TEST_RUNNER_SCREENSHOT_DIR` when given.
final class SettingsUITests: XCTestCase {
    @MainActor
    func testConnectsToTheServer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["KAVITA_LIVE_URL"], let key = env["KAVITA_LIVE_KEY"] else {
            throw XCTSkip("Set KAVITA_LIVE_URL and KAVITA_LIVE_KEY to run against a real server")
        }
        let app = XCUIApplication()
        app.launch()
        app.buttons["Settings"].firstMatch.tap()

        let server = app.textFields["kavita.serverURL"]
        server.clearText()
        server.typeText(url)
        let apiKey = app.secureTextFields["kavita.apiKey"]
        apiKey.clearText()
        apiKey.typeText(key)

        let connected = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Connected to Kavita'")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 20))

        if let dir = env["SCREENSHOT_DIR"] {
            let name = UIDevice.current.userInterfaceIdiom == .pad ? "settings-ipad.png" : "settings-iphone.png"
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(filePath: dir).appending(path: name))
        }
    }
}

private extension XCUIElement {
    /// Focuses the field with the cursor at the end (a plain tap can land mid-text), then
    /// deletes what's there, e.g. values saved by an earlier run.
    func clearText() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        guard let value = value as? String, !value.isEmpty, value != placeholderValue else { return }
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    }
}
