import Foundation
import GRDB

/// A Kavita library, kept for the browse filter so it works offline.
struct LibraryRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    static let databaseTableName = "library"

    var id: Int
    var name: String
    var type: Int
}

/// A Kavita series the app knows about: in the library, or opened from Browse.
struct SeriesRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    static let databaseTableName = "series"

    /// The Kavita series id.
    var id: Int
    var libraryId: Int
    var name: String
    var summary: String?
    var authors: String?
    var artists: String?
    var genres: String?
    /// Kavita's `publicationStatus`.
    var status: Int?
    var inLibrary: Bool
    var readerMode: String?
    var lastOpenedAt: Date?

    enum Columns {
        static let name = Column(CodingKeys.name)
        static let inLibrary = Column(CodingKeys.inLibrary)
    }
}

extension KavitaSeries {
    /// The name shown for the series, as on Android.
    var title: String { name ?? localizedName ?? originalName ?? "Series \(id)" }
}

extension AppDatabase {
    // MARK: Libraries

    /// Replaces the stored libraries with the server's.
    func saveLibraries(_ libraries: [KavitaLibrary]) async throws {
        try await writer.write { db in
            try LibraryRecord.deleteAll(db)
            for library in libraries {
                try LibraryRecord(id: library.id, name: library.name, type: library.type).insert(db)
            }
        }
    }

    /// Libraries by name, updated as they change.
    func libraries() -> AsyncValueObservation<[LibraryRecord]> {
        ValueObservation
            .tracking { db in
                try LibraryRecord.order(sql: "name COLLATE NOCASE").fetchAll(db)
            }
            .values(in: writer)
    }

    // MARK: Series

    /// Adds a series to the library or removes it. A removed series stays cached.
    func setInLibrary(_ series: KavitaSeries, _ inLibrary: Bool) async throws {
        try await writer.write { db in
            if var record = try SeriesRecord.fetchOne(db, key: series.id) {
                record.name = series.title
                record.libraryId = series.libraryId
                record.inLibrary = inLibrary
                try record.update(db)
            } else {
                try SeriesRecord(id: series.id, libraryId: series.libraryId, name: series.title, inLibrary: inLibrary).insert(db)
            }
        }
    }

    func setInLibrary(seriesId: Int, _ inLibrary: Bool) async throws {
        try await writer.write { db in
            _ = try SeriesRecord.filter(key: seriesId).updateAll(db, SeriesRecord.Columns.inLibrary.set(to: inLibrary))
        }
    }

    /// Updates the name and library of series already stored; others are ignored.
    func updateSeries(_ series: [KavitaSeries]) async throws {
        try await writer.write { db in
            for item in series {
                guard var record = try SeriesRecord.fetchOne(db, key: item.id) else { continue }
                record.name = item.title
                record.libraryId = item.libraryId
                try record.update(db)
            }
        }
    }

    /// Series in the library by name, updated as they change.
    func librarySeries() -> AsyncValueObservation<[SeriesRecord]> {
        ValueObservation
            .tracking { db in
                try SeriesRecord
                    .filter(SeriesRecord.Columns.inLibrary)
                    .order(sql: "name COLLATE NOCASE")
                    .fetchAll(db)
            }
            .values(in: writer)
    }

    /// Ids of the series in the library, updated as they change.
    func libraryIDs() -> AsyncValueObservation<Set<Int>> {
        ValueObservation
            .tracking { db in
                try Set(Int.fetchAll(db, SeriesRecord.select(Column("id")).filter(SeriesRecord.Columns.inLibrary)))
            }
            .values(in: writer)
    }
}

extension SeriesRecord {
    init(id: Int, libraryId: Int, name: String, inLibrary: Bool) {
        self.init(
            id: id, libraryId: libraryId, name: name, summary: nil, authors: nil, artists: nil, genres: nil,
            status: nil, inLibrary: inLibrary, readerMode: nil, lastOpenedAt: nil
        )
    }
}
