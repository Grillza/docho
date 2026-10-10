import XCTest
@testable import Mihonka

final class KavitaChapterListTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func volumes(_ json: String) throws -> [KavitaVolume] {
        try JSONDecoder().decode([KavitaVolume].self, from: Data(json.utf8))
    }

    /// A Kavita 0.8 series with every kind of entry, sent out of order.
    private let modern = #"""
    [
      {"id": 4, "name": "100000", "minNumber": 100000, "chapters": [
        {"id": 40, "minNumber": -100000, "number": "-100000", "isSpecial": true, "range": "file.cbz",
         "titleName": "Omake", "volumeId": 4},
        {"id": 41, "minNumber": -100000, "number": "-100000", "isSpecial": true, "range": "", "volumeId": 4}
      ]},
      {"id": 2, "name": "2", "minNumber": 2, "chapters": [
        {"id": 20, "minNumber": -100000, "number": "-100000", "range": "", "titleName": "The Second",
         "volumeId": 2, "pages": 180}
      ]},
      {"id": 3, "name": "-100000", "minNumber": -100000, "chapters": [
        {"id": 31, "minNumber": 3.5, "number": "3.5", "range": "3.5", "titleName": "Extra", "volumeId": 3},
        {"id": 30, "minNumber": 3, "number": "3", "range": "3", "volumeId": 3}
      ]},
      {"id": 1, "name": "1", "minNumber": 1, "chapters": [
        {"id": 11, "minNumber": 2, "number": "2", "range": "2", "titleName": "2", "volumeId": 1},
        {"id": 10, "minNumber": 1, "number": "1", "range": "1", "titleName": "Start", "volumeId": 1,
         "pages": 20, "pagesRead": 5}
      ]}
    ]
    """#

    func testReadingOrderIsVolumesThenLooseChaptersThenSpecials() throws {
        let entries = KavitaChapterList.build(try volumes(modern))
        XCTAssertEqual(entries.map(\.chapterId), [10, 11, 20, 30, 31, 40, 41])
    }

    func testNamesFollowAndroid() throws {
        let entries = KavitaChapterList.build(try volumes(modern))
        XCTAssertEqual(entries.map(\.name), [
            "Vol. 1 Ch. 1 - Start",
            "Vol. 1 Ch. 2", // a titleName equal to the range is left out
            "Volume 2 - The Second",
            "Ch. 3",
            "Ch. 3.5 - Extra",
            "Omake",
            "Special",
        ])
    }

    func testNumbersFollowAndroid() throws {
        let entries = KavitaChapterList.build(try volumes(modern))
        XCTAssertEqual(entries.map(\.number), [1, 2, -99_998, 3, 3.5, -200_000, -199_999])
    }

    func testKeepsTheIdsAndPagesProgressNeeds() throws {
        let first = try XCTUnwrap(KavitaChapterList.build(try volumes(modern)).first)
        XCTAssertEqual(first.volumeId, 1)
        XCTAssertEqual(first.pages, 20)
        XCTAssertEqual(first.pagesRead, 5)
    }

    func testOlderServersWithoutMinNumber() throws {
        // Before 0.8: loose chapters sit in volume 0, and a chapter "0" is a whole-volume file.
        let entries = KavitaChapterList.build(try volumes(#"""
        [
          {"id": 1, "name": "0", "number": 0, "chapters": [{"id": 10, "number": "5", "range": "5"}]},
          {"id": 2, "name": "Volume Two", "number": 2, "chapters": [
            {"id": 20, "number": "0", "range": "", "titleName": "Volume Two"}
          ]}
        ]
        """#))
        XCTAssertEqual(entries.map(\.name), ["Volume Volume Two", "Ch. 5"])
        XCTAssertEqual(entries.map(\.number), [-99_998, 5])
    }

    func testCommaDecimalChapterNumbers() throws {
        let entries = KavitaChapterList.build(try volumes(#"""
        [{"id": 1, "minNumber": -100000, "chapters": [{"id": 10, "number": "10,5", "range": ""}]}]
        """#))
        XCTAssertEqual(entries.first?.name, "Ch. 10.5")
        XCTAssertEqual(entries.first?.number, 10.5)
    }

    func testUploadDatePrefersReleaseDateThenCreated() throws {
        let entries = KavitaChapterList.build(try volumes(#"""
        [{"id": 1, "minNumber": 1, "chapters": [
          {"id": 10, "minNumber": 1, "releaseDate": "2021-03-04T00:00:00", "created": "2022-01-01T10:00:00"},
          {"id": 11, "minNumber": 2, "releaseDate": "0001-01-01T00:00:00", "created": "2022-01-01T10:00:00"},
          {"id": 12, "minNumber": 3}
        ]}]
        """#), timeZone: utc)
        XCTAssertEqual(entries.map(\.dateUpload), [
            Date(timeIntervalSince1970: 1_614_816_000),
            Date(timeIntervalSince1970: 1_641_031_200),
            nil,
        ])
    }

    func testParsesKavitaDates() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        // Local time without an offset is read in the given time zone; fractions are ignored.
        XCTAssertEqual(
            KavitaChapterList.parseDate("2024-01-02T03:04:05.1234567", timeZone: tokyo),
            Date(timeIntervalSince1970: 1_704_132_245)
        )
        XCTAssertEqual(KavitaChapterList.parseDate("2024-01-02T03:04:05Z", timeZone: tokyo), Date(timeIntervalSince1970: 1_704_164_645))
        XCTAssertEqual(KavitaChapterList.parseDate("2024-01-02T03:04:05+02:00"), Date(timeIntervalSince1970: 1_704_157_445))
        XCTAssertEqual(KavitaChapterList.parseDate("2024-01-02T03:04:05-0130"), Date(timeIntervalSince1970: 1_704_170_045))
        XCTAssertNil(KavitaChapterList.parseDate("0001-01-01T00:00:00"))
        XCTAssertNil(KavitaChapterList.parseDate("yesterday"))
        XCTAssertNil(KavitaChapterList.parseDate(nil))
    }

    func testSeriesDetailsLikeAndroid() throws {
        let metadata = try JSONDecoder().decode(KavitaSeriesMetadata.self, from: Data(#"""
        {"summary": "  A story.\n ", "writers": [{"name": "Miura"}, {"name": "Miura"}],
         "coverArtists": [{"name": "Studio"}], "pencillers": [],
         "genres": [{"title": "Action"}, {"title": " "}], "tags": [{"title": "Dark"}], "publicationStatus": 4}
        """#.utf8))
        let details = KavitaSeriesDetails(metadata)
        XCTAssertEqual(details.summary, "A story.")
        XCTAssertEqual(details.authors, "Miura")
        XCTAssertEqual(details.artists, "Studio")
        XCTAssertEqual(details.genres, "Action, Dark")
        XCTAssertEqual(PublicationStatus.title(details.status), "Completed")
        XCTAssertNil(PublicationStatus.title(-1))
    }
}
