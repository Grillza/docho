import Foundation
import GRDB

/// A chapter in the download queue.
struct DownloadRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "download"

    enum State: String, Codable, Sendable {
        case queued
        case downloading
        case failed
    }

    var chapterId: Int
    var seriesId: Int
    var state: State
    var pagesDone = 0
    var pagesTotal = 0
    var error: String?
    var queuedAt = Date()

    var progress: Double { pagesTotal > 0 ? Double(pagesDone) / Double(pagesTotal) : 0 }

    enum Columns {
        static let seriesId = Column(CodingKeys.seriesId)
        static let state = Column(CodingKeys.state)
        static let queuedAt = Column(CodingKeys.queuedAt)
    }
}

/// A queue entry with the names to show it by.
struct DownloadQueueItem: FetchableRecord, Sendable, Equatable, Identifiable {
    var download: DownloadRecord
    var chapterName: String
    var seriesName: String
    var source: Int64

    var id: Int { download.chapterId }

    init(row: Row) throws {
        download = try DownloadRecord(row: row)
        chapterName = row["chapterName"] ?? ""
        seriesName = row["seriesName"] ?? ""
        source = row["source"] ?? 0
    }
}

/// A series with chapters on the device.
struct DownloadedSeries: Decodable, FetchableRecord, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var chapters: Int
}

extension AppDatabase {
    /// Adds chapters to the queue, skipping those already downloaded or queued. Returns how many were added.
    @discardableResult
    func queueDownloads(_ chapters: [ChapterRecord]) async throws -> Int {
        try await writer.write { db in
            var added = 0
            for chapter in chapters where !chapter.isDownloaded {
                guard try DownloadRecord.fetchOne(db, key: chapter.id) == nil else { continue }
                try DownloadRecord(chapterId: chapter.id, seriesId: chapter.seriesId, state: .queued, pagesTotal: chapter.pages)
                    .insert(db)
                added += 1
            }
            return added
        }
    }

    /// Every chapter in the queue, oldest first.
    func queuedDownloads() async throws -> [DownloadRecord] {
        try await writer.read { db in try DownloadRecord.order(DownloadRecord.Columns.queuedAt).fetchAll(db) }
    }

    /// The oldest queued chapter, if any.
    func nextQueuedDownload() async throws -> DownloadRecord? {
        try await writer.read { db in
            try DownloadRecord
                .filter(DownloadRecord.Columns.state == DownloadRecord.State.queued.rawValue)
                .order(DownloadRecord.Columns.queuedAt)
                .fetchOne(db)
        }
    }

    func updateDownload(_ chapterId: Int, _ change: @escaping @Sendable (inout DownloadRecord) -> Void) async throws {
        try await writer.write { db in
            guard var record = try DownloadRecord.fetchOne(db, key: chapterId) else { return }
            change(&record)
            try record.update(db)
        }
    }

    /// Requeues downloads interrupted when the app last stopped, and failed ones when `failed` is set.
    func requeueDownloads(failed: Bool = false) async throws {
        try await writer.write { db in
            var states = [DownloadRecord.State.downloading.rawValue]
            if failed { states.append(DownloadRecord.State.failed.rawValue) }
            _ = try DownloadRecord
                .filter(states.contains(DownloadRecord.Columns.state))
                .updateAll(db, DownloadRecord.Columns.state.set(to: DownloadRecord.State.queued.rawValue))
        }
    }

    func removeDownloads(_ chapterIds: [Int]) async throws {
        try await writer.write { db in
            _ = try DownloadRecord.deleteAll(db, keys: chapterIds)
        }
    }

    /// The finished chapter leaves the queue and counts as downloaded.
    func finishDownload(_ chapterId: Int) async throws {
        try await writer.write { db in
            _ = try DownloadRecord.deleteOne(db, key: chapterId)
            _ = try ChapterRecord.filter(key: chapterId).updateAll(db, Column("isDownloaded").set(to: true))
        }
    }

    func setDownloaded(_ chapterIds: [Int], _ downloaded: Bool) async throws {
        try await writer.write { db in
            _ = try ChapterRecord.filter(keys: chapterIds).updateAll(db, Column("isDownloaded").set(to: downloaded))
        }
    }

    /// The queue in order, updated as it changes.
    func downloadQueue() -> AsyncValueObservation<[DownloadQueueItem]> {
        ValueObservation
            .tracking { db in
                try DownloadQueueItem.fetchAll(db, sql: """
                    SELECT download.*, chapter.name AS chapterName, series.name AS seriesName, series.source AS source
                    FROM download
                    LEFT JOIN chapter ON chapter.id = download.chapterId
                    LEFT JOIN series ON series.id = download.seriesId
                    ORDER BY download.queuedAt
                    """)
            }
            .values(in: writer)
    }

    /// One series' queue entries by chapter id, updated as they change.
    func downloads(seriesId: Int) -> AsyncValueObservation<[Int: DownloadRecord]> {
        ValueObservation
            .tracking { db in
                let records = try DownloadRecord.filter(DownloadRecord.Columns.seriesId == seriesId).fetchAll(db)
                return Dictionary(uniqueKeysWithValues: records.map { ($0.chapterId, $0) })
            }
            .values(in: writer)
    }

    /// Series with downloaded chapters, by name, updated as they change.
    func downloadedSeries() -> AsyncValueObservation<[DownloadedSeries]> {
        ValueObservation
            .tracking { db in
                try DownloadedSeries.fetchAll(db, sql: """
                    SELECT series.id, series.name, COUNT(chapter.id) AS chapters
                    FROM chapter JOIN series ON series.id = chapter.seriesId
                    WHERE chapter.isDownloaded
                    GROUP BY series.id
                    ORDER BY series.name COLLATE NOCASE
                    """)
            }
            .values(in: writer)
    }

    /// Downloaded chapters of a series; only read ones when `readOnly` is set.
    func downloadedChapterIds(seriesId: Int, readOnly: Bool = false) async throws -> [Int] {
        try await writer.read { db in
            var request = ChapterRecord
                .select(Column("id"))
                .filter(ChapterRecord.Columns.seriesId == seriesId)
                .filter(Column("isDownloaded") == true)
            if readOnly { request = request.filter(ChapterRecord.Columns.read) }
            return try Int.fetchAll(db, request)
        }
    }
}
