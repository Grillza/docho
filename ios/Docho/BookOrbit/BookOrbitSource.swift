import Foundation

/// BookOrbit built in as a source (Android's `BookOrbitSource`). A BookOrbit series is a series
/// and each of its books with a comic archive is a chapter, read page by page through BookOrbit's
/// comic page API. Series URLs are `/series/{seriesId}` and chapter URLs
/// `/book/{bookId}/file/{fileId}`, so the ids progress sync needs never take an extra request.
final class BookOrbitSource: MangaSource {
    static let id: Int64 = 0x424F_4F4B_4F52_42 // "BOOKORB"
    static let name = "BookOrbit"

    private static let sortName = "name"
    private static let sortLastAdded = "lastAddedAt"
    private static let sortFields = [sortName, sortLastAdded, "bookCount", "readProgress"]

    let client: BookOrbitClient
    private let settings: BookOrbitSettings
    let progressCache = ProgressCache<Int, [BookOrbitBook]>()
    private let libraryCache = LibraryNames<BookOrbitLibrary>()

    init(client: BookOrbitClient, settings: BookOrbitSettings) {
        self.client = client
        self.settings = settings
    }

    var id: Int64 { Self.id }
    var name: String { Self.name }
    var supportsLatest: Bool { true }
    var supportsUnread: Bool { true }
    var iconAsset: String? { "brand.bookorbit" }
    var isConfigured: Bool { settings.isConfigured }

    func popular(page: Int) async throws -> MangasPage {
        try await browse(page, query: nil, sort: Self.sortName, ascending: true, libraryId: nil)
    }

    func latest(page: Int) async throws -> MangasPage {
        try await browse(page, query: nil, sort: Self.sortLastAdded, ascending: false, libraryId: nil)
    }

    /// BookOrbit can only filter for series not started or in progress, not both at once, so the
    /// whole list is loaded newest first on the first page and the finished series dropped.
    func unread(page: Int) async throws -> MangasPage {
        guard page <= 1 else { return MangasPage(mangas: [], hasNextPage: false) }
        var unread: [SManga] = []
        var serverPage = 0
        while true {
            let result = try await client.seriesPage(page: serverPage, query: nil, sort: Self.sortLastAdded, ascending: false, libraryId: nil)
            unread += result.items.filter { $0.readCount < $0.bookCount }.map(manga)
            serverPage += 1
            if result.items.isEmpty || serverPage * BookOrbitClient.pageSize >= result.total { break }
        }
        return MangasPage(mangas: unread, hasNextPage: false)
    }

    func search(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        var libraryId: Int?
        if let index = filters.selectState("Library"), index > 0 {
            let libraries = await libraryCache.value
            if libraries.indices.contains(index - 1) { libraryId = libraries[index - 1].id }
        }
        var sort = Self.sortName
        var ascending = true
        if let selection = filters.sortState("Sort"), Self.sortFields.indices.contains(selection.index) {
            sort = Self.sortFields[selection.index]
            ascending = selection.ascending
        }
        return try await browse(page, query: query, sort: sort, ascending: ascending, libraryId: libraryId)
    }

    func filterList() async -> [SourceFilter] {
        if let libraries = try? await client.libraries() {
            await libraryCache.set(libraries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
        let names = await libraryCache.value.map(\.name)
        return [
            .select(name: "Library", values: [String(localized: "All")] + names, state: 0),
            .sort(
                name: "Sort",
                values: [String(localized: "Name"), String(localized: "Recently added"), String(localized: "Number of books"), String(localized: "Reading progress")],
                selection: .init(index: 0, ascending: true)
            ),
        ]
    }

    /// Docho counts pages from 1, BookOrbit from 0.
    private func browse(_ page: Int, query: String?, sort: String, ascending: Bool, libraryId: Int?) async throws -> MangasPage {
        let result = try await client.seriesPage(page: page - 1, query: query, sort: sort, ascending: ascending, libraryId: libraryId)
        return MangasPage(mangas: result.items.map(manga), hasNextPage: page * BookOrbitClient.pageSize < result.total)
    }

    /// One request carries both the series details and its books.
    func update(_ manga: SManga, details: Bool, chapters: Bool) async throws -> (manga: SManga, chapters: [SChapter]?) {
        guard let seriesId = Self.seriesId(manga.url) else { throw SourceError.noPages }
        let books = try await client.seriesBooks(seriesId)
        progressCache.put(seriesId, books.items)
        var detailed = manga
        if details {
            detailed.title = books.seriesInfo?.name ?? manga.title
            let authors = books.seriesInfo?.authors ?? []
            detailed.author = authors.isEmpty ? nil : authors.joined(separator: ", ")
            var seen = Set<String>()
            let genres = books.items.flatMap(\.genres).filter { seen.insert($0).inserted }
            detailed.genre = genres.isEmpty ? nil : genres.joined(separator: ", ")
            detailed.thumbnailURL = books.items.first.flatMap { client.thumbnailURL(bookId: $0.id)?.absoluteString } ?? manga.thumbnailURL
            detailed.status = .unknown
            detailed.initialized = true
        }
        let list: [SChapter]? = chapters ? books.items.compactMap { book in
            // Ebooks and audiobooks have no page images to show.
            guard let file = book.comicFile else { return nil }
            var memo = ChapterMemo()
            // BookOrbit names a book after its file unless metadata renames it, and its book list
            // sends no file paths, so the title stands in for the file name.
            if let title = book.title, !title.isBlank { memo[ChapterMemo.fileName] = .string(title) }
            return SChapter(
                url: Self.chapterURL(bookId: book.id, fileId: file.id),
                name: Self.chapterName(title: book.title, seriesIndex: book.seriesIndex),
                dateUpload: ServerDates.parse(book.addedAt) ?? ServerDates.parse(book.publishedDate),
                number: book.seriesIndex.flatMap(Double.init) ?? -1,
                memo: memo
            )
        } : nil
        return (detailed, list)
    }

    func pages(_ chapter: SChapter) async throws -> [SourcePage] {
        guard let fileId = Self.fileId(chapter.url) else { throw SourceError.noPages }
        let count = try await client.pageCount(fileId: fileId)
        return (0..<count).compactMap { index in client.pageImageURL(fileId: fileId, page: index).map { SourcePage(index: index, imageURL: $0) } }
    }

    func imageRequest(_ page: SourcePage) -> URLRequest { authorized(page.imageURL) }

    func coverRequest(_ manga: SManga) -> URLRequest? {
        manga.thumbnailURL.flatMap(URL.init(string:)).map(authorized)
    }

    func webURL(_ manga: SManga) -> URL? { Self.seriesId(manga.url).flatMap(client.seriesWebURL) }

    private func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(ServerAddress.userAgent, forHTTPHeaderField: "User-Agent")
        if let token = client.cachedToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func manga(_ series: BookOrbitSeries) -> SManga {
        SManga(
            url: Self.seriesURL(series.id), title: series.name,
            author: series.authors.isEmpty ? nil : series.authors.joined(separator: ", "),
            thumbnailURL: series.coverBookIds.first.flatMap { client.thumbnailURL(bookId: $0)?.absoluteString }
        )
    }

    static func seriesURL(_ seriesId: Int) -> String { "/series/\(seriesId)" }
    static func chapterURL(bookId: Int, fileId: Int) -> String { "/book/\(bookId)/file/\(fileId)" }

    static func seriesId(_ url: String) -> Int? {
        url.components(separatedBy: "/series/").last.flatMap { Int($0.prefix { $0.isNumber }) }
    }

    static func bookId(_ url: String) -> Int? {
        guard url.contains("/book/") else { return nil }
        return url.components(separatedBy: "/book/")[1].split(separator: "/").first.flatMap { Int($0) }
    }

    static func fileId(_ url: String) -> Int? {
        guard url.contains("/file/") else { return nil }
        return url.components(separatedBy: "/file/").last.flatMap { Int($0.prefix { $0.isNumber }) }
    }

    /// "Vol. 3 - Title", or whichever half the book has.
    static func chapterName(title: String?, seriesIndex: String?) -> String {
        let title = title?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        switch (seriesIndex, title) {
        case let (index?, title?): return "Vol. \(index) - \(title)"
        case let (index?, nil): return "Vol. \(index)"
        case let (nil, title?): return title
        case (nil, nil): return "Untitled"
        }
    }
}
