import XCTest
@testable import Docho

@MainActor
final class SeriesModelTests: XCTestCase {
    private var app: AppModel!
    private var model: SeriesModel!

    override func setUp() async throws {
        app = try TestApp.make("series").app
        let series = try await app.database.localSeries(
            source: KavitaSource.id, manga: SManga(url: "/library/2/series/7", title: "Berserk")
        )
        model = SeriesModel(app: app, seriesId: series.id)
        Task { await model.observeSeries() }
        while model.series == nil { await Task.yield() }
    }

    func testRefreshStoresTheSeriesAndItsChaptersAndPullsProgress() async throws {
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
                  {"id": 10, "minNumber": 1, "number": "1", "range": "1", "pages": 20, "pagesRead": 20, "volumeId": 1,
                   "files": [{"filePath": "/manga/Berserk/Berserk v01.cbz", "koreaderHash": "ABC"}]}
                ]}]
                """#)
            default:
                .json("", status: 404)
            }
        }

        await model.refresh()

        XCTAssertNil(model.refreshError)
        let series = try await app.database.seriesRecord(id: model.seriesId)
        XCTAssertEqual(series?.name, "Berserk")
        XCTAssertEqual(series?.authors, "Miura")
        XCTAssertEqual(series?.mangaStatus, .onHiatus)
        let chapters = try await app.database.chapterList(seriesId: model.seriesId)
        XCTAssertEqual(chapters.map(\.name), ["Vol. 1 Ch. 1"])
        XCTAssertEqual(chapters.first?.url, "/chapter/10")
        XCTAssertEqual(chapters.first?.chapterMemo.string(ChapterMemo.fileName), "Berserk v01.cbz")
        XCTAssertEqual(chapters.first?.chapterMemo.string(KavitaSource.memoKoreaderHash), "abc")
        XCTAssertEqual(chapters.first?.read, true, "pulled from the server; sync is on by default")
    }

    func testRefreshReportsErrors() async {
        StubURLProtocol.reset { request in
            request.path.hasSuffix("/Plugin/authenticate") ? .json(#"{"username": "u", "token": "t"}"#) : .json("", status: 500)
        }
        await model.refresh()
        XCTAssertEqual(model.refreshError, "HTTP 500")
        XCTAssertFalse(model.isRefreshing)
    }

    func testNextChapterIsTheFirstUnreadAfterTheLastRead() async throws {
        let series = try await app.seedKavitaSeries(chapters: [(1, 5), (2, 5), (3, 5)])
        let model = SeriesModel(app: app, seriesId: series.id)
        Task { await model.observeSeries() }
        Task { await model.observeChapters() }
        while model.chapters.count < 3 || model.series == nil { await Task.yield() }
        XCTAssertEqual(model.nextChapter?.url, "/chapter/1")
        XCTAssertFalse(model.hasStarted)

        await model.setRead([model.chapters[1].id], true)
        while !model.chapters[1].read { await Task.yield() }
        XCTAssertEqual(model.nextChapter?.url, "/chapter/3")
        XCTAssertTrue(model.hasStarted)
    }
}
