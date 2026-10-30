import GRDB
import XCTest
@testable import Doki

final class SkeletonTests: XCTestCase {
    func testSectionsAreLibraryBrowseDownloadsSettings() {
        XCTAssertEqual(AppSection.allCases, [.library, .browse, .downloads, .settings])
    }

    func testGRDBIsLinked() throws {
        let queue = try DatabaseQueue()
        let one = try queue.read { try Int.fetchOne($0, sql: "SELECT 1") }
        XCTAssertEqual(one, 1)
    }

    func testInfoPlistAllowsPlainHttpAndBackgroundRefresh() throws {
        // Hosted tests run inside the app, so Bundle.main is Doki.app.
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let ats = try XCTUnwrap(info["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
        XCTAssertNotNil(info["NSLocalNetworkUsageDescription"])
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["fetch"])
        XCTAssertEqual(info["BGTaskSchedulerPermittedIdentifiers"] as? [String], ["app.doki.progress-sync"])
    }
}
