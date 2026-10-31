import Foundation

/// Port of Android's `Shikimori`: GraphQL for reading at shikimori.io and the v2 REST API for
/// the user's list (`user_rates`), signed in with OAuth. The list entry's id is the track's
/// `libraryId`.
final class Shikimori: Tracker {
    static let id: Int64 = 4
    private static let clientId = "PB9dq8DzI405s7wdtwTdirYqHiyVMh--djnP7lBUqSA"
    private static let clientSecret = "NajpZcOBKB9sJtgNcejf8OB9jBN1OYYoo-k4h2WWZus"
    private static let site = "https://shikimori.io"
    private static let api = "\(site)/api"
    private static let redirect = "mihon://shikimori-auth"

    static let reading = 1, completed = 2, onHold = 3, dropped = 4, planToRead = 5, rereading = 6

    let id: Int64 = Shikimori.id
    let name = "Shikimori"
    let brandColor: UInt32 = 0x343434
    let supportsReadingDates = false
    private let credentials: TrackerCredentials
    private let http: TrackerHTTP

    init(session: URLSession = .shared, defaults: UserDefaults = .standard, keychainService: String = "io.github.grillza.docho") {
        credentials = TrackerCredentials(trackerId: Self.id, defaults: defaults, keychainService: keychainService)
        http = TrackerHTTP(session: session)
    }

    var signIn: TrackerSignIn {
        var components = URLComponents(string: "\(Self.site)/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId), URLQueryItem(name: "redirect_uri", value: Self.redirect),
            URLQueryItem(name: "response_type", value: "code"),
        ]
        return .oauth(components.url!)
    }

    var statuses: [(id: Int, title: String)] {
        [
            (Self.reading, String(localized: "Reading")), (Self.completed, String(localized: "Completed")),
            (Self.onHold, String(localized: "On hold")), (Self.dropped, String(localized: "Dropped")),
            (Self.planToRead, String(localized: "Plan to read")), (Self.rereading, String(localized: "Rereading")),
        ]
    }

    var readingStatus: Int { Self.reading }
    var rereadingStatus: Int? { Self.rereading }
    var completedStatus: Int { Self.completed }
    var scores: [String] { (0...10).map(String.init) }
    func indexToScore(_ index: Int) -> Double { Double(index) }
    func displayScore(_ score: Double) -> String { String(Int(score)) }

    var isSignedIn: Bool { !credentials.token.isEmpty }
    var username: String { credentials.displayName }

    func signIn(callback: URL) async throws {
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value
        else { throw TrackerError.cancelled }
        let reply = try await http.object(request(TrackerHTTP.form(URL(string: "\(Self.site)/oauth/token")!, [
            "grant_type": "authorization_code", "client_id": Self.clientId, "client_secret": Self.clientSecret,
            "code": code, "redirect_uri": Self.redirect,
        ])))
        guard let token = OAuthToken(json: reply) else { throw TrackerError.notSignedIn }
        credentials.token = token.encoded
        do {
            let user = try await graphQL("query { currentUser { id nickname } }").dict("currentUser") ?? [:]
            guard let id = user["id"].map({ "\($0)" }) else { throw TrackerError.notSignedIn }
            credentials.username = id
            credentials.displayName = user.string("nickname") ?? ""
        } catch {
            signOut()
            throw error
        }
    }

    func signOut() {
        credentials.clear()
    }

    /// Shikimori turns away requests without an identifying User-Agent.
    private func request(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(TrackerHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func accessToken() async throws -> String {
        try await credentials.accessToken { refresh in
            try await http.object(request(TrackerHTTP.form(URL(string: "\(Self.site)/oauth/token")!, [
                "grant_type": "refresh_token", "client_id": Self.clientId, "client_secret": Self.clientSecret, "refresh_token": refresh,
            ])))
        }
    }

    private func graphQL(_ query: String, _ variables: [String: Any] = [:]) async throws -> [String: Any] {
        var request = try TrackerHTTP.jsonBody(URL(string: "\(Self.api)/graphql")!, ["query": query, "variables": variables], token: try await accessToken())
        request = self.request(request)
        let reply = try await http.object(request)
        if let errors = reply["errors"] as? [[String: Any]], let first = errors.first {
            throw TrackerError.server(first.string("message") ?? "GraphQL error")
        }
        return reply.dict("data") ?? [:]
    }

    private func rest(_ path: String, method: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let url = URL(string: "\(Self.api)/v2/\(path)")!
        let token = try await accessToken()
        var request = if let body { try TrackerHTTP.jsonBody(url, method: method, body, token: token) } else { TrackerHTTP.get(url, token: token) }
        request.httpMethod = method
        return try await http.object(self.request(request))
    }

    private static let mangaFields = """
        id name chapters kind poster { mainUrl } score url status airedOn { date } description
        personRoles { person { name } rolesEn }
        """

    func search(_ query: String) async throws -> [TrackSearch] {
        let mangas: [[String: Any]]
        if query.hasPrefix("id:"), let id = Int(query.dropFirst(3).trimmingCharacters(in: .whitespaces)) {
            mangas = try await graphQL("""
                query($ids: String!) { mangas(ids: $ids, limit: 1, kind: "!light_novel,!novel") { \(Self.mangaFields) } }
                """, ["ids": String(id)])["mangas"] as? [[String: Any]] ?? []
        } else {
            mangas = try await graphQL("""
                query($search: String!) { mangas(search: $search, limit: 20, kind: "!light_novel,!novel") { \(Self.mangaFields) } }
                """, ["search": query])["mangas"] as? [[String: Any]] ?? []
        }
        return mangas.map(Self.searchResult)
    }

    private static func searchResult(_ manga: [String: Any]) -> TrackSearch {
        let roles = manga["personRoles"] as? [[String: Any]] ?? []
        func people(_ role: String) -> [String] {
            roles.filter { ($0["rolesEn"] as? [String] ?? []).contains(role) }.compactMap { $0.dict("person")?.string("name") }
        }
        let kind = switch manga.string("kind") {
        case "manga": "Manga"
        case "manhwa": "Manhwa"
        case "manhua": "Manhua"
        case "one_shot": "Oneshot"
        case "doujin": "Doujin"
        default: ""
        }
        let status = switch manga.string("status") {
        case "anons": "Planned"
        case "ongoing": "Ongoing"
        case "released": "Released"
        case "paused": "Paused"
        case "discontinued": "Discontinued"
        default: ""
        }
        return TrackSearch(
            remoteId: manga.int64("id") ?? 0, title: manga.string("name") ?? "",
            coverURL: manga.dict("poster")?.string("mainUrl").flatMap(URL.init(string:)),
            summary: manga.string("description") ?? "", totalChapters: manga["chapters"] as? Int ?? 0,
            publishingStatus: status, publishingType: kind, startDate: manga.dict("airedOn")?.string("date") ?? "",
            score: manga.double("score").flatMap { $0 > 0 ? $0 : nil } ?? -1,
            authors: people("Story"), artists: people("Art"), trackingURL: absolute(manga.string("url"))
        )
    }

    /// Shikimori gives paths ("/mangas/123"); Android keeps whatever it's given.
    private static func absolute(_ url: String?) -> String {
        guard let url, !url.isEmpty else { return "" }
        return url.hasPrefix("/") ? site + url : url
    }

    private static let apiStatuses = [
        reading: "watching", completed: "completed", onHold: "on_hold", dropped: "dropped",
        planToRead: "planned", rereading: "rewatching",
    ]

    /// Shikimori has no list query by id, so the series is read with the user's entry, which is
    /// null when it isn't on their list.
    private func findEntry(_ track: TrackRecord) async throws -> TrackRecord? {
        let data = try await graphQL("""
            query($ids: String!) { mangas(ids: $ids, limit: 1) { id url name chapters userRate { id chapters status score } } }
            """, ["ids": String(track.remoteId)])
        guard let manga = (data["mangas"] as? [[String: Any]])?.first, let rate = manga.dict("userRate") else { return nil }
        var found = track
        found.title = manga.string("name") ?? track.title
        found.totalChapters = manga["chapters"] as? Int ?? track.totalChapters
        found.remoteUrl = Self.absolute(manga.string("url"))
        found.libraryId = rate.int64("id")
        found.lastChapterRead = rate.double("chapters") ?? 0
        found.score = rate.double("score") ?? 0
        found.status = Self.apiStatuses.first { $0.value == rate.string("status") }?.key ?? Self.reading
        return found
    }

    private func userRate(_ track: TrackRecord) -> [String: Any] {
        ["chapters": Int(track.lastChapterRead), "score": Int(track.score), "status": Self.apiStatuses[track.status] ?? "watching"]
    }

    func bind(_ track: TrackRecord, hasReadChapters: Bool) async throws -> TrackRecord {
        if var remote = try await findEntry(track) {
            if remote.status != Self.completed, remote.status != Self.rereading, hasReadChapters { remote.status = Self.reading }
            return try await update(remote, didReadChapter: false)
        }
        var track = track
        track.status = hasReadChapters ? Self.reading : Self.planToRead
        track.score = 0
        var rate = userRate(track)
        rate["user_id"] = credentials.username
        rate["target_id"] = track.remoteId
        rate["target_type"] = "Manga"
        let reply = try await rest("user_rates", method: "POST", body: ["user_rate": rate])
        track.libraryId = reply.int64("id")
        return track
    }

    func update(_ track: TrackRecord, didReadChapter: Bool) async throws -> TrackRecord {
        var track = track
        // Android's Shikimori rule: as the shared one, without the reading dates.
        if track.status != Self.completed, didReadChapter {
            if Int(track.lastChapterRead) == track.totalChapters, track.totalChapters > 0 {
                track.status = Self.completed
            } else if track.status != Self.rereading {
                track.status = Self.reading
            }
        }
        guard let libraryId = track.libraryId else { return try await bind(track, hasReadChapters: track.lastChapterRead > 0) }
        let reply = try await rest("user_rates/\(libraryId)", method: "PUT", body: ["user_rate": userRate(track)])
        track.libraryId = reply.int64("id") ?? libraryId
        return track
    }

    func refresh(_ track: TrackRecord) async throws -> TrackRecord {
        guard let remote = try await findEntry(track) else { throw TrackerError.notFound }
        return remote
    }

    func delete(_ track: TrackRecord) async throws {
        guard let libraryId = track.libraryId else { return }
        _ = try await rest("user_rates/\(libraryId)", method: "DELETE")
    }
}
