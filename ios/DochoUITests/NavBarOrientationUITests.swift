import XCTest

/// iPad: with "Different position in landscape" on, the bar follows each orientation's own
/// position and tab position.
final class NavBarOrientationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testEachOrientationHasItsOwnBarPosition() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Only iPads place the bar")
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // Launch arguments go into UserDefaults' argument domain, ahead of the saved settings.
        app.launchArguments += [
            "-onboarding_complete", "YES",
            "-nav_bar_split_orientation", "YES",
            "-nav_bar_position", "bottom", "-nav_bar_alignment", "center",
            "-nav_bar_position_landscape", "left", "-nav_bar_alignment_landscape", "end",
        ]
        app.launch()
        let library = app.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10))

        // Portrait: a bar along the bottom
        var window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(library.frame.midY, window.maxY - 120)
        save(app, "portrait")

        // Landscape: a rail on the left, its tabs at the bottom
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: nil)
        wait(for: [rotated], timeout: 10)
        sleep(1)
        window = app.windows.firstMatch.frame
        XCTAssertLessThan(library.frame.midX, window.minX + 120)
        XCTAssertGreaterThan(library.frame.midY, window.midY)
        save(app, "landscape")
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "navbar-\(name).png"))
    }
}
