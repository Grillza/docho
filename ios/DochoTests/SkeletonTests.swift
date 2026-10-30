import GRDB
import XCTest
@testable import Docho

final class SkeletonTests: XCTestCase {
    func testTabsAreMihons() {
        XCTAssertEqual(HomeTab.allCases, [.library, .updates, .history, .browse, .more])
    }

    func testGRDBIsLinked() throws {
        let queue = try DatabaseQueue()
        let one = try queue.read { try Int.fetchOne($0, sql: "SELECT 1") }
        XCTAssertEqual(one, 1)
    }

    func testInfoPlistAllowsPlainHttpAndBackgroundWork() throws {
        // Hosted tests run inside the app, so Bundle.main is Docho.app.
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let ats = try XCTUnwrap(info["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
        XCTAssertNotNil(info["NSLocalNetworkUsageDescription"])
        XCTAssertTrue((info["UIBackgroundModes"] as? [String])?.contains("fetch") == true)
        XCTAssertTrue((info["BGTaskSchedulerPermittedIdentifiers"] as? [String])?.contains("io.github.grillza.docho.progress-sync") == true)
    }

    func testEveryThemeHasLightAndDarkSchemes() {
        for theme in AppTheme.allCases {
            XCTAssertNotEqual(theme.light.surface, theme.dark.surface, "\(theme)")
        }
        let black = M3ColorScheme.of(.default, dark: true, pureBlack: true)
        XCTAssertEqual(black.background, .black)
    }

    func testIconsAreInTheAssetCatalog() {
        for name in ["nav.library", "nav.library.fill", "nav.more", "settings", "favorite.fill", "brand.kavita", "brand.komga", "wordmark"] {
            XCTAssertNotNil(UIImage(named: name), name)
        }
    }
}
