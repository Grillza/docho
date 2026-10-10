import Foundation
import GRDB

/// A chapter of a series, with the local reading state. `seriesId`, `libraryId`, `volumeId` and
/// `pages` are what every progress update to Kavita needs (Android keeps them in the chapter memo).
struct ChapterRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    static let databaseTableName = "chapter"

    /// The Kavita chapter id.
    var id: Int
    var seriesId: Int
    var volumeId: Int
    var libraryId: Int
    var name: String
    var number: Double
    /// Position in Kavita's reading order, from 0.
    var readingOrder: Int
    var pages: Int
    var read: Bool
    /// 0-based index of the page being viewed.
    var lastPageRead: Int
    var dateUpload: Date?
    var isDownloaded: Bool

    enum Columns {
        static let seriesId = Column(CodingKeys.seriesId)
        static let readingOrder = Column(CodingKeys.readingOrder)
        static let read = Column(CodingKeys.read)
        static let lastPageRead = Column(CodingKeys.lastPageRead)
    }

    /// Started but not finished.
    var inProgress: Bool { !read && lastPageRead > 0 }
}

extension AppDatabase {
    /// Stores a series fetched from Kavita with its chapters, in one transaction.
    ///
    /// Local reading state is kept for chapters already stored. New chapters start from the
    /// server's `pagesRead` when `seedProgress` is on; that's what the milestone 6 pull would do
    /// for a chapter with no local progress. Chapters gone from the server are deleted.
    func saveSeries(
        _ series: KavitaSeries,
        details: KavitaSeriesDetails,
        chapters entries: [KavitaChapterEntry],
        seedProgress: Bool
    ) async throws {
        try await writer.write { db in
            var record = try SeriesRecord.fetchOne(db, key: series.id)
                ?? SeriesRecord(id: series.id, libraryId: series.libraryId, name: series.title, inLibrary: false)
            record.name = series.title
            record.libraryId = series.libraryId
            record.summary = details.summary
            record.authors = details.authors
            record.artists = details.artists
            record.genres = details.genres
            record.status = details.status
            try record.save(db)

            let existing = try ChapterRecord
                .filter(ChapterRecord.Columns.seriesId == series.id)
                .fetchAll(db)
            let byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

            for (order, entry) in entries.enumerated() {
                var chapter = byId[entry.chapterId] ?? ChapterRecord(
                    id: entry.chapterId, seriesId: series.id, volumeId: entry.volumeId, libraryId: series.libraryId,
                    name: entry.name, number: entry.number, readingOrder: order, pages: entry.pages,
                    read: false, lastPageRead: 0, dateUpload: entry.dateUpload, isDownloaded: false
                )
                if byId[entry.chapterId] == nil, seedProgress, entry.pages > 0 {
                    chapter.read = entry.pagesRead >= entry.pages
                    chapter.lastPageRead = chapter.read ? 0 : entry.pagesRead
                }
                chapter.volumeId = entry.volumeId
                chapter.libraryId = series.libraryId
                chapter.name = entry.name
                chapter.number = entry.number
                chapter.readingOrder = order
                chapter.pages = entry.pages
                chapter.dateUpload = entry.dateUpload
                try chapter.save(db)
            }

            let current = Set(entries.map(\.chapterId))
            for gone in existing where !current.contains(gone.id) {
                try gone.delete(db)
            }
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

    /// Saves the reader's position. `read` never goes back to false here; only a hand mark does that.
    func saveProgress(chapterId: Int, lastPageRead: Int, read: Bool) async throws {
        try await writer.write { db in
            guard var chapter = try ChapterRecord.fetchOne(db, key: chapterId) else { return }
            chapter.lastPageRead = lastPageRead
            chapter.read = chapter.read || read
            try chapter.update(db)
        }
    }

    func setReaderMode(seriesId: Int, _ mode: String?) async throws {
        try await writer.write { db in
            _ = try SeriesRecord.filter(key: seriesId).updateAll(db, Column("readerMode").set(to: mode))
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

    /// One series, updated as it changes; nil until it's been stored.
    func series(id: Int) -> AsyncValueObservation<SeriesRecord?> {
        ValueObservation
            .tracking { db in try SeriesRecord.fetchOne(db, key: id) }
            .values(in: writer)
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
}
