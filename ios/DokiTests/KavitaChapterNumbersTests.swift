import XCTest
@testable import Doki

/// Port of KavitaChapterNumbersTest.kt. Its third case (`calculateChapterGap`) tests Mihon's
/// missing-chapter detection, which the iOS app doesn't have.
final class KavitaChapterNumbersTests: XCTestCase {
    private let volumes = [1, 1.5, 2, 3, 120].map(KavitaChapterList.volumeChapterNumber)
    private let specials = (0...2).map(KavitaChapterList.specialChapterNumber)

    func testVolumesAndSpecialsAreNeverRecognizedChapterNumbers() {
        // Mihon treats negative numbers as unrecognized, apart from -1 and -2 which it parses or reserves.
        for number in volumes + specials {
            XCTAssertLessThan(number, -2, "\(number)")
        }
    }

    func testEveryVolumeAndSpecialGetsItsOwnNumberInKavitasOrder() throws {
        XCTAssertEqual(volumes.sorted(), volumes)
        XCTAssertEqual(specials.sorted(), specials)
        XCTAssertEqual(Set(volumes + specials).count, volumes.count + specials.count)
        XCTAssertLessThan(try XCTUnwrap(specials.max()), try XCTUnwrap(volumes.min()))
    }
}
