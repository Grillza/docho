import GRDB
import XCTest
@testable import Doki

final class ChapterDatabaseTests: XCTestCase {
    private var database: AppDatabase!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
    }

    private func series(name: String = "Berserk") throws -> KavitaSeries {
        try JSONDecoder().decode(KavitaSeries.self, from: Data(#"{"id": 7, "name": "\#(name)", "libraryId": 2}"#.utf8))
    }

    private func details() throws -> KavitaSeriesDetails {
        KavitaSeriesDetails(try JSONDecoder().decode(KavitaSeriesMetadata.self, from: Data(#"{"summary": "s"}"#.utf8)))
    }

    private func entry(_ id: Int, pages: Int = 20, pagesRead: Int = 0, name: String? = nil) -> KavitaChapterEntry {
        KavitaChapterEntry(
            chapterId: id, volumeId: 1, name: name ?? "Ch. \(id)", number: Double(id),
            pages: pages, pagesRead: pagesRead, dateUpload: nil
        )
    }

    private func chapters() async throws -> [ChapterRecord] {
        for try await chapters in database.chapters(seriesId: 7) { return chapters }
        return []
    }

    func testSavesTheSeriesAndChaptersInOrder() async throws {
        try await database.saveSeries(series(), details: details(), chapters: [entry(3), entry(1)], seedProgress: false)

        let stored = try await chapters()
        XCTAssertEqual(stored.map(\.id), [3, 1])
        XCTAssertEqual(stored.map(\.readingOrder), [0, 1])
        XCTAssertEqual(stored.first?.libraryId, 2)
        let record = try await database.writer.read { try SeriesRecord.fetchOne($0, key: 7) }
        XCTAssertEqual(record?.summary, "s")
        XCTAssertEqual(record?.inLibrary, false)
    }

    func testSeedsNewChaptersFromTheServerWhenSyncIsOn() async throws {
        try await database.saveSeries(
            series(), details: details(),
            chapters: [entry(1, pagesRead: 20), entry(2, pagesRead: 6), entry(3), entry(4, pages: 0, pagesRead: 3)],
            seedProgress: true
        )
        let stored = try await chapters()
        XCTAssertEqual(stored.map(\.read), [true, false, false, false])
        XCTAssertEqual(stored.map(\.lastPageRead), [0, 6, 0, 0])
    }

    func testDoesNotSeedWhenSyncIsOff() async throws {
        try await database.saveSeries(series(), details: details(), chapters: [entry(1, pagesRead: 20)], seedProgress: false)
        let first = try await chapters().first
        XCTAssertEqual(first?.read, false)
    }

    func testRefreshKeepsLocalStateUpdatesTheRestAndDropsGoneChapters() async throws {
        try await database.saveSeries(series(), details: details(), chapters: [entry(1), entry(2), entry(3)], seedProgress: false)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE chapter SET lastPageRead = 9, isDownloaded = 1 WHERE id = 2")
            try db.execute(sql: "UPDATE series SET inLibrary = 1 WHERE id = 7")
        }

        try await database.saveSeries(
            series(name: "Berserk Deluxe"), details: details(),
            chapters: [entry(2, pages: 25, pagesRead: 20, name: "Renamed"), entry(4)],
            seedProgress: true
        )

        let stored = try await chapters()
        XCTAssertEqual(stored.map(\.id), [2, 4])
        let kept = stored[0]
        XCTAssertEqual(kept.name, "Renamed")
        XCTAssertEqual(kept.pages, 25)
        XCTAssertEqual(kept.readingOrder, 0)
        XCTAssertEqual(kept.lastPageRead, 9, "a refresh doesn't overwrite local progress")
        XCTAssertFalse(kept.read)
        XCTAssertTrue(kept.isDownloaded)
        let record = try await database.writer.read { try SeriesRecord.fetchOne($0, key: 7) }
        XCTAssertEqual(record?.name, "Berserk Deluxe")
        XCTAssertEqual(record?.inLibrary, true)
    }

    func testMarkingReadAndUnread() async throws {
        try await database.saveSeries(series(), details: details(), chapters: [entry(1), entry(2), entry(3)], seedProgress: false)
        try await database.writer.write { try $0.execute(sql: "UPDATE chapter SET lastPageRead = 4") }

        try await database.setChaptersRead([1, 2], read: true)
        var stored = try await chapters()
        XCTAssertEqual(stored.map(\.read), [true, true, false])
        XCTAssertEqual(stored.map(\.lastPageRead), [4, 4, 4])

        try await database.setChaptersRead([2], read: false)
        stored = try await chapters()
        XCTAssertEqual(stored.map(\.read), [true, false, false])
        XCTAssertEqual(stored[1].lastPageRead, 0, "unread starts again from the first page")
    }

    func testUnreadChaptersBefore() async throws {
        try await database.saveSeries(
            series(), details: details(), chapters: [entry(1), entry(2), entry(3), entry(4)], seedProgress: false
        )
        try await database.setChaptersRead([2], read: true)
        let stored = try await chapters()

        let ids = try await database.unreadChapterIds(before: stored[3])
        XCTAssertEqual(Set(ids), [1, 3])
    }
}
