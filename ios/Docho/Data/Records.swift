import Foundation
import GRDB

/// A Kavita library, kept for the browse filter so it works offline.
struct LibraryRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    static let databaseTableName = "kavitaLibrary"

    var id: Int
    var name: String
    var type: Int
}

/// A series the app knows about (Mihon's `Manga`): in the library, or opened from Browse.
struct SeriesRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable, Hashable {
    static let databaseTableName = "series"

    var id: Int
    var source: Int64
    /// The source's key for the series (`SManga.url`).
    var url: String
    var name: String
    var summary: String?
    var authors: String?
    var artists: String?
    var genres: String?
    /// `MangaStatus` raw value.
    var status: Int
    var thumbnailUrl: String?
    var inLibrary: Bool
    var dateAdded: Date?
    var readerMode: String?
    var lastOpenedAt: Date?
    var lastUpdate: Date?
    var initialized: Bool
    /// The chapter list's sort and filters for this series (`ChapterDisplay`), as JSON.
    var chapterFlags: String?

    enum Columns {
        static let source = Column(CodingKeys.source)
        static let url = Column(CodingKeys.url)
        static let name = Column(CodingKeys.name)
        static let inLibrary = Column(CodingKeys.inLibrary)
    }

    var manga: SManga {
        SManga(
            url: url, title: name, artist: artists, author: authors, description: summary, genre: genres,
            status: MangaStatus(rawValue: status) ?? .unknown, thumbnailURL: thumbnailUrl, initialized: initialized
        )
    }

    var mangaStatus: MangaStatus { MangaStatus(rawValue: status) ?? .unknown }

    var genreList: [String] { manga.genres }

    var chapterDisplay: ChapterDisplay {
        get { chapterFlags.flatMap { try? JSONDecoder().decode(ChapterDisplay.self, from: Data($0.utf8)) } ?? ChapterDisplay() }
        set { chapterFlags = (try? JSONEncoder().encode(newValue)).map { String(decoding: $0, as: UTF8.self) } }
    }
}

extension SeriesRecord {
    /// A new series from a source listing; not stored yet.
    init(id: Int, source: Int64, manga: SManga) {
        self.init(
            id: id, source: source, url: manga.url, name: manga.title, summary: manga.description,
            authors: manga.author, artists: manga.artist, genres: manga.genre, status: manga.status.rawValue,
            thumbnailUrl: manga.thumbnailURL, inLibrary: false, dateAdded: nil, readerMode: nil, lastOpenedAt: nil,
            lastUpdate: nil, initialized: manga.initialized, chapterFlags: nil
        )
    }

    /// Takes what a source sent, keeping details it didn't (a listing has no description).
    mutating func apply(_ manga: SManga) {
        name = manga.title
        if let value = manga.thumbnailURL { thumbnailUrl = value }
        if manga.initialized || manga.author != nil { authors = manga.author }
        if manga.initialized {
            artists = manga.artist
            summary = manga.description
            genres = manga.genre
            status = manga.status.rawValue
            initialized = true
        }
    }
}

/// How a series' chapter list is sorted and filtered (Mihon's chapter flags).
struct ChapterDisplay: Codable, Sendable, Equatable, Hashable {
    enum Sort: String, Codable, CaseIterable, Sendable {
        /// The source's reading order.
        case source
        case number
        case uploadDate
        case alphabet
        /// Natural order of the file names, so v2 comes before v10 (Android 0.22.0).
        case fileName

        var title: String {
            switch self {
            case .source: String(localized: "By source")
            case .number: String(localized: "By chapter number")
            case .uploadDate: String(localized: "By upload date")
            case .alphabet: String(localized: "Alphabetically")
            case .fileName: String(localized: "By file name")
            }
        }
    }

    /// Include, exclude or ignore, like Mihon's tri-state filters.
    enum TriState: Int, Codable, Sendable {
        case off, include, exclude

        var next: TriState {
            switch self {
            case .off: .include
            case .include: .exclude
            case .exclude: .off
            }
        }
    }

    var sort = Sort.source
    /// Mihon lists the newest first by default; iOS part 1 showed reading order. Descending
    /// matches Mihon.
    var descending = true
    var unread = TriState.off
    var downloaded = TriState.off
    var bookmarked = TriState.off
    var showChapterNumbers = false

    var hasFilter: Bool { unread != .off || downloaded != .off || bookmarked != .off }
}

/// A category to group the library by (Mihon's categories).
struct CategoryRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable, Hashable {
    static let databaseTableName = "category"

    /// 0 is the default category, which isn't stored.
    var id: Int
    var name: String
    var sort: Int
    var flags: Int

    static let defaultId = 0
    static let `default` = CategoryRecord(id: defaultId, name: String(localized: "Default"), sort: -1, flags: 0)

    var isDefault: Bool { id == Self.defaultId }
}

struct SeriesCategoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "seriesCategory"

    var seriesId: Int
    var categoryId: Int
}

/// A library entry with what the library grid shows (Mihon's `LibraryManga`).
struct LibraryItem: FetchableRecord, Sendable, Equatable, Identifiable, Hashable {
    var series: SeriesRecord
    var totalChapters: Int
    var readCount: Int
    var bookmarkCount: Int
    var downloadCount: Int
    var latestUpload: Date?
    var lastRead: Date?
    var chapterFetchedAt: Date?
    var categoryIds: [Int]

    var id: Int { series.id }
    var unreadCount: Int { totalChapters - readCount }
    var hasStarted: Bool { readCount > 0 }

    init(row: Row) throws {
        series = try SeriesRecord(row: row)
        totalChapters = row["totalChapters"] ?? 0
        readCount = row["readCount"] ?? 0
        bookmarkCount = row["bookmarkCount"] ?? 0
        downloadCount = row["downloadCount"] ?? 0
        latestUpload = row["latestUpload"]
        lastRead = row["lastRead"]
        chapterFetchedAt = row["chapterFetchedAt"]
        let categories: String? = row["categoryIds"]
        categoryIds = categories?.split(separator: ",").compactMap { Int($0) } ?? []
    }
}

extension AppDatabase {
    // MARK: Kavita libraries

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
            .tracking { db in try LibraryRecord.order(sql: "name COLLATE NOCASE").fetchAll(db) }
            .values(in: writer)
    }

    func storedLibraries() async throws -> [LibraryRecord] {
        try await writer.read { db in try LibraryRecord.order(sql: "name COLLATE NOCASE").fetchAll(db) }
    }

    // MARK: Series

    /// The stored series for a source's listing entry, created if it's new (Mihon's
    /// `networkToLocalManga`). Details already stored are kept.
    func localSeries(source: Int64, manga: SManga) async throws -> SeriesRecord {
        try await writer.write { db in try Self.localSeries(db, source: source, manga: manga) }
    }

    /// Stored series for a page of listing entries, in the same order.
    func localSeries(source: Int64, mangas: [SManga]) async throws -> [SeriesRecord] {
        try await writer.write { db in try mangas.map { try Self.localSeries(db, source: source, manga: $0) } }
    }

    static func localSeries(_ db: Database, source: Int64, manga: SManga) throws -> SeriesRecord {
        if var stored = try SeriesRecord
            .filter(SeriesRecord.Columns.source == source && SeriesRecord.Columns.url == manga.url)
            .fetchOne(db) {
            if !stored.inLibrary {
                // Listing data is fresher for series not in the library; library ones keep theirs.
                let before = stored
                stored.name = manga.title
                if let thumbnail = manga.thumbnailURL { stored.thumbnailUrl = thumbnail }
                if manga.author != nil, !stored.initialized { stored.authors = manga.author }
                if stored != before { try stored.update(db) }
            }
            return stored
        }
        let record = SeriesRecord(id: try Self.nextId(db, table: "series"), source: source, manga: manga)
        try record.insert(db)
        return record
    }

    func seriesRecord(id: Int) async throws -> SeriesRecord? {
        try await writer.read { db in try SeriesRecord.fetchOne(db, key: id) }
    }

    func seriesRecords(source: Int64) async throws -> [SeriesRecord] {
        try await writer.read { db in try SeriesRecord.filter(SeriesRecord.Columns.source == source).fetchAll(db) }
    }

    /// Adds a series to the library or removes it. Added series get a date; removed ones stay cached.
    func setInLibrary(seriesId: Int, _ inLibrary: Bool, categories: [Int]? = nil) async throws {
        try await writer.write { db in
            guard var record = try SeriesRecord.fetchOne(db, key: seriesId) else { return }
            record.inLibrary = inLibrary
            record.dateAdded = inLibrary ? Date() : nil
            try record.update(db)
            if let categories {
                try Self.setCategories(db, seriesIds: [seriesId], categories: categories)
            }
            if !inLibrary {
                _ = try SeriesCategoryRecord.filter(Column("seriesId") == seriesId).deleteAll(db)
            }
        }
    }

    func setReaderMode(seriesId: Int, _ mode: String?) async throws {
        try await writer.write { db in
            _ = try SeriesRecord.filter(key: seriesId).updateAll(db, Column("readerMode").set(to: mode))
        }
    }

    func setChapterDisplay(seriesId: Int, _ display: ChapterDisplay) async throws {
        try await writer.write { db in
            guard var record = try SeriesRecord.fetchOne(db, key: seriesId) else { return }
            record.chapterDisplay = display
            try record.update(db)
        }
    }

    func touchSeries(_ seriesId: Int) async throws {
        try await writer.write { db in
            _ = try SeriesRecord.filter(key: seriesId).updateAll(db, Column("lastOpenedAt").set(to: Date()))
        }
    }

    /// One series, updated as it changes; nil until it's been stored.
    func series(id: Int) -> AsyncValueObservation<SeriesRecord?> {
        ValueObservation
            .tracking { db in try SeriesRecord.fetchOne(db, key: id) }
            .values(in: writer)
    }

    /// Ids of the series in the library, updated as they change (for Browse's "in library" marks).
    func libraryKeys(source: Int64) -> AsyncValueObservation<Set<String>> {
        ValueObservation
            .tracking { db in
                try Set(String.fetchAll(db, SeriesRecord
                    .select(Column("url"))
                    .filter(SeriesRecord.Columns.source == source && SeriesRecord.Columns.inLibrary)))
            }
            .values(in: writer)
    }

    /// Ids of the series in the library.
    func librarySeriesIds() async throws -> [Int] {
        try await writer.read { db in
            try Int.fetchAll(db, SeriesRecord.select(Column("id")).filter(SeriesRecord.Columns.inLibrary))
        }
    }

    func librarySeriesRecords() async throws -> [SeriesRecord] {
        try await writer.read { db in try SeriesRecord.filter(SeriesRecord.Columns.inLibrary).fetchAll(db) }
    }

    /// The library with chapter counts, updated as it changes.
    func library() -> AsyncValueObservation<[LibraryItem]> {
        ValueObservation
            .tracking { db in try LibraryItem.fetchAll(db, sql: Self.librarySQL) }
            .values(in: writer)
    }

    private static let librarySQL = """
        SELECT series.*,
               COUNT(chapter.id) AS totalChapters,
               COALESCE(SUM(chapter.read), 0) AS readCount,
               COALESCE(SUM(chapter.bookmark), 0) AS bookmarkCount,
               COALESCE(SUM(chapter.isDownloaded), 0) AS downloadCount,
               MAX(chapter.dateUpload) AS latestUpload,
               MAX(chapter.dateFetch) AS chapterFetchedAt,
               (SELECT MAX(history.lastRead) FROM history JOIN chapter c ON c.id = history.chapterId
                WHERE c.seriesId = series.id) AS lastRead,
               (SELECT GROUP_CONCAT(categoryId) FROM seriesCategory WHERE seriesId = series.id) AS categoryIds
        FROM series
        LEFT JOIN chapter ON chapter.seriesId = series.id
        WHERE series.inLibrary
        GROUP BY series.id
        """

    // MARK: Categories

    /// User categories by their order, updated as they change.
    func categories() -> AsyncValueObservation<[CategoryRecord]> {
        ValueObservation
            .tracking { db in try CategoryRecord.order(Column("sort")).fetchAll(db) }
            .values(in: writer)
    }

    func categoryList() async throws -> [CategoryRecord] {
        try await writer.read { db in try CategoryRecord.order(Column("sort")).fetchAll(db) }
    }

    func createCategory(_ name: String) async throws {
        try await writer.write { db in
            let sort = (try Int.fetchOne(db, sql: "SELECT MAX(sort) FROM category") ?? -1) + 1
            try CategoryRecord(id: try Self.nextId(db, table: "category"), name: name, sort: sort, flags: 0).insert(db)
        }
    }

    func renameCategory(_ id: Int, to name: String) async throws {
        try await writer.write { db in
            _ = try CategoryRecord.filter(key: id).updateAll(db, Column("name").set(to: name))
        }
    }

    func deleteCategory(_ id: Int) async throws {
        try await writer.write { db in _ = try CategoryRecord.deleteOne(db, key: id) }
    }

    /// Stores categories in the given order.
    func reorderCategories(_ ids: [Int]) async throws {
        try await writer.write { db in
            for (index, id) in ids.enumerated() {
                _ = try CategoryRecord.filter(key: id).updateAll(db, Column("sort").set(to: index))
            }
        }
    }

    /// Puts series in exactly these categories (none means the default category).
    func setCategories(seriesIds: [Int], categories: [Int]) async throws {
        try await writer.write { db in try Self.setCategories(db, seriesIds: seriesIds, categories: categories) }
    }

    private static func setCategories(_ db: Database, seriesIds: [Int], categories: [Int]) throws {
        _ = try SeriesCategoryRecord.filter(seriesIds.contains(Column("seriesId"))).deleteAll(db)
        for seriesId in seriesIds {
            for category in categories where category != CategoryRecord.defaultId {
                try SeriesCategoryRecord(seriesId: seriesId, categoryId: category).insert(db)
            }
        }
    }

    func categoryIds(seriesId: Int) async throws -> [Int] {
        try await writer.read { db in
            try Int.fetchAll(db, sql: "SELECT categoryId FROM seriesCategory WHERE seriesId = ?", arguments: [seriesId])
        }
    }
}
