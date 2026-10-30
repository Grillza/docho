import Foundation
import Synchronization

/// Kavita built in as a source (Android's `KavitaSource`). Series URLs are Kavita's web paths,
/// `/library/{libraryId}/series/{seriesId}`, and chapter URLs `/chapter/{chapterId}`, so the ids
/// progress sync needs never take an extra request; the rest goes in the chapter memo.
final class KavitaSource: MangaSource {
    static let id: Int64 = 0x4B41_5649_5441_31 // "KAVITA1"
    static let name = "Kavita"

    static let memoSeriesId = "kavitaSeriesId"
    static let memoLibraryId = "kavitaLibraryId"
    static let memoVolumeId = "kavitaVolumeId"
    static let memoPages = "kavitaPages"
    static let memoKoreaderHash = "koreaderHash"

    let client: KavitaClient
    private let settings: KavitaSettings
    private let database: AppDatabase
    /// Volumes as last fetched with a chapter list, so the progress sync that follows a refresh
    /// doesn't fetch them again (Android's `progressCache`).
    let progressCache = ProgressCache<Int, [KavitaVolume]>()

    init(client: KavitaClient, settings: KavitaSettings, database: AppDatabase) {
        self.client = client
        self.settings = settings
        self.database = database
    }

    var id: Int64 { Self.id }
    var name: String { Self.name }
    var supportsLatest: Bool { true }
    var supportsUnread: Bool { true }
    var iconAsset: String? { "brand.kavita" }
    var isConfigured: Bool { settings.credentials.isConfigured }

    // MARK: Browse

    func popular(page: Int) async throws -> MangasPage {
        try await browse(page, KavitaFilter(sortOptions: KavitaSortOptions(sortField: KavitaConstants.sortName, isAscending: true)))
    }

    func latest(page: Int) async throws -> MangasPage {
        try await browse(page, KavitaFilter(sortOptions: KavitaSortOptions(sortField: KavitaConstants.sortLastChapterAdded, isAscending: false)))
    }

    /// Kavita's own "unread" filter: read progress below 100%, most recently added first.
    func unread(page: Int) async throws -> MangasPage {
        try await browse(page, KavitaFilter(
            statements: [KavitaFilterStatement(
                comparison: KavitaConstants.comparisonNotEqual, field: KavitaConstants.fieldReadProgress, value: "100"
            )],
            sortOptions: KavitaSortOptions(sortField: KavitaConstants.sortLastChapterAdded, isAscending: false)
        ))
    }

    func search(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        var request = KavitaBrowseRequest(query: query)
        if let index = filters.selectState(Self.libraryFilter), index > 0 {
            let libraries = try await database.storedLibraries()
            if libraries.indices.contains(index - 1) { request.libraryId = libraries[index - 1].id }
        }
        if let sort = filters.sortState(Self.sortFilter), KavitaBrowseSort.allCases.indices.contains(sort.index) {
            request.sort = KavitaBrowseSort.allCases[sort.index]
            request.ascending = sort.ascending
        }
        return try await browse(page, request.filter, addEpubExclusion: false)
    }

    private static let libraryFilter = "Library"
    private static let sortFilter = "Sort"

    func filterList() async -> [SourceFilter] {
        if let libraries = try? await client.libraries() {
            try? await database.saveLibraries(libraries)
        }
        let names = (try? await database.storedLibraries().map(\.name)) ?? []
        return [
            .select(name: Self.libraryFilter, values: [String(localized: "All")] + names, state: 0),
            .sort(name: Self.sortFilter, values: KavitaBrowseSort.allCases.map(\.title), selection: .init(index: 0, ascending: true)),
        ]
    }

    /// EPUBs are rendered as text by Kavita and have no page images to show here.
    private func browse(_ page: Int, _ filter: KavitaFilter, addEpubExclusion: Bool = true) async throws -> MangasPage {
        var filter = filter
        if addEpubExclusion {
            filter.statements.append(KavitaFilterStatement(
                comparison: KavitaConstants.comparisonNotContains, field: KavitaConstants.fieldFormats,
                value: String(KavitaConstants.formatEpub)
            ))
        }
        let result = try await client.seriesPage(filter: filter, page: page)
        return MangasPage(mangas: result.series.map(manga), hasNextPage: result.hasNextPage)
    }

    // MARK: Details and chapters

    func update(_ manga: SManga, details: Bool, chapters: Bool) async throws -> (manga: SManga, chapters: [SChapter]?) {
        guard let seriesId = Self.seriesId(manga.url) else { throw KavitaError.http(status: 404) }
        async let fetchedDetails = details ? mangaDetails(seriesId) : nil
        async let fetchedVolumes = chapters ? client.volumes(seriesId: seriesId) : nil
        let (detailsResult, volumes) = try await (fetchedDetails, fetchedVolumes)
        var list: [SChapter]?
        if let volumes {
            progressCache.put(seriesId, volumes)
            let libraryId = Self.libraryId(manga.url)
            list = KavitaChapterList.build(volumes).map { entry in
                var memo = ChapterMemo([
                    Self.memoSeriesId: .int(seriesId),
                    Self.memoLibraryId: .int(libraryId),
                    Self.memoVolumeId: .int(entry.volumeId),
                    Self.memoPages: .int(entry.pages),
                ])
                if let hash = entry.koreaderHash { memo[Self.memoKoreaderHash] = .string(hash) }
                if let file = entry.fileName { memo[ChapterMemo.fileName] = .string(file) }
                return SChapter(
                    url: Self.chapterURL(entry.chapterId), name: entry.name, dateUpload: entry.dateUpload,
                    number: entry.number, memo: memo
                )
            }
        }
        return (detailsResult ?? manga, list)
    }

    private func mangaDetails(_ seriesId: Int) async throws -> SManga {
        async let series = client.series(id: seriesId)
        async let metadata = client.seriesMetadata(seriesId: seriesId)
        var result = manga(try await series)
        let details = KavitaSeriesDetails(try await metadata)
        result.description = details.summary
        result.author = details.authors
        result.artist = details.artists
        result.genre = details.genres
        result.status = Self.status(details.status)
        result.initialized = true
        return result
    }

    static func status(_ kavita: Int) -> MangaStatus {
        switch kavita {
        case KavitaConstants.statusOngoing: .ongoing
        case KavitaConstants.statusHiatus: .onHiatus
        case KavitaConstants.statusCompleted, KavitaConstants.statusEnded: .completed
        case KavitaConstants.statusCancelled: .cancelled
        default: .unknown
        }
    }

    func pages(_ chapter: SChapter) async throws -> [SourcePage] {
        guard let chapterId = Self.chapterId(chapter.url) else { throw SourceError.noPages }
        let count = try await client.chapter(id: chapterId).pages
        return try (0..<count).map { SourcePage(index: $0, imageURL: try client.pageImageURL(chapterId: chapterId, page: $0)) }
    }

    func coverRequest(_ manga: SManga) -> URLRequest? {
        guard let seriesId = Self.seriesId(manga.url), let url = try? client.seriesCoverURL(seriesId: seriesId) else { return nil }
        return URLRequest(url: url)
    }

    func webURL(_ manga: SManga) -> URL? {
        guard let seriesId = Self.seriesId(manga.url) else { return nil }
        return try? client.seriesWebURL(libraryId: Self.libraryId(manga.url), seriesId: seriesId)
    }

    private func manga(_ series: KavitaSeries) -> SManga {
        SManga(url: Self.seriesURL(libraryId: series.libraryId, seriesId: series.id), title: series.title)
    }

    // MARK: URLs

    static func seriesURL(libraryId: Int, seriesId: Int) -> String { "/library/\(libraryId)/series/\(seriesId)" }
    static func chapterURL(_ chapterId: Int) -> String { "/chapter/\(chapterId)" }

    static func seriesId(_ url: String) -> Int? {
        url.components(separatedBy: "/series/").last.flatMap { Int($0.prefix { $0.isNumber }) }
    }

    static func libraryId(_ url: String) -> Int {
        guard url.contains("/library/") else { return 0 }
        return url.components(separatedBy: "/library/").last.flatMap { Int($0.prefix { $0.isNumber }) } ?? 0
    }

    static func chapterId(_ url: String) -> Int? {
        guard url.contains("/chapter/") else { return nil }
        return url.components(separatedBy: "/chapter/").last.flatMap { Int($0.prefix { $0.isNumber }) }
    }
}

/// Data fetched for a series' chapter list, kept briefly for the sync that follows.
final class ProgressCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private let entries = Mutex<[Key: (Date, Value)]>([:])

    func put(_ key: Key, _ value: Value) {
        entries.withLock { $0[key] = (Date(), value) }
    }

    /// The cached value if it's at most `maxAge` old; each entry is used once.
    func take(_ key: Key, maxAge: TimeInterval = 30) -> Value? {
        entries.withLock { entries in
            guard let (time, value) = entries.removeValue(forKey: key) else { return nil }
            return Date().timeIntervalSince(time) <= maxAge ? value : nil
        }
    }
}

extension KavitaSeries {
    /// The name shown for the series, as on Android.
    var title: String { name ?? localizedName ?? originalName ?? "Series \(id)" }
}
