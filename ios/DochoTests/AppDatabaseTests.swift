import GRDB
import XCTest
@testable import Docho

final class AppDatabaseTests: XCTestCase {
    private var database: AppDatabase!
    private let kavita = KavitaSource.id

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
    }

    private func first<T: Sendable>(_ observation: AsyncValueObservation<T>) async throws -> T {
        for try await value in observation { return value }
        throw CancellationError()
    }

    private func manga(_ id: Int, _ name: String) -> SManga {
        SManga(url: "/library/1/series/\(id)", title: name)
    }

    private func chapter(_ id: Int, name: String? = nil, file: String? = nil, date: Date? = nil) -> SChapter {
        var memo = ChapterMemo([KavitaSource.memoPages: .int(20)])
        if let file { memo[ChapterMemo.fileName] = .string(file) }
        return SChapter(url: "/chapter/\(id)", name: name ?? "Ch. \(id)", dateUpload: date, number: Double(id), memo: memo)
    }

    // MARK: Libraries and series

    func testSavingLibrariesReplacesThemAndSortsByName() async throws {
        try await database.saveLibraries([KavitaLibrary(id: 1, name: "manga"), KavitaLibrary(id: 2, name: "Comics")])
        try await database.saveLibraries([KavitaLibrary(id: 3, name: "Webtoons"), KavitaLibrary(id: 1, name: "manga")])

        let libraries = try await first(database.libraries())
        XCTAssertEqual(libraries.map(\.name), ["manga", "Webtoons"])
    }

    func testListingEntriesBecomeLocalSeriesWithStableIds() async throws {
        let first = try await database.localSeries(source: kavita, mangas: [manga(7, "Berserk"), manga(8, "Monster")])
        let again = try await database.localSeries(source: kavita, mangas: [manga(8, "Monster"), manga(7, "Berserk")])
        XCTAssertEqual(again.map(\.id), [first[1].id, first[0].id])
        XCTAssertNotEqual(first[0].id, first[1].id)

        // The same URL from another source is another series.
        let other = try await database.localSeries(source: KomgaSource.id, manga: manga(7, "Berserk"))
        XCTAssertNotEqual(other.id, first[0].id)
    }

    func testListingsDontOverwriteLibraryEntries() async throws {
        let series = try await database.localSeries(source: kavita, manga: manga(7, "Berserk"))
        try await database.setInLibrary(seriesId: series.id, true)
        _ = try await database.localSeries(source: kavita, manga: manga(7, "Renamed"))
        let stored = try await database.seriesRecord(id: series.id)
        XCTAssertEqual(stored?.name, "Berserk")
    }

    func testAddingAndRemovingSeriesKeepsTheCachedRow() async throws {
        let series = try await database.localSeries(source: kavita, manga: manga(7, "Berserk"))
        try await database.setInLibrary(seriesId: series.id, true)
        var library = try await first(database.library())
        XCTAssertEqual(library.map(\.series.name), ["Berserk"])
        XCTAssertNotNil(library.first?.series.dateAdded)

        try await database.setInLibrary(seriesId: series.id, false)
        library = try await first(database.library())
        XCTAssertEqual(library, [])
        let cached = try await database.seriesRecord(id: series.id)
        XCTAssertEqual(cached?.inLibrary, false)
        XCTAssertNil(cached?.dateAdded)
    }

    func testCategories() async throws {
        try await database.createCategory("Reading")
        try await database.createCategory("Done")
        var categories = try await database.categoryList()
        XCTAssertEqual(categories.map(\.name), ["Reading", "Done"])

        try await database.reorderCategories(categories.reversed().map(\.id))
        categories = try await database.categoryList()
        XCTAssertEqual(categories.map(\.name), ["Done", "Reading"])

        let series = try await database.localSeries(source: kavita, manga: manga(7, "Berserk"))
        try await database.setInLibrary(seriesId: series.id, true, categories: [categories[1].id])
        var item = try await first(database.library()).first
        XCTAssertEqual(item?.categoryIds, [categories[1].id])

        try await database.deleteCategory(categories[1].id)
        item = try await first(database.library()).first
        XCTAssertEqual(item?.categoryIds, [], "a deleted category's series go back to Default")
    }

    // MARK: Chapters

    func testSavesChaptersInReadingOrderWithTheirMemo() async throws {
        let series = try await database.localSeries(source: kavita, manga: manga(7, "Berserk"))
        try await database.saveFromSource(seriesId: series.id, manga: nil, chapters: [chapter(3), chapter(1)])

        let stored = try await database.chapterList(seriesId: series.id)
        XCTAssertEqual(stored.map(\.url), ["/chapter/3", "/chapter/1"])
        XCTAssertEqual(stored.map(\.readingOrder), [0, 1])
        XCTAssertEqual(stored.first?.pages, 20)
        XCTAssertEqual(stored.first?.chapterMemo.int(KavitaSource.memoPages), 20)
    }

    func testRefreshKeepsLocalStateUpdatesTheRestAndDropsGoneChapters() async throws {
        let series = try await database.localSeries(source: kavita, manga: manga(7, "Berserk"))
        try await database.saveFromSource(seriesId: series.id, manga: nil, chapters: [chapter(1), chapter(2), chapter(3)])
        let kept = try await database.chapterList(seriesId: series.id)[1]
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE chapter SET lastPageRead = 9, isDownloaded = 1, bookmark = 1 WHERE id = ?", arguments: [kept.id])
        }

        var details = manga(7, "Berserk Deluxe")
        details.description = "s"
        details.initialized = true
        let added = try await database.saveFromSource(
            seriesId: series.id, manga: details, chapters: [chapter(2, name: "Renamed"), chapter(4)]
        )

        let stored = try await database.chapterList(seriesId: series.id)
        XCTAssertEqual(stored.map(\.url), ["/chapter/2", "/chapter/4"])
        XCTAssertEqual(stored[0].id, kept.id, "a chapter keeps its local id")
        XCTAssertEqual(stored[0].name, "Renamed")
        XCTAssertEqual(stored[0].lastPageRead, 9, "a refresh doesn't overwrite local progress")
        XCTAssertTrue(stored[0].isDownloaded)
        XCTAssertTrue(stored[0].bookmark)
        XCTAssertEqual(added.map(\.url), ["/chapter/4"], "chapters found after the first fetch are new")
        let record = try await database.seriesRecord(id: series.id)
        XCTAssertEqual(record?.name, "Berserk Deluxe")
        XCTAssertEqual(record?.summary, "s")
        XCTAssertEqual(record?.initialized, true)
    }

    func testUpdatesListNewChaptersOfLibrarySeries() async throws {
        let series = try await database.localSeries(source: kavita, manga: manga(7, "Berserk"))
        try await database.setInLibrary(seriesId: series.id, true)
        try await database.saveFromSource(seriesId: series.id, manga: nil, chapters: [chapter(1)])
        try await Task.sleep(for: .milliseconds(20))
        try await database.saveFromSource(seriesId: series.id, manga: nil, chapters: [chapter(1), chapter(2)])

        let updates = try await first(database.updates())
        XCTAssertEqual(updates.map(\.chapter.url), ["/chapter/2"])
        XCTAssertEqual(updates.first?.series.id, series.id)
    }

    func testMarkingReadAndUnread() async throws {
        let series = try await database.localSeries(source: kavita, manga: manga(7, "Berserk"))
        try await database.saveFromSource(seriesId: series.id, manga: nil, chapters: [chapter(1), chapter(2), chapter(3)])
        let ids = try await database.chapterList(seriesId: series.id).map(\.id)
        try await database.writer.write { try $0.execute(sql: "UPDATE chapter SET lastPageRead = 4") }

        try await database.setChaptersRead([ids[0], ids[1]], read: true)
        try await database.setChaptersRead([ids[1]], read: false)
        let stored = try await database.chapterList(seriesId: series.id)
        XCTAssertEqual(stored.map(\.read), [true, false, false])
        XCTAssertEqual(stored.map(\.lastPageRead), [4, 0, 4], "unread starts again from the first page")

        let before = try await database.unreadChapterIds(before: stored[2])
        XCTAssertEqual(before, [ids[1]])
    }

    func testSavingProgressRecordsHistoryUnlessIncognito() async throws {
        let series = try await database.localSeries(source: kavita, manga: manga(7, "Berserk"))
        try await database.saveFromSource(seriesId: series.id, manga: nil, chapters: [chapter(1), chapter(2)])
        let ids = try await database.chapterList(seriesId: series.id).map(\.id)

        try await database.saveProgress(chapterId: ids[0], lastPageRead: 3, read: false)
        try await database.saveProgress(chapterId: ids[1], lastPageRead: 1, read: false, history: false)

        let history = try await first(database.history())
        XCTAssertEqual(history.map(\.chapter.id), [ids[0]])
        let next = try await database.nextChapter(seriesId: series.id)
        XCTAssertEqual(next?.id, ids[0], "the chapter in progress is the one to continue")
    }

    func testChapterSortAndFilter() async throws {
        let series = try await database.localSeries(source: kavita, manga: manga(7, "JoJo"))
        // Volume numbers restart per part, so only the file names give the order.
        try await database.saveFromSource(seriesId: series.id, manga: nil, chapters: [
            chapter(1, name: "Vol. 10", file: "JoJo v10.cbz"),
            chapter(2, name: "Vol. 2", file: "JoJo v2.cbz"),
            chapter(3, name: "Vol. 1", file: "JoJo v1.cbz"),
        ])
        let chapters = try await database.chapterList(seriesId: series.id)
        var display = ChapterDisplay(sort: .fileName, descending: false)
        XCTAssertEqual(chapters.displayed(display).map(\.name), ["Vol. 1", "Vol. 2", "Vol. 10"])

        display.sort = .source
        display.descending = true
        XCTAssertEqual(chapters.displayed(display).map(\.name), ["Vol. 1", "Vol. 2", "Vol. 10"])

        try await database.setChaptersRead([chapters[1].id], read: true)
        display.unread = .include
        let unread = try await database.chapterList(seriesId: series.id).displayed(display)
        XCTAssertEqual(unread.map(\.name), ["Vol. 1", "Vol. 10"])
    }

    // MARK: Migration

    /// PLAN-2 milestone 11: an existing install upgrades with its library, progress, queue and
    /// downloads intact, and its ids unchanged.
    func testVersion4UpgradesWithNothingLost() throws {
        let queue = try AppDatabase.migrated(upTo: "v4")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO library (id, name, type) VALUES (2, 'Manga', 0);
                INSERT INTO series (id, libraryId, name, summary, status, inLibrary, readerMode)
                    VALUES (7, 2, 'Berserk', 'dark', 2, 1, 'webtoon');
                INSERT INTO chapter (id, seriesId, volumeId, libraryId, name, number, readingOrder, pages, read, lastPageRead, isDownloaded)
                    VALUES (70, 7, 5, 2, 'Ch. 1', 1, 0, 20, 1, 0, 1),
                           (71, 7, 5, 2, 'Ch. 2', 2, 1, 20, 0, 6, 0);
                INSERT INTO pendingProgress (chapterId, seriesId, libraryId, volumeId, pageNum, markedByUser, queuedAt)
                    VALUES (71, 7, 2, 5, 6, 0, CURRENT_TIMESTAMP);
                INSERT INTO download (chapterId, seriesId, state, queuedAt) VALUES (71, 7, 'queued', CURRENT_TIMESTAMP);
                """)
        }

        let database = try AppDatabase(queue)
        try queue.read { db in
            let series = try XCTUnwrap(SeriesRecord.fetchOne(db, key: 7))
            XCTAssertEqual(series.source, KavitaSource.id)
            XCTAssertEqual(series.url, "/library/2/series/7")
            XCTAssertEqual(series.mangaStatus, .completed)
            XCTAssertTrue(series.inLibrary)
            XCTAssertEqual(series.readerMode, "webtoon")

            let chapters = try ChapterRecord.order(Column("id")).fetchAll(db)
            XCTAssertEqual(chapters.map(\.id), [70, 71])
            XCTAssertEqual(chapters.map(\.url), ["/chapter/70", "/chapter/71"])
            XCTAssertEqual(chapters.map(\.read), [true, false])
            XCTAssertEqual(chapters[1].lastPageRead, 6)
            XCTAssertTrue(chapters[0].isDownloaded)
            XCTAssertEqual(chapters[1].chapterMemo.int(KavitaSource.memoVolumeId), 5)
            XCTAssertEqual(chapters[1].chapterMemo.int(KavitaSource.memoLibraryId), 2)

            XCTAssertEqual(try PendingProgress.fetchCount(db), 1)
            XCTAssertEqual(try DownloadRecord.fetchOne(db, key: 71)?.state, .queued)
            XCTAssertEqual(try LibraryRecord.fetchCount(db), 1)
        }

        // New rows take ids above the old ones, and chapters still reference their series.
        try queue.write { db in
            XCTAssertEqual(try AppDatabase.nextId(db, table: "series"), 8)
            try SeriesRecord(id: 8, source: KomgaSource.id, manga: SManga(url: "/series/a", title: "Komga")).insert(db)
            try db.execute(sql: "INSERT INTO chapter (id, seriesId, url, name, readingOrder) VALUES (72, 8, '/book/b', 'b', 0)")
            try db.execute(sql: "DELETE FROM series WHERE id = 8")
            XCTAssertEqual(try ChapterRecord.fetchOne(db, key: 72), nil, "chapters are deleted with their series")
        }
        _ = database
    }

    func testOpensOnDiskInAFolderWithASpace() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Application Support \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try AppDatabase.onDisk(in: directory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "docho.sqlite").path(percentEncoded: false)))
    }
}
