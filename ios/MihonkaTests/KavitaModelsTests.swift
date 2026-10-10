import XCTest
@testable import Mihonka

final class KavitaModelsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testDecodesLenientlyWithDefaultsAndUnknownKeys() throws {
        let series = try decode(KavitaSeries.self, #"{"id": 5, "somethingNew": true, "pages": "oops"}"#)
        XCTAssertEqual(series.id, 5)
        XCTAssertNil(series.name)
        XCTAssertEqual(series.pages, 0)
        XCTAssertEqual(series.format, KavitaConstants.formatUnknown)

        let metadata = try decode(KavitaSeriesMetadata.self, "{}")
        XCTAssertEqual(metadata.publicationStatus, -1)
        XCTAssertEqual(metadata.genres, [])
    }

    func testNamedLabelPrefersTitleAndSkipsBlank() throws {
        XCTAssertEqual(try decode(KavitaNamed.self, #"{"title": "Action", "name": "x"}"#).label, "Action")
        XCTAssertEqual(try decode(KavitaNamed.self, #"{"name": "Miura"}"#).label, "Miura")
        XCTAssertNil(try decode(KavitaNamed.self, #"{"title": "  "}"#).label)
    }

    func testVolumeNumberPrefersMinNumber() throws {
        XCTAssertEqual(try decode(KavitaVolume.self, #"{"id": 1, "minNumber": 2, "number": 3}"#).volumeNumber, 2)
        XCTAssertEqual(try decode(KavitaVolume.self, #"{"id": 1, "number": 3}"#).volumeNumber, 3)
        XCTAssertEqual(try decode(KavitaVolume.self, #"{"id": 1}"#).volumeNumber, 0)
    }

    func testChapterNumberParsing() throws {
        XCTAssertEqual(try decode(KavitaChapter.self, #"{"id": 1, "minNumber": 4.5, "number": "9"}"#).chapterNumber, 4.5)
        XCTAssertEqual(try decode(KavitaChapter.self, #"{"id": 1, "number": "10,5"}"#).chapterNumber, 10.5)
        XCTAssertEqual(try decode(KavitaChapter.self, #"{"id": 1, "number": 7}"#).number, "7")
        XCTAssertEqual(try decode(KavitaChapter.self, #"{"id": 1, "number": "abc"}"#).chapterNumber, KavitaConstants.defaultChapterNumber)
        XCTAssertEqual(try decode(KavitaChapter.self, #"{"id": 1}"#).chapterNumber, KavitaConstants.defaultChapterNumber)
    }

    func testFilterEncodesEveryFieldIncludingDefaults() throws {
        let filter = KavitaFilter(statements: [KavitaFilterStatement(comparison: 7, field: 1, value: "berserk")])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(filter)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["statements", "combination", "sortOptions", "limitTo"])
        XCTAssertEqual(object["combination"] as? Int, 1)
        XCTAssertEqual(object["limitTo"] as? Int, 0)
        let sort = try XCTUnwrap(object["sortOptions"] as? [String: Any])
        XCTAssertEqual(sort["sortField"] as? Int, 1)
        XCTAssertEqual(sort["isAscending"] as? Bool, true)
    }

    func testFormatNumber() {
        XCTAssertEqual(formatNumber(3), "3")
        XCTAssertEqual(formatNumber(-100_000), "-100000")
        XCTAssertEqual(formatNumber(10.5), "10.5")
    }
}
