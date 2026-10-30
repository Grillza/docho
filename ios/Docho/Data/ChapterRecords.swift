import Foundation
import GRDB

/// A chapter of a series, with the local reading state (Mihon's `Chapter`).
struct ChapterRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable, Hashable {
    static let databaseTableName = "chapter"

    var id: Int
    var seriesId: Int
    /// The source's key for the chapter (`SChapter.url`).
    var url: String
    var name: String
    var number: Double
    var scanlator: String?
    /// Position in the source's reading order, from 0 (the first chapter).
    var readingOrder: Int
    /// 0 until known; the reader learns it when it opens the chapter.
    var pages: Int
    var read: Bool
    var bookmark: Bool
    /// 0-based index of the page being viewed.
    var lastPageRead: Int
    var dateUpload: Date?
    /// When the app first saw the chapter; Updates lists chapters by it.
    var dateFetch: Date?
    var isDownloaded: Bool
    /// `ChapterMemo` as JSON.
    var memo: String?

    enum Columns {
        static let seriesId = Column(CodingKeys.seriesId)
        static let url = Column(CodingKeys.url)
        static let readingOrder = Column(CodingKeys.readingOrder)
        static let read = Column(CodingKeys.read)
        static let bookmark = Column(CodingKeys.bookmark)
        static let lastPageRead = Column(CodingKeys.lastPageRead)
        static let isDownloaded = Column(CodingKeys.isDownloaded)
    }

    /// Started but not finished.
    var inProgress: Bool { !read && lastPageRead > 0 }

    var chapterMemo: ChapterMemo {
        get { ChapterMemo(json: memo) }
        set { memo = newValue.json }
    }

    var schapter: SChapter {
        SChapter(url: url, name: name, dateUpload: dateUpload, number: number, scanlator: scanlator, memo: chapterMemo)
    }

    /// For the file-name sort: the memo's file name, else the chapter name.
    var fileNameKey: String { chapterMemo.string(ChapterMemo.fileName) ?? name }
}

extension AppDatabase {
    /// Stores a series' details and/or chapter list from its source, in one transaction (Mihon's
    /// `syncChaptersWithSource`). Local reading state is kept for chapters already stored; new
    /// ones are dated now so Updates lists them; chapters gone from the source are deleted.
    /// Returns the chapters that are new.
    @discardableResult
    func saveFromSource(seriesId: Int, manga: SManga?, chapters: [SChapter]?) async throws -> [ChapterRecord] {
        try await writer.write { db in
            guard var series = try SeriesRecord.fetchOne(db, key: seriesId) else { return [] }
            if let manga {
                series.apply(manga)
            }
            guard let chapters else {
                try series.update(db)
                return []
            }
            series.lastUpdate = Date()
            try series.update(db)

            let existing = try ChapterRecord.filter(ChapterRecord.Columns.seriesId == seriesId).fetchAll(db)
            let byURL = Dictionary(existing.map { ($0.url, $0) }) { first, _ in first }
            let now = Date()
            var added: [ChapterRecord] = []
            // A series' first fetch isn't news: those chapters are dated at the epoch, so Updates
            // (chapters fetched after the series was added) only lists chapters found later.
            let firstFetch = existing.isEmpty
            for (order, source) in chapters.enumerated() {
                if var chapter = byURL[source.url] {
                    chapter.name = source.name
                    chapter.number = source.number
                    chapter.scanlator = source.scanlator
                    chapter.readingOrder = order
                    chapter.dateUpload = source.dateUpload ?? chapter.dateUpload
                    let memo = source.memo
                    if !memo.values.isEmpty { chapter.chapterMemo = memo }
                    if let pages = memo.int("kavitaPages") ?? memo.int("pages"), pages > 0 { chapter.pages = pages }
                    try chapter.update(db)
                } else {
                    var chapter = ChapterRecord(
                        id: try Self.nextId(db, table: "chapter"), seriesId: seriesId, url: source.url, name: source.name,
                        number: source.number, scanlator: source.scanlator, readingOrder: order,
                        pages: source.memo.int("kavitaPages") ?? source.memo.int("pages") ?? 0, read: false,
                        bookmark: false, lastPageRead: 0, dateUpload: source.dateUpload,
                        dateFetch: firstFetch ? Date(timeIntervalSince1970: 0) : now, isDownloaded: false, memo: nil
                    )
                    chapter.chapterMemo = source.memo
                    try chapter.insert(db)
                    if !firstFetch { added.append(chapter) }
                }
            }
            let current = Set(chapters.map(\.url))
            for gone in existing where !current.contains(gone.url) {
                try gone.delete(db)
            }
            return added
        }
    }

    /// Marks chapters read or unread locally. Unread also goes back to the first page.
    func setChaptersRead(_ chapterIds: [Int], read: Bool) async throws {
        try await writer.write { db in
            var assignments = [ChapterRecord.Columns.read.set(to: read)]
            if !read { assignments.append(ChapterRecord.Columns.lastPageRead.set(to: 0)) }
            _ = try ChapterRecord.filter(keys: chapterIds).updateAll(db, assignments)
        }
    }

    func setBookmarked(_ chapterIds: [Int], _ bookmarked: Bool) async throws {
        try await writer.write { db in
            _ = try ChapterRecord.filter(keys: chapterIds).updateAll(db, ChapterRecord.Columns.bookmark.set(to: bookmarked))
        }
    }

    /// Saves the reader's position and the reading history. `read` never goes back to false here;
    /// only a hand mark does that. `pages` records the page count once the reader knows it.
    func saveProgress(chapterId: Int, lastPageRead: Int, read: Bool, pages: Int? = nil, history: Bool = true) async throws {
        try await writer.write { db in
            guard var chapter = try ChapterRecord.fetchOne(db, key: chapterId) else { return }
            chapter.lastPageRead = lastPageRead
            chapter.read = chapter.read || read
            if let pages, pages > 0 { chapter.pages = pages }
            try chapter.update(db)
            if history {
                try db.execute(
                    sql: """
                        INSERT INTO history (chapterId, lastRead, timeRead) VALUES (?, ?, 0)
                        ON CONFLICT(chapterId) DO UPDATE SET lastRead = excluded.lastRead
                        """,
                    arguments: [chapterId, Date()]
                )
            }
        }
    }

    func setPageCount(chapterId: Int, pages: Int) async throws {
        try await writer.write { db in
            _ = try ChapterRecord.filter(key: chapterId).updateAll(db, Column("pages").set(to: pages))
        }
    }

    /// The chapter ids before `chapter` in reading order that aren't read yet.
    func unreadChapterIds(before chapter: ChapterRecord) async throws -> [Int] {
        try await writer.read { db in
            try Int.fetchAll(db, ChapterRecord
                .select(Column("id"))
                .filter(ChapterRecord.Columns.seriesId == chapter.seriesId)
                .filter(ChapterRecord.Columns.readingOrder < chapter.readingOrder)
                .filter(!ChapterRecord.Columns.read))
        }
    }

    /// A series' chapters in reading order, updated as they change.
    func chapters(seriesId: Int) -> AsyncValueObservation<[ChapterRecord]> {
        ValueObservation
            .tracking { db in
                try ChapterRecord
                    .filter(ChapterRecord.Columns.seriesId == seriesId)
                    .order(ChapterRecord.Columns.readingOrder)
                    .fetchAll(db)
            }
            .values(in: writer)
    }

    /// A series' chapters in reading order, once.
    func chapterList(seriesId: Int) async throws -> [ChapterRecord] {
        try await writer.read { db in
            try ChapterRecord
                .filter(ChapterRecord.Columns.seriesId == seriesId)
                .order(ChapterRecord.Columns.readingOrder)
                .fetchAll(db)
        }
    }

    func chapters(ids: [Int]) async throws -> [ChapterRecord] {
        try await writer.read { db in try ChapterRecord.fetchAll(db, keys: ids) }
    }

    func chapter(id: Int) async throws -> ChapterRecord? {
        try await writer.read { db in try ChapterRecord.fetchOne(db, key: id) }
    }

    /// Applies pulled progress in one transaction. Pages only ever move forward here, in case the
    /// reader saved a later page while the server was being asked.
    func applyPulled(_ changes: [PulledProgress]) async throws {
        guard !changes.isEmpty else { return }
        try await writer.write { db in
            for change in changes {
                guard var chapter = try ChapterRecord.fetchOne(db, key: change.chapterId) else { continue }
                if change.read { chapter.read = true }
                if let page = change.lastPageRead { chapter.lastPageRead = max(chapter.lastPageRead, page) }
                try chapter.update(db)
            }
        }
    }
}

/// A pulled change to one chapter's local progress (by local chapter id).
struct PulledProgress: Sendable, Equatable {
    var chapterId: Int
    /// Set the chapter read.
    var read = false
    /// Raise `lastPageRead` to this page.
    var lastPageRead: Int?
}

extension Array where Element == ChapterRecord {
    /// The chapter list as the series screen shows it: filtered and sorted per `display`.
    func displayed(_ display: ChapterDisplay, downloaded downloadedOnly: Bool = false) -> [ChapterRecord] {
        let filtered = filter { chapter in
            Self.matches(display.unread, !chapter.read)
                && Self.matches(downloadedOnly ? .include : display.downloaded, chapter.isDownloaded)
                && Self.matches(display.bookmarked, chapter.bookmark)
        }
        let ascending: [ChapterRecord] = switch display.sort {
        case .source: filtered.sorted { $0.readingOrder < $1.readingOrder }
        case .number: filtered.sorted { ($0.number, $0.readingOrder) < ($1.number, $1.readingOrder) }
        case .uploadDate:
            filtered.sorted { ($0.dateUpload ?? .distantPast, $0.readingOrder) < ($1.dateUpload ?? .distantPast, $1.readingOrder) }
        case .alphabet:
            filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .fileName:
            filtered.sorted { $0.fileNameKey.localizedStandardCompare($1.fileNameKey) == .orderedAscending }
        }
        return display.descending ? ascending.reversed() : ascending
    }

    private static func matches(_ state: ChapterDisplay.TriState, _ value: Bool) -> Bool {
        switch state {
        case .off: true
        case .include: value
        case .exclude: !value
        }
    }
}
