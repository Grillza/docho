import XCTest
@testable import Docho

final class AppUpdateCheckerTests: XCTestCase {
    private let body = """
    ## Android

    Android 8.0 or higher.

    ### Changed

    - Android change

    ## iOS and iPadOS

    Version 0.28.0.

    ### Added

    - iOS change
    """

    private func json(assets: [String]) -> Data {
        let object: [String: Any] = [
            "tag_name": "v0.28.0", "body": body, "html_url": "https://github.com/Grillza/docho/releases/tag/v0.28.0",
            "assets": assets.map { ["name": $0] },
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testTakesTheVersionFromTheIpaAndOnlyTheIosNotes() throws {
        let release = try XCTUnwrap(AppUpdateChecker.parse(json(assets: ["docho-0.27.1-universal.apk", "docho-0.28.0.ipa"])))
        XCTAssertEqual(release.version, "0.28.0")
        XCTAssertTrue(release.notes.hasPrefix("Version 0.28.0."))
        XCTAssertTrue(release.notes.contains("iOS change"))
        XCTAssertFalse(release.notes.contains("Android change"))
    }

    func testAReleaseWithoutAnIpaIsIgnored() throws {
        XCTAssertNil(try AppUpdateChecker.parse(json(assets: ["docho-0.28.0-universal.apk"])))
    }

    private func offered(_ current: String, _ latest: String, skipped: String? = nil, skipPatches: Bool = false) -> Bool {
        let release = AppRelease(version: latest, notes: "", page: URL(string: "https://example.com")!)
        return AppUpdateChecker.evaluate(release, current: current, skipped: skipped, skipPatchUpdates: skipPatches) != .noNewUpdate
    }

    func testComparesVersionsNumerically() {
        XCTAssertTrue(offered("0.27.2", "0.28.0"))
        XCTAssertTrue(offered("0.27.9", "0.27.10"))
        XCTAssertFalse(offered("1.0.0", "0.99.0"))
        XCTAssertFalse(offered("0.28.0", "0.28.0"))
    }

    func testSkippedVersionIsNotOfferedButANewerOneIs() {
        XCTAssertFalse(offered("0.27.2", "0.28.0", skipped: "0.28.0"))
        XCTAssertTrue(offered("0.27.2", "0.28.1", skipped: "0.28.0"))
    }

    func testSkippingBugFixUpdates() {
        XCTAssertFalse(offered("0.28.0", "0.28.1", skipPatches: true))
        XCTAssertTrue(offered("0.28.0", "0.28.1", skipPatches: false))
        XCTAssertTrue(offered("0.28.1", "0.29.0", skipPatches: true))
        XCTAssertTrue(offered("0.28.1", "1.0.0", skipPatches: true))
    }
}
