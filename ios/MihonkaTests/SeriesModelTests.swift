import XCTest
@testable import Mihonka

@MainActor
final class SeriesModelTests: XCTestCase {
    private var app: AppModel!
    private var model: SeriesModel!
    private var defaultsSuite = ""

    override func setUp() async throws {
        defaultsSuite = "app.mihonka.tests.series.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        let settings = KavitaSettings(defaults: defaults, keychainService: "app.mihonka.tests.series")
        settings.serverURL = "https://kavita.test"
        settings.apiKey = "key-1"
        app = AppModel(settings: settings, session: StubURLProtocol.session(), database: try .inMemory())
        model = SeriesModel(app: app, seriesId: 7)
    }

    override func tearDown() async throws {
        app.settings.apiKey = ""
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    func testRefreshStoresTheSeriesAndItsChapters() async throws {
        StubURLProtocol.reset { request in
            switch request.path {
            case let path where path.hasSuffix("/Plugin/authenticate"):
                .json(#"{"username": "u", "token": "t"}"#)
            case "/api/Series/7":
                .json(#"{"id": 7, "name": "Berserk", "libraryId": 2}"#)
            case "/api/Series/metadata":
                .json(#"{"summary": "Guts.", "writers": [{"name": "Miura"}], "publicationStatus": 1}"#)
            case "/api/Series/volumes":
                .json(#"""
                [{"id": 1, "minNumber": 1, "name": "1", "chapters": [
                  {"id": 10, "minNumber": 1, "number": "1", "range": "1", "pages": 20, "pagesRead": 20, "volumeId": 1}
                ]}]
                """#)
            default:
                .json("", status: 404)
            }
        }

        await model.refresh()

        XCTAssertNil(model.refreshError)
        let series = try await app.database.writer.read { try SeriesRecord.fetchOne($0, key: 7) }
        XCTAssertEqual(series?.name, "Berserk")
        XCTAssertEqual(series?.authors, "Miura")
        XCTAssertEqual(PublicationStatus.title(series?.status), "On hiatus")
        let chapters = try await app.database.writer.read { try ChapterRecord.fetchAll($0) }
        XCTAssertEqual(chapters.map(\.name), ["Vol. 1 Ch. 1"])
        XCTAssertEqual(chapters.first?.read, true, "seeded from the server; sync is on by default")
    }

    func testRefreshReportsErrors() async {
        StubURLProtocol.reset { request in
            request.path.hasSuffix("/Plugin/authenticate") ? .json(#"{"username": "u", "token": "t"}"#) : .json("", status: 500)
        }
        await model.refresh()
        XCTAssertEqual(model.refreshError, "HTTP 500")
        XCTAssertFalse(model.isRefreshing)
    }
}
