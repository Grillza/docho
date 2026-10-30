import Foundation

/// Komga built in as a source (Android's `KomgaSource`). A Komga series is a series, and each of
/// its books that Komga serves as pages (comic archives, PDFs, image-based EPUBs) is a chapter.
/// Series URLs are `/series/{seriesId}` and chapter URLs `/book/{bookId}`; Komga ids are strings.
final class KomgaSource: MangaSource {
    static let id: Int64 = 0x4B4F_4D47_4130_31 // "KOMGA01"
    static let name = "Komga"

    private static let sortTitle = "metadata.titleSort,asc"
    private static let sortLastModified = "lastModified,desc"
    private static let writerRoles: Set<String> = ["writer"]
    private static let artistRoles: Set<String> = ["penciller", "inker", "colorist", "cover"]
    private static let sortFields = ["metadata.titleSort", "created", "lastModified", "booksCount"]

    let client: KomgaClient
    private let settings: KomgaSettings
    /// Books as last fetched with the chapter list, for the sync that follows.
    let progressCache = ProgressCache<String, [KomgaBook]>()
    private let libraryCache = LibraryNames<KomgaLibrary>()

    init(client: KomgaClient, settings: KomgaSettings) {
        self.client = client
        self.settings = settings
    }

    var id: Int64 { Self.id }
    var name: String { Self.name }
    var supportsLatest: Bool { true }
    var supportsUnread: Bool { true }
    var iconAsset: String? { "brand.komga" }
    var isConfigured: Bool { settings.isConfigured }

    func popular(page: Int) async throws -> MangasPage {
        try await browse(page, query: nil, sort: Self.sortTitle, libraryId: nil)
    }

    func latest(page: Int) async throws -> MangasPage {
        try await browse(page, query: nil, sort: Self.sortLastModified, libraryId: nil)
    }

    /// Komga filters by read status itself: series not started or part read, latest first.
    func unread(page: Int) async throws -> MangasPage {
        try await browse(page, query: nil, sort: Self.sortLastModified, libraryId: nil, unreadOnly: true)
    }

    func search(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        var libraryId: String?
        if let index = filters.selectState("Library"), index > 0 {
            let libraries = await libraryCache.value
            if libraries.indices.contains(index - 1) { libraryId = libraries[index - 1].id }
        }
        var sort = Self.sortTitle
        if let selection = filters.sortState("Sort"), Self.sortFields.indices.contains(selection.index) {
            sort = Self.sortFields[selection.index] + (selection.ascending ? ",asc" : ",desc")
        }
        return try await browse(page, query: query, sort: sort, libraryId: libraryId)
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
                values: [String(localized: "Title"), String(localized: "Recently added"), String(localized: "Recently updated"), String(localized: "Number of books")],
                selection: .init(index: 0, ascending: true)
            ),
        ]
    }

    /// Docho counts pages from 1, Komga from 0.
    private func browse(_ page: Int, query: String?, sort: String, libraryId: String?, unreadOnly: Bool = false) async throws -> MangasPage {
        let result = try await client.seriesPage(page: page - 1, query: query, sort: sort, libraryId: libraryId, unreadOnly: unreadOnly)
        return MangasPage(mangas: result.content.map { manga($0) }, hasNextPage: !result.last)
    }

    func update(_ manga: SManga, details: Bool, chapters: Bool) async throws -> (manga: SManga, chapters: [SChapter]?) {
        let seriesId = Self.seriesId(manga.url)
        let detailed = details ? self.manga(try await client.series(seriesId), details: true) : manga
        var list: [SChapter]?
        if chapters {
            let books = try await client.seriesBooks(seriesId)
            progressCache.put(seriesId, books)
            list = books.filter(\.hasPages).map { book in
                SChapter(
                    url: Self.chapterURL(book.id),
                    name: Self.chapterName(title: book.metadata.title.isBlank ? book.name : book.metadata.title, number: book.metadata.number),
                    dateUpload: ServerDates.parse(book.created) ?? ServerDates.parse(book.metadata.releaseDate),
                    number: book.metadata.numberSort,
                    memo: ChapterMemo([ChapterMemo.fileName: .string(book.fileName), "pages": .int(book.media.pagesCount)])
                )
            }
        }
        return (detailed, list)
    }

    func pages(_ chapter: SChapter) async throws -> [SourcePage] {
        let bookId = Self.bookId(chapter.url)
        return try await client.pages(bookId).enumerated().compactMap { index, page in
            client.pageImageURL(bookId: bookId, page: page.number).map { SourcePage(index: index, imageURL: $0) }
        }
    }

    func imageRequest(_ page: SourcePage) -> URLRequest { client.authorized(page.imageURL) }

    func coverRequest(_ manga: SManga) -> URLRequest? {
        client.thumbnailURL(seriesId: Self.seriesId(manga.url)).map(client.authorized)
    }

    func webURL(_ manga: SManga) -> URL? { client.seriesWebURL(Self.seriesId(manga.url)) }

    private func manga(_ series: KomgaSeries, details: Bool = false) -> SManga {
        var manga = SManga(url: Self.seriesURL(series.id), title: series.title)
        manga.author = Self.names(series.booksMetadata.authors, roles: Self.writerRoles)
        if details {
            manga.artist = Self.names(series.booksMetadata.authors, roles: Self.artistRoles)
            let summary = series.metadata.summary.isBlank ? series.booksMetadata.summary : series.metadata.summary
            manga.description = summary.isBlank ? nil : summary
            var seen = Set<String>()
            let genres = (series.metadata.genres + series.metadata.tags).filter { seen.insert($0).inserted }
            manga.genre = genres.isEmpty ? nil : genres.joined(separator: ", ")
            manga.status = switch series.metadata.status {
            case "ONGOING": .ongoing
            case "ENDED": .completed
            case "HIATUS": .onHiatus
            case "ABANDONED": .cancelled
            default: .unknown
            }
            manga.initialized = true
        }
        return manga
    }

    private static func names(_ authors: [KomgaSeries.Author], roles: Set<String>) -> String? {
        var seen = Set<String>()
        let names = authors.filter { roles.contains($0.role) }.map(\.name).filter { seen.insert($0).inserted }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    static func seriesURL(_ seriesId: String) -> String { "/series/\(seriesId)" }
    static func chapterURL(_ bookId: String) -> String { "/book/\(bookId)" }

    static func seriesId(_ url: String) -> String {
        String(url.components(separatedBy: "/series/").last?.split(separator: "/").first ?? "")
    }

    static func bookId(_ url: String) -> String {
        bookIdOrNil(url) ?? ""
    }

    static func bookIdOrNil(_ url: String) -> String? {
        guard url.contains("/book/") else { return nil }
        let id = url.components(separatedBy: "/book/").last?.split(separator: "/").first?.split(separator: "?").first.map(String.init)
        return id?.isEmpty == false ? id : nil
    }

    /// "#3 - Title", or the title alone when it's no more than the number.
    static func chapterName(title: String, number: String) -> String {
        let title = title.trimmingCharacters(in: .whitespaces)
        let number = number.trimmingCharacters(in: .whitespaces)
        if number.isEmpty { return title.isEmpty ? "Untitled" : title }
        if title.isEmpty || title == number { return "#\(number)" }
        return "#\(number) - \(title)"
    }
}

/// A server's libraries for its browse filter, which is built before searching.
actor LibraryNames<Library: Sendable> {
    private(set) var value: [Library] = []

    func set(_ libraries: [Library]) {
        value = libraries
    }
}
