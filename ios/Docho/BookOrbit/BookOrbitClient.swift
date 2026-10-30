import Foundation
import Synchronization

/// Port of `BookOrbitPreferences.kt`.
final class BookOrbitSettings: Sendable {
    let store: ServerSettings

    init(store: ServerSettings = ServerSettings(prefix: "bookorbit")) {
        self.store = store
    }

    /// Address of the BookOrbit server as opened in a browser, e.g. `http://bookorbit.lan:3010`.
    var serverURL: String {
        get { store.string("server_url") }
        set { store.setString("server_url", newValue) }
    }

    var username: String {
        get { store.string("username") }
        set { store.setString("username", newValue) }
    }

    var password: String {
        get { store.secret("password") }
        set { store.setSecret("password", newValue) }
    }

    /// The session BookOrbit gave this install, so the app doesn't add a new session to the
    /// account every time it starts.
    var refreshToken: String {
        get { store.secret("refresh_token") }
        set { store.setSecret("refresh_token", newValue) }
    }

    var syncProgress: Bool {
        get { store.bool("sync_progress", default: true) }
        set { store.setBool("sync_progress", newValue) }
    }

    var isConfigured: Bool { !serverURL.isBlank && !username.isBlank && !password.isBlank }

    func reset() {
        store.reset(plain: ["server_url", "username", "sync_progress"], secret: ["password", "refresh_token"])
    }
}

enum BookOrbitError: LocalizedError, Equatable {
    case notConfigured
    case authRejected
    case rateLimited
    case signInFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "BookOrbit is not set up. Add your server in Settings → Sync."
        case .authRejected: "BookOrbit rejected the username or password."
        case .rateLimited: "BookOrbit is limiting sign-ins; try again in a minute"
        case .signInFailed(let code): "BookOrbit sign-in failed (HTTP \(code))"
        }
    }
}

/// Port of `BookOrbitApi.kt`. Signs in the way BookOrbit's own iPhone app does, as a "native"
/// client: the password is exchanged for an access token, attached to every request, and a
/// refresh token that renews it. Concurrent requests share one sign-in.
actor BookOrbitClient {
    static let pageSize = 50
    private static let booksPageSize = 100

    nonisolated let status = ConnectionStatus()
    private let session: URLSession
    private let settings: BookOrbitSettings

    /// The settings a token was issued for, so a token is never sent to a different account.
    private struct Session: Equatable {
        var apiURL: String
        var username: String
        var accessToken: String
    }

    private var current: Session?
    private var signingIn: Task<Session, any Error>?

    init(settings: BookOrbitSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    /// `https://host[:port][/subpath]/api/v1`, or nil while no server is configured.
    nonisolated var apiURL: String? { ServerAddress.normalize(settings.serverURL, apiPath: "/api/v1") }

    static func normalizeApiURL(_ input: String) -> String? { ServerAddress.normalize(input, apiPath: "/api/v1") }

    @discardableResult
    func checkConnection() async -> ServerConnection {
        guard settings.isConfigured else {
            status.publish(.unknown)
            return .unknown
        }
        let snapshot = [settings.serverURL, settings.username, settings.password]
        status.publish(.checking)
        let result: ServerConnection
        do {
            let user: BookOrbitUser = try await get("/auth/me")
            result = .connected(user.username ?? settings.username)
        } catch {
            result = .failed(error.localizedDescription)
        }
        if snapshot == [settings.serverURL, settings.username, settings.password] { status.publish(result) }
        return result
    }

    /// Forgets the session, for when the server or account in settings changes.
    func signOut() {
        current = nil
        signingIn?.cancel()
        signingIn = nil
        settings.refreshToken = ""
    }

    func libraries() async throws -> [BookOrbitLibrary] { try await get("/libraries") }

    /// One page of series, `page` counting from 0.
    func seriesPage(page: Int, query: String?, sort: String, ascending: Bool, libraryId: Int?) async throws -> BookOrbitSeriesPage {
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "size", value: String(Self.pageSize)),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "order", value: ascending ? "asc" : "desc"),
        ]
        if let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let libraryId { items.append(URLQueryItem(name: "libraryId", value: String(libraryId))) }
        return try await get("/series", query: items)
    }

    /// Every book in a series, in series order, with the series' name and authors.
    func seriesBooks(_ seriesId: Int) async throws -> BookOrbitSeriesBooksPage {
        var books: [BookOrbitBook] = []
        var info: BookOrbitSeriesInfo?
        var page = 0
        while true {
            let result: BookOrbitSeriesBooksPage = try await get(
                "/series/\(seriesId)/books",
                query: [
                    URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "size", value: String(Self.booksPageSize)),
                    URLQueryItem(name: "sort", value: "seriesIndex"), URLQueryItem(name: "order", value: "asc"),
                ]
            )
            books += result.items
            info = info ?? result.seriesInfo
            if result.items.isEmpty || books.count >= result.total { break }
            page += 1
        }
        return BookOrbitSeriesBooksPage(items: books, total: books.count, seriesInfo: info)
    }

    func book(_ bookId: Int) async throws -> BookOrbitBookDetail { try await get("/books/\(bookId)") }

    func pageCount(fileId: Int) async throws -> Int {
        let result: BookOrbitPageCount = try await get("/cbz/files/\(fileId)/pages")
        return result.pageCount
    }

    func progress(fileId: Int) async throws -> BookOrbitProgress { try await get("/books/files/\(fileId)/progress") }

    func saveProgress(fileId: Int, _ progress: BookOrbitProgress) async throws {
        _ = try await send("/books/files/\(fileId)/progress", method: "POST", body: JSONEncoder().encode(progress))
    }

    /// Marks a book unread: its position is cleared and its status set back.
    func markUnread(bookId: Int, fileId: Int) async throws {
        _ = try await send("/books/files/\(fileId)/progress", method: "DELETE")
        try await setStatus(bookId: bookId, BookOrbitBook.statusUnread)
    }

    func setStatus(bookId: Int, _ status: String) async throws {
        _ = try await send("/books/\(bookId)/status", method: "PATCH", body: JSONEncoder().encode(["status": status]))
    }

    nonisolated func thumbnailURL(bookId: Int) -> URL? { apiURL.flatMap { URL(string: "\($0)/books/\(bookId)/thumbnail") } }
    nonisolated func pageImageURL(fileId: Int, page: Int) -> URL? { apiURL.flatMap { URL(string: "\($0)/cbz/files/\(fileId)/pages/\(page)") } }
    nonisolated func seriesWebURL(_ seriesId: Int) -> URL? {
        apiURL.flatMap { URL(string: "\($0.dropLast("/api/v1".count))/series/\(seriesId)") }
    }

    /// An image request with the current access token. Images are fetched by Nuke and the
    /// download session, outside this actor, so they read the token as it is now.
    func authorizedImage(_ url: URL) async -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(ServerAddress.userAgent, forHTTPHeaderField: "User-Agent")
        if let apiURL, let token = try? await accessToken(apiURL: apiURL, forceRefresh: false) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// The token as last known, without signing in; for building requests synchronously.
    nonisolated var cachedToken: String? { tokenCache.value }
    private nonisolated let tokenCache = TokenCache()

    // MARK: Requests

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(path, query: query))
    }

    private func send(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard settings.isConfigured, let apiURL, var components = URLComponents(string: apiURL + path) else {
            throw BookOrbitError.notConfigured
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw BookOrbitError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(ServerAddress.userAgent, forHTTPHeaderField: "User-Agent")

        request.setValue("Bearer \(try await accessToken(apiURL: apiURL, forceRefresh: false))", forHTTPHeaderField: "Authorization")
        var (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            request.setValue("Bearer \(try await accessToken(apiURL: apiURL, forceRefresh: true))", forHTTPHeaderField: "Authorization")
            (data, response) = try await session.data(for: request)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HTTPError.status(code) }
        return data
    }

    /// An access token for the current settings: the one in memory, else one from the saved
    /// refresh token, else a fresh sign-in with the password.
    private func accessToken(apiURL: String, forceRefresh: Bool) async throws -> String {
        let username = settings.username
        if !forceRefresh, let current, current.apiURL == apiURL, current.username == username {
            return current.accessToken
        }
        if let signingIn { return try await signingIn.value.accessToken }
        let refreshToken = (current == nil || current?.apiURL == apiURL) ? settings.refreshToken : ""
        let task = Task { [session, settings] in
            var credentials: BookOrbitCredentials?
            if !refreshToken.isBlank {
                credentials = try await Self.refresh(apiURL: apiURL, refreshToken: refreshToken, session: session)
            }
            if credentials == nil {
                credentials = try await Self.signIn(apiURL: apiURL, username: username, password: settings.password, session: session)
            }
            guard let credentials else { throw BookOrbitError.authRejected }
            if let refresh = credentials.refreshToken { settings.refreshToken = refresh }
            return Session(apiURL: apiURL, username: username, accessToken: credentials.accessToken)
        }
        signingIn = task
        defer { signingIn = nil }
        do {
            let session = try await task.value
            current = session
            tokenCache.set(session.accessToken)
            status.publish(.connected(username))
            return session.accessToken
        } catch BookOrbitError.authRejected {
            settings.refreshToken = ""
            status.publish(.failed(BookOrbitError.authRejected.localizedDescription))
            throw BookOrbitError.authRejected
        }
    }

    /// nil when the refresh token is no longer accepted, so the caller signs in again.
    private static func refresh(apiURL: String, refreshToken: String, session: URLSession) async throws -> BookOrbitCredentials? {
        let (data, code) = try await post(apiURL + "/auth/refresh", body: ["refreshToken": refreshToken], session: session)
        if (200..<300).contains(code) { return try JSONDecoder().decode(BookOrbitCredentials.self, from: data) }
        if code == 400 || code == 401 { return nil }
        throw BookOrbitError.signInFailed(code)
    }

    private static func signIn(apiURL: String, username: String, password: String, session: URLSession) async throws -> BookOrbitCredentials {
        let body = ["username": username, "password": password, "clientKind": "native", "deviceLabel": "Docho"]
        let (data, code) = try await post(apiURL + "/auth/login", body: body, session: session)
        switch code {
        case 200..<300: return try JSONDecoder().decode(BookOrbitCredentials.self, from: data)
        case 401, 403: throw BookOrbitError.authRejected
        case 429: throw BookOrbitError.rateLimited
        default: throw BookOrbitError.signInFailed(code)
        }
    }

    private static func post(_ url: String, body: [String: String], session: URLSession) async throws -> (Data, Int) {
        guard let url = URL(string: url) else { throw BookOrbitError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ServerAddress.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// The latest access token, readable without awaiting the client.
final class TokenCache: Sendable {
    private let token = Mutex<String?>(nil)

    var value: String? { token.withLock { $0 } }

    func set(_ value: String?) {
        token.withLock { $0 = value }
    }
}

// MARK: - Models

struct BookOrbitCredentials: Decodable, Sendable {
    var accessToken: String
    var refreshToken: String?
}

struct BookOrbitUser: Decodable, Sendable {
    var username: String?
}

struct BookOrbitLibrary: Decodable, Sendable, Equatable {
    var id: Int
    var name: String
}

struct BookOrbitSeriesPage: Decodable, Sendable {
    var items: [BookOrbitSeries]
    var total: Int

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = values.lenient(.items, default: [])
        total = values.lenient(.total, default: 0)
    }

    private enum CodingKeys: String, CodingKey { case items, total }
}

struct BookOrbitSeries: Decodable, Sendable, Equatable {
    var id: Int
    var name: String
    var authors: [String]
    var coverBookIds: [Int]
    var bookCount: Int
    /// Books the user has marked read.
    var readCount: Int

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        name = values.lenient(.name, default: "")
        authors = values.lenient(.authors, default: [])
        coverBookIds = values.lenient(.coverBookIds, default: [])
        bookCount = values.lenient(.bookCount, default: 0)
        readCount = values.lenient(.readCount, default: 0)
    }

    private enum CodingKeys: String, CodingKey { case id, name, authors, coverBookIds, bookCount, readCount }
}

struct BookOrbitSeriesBooksPage: Decodable, Sendable {
    var items: [BookOrbitBook]
    var total: Int
    var seriesInfo: BookOrbitSeriesInfo?

    init(items: [BookOrbitBook], total: Int, seriesInfo: BookOrbitSeriesInfo?) {
        self.items = items
        self.total = total
        self.seriesInfo = seriesInfo
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = values.lenient(.items, default: [])
        total = values.lenient(.total, default: 0)
        seriesInfo = values.lenient(.seriesInfo, default: nil)
    }

    private enum CodingKeys: String, CodingKey { case items, total, seriesInfo }
}

struct BookOrbitSeriesInfo: Decodable, Sendable {
    var id: Int
    var name: String
    var authors: [String]

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        name = values.lenient(.name, default: "")
        authors = values.lenient(.authors, default: [])
    }

    private enum CodingKeys: String, CodingKey { case id, name, authors }
}

struct BookOrbitBook: Decodable, Sendable, Equatable {
    static let comicFormats: Set<String> = ["cbz", "cbr", "cb7", "cbt"]
    static let statusRead = "read"
    static let statusUnread = "unread"

    var id: Int
    var title: String?
    var seriesIndex: String?
    var files: [File]
    var genres: [String]
    /// How far the user is, from 0 to 100, or nil if not started.
    var readingProgress: Double?
    var readStatus: String?
    var addedAt: String?
    var publishedDate: String?

    struct File: Decodable, Sendable, Equatable {
        var id: Int
        var format: String?
    }

    /// The comic archive Docho can show page by page; BookOrbit's page API only serves these.
    var comicFile: File? { files.first { Self.comicFormats.contains($0.format?.lowercased() ?? "") } }

    var isRead: Bool { readStatus == Self.statusRead || (readingProgress ?? 0) >= 100 }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        title = values.lenient(.title, default: nil)
        // BookOrbit sends the index as a string; accept a number too.
        let indexString: String? = values.lenient(.seriesIndex, default: nil)
        let indexNumber: Double? = values.lenient(.seriesIndex, default: nil)
        seriesIndex = indexString ?? indexNumber.map(formatNumber)
        files = values.lenient(.files, default: [])
        genres = values.lenient(.genres, default: [])
        readingProgress = values.lenient(.readingProgress, default: nil)
        let status = try? values.nestedContainer(keyedBy: StatusKeys.self, forKey: .readStatus)
        readStatus = status?.lenient(.status, default: nil)
        addedAt = values.lenient(.addedAt, default: nil)
        publishedDate = values.lenient(.publishedDate, default: nil)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, seriesIndex, files, genres, readingProgress, readStatus, addedAt, publishedDate
    }

    private enum StatusKeys: String, CodingKey { case status }
}

struct BookOrbitBookDetail: Decodable, Sendable {
    var id: Int
    var files: [File]

    struct File: Decodable, Sendable {
        var id: Int
        /// KOReader's partial MD5 of the file, which BookOrbit matches KOReader's progress by.
        var fileHash: String?
    }
}

struct BookOrbitPageCount: Decodable, Sendable {
    var pageCount: Int
}

/// A file's position: `pageNumber` is 1-based and `percentage` runs from 0 to 100.
struct BookOrbitProgress: Codable, Sendable, Equatable {
    var pageNumber: Int?
    var percentage: Double

    init(pageNumber: Int?, percentage: Double) {
        self.pageNumber = pageNumber
        self.percentage = percentage
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pageNumber = values.lenient(.pageNumber, default: nil)
        percentage = values.lenient(.percentage, default: 0)
    }

    /// Both fields always go out, as BookOrbit expects.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageNumber, forKey: .pageNumber)
        try container.encode(percentage, forKey: .percentage)
    }

    private enum CodingKeys: String, CodingKey { case pageNumber, percentage }
}
