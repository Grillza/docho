import XCTest
@testable import Docho

final class PageSpreadsTests: XCTestCase {
    func testTheCoverStandsAloneAndTheRestArePaired() {
        XCTAssertEqual(PageSpreads.pair(pageCount: 6, wide: [], coverAlone: true), [[0], [1, 2], [3, 4], [5]])
    }

    func testWithoutCoverAloneTheFirstTwoPagesArePaired() {
        XCTAssertEqual(PageSpreads.pair(pageCount: 5, wide: [], coverAlone: false), [[0, 1], [2, 3], [4]])
    }

    func testWidePagesStandAloneAndPairingCarriesOnAfterThem() {
        // Page 3 is a double-page scan: 2 can't pair with it, and 4 pairs with 5.
        XCTAssertEqual(PageSpreads.pair(pageCount: 7, wide: [3], coverAlone: true), [[0], [1, 2], [3], [4, 5], [6]])
        XCTAssertEqual(PageSpreads.pair(pageCount: 4, wide: [2], coverAlone: true), [[0], [1], [2], [3]])
    }

    func testEdgeCases() {
        XCTAssertEqual(PageSpreads.pair(pageCount: 0, wide: [], coverAlone: true), [])
        XCTAssertEqual(PageSpreads.pair(pageCount: 1, wide: [], coverAlone: false), [[0]])
        XCTAssertEqual(PageSpreads.pair(pageCount: 2, wide: [], coverAlone: true), [[0], [1]])
    }

    func testEveryPageAppearsOnceInOrder() {
        for count in 0..<12 {
            for coverAlone in [true, false] {
                let flat = PageSpreads.pair(pageCount: count, wide: [2, 7], coverAlone: coverAlone).flatMap { $0 }
                XCTAssertEqual(flat, Array(0..<count))
            }
        }
    }
}
