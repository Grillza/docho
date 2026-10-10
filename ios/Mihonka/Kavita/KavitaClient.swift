import Foundation

/// The saved server address (as typed) and API key.
struct KavitaCredentials: Sendable, Equatable {
    var serverURL: String
    var apiKey: String

    var isConfigured: Bool { !serverURL.isBlank && !apiKey.isBlank }
}

/// Outcome of the latest sign-in, shown as the status light in settings.
enum KavitaConnection: Sendable, Equatable {
    /// No server configured, or not checked yet.
    case unknown
    case checking
    case connected(username: String, version: String?)
    case failed(reason: String)
}

enum KavitaError: LocalizedError, Equatable {
    case notConfigured
    case invalidServerAddress
    case authRejected
    case signInFailed(status: Int)
    case http(status: Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Kavita is not set up. Add your server in Settings."
        case .invalidServerAddress: "Invalid server address"
        case .authRejected: "Kavita rejected the API key."
        case .signInFailed(let status): "Kavita sign-in failed (HTTP \(status))"
        case .http(let status): "HTTP \(status)"
        }
    }
}

/// Port of `KavitaApi.kt`. Talks to the configured Kavita server using the plugin flow Kavita
/// offers third-party readers: the API key is exchanged for a JWT, which is attached to every
/// request and renewed once when the server answers 401. Concurrent requests share one sign-in.
actor KavitaClient {
    static let pageSize = 30
    private static let pluginName = "Mihonka"

    nonisolated let connectionChanges: AsyncStream<KavitaConnection>
    private let connectionContinuation: AsyncStream<KavitaConnection>.Continuation

    private let session: URLSession
    private let credentials: @Sendable () -> KavitaCredentials
    private let userAgent: String

    private struct SessionKey: Equatable {
        var apiURL: String
        var apiKey: String
    }

    private var signedIn: (key: SessionKey, token: String)?
    private var signingIn: (key: SessionKey, task: Task<KavitaUser, any Error>)?

    init(
        session: URLSession = .shared,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
        credentials: @escaping @Sendable () -> KavitaCredentials
    ) {
        self.session = session
        self.credentials = credentials
        self.userAgent = "Mihonka-iOS v\(appVersion) (app.mihonka)"
        (connectionChanges, connectionContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - Connection

    /// Signs in with the saved settings and publishes the outcome to `connectionChanges`.
    @discardableResult
    func checkConnection() async -> KavitaConnection {
        let creds = credentials()
        guard creds.isConfigured else {
            connectionContinuation.yield(.unknown)
            return .unknown
        }
        connectionContinuation.yield(.checking)
        let result: KavitaConnection
        do {
            guard let apiURL = Self.normalizeApiURL(creds.serverURL) else { throw KavitaError.invalidServerAddress }
            let key = SessionKey(apiURL: apiURL, apiKey: creds.apiKey)
            let user = try await Self.authenticate(key, session: session, userAgent: userAgent)
            signedIn = (key, user.token)
            result = .connected(username: user.username, version: user.kavitaVersion)
        } catch {
            result = .failed(reason: error.localizedDescription)
        }
        // Settings may have changed while signing in; only the latest check counts.
        if credentials() == creds {
            connectionContinuation.yield(result)
        }
        return result
    }

    // MARK: - Endpoints

    func libraries() async throws -> [KavitaLibrary] {
        try await get("/Library/libraries")
    }

    func seriesPage(filter: KavitaFilter, page: Int, pageSize: Int = KavitaClient.pageSize) async throws -> KavitaSeriesPage {
        let (data, response) = try await send(
            "POST",
            "/Series/all-v2?pageNumber=\(page)&pageSize=\(pageSize)",
            body: JSONEncoder().encode(filter)
        )
        let series = try JSONDecoder().decode([KavitaSeries].self, from: data)
        let pagination = response.value(forHTTPHeaderField: "Pagination")
            .flatMap { try? JSONDecoder().decode(KavitaPagination.self, from: Data($0.utf8)) }
        let hasNext = pagination.map { $0.currentPage < $0.totalPages } ?? (series.count >= pageSize)
        return KavitaSeriesPage(series: series, hasNextPage: hasNext)
    }

    func series(id seriesId: Int) async throws -> KavitaSeries {
        try await get("/Series/\(seriesId)")
    }

    func seriesMetadata(seriesId: Int) async throws -> KavitaSeriesMetadata {
        try await get("/Series/metadata?seriesId=\(seriesId)")
    }

    func volumes(seriesId: Int) async throws -> [KavitaVolume] {
        try await get("/Series/volumes?seriesId=\(seriesId)")
    }

    func chapter(id chapterId: Int) async throws -> KavitaChapter {
        try await get("/Chapter?chapterId=\(chapterId)")
    }

    /// The page the server has for one chapter; `pages` means read. Servers without
    /// `get-progress` answer 404, and then the chapter's `pagesRead` from the volumes is used.
    func pagesRead(seriesId: Int, chapterId: Int) async throws -> Int {
        do {
            let position: KavitaReadPosition = try await get("/Reader/get-progress?chapterId=\(chapterId)")
            return position.pageNum
        } catch KavitaError.http(status: 404) {
            return try await volumes(seriesId: seriesId)
                .lazy.flatMap(\.chapters)
                .first { $0.id == chapterId }?
                .pagesRead ?? 0
        }
    }

    func saveProgress(_ progress: KavitaProgress) async throws {
        _ = try await send("POST", "/Reader/progress", body: JSONEncoder().encode(progress))
    }

    /// Marks whole chapters read (`read = true`) or unread in one request.
    func setChaptersRead(seriesId: Int, chapterIds: [Int], read: Bool) async throws {
        let body = KavitaMarkChapters(seriesId: seriesId, volumeIds: [], chapterIds: chapterIds)
        let endpoint = read ? "mark-multiple-read" : "mark-multiple-unread"
        _ = try await send("POST", "/Reader/\(endpoint)", body: JSONEncoder().encode(body))
    }

    nonisolated func seriesCoverURL(seriesId: Int) throws -> URL {
        try url(apiURL(), "/Image/series-cover?seriesId=\(seriesId)")
    }

    nonisolated func pageImageURL(chapterId: Int, page: Int) throws -> URL {
        try url(apiURL(), "/Reader/image?chapterId=\(chapterId)&page=\(page)&extractPdf=true")
    }

    /// Address of the series in Kavita's own web UI.
    nonisolated func seriesWebURL(libraryId: Int, seriesId: Int) throws -> URL {
        let base = try apiURL().dropLast("/api".count)
        return try url(String(base), "/library/\(libraryId)/series/\(seriesId)")
    }

    // MARK: - Requests

    private func get<T: Decodable>(_ pathAndQuery: String) async throws -> T {
        let (data, _) = try await send("GET", pathAndQuery)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Sends an authorized request, signing in again once on a 401.
    private func send(_ method: String, _ pathAndQuery: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let creds = credentials()
        guard creds.isConfigured else { throw KavitaError.notConfigured }
        guard let apiURL = Self.normalizeApiURL(creds.serverURL) else { throw KavitaError.invalidServerAddress }
        let key = SessionKey(apiURL: apiURL, apiKey: creds.apiKey)

        var request = URLRequest(url: Self.addingApiKeyIfImage(try url(apiURL, pathAndQuery), apiKey: creds.apiKey))
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        var token = try await token(for: key, replacing: nil)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await data(for: request)
        if response.statusCode == 401 {
            token = try await self.token(for: key, replacing: token)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            (data, response) = try await self.data(for: request)
        }
        guard (200..<300).contains(response.statusCode) else { throw KavitaError.http(status: response.statusCode) }
        return (data, response)
    }

    /// A valid token for `key`. Signs in when there is none, when the settings changed, or when
    /// `stale` (a token the server just refused) is still the current one.
    private func token(for key: SessionKey, replacing stale: String?) async throws -> String {
        if let signedIn, signedIn.key == key, signedIn.token != stale {
            return signedIn.token
        }
        if let signingIn, signingIn.key == key {
            return try await signingIn.task.value.token
        }

        let task = Task { [session, userAgent] in
            try await Self.authenticate(key, session: session, userAgent: userAgent)
        }
        signingIn = (key, task)
        defer { if signingIn?.task == task { signingIn = nil } }
        do {
            let user = try await task.value
            signedIn = (key, user.token)
            connectionContinuation.yield(.connected(username: user.username, version: user.kavitaVersion))
            return user.token
        } catch KavitaError.authRejected {
            connectionContinuation.yield(.failed(reason: KavitaError.authRejected.localizedDescription))
            throw KavitaError.authRejected
        }
    }

    private static func authenticate(_ key: SessionKey, session: URLSession, userAgent: String) async throws -> KavitaUser {
        var components = URLComponents(string: key.apiURL + "/Plugin/authenticate")
        components?.queryItems = [
            URLQueryItem(name: "apiKey", value: key.apiKey),
            URLQueryItem(name: "pluginName", value: pluginName),
        ]
        guard let url = components?.url else { throw KavitaError.invalidServerAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw KavitaError.authRejected }
        guard (200..<300).contains(status) else { throw KavitaError.signInFailed(status: status) }
        return try JSONDecoder().decode(KavitaUser.self, from: data)
    }

    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private nonisolated func apiURL() throws -> String {
        let creds = credentials()
        guard !creds.serverURL.isBlank else { throw KavitaError.notConfigured }
        guard let apiURL = Self.normalizeApiURL(creds.serverURL) else { throw KavitaError.invalidServerAddress }
        return apiURL
    }

    private nonisolated func url(_ base: String, _ pathAndQuery: String) throws -> URL {
        guard let url = URL(string: base + pathAndQuery) else { throw KavitaError.invalidServerAddress }
        return url
    }

    // MARK: - URL rules

    /// Kavita's image endpoints authenticate with an `apiKey` query parameter rather than the
    /// bearer token, because its web UI loads them through `<img>` tags.
    static func addingApiKeyIfImage(_ url: URL, apiKey: String) -> URL {
        guard url.path().range(of: "/image", options: .caseInsensitive) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "apiKey" }) else { return url }
        items.append(URLQueryItem(name: "apiKey", value: apiKey))
        components.queryItems = items
        return components.url ?? url
    }

    /// `https://host[:port][/subpath]/api`, from what people paste: a bare host, a URL with or
    /// without a trailing slash, or a link that already contains `/api/…` (such as Kavita's OPDS
    /// URL). Returns nil when nothing usable is left.
    ///
    /// Differs from Android on purpose: `/api` is only looked for as a path segment after the
    /// host, so `https://api.example.com` keeps its host (Android cuts it to `https://api`).
    static func normalizeApiURL(_ input: String) -> String? {
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

        let result = scheme + base + "/api"
        guard let url = URL(string: result, encodingInvalidCharacters: false),
              let host = url.host(), !host.isEmpty
        else { return nil }
        return result
    }
}
