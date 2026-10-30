import Foundation
import GRDB

/// The app's SQLite database. Schema changes go in new migrations; never edit a shipped one.
struct AppDatabase: Sendable {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// `Application Support/docho.sqlite`.
    static func onDisk() throws -> AppDatabase {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return try onDisk(in: directory)
    }

    /// The database file in `directory`. The path is passed unencoded: `URL.path()` would turn
    /// "Application Support" into "Application%20Support".
    static func onDisk(in directory: URL) throws -> AppDatabase {
        try AppDatabase(DatabasePool(path: directory.appending(path: "docho.sqlite").path(percentEncoded: false)))
    }

    static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    /// The next id for a table with AUTOINCREMENT, so records can be inserted with their id known.
    /// SQLite never hands an AUTOINCREMENT id out twice, which keeps old download folders unique.
    static func nextId(_ db: Database, table: String) throws -> Int {
        let sequence = try Int.fetchOne(db, sql: "SELECT seq FROM sqlite_sequence WHERE name = ?", arguments: [table]) ?? 0
        let highest = try Int.fetchOne(db, sql: "SELECT MAX(id) FROM \(table)") ?? 0
        return max(sequence, highest) + 1
    }

    /// A database migrated only as far as `version`, to test upgrades from it.
    static func migrated(upTo version: String) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: version)
        return queue
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "library") { table in
                table.primaryKey("id", .integer)
                table.column("name", .text).notNull()
                table.column("type", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "series") { table in
                table.primaryKey("id", .integer) // Kavita series id
                table.column("libraryId", .integer).notNull()
                table.column("name", .text).notNull()
                table.column("summary", .text)
                table.column("authors", .text)
                table.column("genres", .text)
                table.column("status", .integer)
                table.column("inLibrary", .boolean).notNull().defaults(to: false).indexed()
                table.column("readerMode", .text)
                table.column("lastOpenedAt", .datetime)
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "series") { table in
                table.add(column: "artists", .text)
            }
            try db.create(table: "chapter") { table in
                table.primaryKey("id", .integer) // Kavita chapter id
                table.column("seriesId", .integer).notNull().indexed()
                    .references("series", onDelete: .cascade)
                table.column("volumeId", .integer).notNull()
                table.column("libraryId", .integer).notNull()
                table.column("name", .text).notNull()
                table.column("number", .double).notNull()
                table.column("readingOrder", .integer).notNull()
                table.column("pages", .integer).notNull()
                table.column("read", .boolean).notNull().defaults(to: false)
                table.column("lastPageRead", .integer).notNull().defaults(to: 0)
                table.column("dateUpload", .datetime)
                table.column("isDownloaded", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v3") { db in
            // Progress waiting to reach Kavita; one entry per chapter. Not tied to `chapter`, so
            // an entry survives the chapter being deleted locally.
            try db.create(table: "pendingProgress") { table in
                table.primaryKey("chapterId", .integer)
                table.column("seriesId", .integer).notNull().indexed()
                table.column("libraryId", .integer).notNull()
                table.column("volumeId", .integer).notNull()
                table.column("pageNum", .integer).notNull()
                table.column("markedByUser", .boolean).notNull().defaults(to: false)
                table.column("queuedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v4") { db in
            // Chapters waiting to download, or downloading, or failed. Done ones leave the queue
            // and are marked `chapter.isDownloaded`.
            try db.create(table: "download") { table in
                table.primaryKey("chapterId", .integer)
                table.column("seriesId", .integer).notNull().indexed()
                table.column("state", .text).notNull()
                table.column("pagesDone", .integer).notNull().defaults(to: 0)
                table.column("pagesTotal", .integer).notNull().defaults(to: 0)
                table.column("error", .text)
                table.column("queuedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v5", foreignKeyChecks: .deferred) { db in
            try migrateToSources(db)
        }
        return migrator
    }

    /// Part 2's data model for several sources (PLAN-2.md, Part B). Series and chapters are keyed
    /// by `(source, url)` with Android's URLs; the existing local ids are kept, so download folders
    /// and queued progress stay valid, and new rows take AUTOINCREMENT ids above them.
    private static func migrateToSources(_ db: Database) throws {
        let kavita = KavitaSource.id
        // The new chapter table names `series` from the start: SQLite doesn't rewrite a
        // reference to `series_v5` when that table is renamed with foreign keys off.
        try db.execute(sql: """
            CREATE TABLE series_v5 (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source INTEGER NOT NULL,
                url TEXT NOT NULL,
                name TEXT NOT NULL,
                summary TEXT,
                authors TEXT,
                artists TEXT,
                genres TEXT,
                status INTEGER NOT NULL DEFAULT 0,
                thumbnailUrl TEXT,
                inLibrary BOOLEAN NOT NULL DEFAULT 0,
                dateAdded DATETIME,
                readerMode TEXT,
                lastOpenedAt DATETIME,
                lastUpdate DATETIME,
                initialized BOOLEAN NOT NULL DEFAULT 0,
                chapterFlags TEXT,
                UNIQUE(source, url)
            );
            INSERT INTO series_v5 (id, source, url, name, summary, authors, artists, genres, status,
                                   inLibrary, dateAdded, readerMode, lastOpenedAt, initialized)
            SELECT id, \(kavita), '/library/' || libraryId || '/series/' || id, name, summary, authors, artists,
                   genres,
                   CASE status WHEN 0 THEN 1 WHEN 1 THEN 6 WHEN 2 THEN 2 WHEN 4 THEN 2 WHEN 3 THEN 5 ELSE 0 END,
                   inLibrary, CASE WHEN inLibrary THEN CURRENT_TIMESTAMP END, readerMode, lastOpenedAt,
                   summary IS NOT NULL OR genres IS NOT NULL
            FROM series;

            CREATE TABLE chapter_v5 (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                seriesId INTEGER NOT NULL REFERENCES series(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                name TEXT NOT NULL,
                number DOUBLE NOT NULL DEFAULT -1,
                scanlator TEXT,
                readingOrder INTEGER NOT NULL,
                pages INTEGER NOT NULL DEFAULT 0,
                read BOOLEAN NOT NULL DEFAULT 0,
                bookmark BOOLEAN NOT NULL DEFAULT 0,
                lastPageRead INTEGER NOT NULL DEFAULT 0,
                dateUpload DATETIME,
                dateFetch DATETIME,
                isDownloaded BOOLEAN NOT NULL DEFAULT 0,
                memo TEXT,
                UNIQUE(seriesId, url)
            );
            INSERT INTO chapter_v5 (id, seriesId, url, name, number, readingOrder, pages, read, lastPageRead,
                                    dateUpload, dateFetch, isDownloaded, memo)
            SELECT id, seriesId, '/chapter/' || id, name, number, readingOrder, pages, read, lastPageRead,
                   dateUpload, COALESCE(dateUpload, CURRENT_TIMESTAMP), isDownloaded,
                   json_object('kavitaSeriesId', seriesId, 'kavitaLibraryId', libraryId,
                               'kavitaVolumeId', volumeId, 'kavitaPages', pages)
            FROM chapter;

            DROP TABLE chapter;
            DROP TABLE series;
            ALTER TABLE series_v5 RENAME TO series;
            ALTER TABLE chapter_v5 RENAME TO chapter;
            CREATE INDEX series_on_inLibrary ON series(inLibrary);
            CREATE INDEX chapter_on_seriesId ON chapter(seriesId);
            CREATE INDEX chapter_on_dateFetch ON chapter(dateFetch);
            """)

        // Kavita's libraries, for its browse filter.
        try db.rename(table: "library", to: "kavitaLibrary")

        // Mihon's categories. Series in none of them are in the default category.
        try db.create(table: "category") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("name", .text).notNull()
            table.column("sort", .integer).notNull().defaults(to: 0)
            table.column("flags", .integer).notNull().defaults(to: 0)
        }
        try db.create(table: "seriesCategory") { table in
            table.column("seriesId", .integer).notNull().references("series", onDelete: .cascade)
            table.column("categoryId", .integer).notNull().references("category", onDelete: .cascade)
            table.primaryKey(["seriesId", "categoryId"])
        }

        // Reading history, one row per chapter read.
        try db.create(table: "history") { table in
            table.primaryKey("chapterId", .integer).references("chapter", onDelete: .cascade)
            table.column("lastRead", .datetime).notNull().indexed()
            table.column("timeRead", .integer).notNull().defaults(to: 0)
        }

        // Progress waiting to reach Komga, BookOrbit or a KOReader server (Kavita keeps its own
        // `pendingProgress` table). `key` is what the server knows the chapter by.
        try db.create(table: "syncQueue") { table in
            table.column("engine", .text).notNull()
            table.column("key", .text).notNull()
            table.column("seriesKey", .text).notNull()
            table.column("payload", .text).notNull()
            table.column("markedByUser", .boolean).notNull().defaults(to: false)
            table.column("queuedAt", .datetime).notNull()
            table.primaryKey(["engine", "key"])
        }
    }
}
