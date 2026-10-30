import Foundation
import Synchronization

/// Where series come from (Tachiyomi's `CatalogueSource`). Kavita, Komga and BookOrbit are built
/// in; extensions would be further implementations.
///
/// Chapters are returned in **reading order**, oldest first (Android's sources return them newest
/// first; the iOS app stores reading order directly).
protocol MangaSource: Sendable {
    /// Fixed for the source's lifetime; stored with every series read from it.
    var id: Int64 { get }
    var name: String { get }
    /// "other" for sources not tied to a language, such as the built-in servers.
    var lang: String { get }
    var supportsLatest: Bool { get }
    /// Whether the source offers Docho's "Unread" listing next to Popular and Latest.
    var supportsUnread: Bool { get }
    /// An asset name for the source's logo, if it has one.
    var iconAsset: String? { get }
    /// Whether the source can be used now; unconfigured built-ins are hidden from Browse.
    var isConfigured: Bool { get }

    func popular(page: Int) async throws -> MangasPage
    func latest(page: Int) async throws -> MangasPage
    func unread(page: Int) async throws -> MangasPage
    func search(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage
    /// The filters with their default states.
    func filterList() async -> [SourceFilter]

    /// Fetches the details, the chapters, or both. Chapters come in reading order; nil when not asked for.
    func update(_ manga: SManga, details: Bool, chapters: Bool) async throws -> (manga: SManga, chapters: [SChapter]?)
    func pages(_ chapter: SChapter) async throws -> [SourcePage]
    /// The request for a page image, with whatever the server needs to accept it.
    func imageRequest(_ page: SourcePage) -> URLRequest
    func coverRequest(_ manga: SManga) -> URLRequest?
    /// The series on the server's own website, for "Open in browser".
    func webURL(_ manga: SManga) -> URL?
}

extension MangaSource {
    var lang: String { "other" }
    var supportsUnread: Bool { false }
    var iconAsset: String? { nil }

    func latest(page: Int) async throws -> MangasPage { MangasPage(mangas: [], hasNextPage: false) }
    func unread(page: Int) async throws -> MangasPage { MangasPage(mangas: [], hasNextPage: false) }
    func filterList() async -> [SourceFilter] { [] }
    func imageRequest(_ page: SourcePage) -> URLRequest { URLRequest(url: page.imageURL) }
    func webURL(_ manga: SManga) -> URL? { nil }
}

/// A series' source when it isn't available: shown with its id, and only downloaded chapters open.
struct StubSource: MangaSource {
    let id: Int64

    var name: String { String(localized: "Unknown source (\(String(id, radix: 16)))") }
    var supportsLatest: Bool { false }
    var isConfigured: Bool { false }

    func popular(page: Int) async throws -> MangasPage { throw SourceError.notInstalled }
    func search(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage { throw SourceError.notInstalled }
    func update(_ manga: SManga, details: Bool, chapters: Bool) async throws -> (manga: SManga, chapters: [SChapter]?) {
        throw SourceError.notInstalled
    }
    func pages(_ chapter: SChapter) async throws -> [SourcePage] { throw SourceError.notInstalled }
    func coverRequest(_ manga: SManga) -> URLRequest? { manga.thumbnailURL.flatMap(URL.init(string:)).map { URLRequest(url: $0) } }
}

enum SourceError: LocalizedError {
    case notInstalled
    case noPages

    var errorDescription: String? {
        switch self {
        case .notInstalled: String(localized: "Source not installed")
        case .noPages: String(localized: "No pages found")
        }
    }
}

/// The sources the app knows, by id (Mihon's `SourceManager`): the built-in ones, and those a
/// Suwayomi server offers, which come and go as extensions are installed.
final class SourceManager: Sendable {
    private let builtIn: [any MangaSource]
    private let dynamic = Mutex<[any MangaSource]>([])

    init(sources: [any MangaSource]) {
        builtIn = sources
    }

    var sources: [any MangaSource] {
        builtIn + dynamic.withLock { $0 }
    }

    func setDynamic(_ sources: [any MangaSource]) {
        dynamic.withLock { $0 = sources.filter { source in !builtIn.contains { $0.id == source.id } } }
    }

    func source(_ id: Int64) -> any MangaSource {
        sources.first { $0.id == id } ?? StubSource(id: id)
    }

    /// Sources to list under Browse: those set up, in a fixed order.
    var available: [any MangaSource] {
        sources.filter(\.isConfigured)
    }

    static func isBuiltIn(_ id: Int64) -> Bool {
        [LocalSource.id, KavitaSource.id, KomgaSource.id, BookOrbitSource.id].contains(id)
    }
}

/// Shared helpers for the built-in servers' addresses.
enum ServerAddress {
    /// Accepts a bare host, a URL with or without a trailing slash, or one that already has
    /// `/api/…`; returns the base with `apiPath` added (Android's `normalizeApiUrl` for Komga
    /// and BookOrbit). Like Kavita's on iOS, `/api` is only cut as a path segment after the host.
    static func normalize(_ input: String, apiPath: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var scheme = "http://"
        var rest = Substring(trimmed)
        for candidate in ["http://", "https://"] where trimmed.lowercased().hasPrefix(candidate) {
            scheme = String(trimmed.prefix(candidate.count))
            rest = trimmed.dropFirst(candidate.count)
        }
        while rest.hasSuffix("/") { rest.removeLast() }
        guard !rest.isEmpty else { return nil }
        let path = rest.drop { $0 != "/" }
        let base = path.firstRange(of: #/\/api(?=$|[\/?#])/#.ignoresCase()).map { rest[..<$0.lowerBound] } ?? rest
        let result = scheme + base + apiPath
        guard let url = URL(string: result, encodingInvalidCharacters: false), let host = url.host(), !host.isEmpty else {
            return nil
        }
        return result
    }

    /// The user agent the built-in servers see, as on Android.
    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "Docho-iOS v\(version) (io.github.grillza.docho)"
    }
}

/// Server dates: an offset or `Z` is honoured; a date alone is the start of that local day.
enum ServerDates {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isBlank else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
    }
}
