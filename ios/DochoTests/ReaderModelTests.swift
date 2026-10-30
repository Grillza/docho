import GRDB
import XCTest
@testable import Docho

@MainActor
final class ReaderModelTests: XCTestCase {
    private var app: AppModel!
    private var defaults: UserDefaults!
    private var series: SeriesRecord!

    override func setUp() async throws {
        let parts = try TestApp.make("reader")
        app = parts.app
        defaults = parts.defaults
        app.settings.syncProgress = false // KavitaSyncTests covers what the reader sends
        series = try await app.seedKavitaSeries(chapters: [(10, 5), (11, 3), (12, 0)])
    }

    private func chapters() async throws -> [ChapterRecord] {
        try await app.database.chapterList(seriesId: series.id)
    }

    private func model(start index: Int = 0, readerMode: String? = nil) async throws -> ReaderModel {
        let chapters = try await chapters()
        var series = series!
        series.readerMode = readerMode
        return ReaderModel(app: app, series: series, chapters: chapters, start: chapters[index])
    }

    /// Answers Kavita's chapter lookup with `pages` pages.
    private func servePages(_ pages: Int) {
        StubURLProtocol.reset { request in
            request.path.hasSuffix("/Plugin/authenticate")
                ? .json(#"{"username": "u", "token": "t"}"#)
                : .json(#"{"id": \#(request.query("chapterId") ?? "0"), "pages": \#(pages)}"#)
        }
    }

    func testResumesWhereReadingStoppedAndRestartsReadChapters() async throws {
        var chapter = try await chapters()[0]
        chapter.pages = 10
        chapter.lastPageRead = 4
        XCTAssertEqual(ReaderModel.resumePage(chapter), 4)
        chapter.read = true
        XCTAssertEqual(ReaderModel.resumePage(chapter), 0)
        chapter.read = false
        chapter.lastPageRead = 40
        XCTAssertEqual(ReaderModel.resumePage(chapter), 9)
        chapter.pages = 0
        chapter.lastPageRead = 3
        XCTAssertEqual(ReaderModel.resumePage(chapter), 0)
    }

    func testSavesEachPageAndMarksTheChapterReadOnTheLastPage() async throws {
        servePages(5)
        let reader = try await model()
        await reader.loadPages()

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

        let history = try await app.database.writer.read { try HistoryRecord.fetchCount($0) }
        XCTAssertEqual(history, 1)
    }

    func testIncognitoModeKeepsNoHistory() async throws {
        servePages(5)
        app.preferences.incognitoMode = true
        let reader = try await model()
        await reader.loadPages()
        await reader.pageShown(2)
        let history = try await app.database.writer.read { try HistoryRecord.fetchCount($0) }
        XCTAssertEqual(history, 0)
        let page = try await chapters()[0].lastPageRead
        XCTAssertEqual(page, 2, "progress is still saved")
    }

    func testASinglePageChapterIsReadOnceShown() async throws {
        servePages(1)
        let reader = try await model()
        await reader.loadPages()
        await reader.pageShown(0)
        let read = try await chapters()[0].read
        XCTAssertTrue(read)
    }

    func testMovesBetweenChapters() async throws {
        servePages(5)
        let reader = try await model(start: 1)
        let ids = try await chapters().map(\.id)
        XCTAssertEqual(reader.previousChapter?.id, ids[0])
        XCTAssertEqual(reader.nextChapter?.id, ids[2])

        await reader.open(try XCTUnwrap(reader.previousChapter), atEnd: true)
        XCTAssertEqual(reader.chapter.id, ids[0])
        XCTAssertEqual(reader.page, 4, "the previous chapter opens at its last page")
        XCTAssertNil(reader.previousChapter)

        await reader.pageShown(2)
        await reader.open(try XCTUnwrap(reader.nextChapter), atEnd: false)
        XCTAssertEqual(reader.chapter.id, ids[1])
        XCTAssertEqual(reader.page, 0)
        XCTAssertEqual(reader.chapters[0].lastPageRead, 2, "the in-memory list keeps progress made in the reader")
    }

    func testSkipsReadChaptersWhenSetTo() async throws {
        let ids = try await chapters().map(\.id)
        try await app.database.setChaptersRead([ids[1]], read: true)
        app.readerSettings.skipRead = true
        let reader = try await model(start: 0)
        XCTAssertEqual(reader.nextChapter?.id, ids[2])
    }

    func testLoadsThePageListAndStoresTheCount() async throws {
        servePages(8)
        let reader = try await model(start: 2)
        XCTAssertFalse(reader.pagesLoaded)

        await reader.loadPages()

        XCTAssertTrue(reader.pagesLoaded)
        XCTAssertEqual(reader.pageCount, 8)
        XCTAssertNil(reader.loadError)
        XCTAssertEqual(StubURLProtocol.requests.last?.query("chapterId"), "12")
        let pages = try await chapters()[2].pages
        XCTAssertEqual(pages, 8)
    }

    func testTheModeDefaultsToRightToLeftAndIsSavedPerSeries() async throws {
        let reader = try await model()
        XCTAssertEqual(reader.mode, .rightToLeft)

        await reader.setMode(.webtoon)
        let mode = try await app.database.seriesRecord(id: series.id)?.readerMode
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

        let stored = ReaderSettings(defaults: defaults)
        XCTAssertEqual(stored.defaultMode, .leftToRight, "saved")
        XCTAssertFalse(stored.spreads)
        XCTAssertTrue(stored.coverAlone)
    }

    func testJumpsOnlyToPagesThatExist() async throws {
        servePages(5)
        let reader = try await model()
        await reader.loadPages()
        reader.jump(to: 3)
        XCTAssertEqual(reader.jump?.page, 3)
        reader.jump(to: 5)
        XCTAssertEqual(reader.jump?.page, 3)
    }

    func testPageRequestsCarryTheApiKey() async throws {
        servePages(5)
        let reader = try await model()
        await reader.loadPages()
        XCTAssertEqual(
            reader.pageRequest(2)?.url?.absoluteString,
            "https://kavita.test/api/Reader/image?chapterId=10&page=2&extractPdf=true&apiKey=key-1"
        )
    }

    func testTapZonesMatchMihons() {
        XCTAssertEqual(TapZones.default.action(at: CGPoint(x: 0.1, y: 0.5), invert: .none), .left)
        XCTAssertEqual(TapZones.default.action(at: CGPoint(x: 0.9, y: 0.5), invert: .none), .right)
        XCTAssertEqual(TapZones.default.action(at: CGPoint(x: 0.5, y: 0.5), invert: .none), .menu)
        XCTAssertEqual(TapZones.default.action(at: CGPoint(x: 0.1, y: 0.5), invert: .horizontal), .right)
        XCTAssertEqual(TapZones.lShaped.action(at: CGPoint(x: 0.9, y: 0.1), invert: .none), .previous)
        XCTAssertEqual(TapZones.lShaped.action(at: CGPoint(x: 0.1, y: 0.5), invert: .none), .previous)
        XCTAssertEqual(TapZones.lShaped.action(at: CGPoint(x: 0.9, y: 0.5), invert: .none), .next)
        XCTAssertEqual(TapZones.lShaped.action(at: CGPoint(x: 0.1, y: 0.9), invert: .none), .next)
        XCTAssertEqual(TapZones.kindle.action(at: CGPoint(x: 0.5, y: 0.1), invert: .none), .menu)
        XCTAssertEqual(TapZones.kindle.action(at: CGPoint(x: 0.1, y: 0.5), invert: .none), .previous)
        XCTAssertEqual(TapZones.edge.action(at: CGPoint(x: 0.5, y: 0.9), invert: .none), .previous)
        XCTAssertEqual(TapZones.edge.action(at: CGPoint(x: 0.1, y: 0.1), invert: .none), .next)
        XCTAssertEqual(TapZones.disabled.action(at: CGPoint(x: 0.1, y: 0.1), invert: .none), .menu)
    }
}
