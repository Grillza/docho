import Foundation
import GRDB

/// When a chapter was last read (Mihon's `History`).
struct HistoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "history"

    var chapterId: Int
    var lastRead: Date
    var timeRead: Int
}

/// One History row: a series' most recently read chapter (Mihon's `HistoryWithRelations`).
struct HistoryItem: FetchableRecord, Sendable, Equatable, Identifiable {
    var chapter: ChapterRecord
    var series: SeriesRecord
    var lastRead: Date

    var id: Int { chapter.id }

    init(row: Row) throws {
        chapter = try ChapterRecord(row: row.scopes["chapter"] ?? row)
        series = try SeriesRecord(row: row.scopes["series"] ?? row)
        lastRead = row["lastRead"]
    }
}

/// One Updates row: a chapter that appeared in a library series (Mihon's `UpdatesWithRelations`).
struct UpdateItem: FetchableRecord, Sendable, Equatable, Identifiable {
    var chapter: ChapterRecord
    var series: SeriesRecord

    var id: Int { chapter.id }
    var dateFetch: Date { chapter.dateFetch ?? .distantPast }

    init(row: Row) throws {
        chapter = try ChapterRecord(row: row.scopes["chapter"] ?? row)
        series = try SeriesRecord(row: row.scopes["series"] ?? row)
    }
}

extension AppDatabase {
    /// History, one row per series, most recent first; `query` narrows it by series name.
    func history(query: String = "") -> AsyncValueObservation<[HistoryItem]> {
        let pattern = "%\(query)%"
        return ValueObservation
            .tracking { db -> [HistoryItem] in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT chapter.*, series.*, history.lastRead
                    FROM history
                    JOIN chapter ON chapter.id = history.chapterId
                    JOIN series ON series.id = chapter.seriesId
                    WHERE history.lastRead = (
                        SELECT MAX(h.lastRead) FROM history h JOIN chapter c ON c.id = h.chapterId
                        WHERE c.seriesId = series.id)
                      AND series.name LIKE ?
                    ORDER BY history.lastRead DESC
                    LIMIT 500
                    """, arguments: [pattern], adapter: Self.chapterSeriesAdapter(db))
                return try rows.map(HistoryItem.init(row:))
            }
            .values(in: writer)
    }

    /// Removes one chapter's history, or every chapter's of its series when `wholeSeries` is set.
    func deleteHistory(chapterId: Int, wholeSeries: Bool) async throws {
        try await writer.write { db in
            if wholeSeries {
                try db.execute(sql: """
                    DELETE FROM history WHERE chapterId IN (
                        SELECT id FROM chapter WHERE seriesId = (SELECT seriesId FROM chapter WHERE id = ?))
                    """, arguments: [chapterId])
            } else {
                _ = try HistoryRecord.deleteOne(db, key: chapterId)
            }
        }
    }

    func deleteAllHistory() async throws {
        try await writer.write { db in _ = try HistoryRecord.deleteAll(db) }
    }

    /// The chapter to continue a series from: the first unread one in reading order after the
    /// last one read, or the first unread.
    func nextChapter(seriesId: Int) async throws -> ChapterRecord? {
        try await writer.read { db in
            let chapters = try ChapterRecord
                .filter(ChapterRecord.Columns.seriesId == seriesId)
                .order(ChapterRecord.Columns.readingOrder)
                .fetchAll(db)
            if let started = chapters.first(where: \.inProgress) { return started }
            let lastRead = chapters.lastIndex(where: \.read)
            let after = lastRead.map { chapters[($0 + 1)...] } ?? chapters[...]
            return after.first { !$0.read } ?? chapters.first { !$0.read }
        }
    }

    /// New chapters of library series, newest first (Mihon's Updates tab).
    func updates(limit: Int = 500) -> AsyncValueObservation<[UpdateItem]> {
        ValueObservation
            .tracking { db -> [UpdateItem] in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT chapter.*, series.*
                    FROM chapter
                    JOIN series ON series.id = chapter.seriesId
                    WHERE series.inLibrary AND chapter.dateFetch > COALESCE(series.dateAdded, 0)
                    ORDER BY chapter.dateFetch DESC, chapter.readingOrder DESC
                    LIMIT ?
                    """, arguments: [limit], adapter: Self.chapterSeriesAdapter(db))
                return try rows.map(UpdateItem.init(row:))
            }
            .values(in: writer)
    }

    /// Splits `SELECT chapter.*, series.*` rows into "chapter" and "series" scopes.
    private static func chapterSeriesAdapter(_ db: Database) throws -> any RowAdapter {
        let adapters = try splittingRowAdapters(columnCounts: [
            db.columns(in: "chapter").count,
            db.columns(in: "series").count,
        ])
        return ScopeAdapter([
            "chapter": adapters[0],
            "series": adapters[1],
        ])
    }

    /// When the library was last updated from its sources, for Updates' header.
    func lastLibraryUpdate() async throws -> Date? {
        try await writer.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(lastUpdate) FROM series WHERE inLibrary")
        }
    }
}

// MARK: - Sync queue

/// A change waiting to reach Komga, BookOrbit or a KOReader server. Each engine keeps its own
/// entries, keyed by what the server knows the chapter by.
struct SyncQueueRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "syncQueue"

    var engine: String
    var key: String
    /// The series the entry belongs to, in the engine's terms (a server's series id, or a local id).
    var seriesKey: String
    /// The engine's entry, as JSON.
    var payload: String
    var markedByUser: Bool
    var queuedAt: Date
}

extension AppDatabase {
    /// Queues entries, replacing older ones for the same key; a hand mark keeps its priority until
    /// delivered (`mergePending` on Android). Returns the entries as stored.
    func enqueueSync<Entry: Codable & Sendable>(
        engine: String,
        _ entries: [(key: String, seriesKey: String, entry: Entry)],
        markedByUser: Bool
    ) async throws -> [SyncQueueRecord] {
        try await writer.write { db in
            try entries.map { item in
                let previous = try SyncQueueRecord.fetchOne(db, key: ["engine": engine, "key": item.key])
                let record = SyncQueueRecord(
                    engine: engine, key: item.key, seriesKey: item.seriesKey,
                    payload: String(decoding: try JSONEncoder().encode(item.entry), as: UTF8.self),
                    markedByUser: markedByUser || previous?.markedByUser == true, queuedAt: Date()
                )
                try record.save(db)
                return record
            }
        }
    }

    /// Drops delivered entries, but only those nothing newer has replaced in the meantime.
    func removeSync(_ delivered: [SyncQueueRecord]) async throws {
        try await writer.write { db in
            for entry in delivered {
                if let current = try SyncQueueRecord.fetchOne(db, key: ["engine": entry.engine, "key": entry.key]),
                   current.payload == entry.payload, current.markedByUser == entry.markedByUser {
                    try current.delete(db)
                }
            }
        }
    }

    func syncQueue(engine: String, seriesKey: String? = nil) async throws -> [SyncQueueRecord] {
        try await writer.read { db in
            var request = SyncQueueRecord.filter(Column("engine") == engine).order(Column("queuedAt"))
            if let seriesKey { request = request.filter(Column("seriesKey") == seriesKey) }
            return try request.fetchAll(db)
        }
    }

    func clearSyncQueue(engine: String) async throws {
        try await writer.write { db in _ = try SyncQueueRecord.filter(Column("engine") == engine).deleteAll(db) }
    }

    /// How many entries each engine has waiting, updated as it changes.
    func syncQueueCounts() -> AsyncValueObservation<[String: Int]> {
        ValueObservation
            .tracking { db in
                var counts = Dictionary(
                    try Row.fetchAll(db, sql: "SELECT engine, COUNT(*) AS n FROM syncQueue GROUP BY engine")
                        .map { (row: Row) -> (String, Int) in (row["engine"], row["n"]) }
                ) { first, _ in first }
                counts[KavitaSync.engine] = try PendingProgress.fetchCount(db)
                return counts
            }
            .values(in: writer)
    }
}

extension SyncQueueRecord {
    func decode<Entry: Decodable>(_ type: Entry.Type) -> Entry? {
        try? JSONDecoder().decode(type, from: Data(payload.utf8))
    }
}
