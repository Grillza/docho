import XCTest
@testable import Mihonka

/// Port of KavitaUrlsTest.kt. Its manga/chapter URL half doesn't apply: iOS stores Kavita ids
/// directly instead of encoding them into Mihon's manga and chapter URLs.
final class KavitaUrlsTests: XCTestCase {
    func testNormalizesTheServerAddressesPeoplePaste() {
        XCTAssertEqual(KavitaClient.normalizeApiURL("https://kavita.example.com"), "https://kavita.example.com/api")
        XCTAssertEqual(KavitaClient.normalizeApiURL(" https://kavita.example.com/ "), "https://kavita.example.com/api")
        XCTAssertEqual(KavitaClient.normalizeApiURL("192.168.1.10:5000"), "http://192.168.1.10:5000/api")
        XCTAssertEqual(KavitaClient.normalizeApiURL("https://example.com/kavita/"), "https://example.com/kavita/api")
        XCTAssertEqual(
            KavitaClient.normalizeApiURL("https://kavita.example.com/api/opds/0f8c3b1e-aaaa-bbbb"),
            "https://kavita.example.com/api"
        )
        XCTAssertNil(KavitaClient.normalizeApiURL("   "))
    }

    func testOnlyCutsAtAnApiPathSegment() {
        // Android cuts these short; iOS deliberately doesn't (see PLAN.md).
        XCTAssertEqual(KavitaClient.normalizeApiURL("https://api.example.com"), "https://api.example.com/api")
        XCTAssertEqual(KavitaClient.normalizeApiURL("https://example.com/apiary"), "https://example.com/apiary/api")
        XCTAssertEqual(KavitaClient.normalizeApiURL("HTTPS://kavita.example.com/API"), "HTTPS://kavita.example.com/api")
        XCTAssertEqual(KavitaClient.normalizeApiURL("kavita.local:5000/api?x=1"), "http://kavita.local:5000/api")
    }

    func testRejectsAddressesWithoutAHost() {
        XCTAssertNil(KavitaClient.normalizeApiURL("https://"))
        XCTAssertNil(KavitaClient.normalizeApiURL("http://exa mple.com"))
    }

    func testAddsTheApiKeyToImageRequestsOnly() throws {
        let cover = try XCTUnwrap(URL(string: "https://k.test/api/Image/series-cover?seriesId=3"))
        XCTAssertEqual(
            KavitaClient.addingApiKeyIfImage(cover, apiKey: "k").absoluteString,
            "https://k.test/api/Image/series-cover?seriesId=3&apiKey=k"
        )

        let page = try XCTUnwrap(URL(string: "https://k.test/api/Reader/image?chapterId=1&page=0"))
        XCTAssertEqual(
            KavitaClient.addingApiKeyIfImage(page, apiKey: "k").absoluteString,
            "https://k.test/api/Reader/image?chapterId=1&page=0&apiKey=k"
        )

        let keyed = try XCTUnwrap(URL(string: "https://k.test/api/Reader/image?apiKey=other"))
        XCTAssertEqual(KavitaClient.addingApiKeyIfImage(keyed, apiKey: "k"), keyed)

        let series = try XCTUnwrap(URL(string: "https://k.test/api/Series/3"))
        XCTAssertEqual(KavitaClient.addingApiKeyIfImage(series, apiKey: "k"), series)
    }

    func testBuildsImageAndWebUrls() throws {
        let credentials = TestCredentials(serverURL: "https://example.com/kavita/")
        let client = KavitaClient { credentials.current }
        XCTAssertEqual(
            try client.seriesCoverURL(seriesId: 42).absoluteString,
            "https://example.com/kavita/api/Image/series-cover?seriesId=42&apiKey=key-1"
        )
        XCTAssertEqual(
            try client.pageImageURL(chapterId: 7, page: 0).absoluteString,
            "https://example.com/kavita/api/Reader/image?chapterId=7&page=0&extractPdf=true&apiKey=key-1"
        )
        XCTAssertEqual(
            try client.seriesWebURL(libraryId: 3, seriesId: 42).absoluteString,
            "https://example.com/kavita/library/3/series/42"
        )
    }
}
