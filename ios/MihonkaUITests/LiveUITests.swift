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

    @MainActor
    func testOpensASeriesAndMarksAChapterRead() throws {
        let app = try launchConnected()
        app.buttons["Browse"].firstMatch.tap()
        app.buttons["Kavita"].firstMatch.tap()
        let first = app.descendants(matching: .any).matching(identifier: "browse.series").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), "no series in browse")
        first.tap()

        let row = app.descendants(matching: .any).matching(identifier: "chapter.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no chapters")
        Thread.sleep(forTimeInterval: 2) // cover and details
        screenshot("series")

        // The row may start read, unread or part-read (from the server), so go to Read first.
        if row.value as? String != "Read" {
            row.swipeRight()
            app.buttons["Mark as Read"].firstMatch.tap()
        }
        XCTAssertTrue(waitFor(row, value: "Read"))

        row.press(forDuration: 1.0)
        app.buttons["Mark as Unread"].tap()
        XCTAssertTrue(waitFor(row, value: "Unread"))

        let library = app.buttons["series.library"]
        let wasInLibrary = library.label == "In Library"
        library.tap()
        XCTAssertTrue(app.buttons[wasInLibrary ? "Add to Library" : "In Library"].waitForExistence(timeout: 3))
        library.tap()
        XCTAssertTrue(app.buttons[wasInLibrary ? "In Library" : "Add to Library"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testReadsAChapterAndResumesThere() throws {
        let app = try launchConnected()
        app.buttons["Browse"].firstMatch.tap()
        app.buttons["Kavita"].firstMatch.tap()
        let first = app.descendants(matching: .any).matching(identifier: "browse.series").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), "no series in browse")
        first.tap()

        // Start the first chapter from page 1: mark it unread, then open it.
        let row = app.descendants(matching: .any).matching(identifier: "chapter.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no chapters")
        if row.value as? String != "Unread" {
            if row.value as? String != "Read" {
                row.swipeRight()
                app.buttons["Mark as Read"].firstMatch.tap()
            }
            row.press(forDuration: 1.0)
            app.buttons["Mark as Unread"].tap()
        }
        XCTAssertTrue(waitFor(row, value: "Unread"))
        row.tap()

        let pages = app.collectionViews["reader.pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 10), "reader didn't open")
        let firstPage = pages.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Page 1 of'")).firstMatch
        XCTAssertTrue(firstPage.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(firstPage, value: "Loaded", timeout: 20), "page 1 didn't load")
        screenshot("reader")

        // Right to left by default: the left third turns to the next page.
        pages.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        let secondPage = pages.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Page 2 of'")).firstMatch
        XCTAssertTrue(secondPage.waitForExistence(timeout: 5), "didn't turn to page 2")

        // The middle shows the overlay with the page position.
        pages.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let slider = app.descendants(matching: .any).matching(identifier: "reader.page").firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        XCTAssertTrue((slider.value as? String)?.hasPrefix("2 of") ?? false, "\(slider.value ?? "nil")")
        screenshot("reader-overlay")

        // Next chapter from the overlay, then back to the series.
        let chapterTitle = NSPredicate(format: "label BEGINSWITH 'Vol.' OR label BEGINSWITH 'Ch.' OR label BEGINSWITH 'Volume'")
        let title = app.staticTexts.matching(chapterTitle).firstMatch
        let firstTitle = title.label
        app.buttons["Next chapter"].tap()
        XCTAssertTrue(waitFor(slider, value: "1 of", prefix: true))
        XCTAssertNotEqual(title.label, firstTitle)

        app.buttons["reader.close"].tap()
        XCTAssertTrue(waitFor(row, value: "Page 2 of", prefix: true), "progress not shown: \(row.value ?? "nil")")
    }

    @MainActor
    func testReadsInSpreadsAndInWebtoonMode() throws {
        let app = try launchConnected()
        let spreads = app.switches["Two-page spreads in landscape"]
        XCTAssertTrue(spreads.waitForExistence(timeout: 5))
        setSwitch(spreads, on: true)
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }

        app.buttons["Browse"].firstMatch.tap()
        app.buttons["Kavita"].firstMatch.tap()
        let first = app.descendants(matching: .any).matching(identifier: "browse.series").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), "no series in browse")
        first.tap()
        let row = app.descendants(matching: .any).matching(identifier: "chapter.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no chapters")
        row.tap()

        let pages = app.collectionViews["reader.pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 10), "reader didn't open")
        setMode(app, pages, "Right to left")

        // Landscape pairs pages; the cover stands alone, so a page or two on there's a pair.
        XCUIDevice.shared.orientation = .landscapeLeft
        let pair = pages.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Pages '")).firstMatch
        for _ in 0..<2 where !pair.waitForExistence(timeout: 3) {
            pages.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        }
        XCTAssertTrue(pair.waitForExistence(timeout: 5), "no two-page spread in landscape")
        XCTAssertTrue(waitFor(pair, value: "Loaded", timeout: 20), "the spread didn't load")
        hideOverlay(app, pages)
        screenshot("spreads")
        XCUIDevice.shared.orientation = .portrait

        // Webtoon: scrolling down moves through the pages.
        setMode(app, pages, "Webtoon")
        let loaded = pages.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Page ' AND value == 'Loaded'"))
        XCTAssertTrue(loaded.firstMatch.waitForExistence(timeout: 20), "no webtoon page loaded")
        // The overlay is still up from picking the mode.
        let slider = app.descendants(matching: .any).matching(identifier: "reader.page").firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        let before = pageNumber(slider)
        hideOverlay(app, pages)
        for _ in 0..<4 {
            pages.swipeUp(velocity: .fast)
        }
        Thread.sleep(forTimeInterval: 2) // let the pages load for the screenshot
        screenshot("webtoon")
        pages.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(pageNumber(slider), before, "scrolling didn't move on")

        // Leave the series as the other tests expect it, and spreads off.
        setMode(app, pages, "Right to left")
        app.buttons["reader.close"].tap()
        app.buttons["Settings"].firstMatch.tap()
        setSwitch(spreads, on: false)
    }

    /// Picks a mode from the reader's menu, showing the overlay first if needed.
    @MainActor
    private func setMode(_ app: XCUIApplication, _ pages: XCUIElement, _ mode: String) {
        let menu = app.buttons["reader.settings"]
        if !menu.exists || !menu.isHittable {
            pages.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        app.buttons[mode].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    @MainActor
    private func hideOverlay(_ app: XCUIApplication, _ pages: XCUIElement) {
        guard app.buttons["reader.close"].exists else { return }
        pages.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = app.buttons["reader.close"].waitForNonExistence(timeout: 3)
    }

    /// The current page from the slider's value, "3 of 57".
    @MainActor
    private func pageNumber(_ slider: XCUIElement) -> Int {
        Int((slider.value as? String)?.split(separator: " ").first ?? "") ?? 0
    }

    @MainActor
    private func setSwitch(_ toggle: XCUIElement, on isOn: Bool) {
        guard (toggle.value as? String == "1") != isOn else { return }
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(waitFor(toggle, value: isOn ? "1" : "0"))
    }

    private func waitFor(_ element: XCUIElement, value: String, prefix: Bool = false, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: prefix ? "value BEGINSWITH %@" : "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
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
