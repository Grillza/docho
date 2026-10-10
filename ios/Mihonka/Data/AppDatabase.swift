import Foundation
import GRDB

/// The app's SQLite database. Schema changes go in new migrations; never edit a shipped one.
struct AppDatabase: Sendable {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// `Application Support/mihonka.sqlite`.
    static func onDisk() throws -> AppDatabase {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return try AppDatabase(DatabasePool(path: directory.appending(path: "mihonka.sqlite").path()))
    }

    static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
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
        return migrator
    }
}
