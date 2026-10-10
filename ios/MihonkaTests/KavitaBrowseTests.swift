import XCTest
@testable import Mihonka

final class KavitaBrowseTests: XCTestCase {
    private let noEpub = KavitaFilterStatement(comparison: 8, field: 21, value: "3")

    func testDefaultBrowseIsByNameAndExcludesEpub() {
        let filter = KavitaBrowseRequest().filter
        XCTAssertEqual(filter.statements, [noEpub])
        XCTAssertEqual(filter.sortOptions, KavitaSortOptions(sortField: 1, isAscending: true))
        XCTAssertEqual(filter.combination, 1)
    }

    func testSearchAndLibraryComeBeforeTheEpubExclusion() {
        let request = KavitaBrowseRequest(query: "  berserk ", libraryId: 4, sort: .lastChapterAdded, ascending: false)
        XCTAssertEqual(request.filter.statements, [
            KavitaFilterStatement(comparison: 7, field: 1, value: "berserk"),
            KavitaFilterStatement(comparison: 5, field: 19, value: "4"),
            noEpub,
        ])
        XCTAssertEqual(request.filter.sortOptions, KavitaSortOptions(sortField: 4, isAscending: false))
    }

    func testBlankSearchAddsNothing() {
        XCTAssertEqual(KavitaBrowseRequest(query: "   ").filter.statements, [noEpub])
    }

    func testSortFields() {
        XCTAssertEqual(KavitaBrowseSort.allCases.map(\.field), [1, 2, 4, 7])
    }

    func testTitleFallsBackLikeAndroid() throws {
        func title(_ json: String) throws -> String {
            try JSONDecoder().decode(KavitaSeries.self, from: Data(json.utf8)).title
        }
        XCTAssertEqual(try title(#"{"id": 1, "name": "A", "localizedName": "B"}"#), "A")
        XCTAssertEqual(try title(#"{"id": 1, "localizedName": "B", "originalName": "C"}"#), "B")
        XCTAssertEqual(try title(#"{"id": 1, "originalName": "C"}"#), "C")
        XCTAssertEqual(try title(#"{"id": 9}"#), "Series 9")
    }
}
