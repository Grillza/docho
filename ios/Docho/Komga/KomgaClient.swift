import Foundation

/// Port of `KomgaPreferences.kt`.
final class KomgaSettings: Sendable {
    let store: ServerSettings

    init(store: ServerSettings = ServerSettings(prefix: "komga")) {
        self.store = store
    }

    /// Address of the Komga server as opened in a browser, e.g. `http://komga.lan:25600`.
    var serverURL: String {
        get { store.string("server_url") }
        set { store.setString("server_url", newValue) }
    }

    var apiKey: String {
        get { store.secret("api_key") }
        set { store.setSecret("api_key", newValue) }
    }

    /// Pushes reading progress to Komga and pulls it back, page by page.
    var syncProgress: Bool {
        get { store.bool("sync_progress", default: true) }
        set { store.setBool("sync_progress", newValue) }
    }

    /// Whether Komga books may be downloaded in full to match them with KOReader, which knows a
    /// book by a hash of samples across its file. Komga can't serve part of a file.
    var koreaderDownloads: Bool {
        get { store.bool("koreader_downloads", default: false) }
        set { store.setBool("koreader_downloads", newValue) }
    }

    /// Set by "Don't show this again" on the notice explaining `koreaderDownloads`.
    var koreaderNoticeHidden: Bool {
        get { store.bool("koreader_notice_hidden", default: false) }
        set { store.setBool("koreader_notice_hidden", newValue) }
    }

    var isConfigured: Bool { !serverURL.isBlank && !apiKey.isBlank }

    func reset() {
        store.reset(plain: ["server_url", "sync_progress", "koreader_downloads", "koreader_notice_hidden"], secret: ["api_key"])
    }
}

enum KomgaError: LocalizedError, Equatable {
    case notConfigured
    case authRejected

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Komga is not set up. Add your server in Settings → Sync."
        case .authRejected: "Komga rejected the API key."
        }
    }
}

/// Port of `KomgaApi.kt`. Komga accepts an API key in the `X-API-Key` header on every request,
/// so there's no session to keep; page images and covers need it too.
actor KomgaClient {
    static let pageSize = 50

    nonisolated let status = ConnectionStatus()
    private let session: URLSession
    private let settings: KomgaSettings

    init(settings: KomgaSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    /// `https://host[:port][/subpath]/api`, or nil while no server is configured.
    nonisolated var apiURL: String? { ServerAddress.normalize(settings.serverURL, apiPath: "/api") }

    static func normalizeApiURL(_ input: String) -> String? { ServerAddress.normalize(input, apiPath: "/api") }

    /// Asks the server who the key belongs to and publishes the outcome.
    @discardableResult
    func checkConnection() async -> ServerConnection {
        let server = settings.serverURL
        let key = settings.apiKey
        guard settings.isConfigured else {
            status.publish(.unknown)
            return .unknown
        }
        status.publish(.checking)
        let result: ServerConnection
        do {
            let user: KomgaUser = try await get("/v2/users/me")
            result = .connected(user.email)
        } catch {
            result = .failed(error.localizedDescription)
        }
        // Settings may have changed while checking; only the latest check counts.
        if server == settings.serverURL, key == settings.apiKey { status.publish(result) }
        return result
    }

    func libraries() async throws -> [KomgaLibrary] {
        try await get("/v1/libraries")
    }

    /// One page of series, `page` counting from 0.
    func seriesPage(page: Int, query: String?, sort: String, libraryId: String?, unreadOnly: Bool = false) async throws -> KomgaPage<KomgaSeries> {
        try await post(
            "/v1/series/list?page=\(page)&size=\(Self.pageSize)&sort=\(sort.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sort)",
            body: Self.seriesSearch(query: query, libraryId: libraryId, unreadOnly: unreadOnly)
        )
    }

    /// Every book of a series, in Komga's reading order.
    func seriesBooks(_ seriesId: String) async throws -> [KomgaBook] {
        let body: [String: Any] = ["condition": ["allOf": [Self.isCondition("seriesId", seriesId), Self.notDeleted]]]
        let page: KomgaPage<KomgaBook> = try await post("/v1/books/list?unpaged=true&sort=metadata.numberSort,asc", body: body)
        return page.content
    }

    func series(_ seriesId: String) async throws -> KomgaSeries { try await get("/v1/series/\(seriesId)") }
    func book(_ bookId: String) async throws -> KomgaBook { try await get("/v1/books/\(bookId)") }
    func pages(_ bookId: String) async throws -> [KomgaPageInfo] { try await get("/v1/books/\(bookId)/pages") }

    /// Moves the book to `page` (1-based); Komga marks it finished when that is the last page.
    func saveProgress(_ bookId: String, page: Int) async throws {
        try await patchProgress(bookId, ["page": page])
    }

    func markRead(_ bookId: String) async throws {
        try await patchProgress(bookId, ["completed": true])
    }

    func markUnread(_ bookId: String) async throws {
        _ = try await send(try request("/v1/books/\(bookId)/read-progress", method: "DELETE"))
    }

    private func patchProgress(_ bookId: String, _ body: [String: Any]) async throws {
        var request = try request("/v1/books/\(bookId)/read-progress", method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(request)
    }

    /// KOReader's hash of a book's file. Komga only sends whole files, so this streams the book
    /// up to the last sample KOReader takes and keeps none of it.
    func koreaderHash(_ bookId: String) async throws -> String {
        let (bytes, response) = try await session.bytes(for: try request("/v1/books/\(bookId)/file"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HTTPError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let size = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        return try await KoreaderHash.compute(stream: bytes, size: size)
    }

    nonisolated func thumbnailURL(seriesId: String) -> URL? { apiURL.flatMap { URL(string: "\($0)/v1/series/\(seriesId)/thumbnail") } }
    nonisolated func pageImageURL(bookId: String, page: Int) -> URL? { apiURL.flatMap { URL(string: "\($0)/v1/books/\(bookId)/pages/\(page)") } }
    nonisolated func seriesWebURL(_ seriesId: String) -> URL? {
        apiURL.flatMap { URL(string: "\($0.dropLast("/api".count))/series/\(seriesId)") }
    }

    /// An authorised request for an image, for Nuke and downloads.
    nonisolated func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(settings.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue(ServerAddress.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: Requests

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard settings.isConfigured, let apiURL else { throw KomgaError.notConfigured }
        guard let url = URL(string: apiURL + path) else { throw KomgaError.notConfigured }
        var request = authorized(url)
        request.httpMethod = method
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            status.publish(.failed(KomgaError.authRejected.localizedDescription))
            throw KomgaError.authRejected
        }
        guard (200..<300).contains(code) else { throw HTTPError.status(code) }
        return data
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(try request(path)))
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var request = try request(path, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try JSONDecoder().decode(T.self, from: try await send(request))
    }

    // MARK: Search bodies

    /// Komga's series search: a condition tree plus an optional full-text search. Deleted series
    /// are always left out, as Komga's own UI does.
    static func seriesSearch(query: String?, libraryId: String?, unreadOnly: Bool) -> [String: Any] {
        var conditions: [[String: Any]] = [notDeleted]
        if let libraryId { conditions.append(isCondition("libraryId", libraryId)) }
        if unreadOnly {
            conditions.append(["anyOf": [isCondition("readStatus", "UNREAD"), isCondition("readStatus", "IN_PROGRESS")]])
        }
        var body: [String: Any] = ["condition": ["allOf": conditions]]
        if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            body["fullTextSearch"] = query
        }
        return body
    }

    static func isCondition(_ field: String, _ value: String) -> [String: Any] {
        [field: ["operator": "is", "value": value]]
    }

    static var notDeleted: [String: Any] { ["deleted": ["operator": "isFalse"]] }
}

// MARK: - Models

/// Only the fields Docho reads; Komga ids are strings and its lists come as Spring pages.
struct KomgaUser: Decodable, Sendable {
    var email: String

    init(from decoder: any Decoder) throws {
        email = try decoder.container(keyedBy: CodingKeys.self).lenient(.email, default: "")
    }

    private enum CodingKeys: String, CodingKey { case email }
}

struct KomgaLibrary: Decodable, Sendable, Equatable {
    var id: String
    var name: String
}

struct KomgaPage<T: Decodable & Sendable>: Decodable, Sendable {
    var content: [T]
    var last: Bool

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        content = values.lenient(.content, default: [])
        last = values.lenient(.last, default: true)
    }

    private enum CodingKeys: String, CodingKey { case content, last }
}

struct KomgaSeries: Decodable, Sendable, Equatable {
    var id: String
    var name: String
    var booksCount: Int
    var metadata: Metadata
    var booksMetadata: BooksMetadata

    var title: String { metadata.title.isBlank ? name : metadata.title }

    struct Metadata: Decodable, Sendable, Equatable {
        var title = ""
        var summary = ""
        var status = ""
        var genres: [String] = []
        var tags: [String] = []

        init() {}

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            title = values.lenient(.title, default: "")
            summary = values.lenient(.summary, default: "")
            status = values.lenient(.status, default: "")
            genres = values.lenient(.genres, default: [])
            tags = values.lenient(.tags, default: [])
        }

        private enum CodingKeys: String, CodingKey { case title, summary, status, genres, tags }
    }

    /// What Komga gathers from the books of a series: their authors, and a summary if the series has none.
    struct BooksMetadata: Decodable, Sendable, Equatable {
        var authors: [Author] = []
        var summary = ""

        init() {}

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            authors = values.lenient(.authors, default: [])
            summary = values.lenient(.summary, default: "")
        }

        private enum CodingKeys: String, CodingKey { case authors, summary }
    }

    struct Author: Decodable, Sendable, Equatable {
        var name: String
        var role: String

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            role = values.lenient(.role, default: "")
        }

        private enum CodingKeys: String, CodingKey { case name, role }
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = values.lenient(.name, default: "")
        booksCount = values.lenient(.booksCount, default: 0)
        metadata = values.lenient(.metadata, default: Metadata())
        booksMetadata = values.lenient(.booksMetadata, default: BooksMetadata())
    }

    private enum CodingKeys: String, CodingKey { case id, name, booksCount, metadata, booksMetadata }
}

struct KomgaBook: Decodable, Sendable, Equatable {
    var id: String
    var seriesId: String
    var name: String
    /// The file's path, or only its name for accounts that aren't administrators.
    var url: String
    var created: String?
    var media: Media
    var metadata: Metadata
    var readProgress: ReadProgress?

    struct Media: Decodable, Sendable, Equatable {
        var status = ""
        var pagesCount = 0
        var mediaProfile = ""
        var epubDivinaCompatible = false

        init() {}

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            status = values.lenient(.status, default: "")
            pagesCount = values.lenient(.pagesCount, default: 0)
            mediaProfile = values.lenient(.mediaProfile, default: "")
            epubDivinaCompatible = values.lenient(.epubDivinaCompatible, default: false)
        }

        private enum CodingKeys: String, CodingKey { case status, pagesCount, mediaProfile, epubDivinaCompatible }
    }

    struct Metadata: Decodable, Sendable, Equatable {
        var title = ""
        var number = ""
        var numberSort: Double = -1
        var releaseDate: String?

        init() {}

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            title = values.lenient(.title, default: "")
            number = values.lenient(.number, default: "")
            numberSort = values.lenient(.numberSort, default: -1)
            releaseDate = values.lenient(.releaseDate, default: nil)
        }

        private enum CodingKeys: String, CodingKey { case title, number, numberSort, releaseDate }
    }

    /// The page reached, counting from 1, and whether the book is finished.
    struct ReadProgress: Decodable, Sendable, Equatable {
        var page: Int
        var completed: Bool

        init(page: Int, completed: Bool) {
            self.page = page
            self.completed = completed
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            page = values.lenient(.page, default: 0)
            completed = values.lenient(.completed, default: false)
        }

        private enum CodingKeys: String, CodingKey { case page, completed }
    }

    /// Komga turns comic archives, PDFs and image-based EPUBs into page images; other EPUBs are text.
    var hasPages: Bool {
        media.status == "READY" && media.pagesCount > 0 && (["DIVINA", "PDF"].contains(media.mediaProfile) || media.epubDivinaCompatible)
    }

    var fileName: String {
        let last = url.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        return last.isBlank ? name : last
    }

    var isRead: Bool { readProgress?.completed == true }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        seriesId = values.lenient(.seriesId, default: "")
        name = values.lenient(.name, default: "")
        url = values.lenient(.url, default: "")
        created = values.lenient(.created, default: nil)
        media = values.lenient(.media, default: Media())
        metadata = values.lenient(.metadata, default: Metadata())
        readProgress = values.lenient(.readProgress, default: nil)
    }

    private enum CodingKeys: String, CodingKey { case id, seriesId, name, url, created, media, metadata, readProgress }
}

struct KomgaPageInfo: Decodable, Sendable {
    var number: Int
}
