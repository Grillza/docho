import Foundation
import GRDB

/// A progress change waiting to reach Kavita (Android's `KavitaPendingProgress`).
struct PendingProgress: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "pendingProgress"

    var chapterId: Int
    var seriesId: Int
    var libraryId: Int
    var volumeId: Int
    var pageNum: Int
    /// A read/unread mark made by hand; it's sent even if the server has read further.
    var markedByUser: Bool
    var queuedAt: Date

    init(_ progress: KavitaProgress, markedByUser: Bool, queuedAt: Date = Date()) {
        chapterId = progress.chapterId
        seriesId = progress.seriesId
        libraryId = progress.libraryId
        volumeId = progress.volumeId
        pageNum = progress.pageNum
        self.markedByUser = markedByUser
        self.queuedAt = queuedAt
    }

    var progress: KavitaProgress {
        KavitaProgress(volumeId: volumeId, chapterId: chapterId, pageNum: pageNum, seriesId: seriesId, libraryId: libraryId)
    }

    /// The same change, ignoring when it was queued (the database rounds dates to milliseconds).
    func isSameChange(as other: PendingProgress) -> Bool {
        progress == other.progress && markedByUser == other.markedByUser
    }

    enum Columns {
        static let seriesId = Column(CodingKeys.seriesId)
        static let queuedAt = Column(CodingKeys.queuedAt)
    }
}

/// A pulled change to one chapter's local progress.
struct PulledProgress: Sendable, Equatable {
    var chapterId: Int
    /// Set the chapter read.
    var read = false
    /// Raise `lastPageRead` to this page.
    var lastPageRead: Int?
}

extension AppDatabase {
    /// Queues changes, replacing older ones for the same chapter (see `KavitaSync.mergePending`).
    /// Returns the entries as stored.
    func enqueue(_ progress: [KavitaProgress], markedByUser: Bool) async throws -> [PendingProgress] {
        try await writer.write { db in
            try progress.map { change in
                let previous = try PendingProgress.fetchOne(db, key: change.chapterId)
                let entry = KavitaSync.mergePending(previous, change, markedByUser: markedByUser)
                try entry.save(db)
                return entry
            }
        }
    }

    /// Drops delivered entries, but only those nothing newer has replaced in the meantime.
    func removePending(_ delivered: [PendingProgress]) async throws {
        try await writer.write { db in
            for entry in delivered {
                if let current = try PendingProgress.fetchOne(db, key: entry.chapterId), current.isSameChange(as: entry) {
                    try current.delete(db)
                }
            }
        }
    }

    /// Queued changes, oldest first; only one series' when `seriesId` is given.
    func pendingProgress(seriesId: Int? = nil) async throws -> [PendingProgress] {
        try await writer.read { db in
            var request = PendingProgress.order(PendingProgress.Columns.queuedAt)
            if let seriesId { request = request.filter(PendingProgress.Columns.seriesId == seriesId) }
            return try request.fetchAll(db)
        }
    }

    /// How many chapters have progress waiting to be sent, updated as it changes.
    func pendingCount() -> AsyncValueObservation<Int> {
        ValueObservation.tracking { db in try PendingProgress.fetchCount(db) }.values(in: writer)
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

    /// Ids of the series added to the library.
    func librarySeriesIds() async throws -> [Int] {
        try await writer.read { db in
            try Int.fetchAll(db, SeriesRecord.select(Column("id")).filter(Column("inLibrary") == true))
        }
    }
}
