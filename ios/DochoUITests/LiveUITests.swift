import XCTest

/// Drives the app against real Kavita and Komga servers, such as the Docker ones described in
/// PLAN-2.md. Skipped unless the servers are given:
///
///     TEST_RUNNER_DOCHO_KAVITA_URL / _KEY    a Kavita server and API key
///     TEST_RUNNER_DOCHO_KOMGA_URL / _KEY     a Komga server and API key (the progress checks)
///     TEST_RUNNER_DOCHO_KOMGA_SERIES         the name of a Komga series with 2+ books of 3+ pages
///     TEST_RUNNER_SCREENSHOT_DIR             where to save screenshots (optional)
///
/// The app starts from an empty library each time (`DOCHO_RESET`).
final class LiveUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Kavita

    @MainActor
    func testBrowsesKavitaAndAddsASeriesToTheLibrary() throws {
        let app = try launch(needsKomga: false)

        app.buttons["tab.browse"].tap()
        let kavita = app.buttons["browse.source.Kavita"]
        XCTAssertTrue(kavita.waitForExistence(timeout: 10), "Kavita isn't listed under Browse")
        screenshot(app, "browse")
        kavita.tap()
        let item = app.descendants(matching: .any).matching(identifier: "browse.item").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 20), "no series in browse")
        let title = item.label
        Thread.sleep(forTimeInterval: 2) // covers, for the screenshot
        screenshot(app, "browse-kavita")
        item.tap()

        let library = app.buttons["series.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chapter.row").firstMatch.waitForExistence(timeout: 20))
        screenshot(app, "series")
        library.tap()
        XCTAssertTrue(app.buttons["In library"].waitForExistence(timeout: 5))

        app.buttons["tab.library"].tap()
        let added = app.descendants(matching: .any).matching(identifier: "library.item").firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 5), "series not in the library")
        XCTAssertTrue(added.label.hasPrefix(title.components(separatedBy: ",")[0]), "library shows \(added.label), browse showed \(title)")
        screenshot(app, "library")
    }

    // MARK: Komga (PLAN-2 milestone 14)

    @MainActor
    func testReadsAKomgaBookAndSyncsProgressBothWays() async throws {
        let app = try launch(needsKomga: true)
        let komga = try XCTUnwrap(KomgaAPI(env))
        let series = try XCTUnwrap(env["DOCHO_KOMGA_SERIES"])
        let book = try await komga.firstBook(ofSeries: series)
        try await komga.markUnread(book)

        openKomgaSeries(app, named: series)
        let row = app.descendants(matching: .any).matching(identifier: "chapter.row")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "#1")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no first book")
        row.tap()

        // Turn to page 3 with taps on the next side of the screen (right to left by default).
        let pages = app.descendants(matching: .any).matching(identifier: "reader.pages").firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 20), "the reader didn't open")
        try await Task.sleep(for: .seconds(1))
        for _ in 0..<2 {
            pages.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            try await Task.sleep(for: .milliseconds(800))
        }
        screenshot(app, "reader")
        // The page goes to Komga after a short pause: page 3 (1-based).
        let sent = await eventually { (try? await komga.progress(book))?.page == 3 }
        XCTAssertTrue(sent, "Komga didn't get page 3")

        // Close, then set progress in Komga's own reader and reopen: the app shows it.
        pages.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["reader.close"].tap()
        try await komga.setPage(book, page: 5)
        app.buttons["More options"].firstMatch.tap()
        app.buttons["Refresh"].tap()
        let pulled = row.waitFor(labelContaining: "Page 5", timeout: 15)
        XCTAssertTrue(pulled, "Komga's page didn't come down: \(row.label)")

        // Marking unread in the app clears it in Komga.
        row.press(forDuration: 1.0)
        let unread = app.buttons["Mark as unread"]
        XCTAssertTrue(unread.waitForExistence(timeout: 5))
        unread.tap()
        let cleared = await eventually { (try? await komga.progress(book)) == nil }
        XCTAssertTrue(cleared, "marking unread didn't clear Komga's progress")
    }

    @MainActor
    func testDownloadsAChapterAndReadsItOffline() throws {
        let app = try launch(needsKomga: true)
        let series = try XCTUnwrap(env["DOCHO_KOMGA_SERIES"])
        openKomgaSeries(app, named: series)

        let download = app.buttons.matching(identifier: "chapter.download").element(boundBy: 0)
        XCTAssertTrue(download.waitForExistence(timeout: 20))
        download.tap()
        let downloaded = app.buttons.matching(identifier: "chapter.download")
            .matching(NSPredicate(format: "label == %@", "Delete download")).firstMatch
        XCTAssertTrue(downloaded.waitForExistence(timeout: 60), "the chapter didn't finish downloading")
        screenshot(app, "downloaded")

        // Break the server address, then read the downloaded chapter.
        app.terminate()
        app.launchEnvironment["DOCHO_KOMGA_URL"] = "http://127.0.0.1:9"
        app.launchEnvironment["DOCHO_RESET"] = "0"
        app.launch()
        openDownloadedSeries(app)
        let row = app.descendants(matching: .any).matching(identifier: "chapter.row")
            .matching(NSPredicate(format: "label CONTAINS %@", "Downloaded")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let pages = app.descendants(matching: .any).matching(identifier: "reader.pages").firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 20), "the downloaded chapter didn't open offline")
        screenshot(app, "offline-reader")
    }

    @MainActor
    func testTheSyncPageShowsEachServersConnection() throws {
        let app = try launch(needsKomga: true)
        app.buttons["tab.more"].tap()
        app.buttons["more.settings"].tap()
        app.buttons["settings.sync"].tap()
        let kavita = app.buttons["sync.section.Kavita"]
        XCTAssertTrue(kavita.waitForExistence(timeout: 5))
        XCTAssertTrue(kavita.waitFor(labelContaining: "Connected to Kavita", timeout: 15), kavita.label)
        XCTAssertTrue(app.buttons["sync.section.Komga"].waitFor(labelContaining: "Connected to Komga", timeout: 15))
        screenshot(app, "sync-settings")
    }

    // MARK: Helpers

    @MainActor
    private func launch(needsKomga: Bool) throws -> XCUIApplication {
        guard let kavitaURL = env["DOCHO_KAVITA_URL"], let kavitaKey = env["DOCHO_KAVITA_KEY"] else {
            throw XCTSkip("Set TEST_RUNNER_DOCHO_KAVITA_URL and _KEY to run against a server")
        }
        let app = XCUIApplication()
        app.launchEnvironment = ["DOCHO_KAVITA_URL": kavitaURL, "DOCHO_KAVITA_KEY": kavitaKey, "DOCHO_RESET": "1"]
        if needsKomga {
            guard let url = env["DOCHO_KOMGA_URL"], let key = env["DOCHO_KOMGA_KEY"], env["DOCHO_KOMGA_SERIES"] != nil else {
                throw XCTSkip("Set TEST_RUNNER_DOCHO_KOMGA_URL, _KEY and _SERIES to run the Komga checks")
            }
            app.launchEnvironment["DOCHO_KOMGA_URL"] = url
            app.launchEnvironment["DOCHO_KOMGA_KEY"] = key
        }
        app.launch()
        return app
    }

    @MainActor
    private func openKomgaSeries(_ app: XCUIApplication, named series: String) {
        app.buttons["tab.browse"].tap()
        let komga = app.buttons["browse.source.Komga"]
        XCTAssertTrue(komga.waitForExistence(timeout: 10), "Komga isn't listed under Browse")
        komga.tap()
        let item = app.descendants(matching: .any).matching(identifier: "browse.item")
            .matching(NSPredicate(format: "label BEGINSWITH %@", series)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 20), "\(series) isn't in Komga")
        item.tap()
        XCTAssertTrue(app.buttons["series.library"].waitForExistence(timeout: 10))
        app.buttons["series.library"].tap() // in the library, so it's easy to find again
    }

    @MainActor
    private func openDownloadedSeries(_ app: XCUIApplication) {
        app.buttons["tab.library"].tap()
        let item = app.descendants(matching: .any).matching(identifier: "library.item").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.tap()
    }

    @MainActor
    private func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await condition()
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
    }
}

private extension XCUIElement {
    /// Waits until the element's label contains `text`.
    func waitFor(labelContaining text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if exists, label.contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }
}

/// Komga's API, for playing "another device" in the tests.
private struct KomgaAPI {
    let base: String
    let key: String

    init?(_ env: [String: String]) {
        guard let url = env["DOCHO_KOMGA_URL"], let key = env["DOCHO_KOMGA_KEY"] else { return nil }
        base = url.hasSuffix("/") ? String(url.dropLast()) : url
        self.key = key
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: base + "/api" + path)!)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw URLError(.badServerResponse) }
        return data
    }

    func firstBook(ofSeries name: String) async throws -> String {
        let series = try JSONSerialization.jsonObject(with: try await request("/v1/series?search=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)")) as? [String: Any]
        let id = ((series?["content"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
        let books = try JSONSerialization.jsonObject(with: try await request("/v1/series/\(id)/books?sort=metadata.numberSort,asc")) as? [String: Any]
        return ((books?["content"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
    }

    /// The page reached (1-based) and whether it's finished; nil when unread.
    func progress(_ book: String) async throws -> (page: Int, completed: Bool)? {
        let json = try JSONSerialization.jsonObject(with: try await request("/v1/books/\(book)")) as? [String: Any]
        guard let progress = json?["readProgress"] as? [String: Any] else { return nil }
        return (progress["page"] as? Int ?? 0, progress["completed"] as? Bool ?? false)
    }

    func setPage(_ book: String, page: Int) async throws {
        _ = try await request("/v1/books/\(book)/read-progress", method: "PATCH", body: ["page": page])
    }

    func markUnread(_ book: String) async throws {
        _ = try? await request("/v1/books/\(book)/read-progress", method: "DELETE")
    }
}
