import GRDB
import XCTest
@testable import Doki

@MainActor
final class ReaderModelTests: XCTestCase {
    private var app: AppModel!
    private var defaultsSuite = ""

    override func setUp() async throws {
        defaultsSuite = "app.doki.tests.reader.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        let settings = KavitaSettings(defaults: defaults, keychainService: "app.doki.tests.reader")
        settings.serverURL = "https://kavita.test"
        settings.apiKey = "key-1"
        settings.syncProgress = false // KavitaSyncTests covers what the reader sends
        app = AppModel(
            settings: settings, session: StubURLProtocol.session(), database: try .inMemory(),
            readerSettings: ReaderSettings(defaults: defaults)
        )

        let series = try JSONDecoder().decode(KavitaSeries.self, from: Data(#"{"id": 7, "name": "S", "libraryId": 2}"#.utf8))
        let details = KavitaSeriesDetails(try JSONDecoder().decode(KavitaSeriesMetadata.self, from: Data("{}".utf8)))
        let entries = [(10, 5), (11, 3), (12, 0)].map { id, pages in
            KavitaChapterEntry(
                chapterId: id, volumeId: 1, name: "Ch. \(id)", number: Double(id), pages: pages, pagesRead: 0, dateUpload: nil
            )
        }
        try await app.database.saveSeries(series, details: details, chapters: entries, seedProgress: false)
    }

    override func tearDown() async throws {
        app.settings.apiKey = ""
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    private func chapters() async throws -> [ChapterRecord] {
        try await app.database.writer.read { try ChapterRecord.order(Column("readingOrder")).fetchAll($0) }
    }

    private func model(start index: Int = 0, readerMode: String? = nil) async throws -> ReaderModel {
        let chapters = try await chapters()
        return ReaderModel(app: app, seriesId: 7, seriesName: "S", readerMode: readerMode, chapters: chapters, start: chapters[index])
    }

    func testResumesWhereReadingStoppedAndRestartsReadChapters() {
        func chapter(read: Bool, lastPageRead: Int, pages: Int = 10) -> ChapterRecord {
            ChapterRecord(
                id: 1, seriesId: 7, volumeId: 1, libraryId: 2, name: "", number: 1, readingOrder: 0, pages: pages,
                read: read, lastPageRead: lastPageRead, dateUpload: nil, isDownloaded: false
            )
        }
        XCTAssertEqual(ReaderModel.resumePage(chapter(read: false, lastPageRead: 4)), 4)
        XCTAssertEqual(ReaderModel.resumePage(chapter(read: true, lastPageRead: 4)), 0)
        XCTAssertEqual(ReaderModel.resumePage(chapter(read: false, lastPageRead: 40)), 9)
        XCTAssertEqual(ReaderModel.resumePage(chapter(read: false, lastPageRead: 3, pages: 0)), 0)
    }

    func testSavesEachPageAndMarksTheChapterReadOnTheLastPage() async throws {
        let reader = try await model()

        await reader.pageShown(2)
        var stored = try await chapters()[0]
        XCTAssertEqual(stored.lastPageRead, 2)
        XCTAssertFalse(stored.read)

        await reader.pageShown(4)
        stored = try await chapters()[0]
        XCTAssertEqual(stored.lastPageRead, 4)
        XCTAssertTrue(stored.read)

        await reader.pageShown(1)
        stored = try await chapters()[0]
        XCTAssertEqual(stored.lastPageRead, 1)
        XCTAssertTrue(stored.read, "going back doesn't unmark a read chapter")
    }

    func testASinglePageChapterIsReadOnceShown() async throws {
        try await app.database.writer.write { try $0.execute(sql: "UPDATE chapter SET pages = 1 WHERE id = 10") }
        let reader = try await model()
        await reader.pageShown(0)
        let read = try await chapters()[0].read
        XCTAssertTrue(read)
    }

    func testMovesBetweenChapters() async throws {
        let reader = try await model(start: 1)
        XCTAssertEqual(reader.previousChapter?.id, 10)
        XCTAssertEqual(reader.nextChapter?.id, 12)

        await reader.open(try XCTUnwrap(reader.previousChapter), atEnd: true)
        XCTAssertEqual(reader.chapter.id, 10)
        XCTAssertEqual(reader.page, 4, "the previous chapter opens at its last page")
        XCTAssertNil(reader.previousChapter)

        await reader.pageShown(2)
        await reader.open(try XCTUnwrap(reader.nextChapter), atEnd: false)
        XCTAssertEqual(reader.chapter.id, 11)
        XCTAssertEqual(reader.page, 0)
        XCTAssertEqual(reader.chapters[0].lastPageRead, 2, "the in-memory list keeps progress made in the reader")
    }

    func testFetchesThePageCountWhenTheListHasNone() async throws {
        StubURLProtocol.reset { request in
            request.path.hasSuffix("/Plugin/authenticate") ? .json(#"{"username": "u", "token": "t"}"#) : .json(#"{"id": 12, "pages": 8}"#)
        }
        let reader = try await model(start: 2)
        XCTAssertEqual(reader.pageCount, 0)

        await reader.loadPageCount()

        XCTAssertEqual(reader.pageCount, 8)
        XCTAssertNil(reader.loadError)
        XCTAssertEqual(StubURLProtocol.requests.last?.query("chapterId"), "12")
    }

    func testTheModeDefaultsToRightToLeftAndIsSavedPerSeries() async throws {
        let reader = try await model()
        XCTAssertEqual(reader.mode, .rightToLeft)

        await reader.setMode(.webtoon)
        let mode = try await app.database.writer.read { try SeriesRecord.fetchOne($0, key: 7)?.readerMode }
        XCTAssertEqual(mode, "webtoon")
        let reopened = try await model(readerMode: mode)
        XCTAssertEqual(reopened.mode, .webtoon)
    }

    func testSeriesWithoutAModeUseTheDefaultFromSettings() async throws {
        app.readerSettings.defaultMode = .leftToRight
        let reader = try await model(readerMode: nil)
        XCTAssertEqual(reader.mode, .leftToRight)
        let own = try await model(readerMode: "rtl")
        XCTAssertEqual(own.mode, .rightToLeft)

        let stored = ReaderSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuite)))
        XCTAssertEqual(stored.defaultMode, .leftToRight, "saved")
        XCTAssertFalse(stored.spreads)
        XCTAssertTrue(stored.coverAlone)
    }

    func testJumpsOnlyToPagesThatExist() async throws {
        let reader = try await model()
        reader.jump(to: 3)
        XCTAssertEqual(reader.jump?.page, 3)
        reader.jump(to: 5)
        XCTAssertEqual(reader.jump?.page, 3)
    }

    func testPageURLsCarryTheApiKey() async throws {
        let reader = try await model()
        XCTAssertEqual(
            reader.pageURL(2)?.absoluteString,
            "https://kavita.test/api/Reader/image?chapterId=10&page=2&extractPdf=true&apiKey=key-1"
        )
    }
}
