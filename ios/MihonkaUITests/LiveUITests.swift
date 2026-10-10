import XCTest

/// Drives the app against a real Kavita server. Skipped unless `TEST_RUNNER_KAVITA_LIVE_URL` and
/// `TEST_RUNNER_KAVITA_LIVE_KEY` are set. Screenshots go to `TEST_RUNNER_SCREENSHOT_DIR` when given.
final class LiveUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    @MainActor
    func testConnectsToTheServer() throws {
        let app = try launchConnected()
        screenshot("settings")
        _ = app
    }

    @MainActor
    func testBrowsesKavitaAndAddsASeriesToTheLibrary() throws {
        let app = try launchConnected()

        app.buttons["Browse"].firstMatch.tap()
        app.buttons["Kavita"].firstMatch.tap()
        let first = app.descendants(matching: .any).matching(identifier: "browse.series").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), "no series in browse")
        let title = first.label
        Thread.sleep(forTimeInterval: 3) // let the covers load for the screenshot
        screenshot("browse")

        first.press(forDuration: 1.0)
        let add = app.buttons["Add to Library"]
        if add.waitForExistence(timeout: 5) {
            add.tap()
        } else {
            // Already in the library from an earlier run; dismiss the menu.
            app.buttons["Remove from Library"].firstMatch.tap()
            first.press(forDuration: 1.0)
            app.buttons["Add to Library"].tap()
        }

        app.buttons["Library"].firstMatch.tap()
        let added = app.descendants(matching: .any).matching(identifier: "library.series").firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 5), "series not in the library")
        XCTAssertTrue(title.hasPrefix(added.label), "library shows \(added.label), browse showed \(title)")
        screenshot("library")

        added.press(forDuration: 1.0)
        app.buttons["Remove from Library"].tap()
        XCTAssertTrue(app.staticTexts["Your Library Is Empty"].waitForExistence(timeout: 5))
    }

    /// Launches the app and enters the live server in Settings, waiting until it connects.
    @MainActor
    private func launchConnected() throws -> XCUIApplication {
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
        XCTAssertTrue(connected.waitForExistence(timeout: 20), "not connected")
        // Let the debounced save finish before leaving Settings.
        Thread.sleep(forTimeInterval: 0.5)
        return app
    }

    @MainActor
    private func screenshot(_ name: String) {
        guard let dir = env["SCREENSHOT_DIR"] else { return }
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(filePath: dir).appending(path: "\(name)-\(idiom).png"))
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
