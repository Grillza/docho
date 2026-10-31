import Foundation
import Synchronization

/// Port of Android's `MangaBaka`: the v1 API at api.mangabaka.org, signed in with OAuth and an
/// S256 PKCE challenge. Scores are always 0–100; the user's rating step on the site sets how
/// finely they're picked.
final class MangaBaka: Tracker {
    static let id: Int64 = 11
    private static let clientId = "zEZYMHXLWsLsafgbvJHXqzGvqQNOdkpo"
    private static let site = "https://mangabaka.org"
    private static let api = "https://api.mangabaka.org/v1"
    private static let oauth = "\(site)/auth/oauth2"
    private static let redirect = "mihon://mangabaka-auth"
    private static let scopes = "library.read library.write offline_access openid"
    private static let titleLanguages = ["en", "ja-Latn", "ja", "ko-Latn", "ko", "zh-Latn", "zh"]

    static let reading = 1, completed = 2, paused = 3, dropped = 4, planToRead = 5, rereading = 6, considering = 7

    let id: Int64 = MangaBaka.id
    let name = "MangaBaka"
    let brandColor: UInt32 = 0xFF6740
    let supportsPrivate = true
    private let credentials: TrackerCredentials
    private let http: TrackerHTTP
    private let pkce = Mutex(PKCE())

    init(session: URLSession = .shared, defaults: UserDefaults = .standard, keychainService: String = "io.github.grillza.docho") {
        credentials = TrackerCredentials(trackerId: Self.id, defaults: defaults, keychainService: keychainService)
        http = TrackerHTTP(session: session)
    }

    var signIn: TrackerSignIn {
        let pkce = pkce.withLock { value in
            value = PKCE()
            return value
        }
        var components = URLComponents(string: "\(Self.oauth)/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId), URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes), URLQueryItem(name: "redirect_uri", value: Self.redirect),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return .oauth(components.url!)
    }

    var statuses: [(id: Int, title: String)] {
        [
            (Self.reading, String(localized: "Reading")), (Self.completed, String(localized: "Completed")),
            (Self.paused, String(localized: "Paused")), (Self.dropped, String(localized: "Dropped")),
            (Self.planToRead, String(localized: "Plan to read")), (Self.rereading, String(localized: "Rereading")),
            (Self.considering, String(localized: "Considering")),
        ]
    }

    var readingStatus: Int { Self.reading }
    var rereadingStatus: Int? { Self.rereading }
    var completedStatus: Int { Self.completed }

    /// The user's rating step on MangaBaka (1, 5, 10, 20 or 25), as Android's `mangabaka_score_type`.
    var ratingStep: Int {
        get { Int(credentials.string("mangabaka_rating_steps")) ?? 1 }
        set { credentials.setString("mangabaka_rating_steps", String(newValue)) }
    }

    private var scoreValues: [Int] { Array(stride(from: 0, through: 100, by: max(ratingStep, 1))) }
    var scores: [String] { scoreValues.map(String.init) }
    func indexToScore(_ index: Int) -> Double { Double(scoreValues[min(max(index, 0), scoreValues.count - 1)]) }
    func displayScore(_ score: Double) -> String { String(Int(score)) }

    var isSignedIn: Bool { !credentials.token.isEmpty }
    var username: String { credentials.displayName }

    func signIn(callback: URL) async throws {
        let pkce = pkce.withLock { $0 }
        let code = try pkce.code(from: callback)
        let reply = try await http.object(request(TrackerHTTP.form(URL(string: "\(Self.oauth)/token")!, [
            "client_id": Self.clientId, "code": code, "code_verifier": pkce.verifier, "code_challenge_method": "S256",
            "grant_type": "authorization_code", "redirect_uri": Self.redirect, "scope": Self.scopes,
        ])))
        guard let token = OAuthToken(json: reply) else { throw TrackerError.notSignedIn }
        credentials.token = token.encoded
        do {
            let profile = try await http.object(authorized(URL(string: "\(Self.api)/my/profile")!)).dict("data") ?? [:]
            ratingStep = profile["rating_steps"] as? Int ?? 1
            credentials.username = "user"
            credentials.displayName = profile.string("nickname") ?? profile.string("preferred_username") ?? profile.string("id") ?? ""
        } catch {
            signOut()
            throw error
        }
    }

    func signOut() {
        credentials.clear()
    }

    private func request(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(TrackerHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func authorized(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> URLRequest {
        let token = try await credentials.accessToken { refresh in
            try await http.object(request(TrackerHTTP.form(URL(string: "\(Self.oauth)/token")!, [
                "grant_type": "refresh_token", "client_id": Self.clientId, "refresh_token": refresh, "redirect_uri": Self.redirect,
            ])))
        }
        var request = if let body { try TrackerHTTP.jsonBody(url, method: method, body, token: token) } else { TrackerHTTP.get(url, token: token) }
        request.httpMethod = method
        return self.request(request)
    }

    private func libraryURL(_ remoteId: Int64) -> URL {
        URL(string: "\(Self.api)/my/library/\(remoteId)")!
    }

    func search(_ query: String) async throws -> [TrackSearch] {
        if query.hasPrefix("id:"), let id = Int(query.dropFirst(3).trimmingCharacters(in: .whitespaces)) {
            do {
                let item = try await http.object(authorized(URL(string: "\(Self.api)/series/\(id)")!)).dict("data") ?? [:]
                return [Self.searchResult(item)]
            } catch TrackerError.notFound {
                return []
            }
        }
        var components = URLComponents(string: "\(Self.api)/series/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type_not", value: "novel")]
        let reply = try await http.object(request(URLRequest(url: components.url!)))
        return (reply["data"] as? [[String: Any]] ?? []).map(Self.searchResult)
    }

    /// Android's `chooseBestTitle`: the primary, then official, then native title in the first
    /// language of `titleLanguages` that has one.
    private static func bestTitle(_ item: [String: Any]) -> String {
        let titles = item["titles"] as? [[String: Any]] ?? []
        func rank(_ title: [String: Any]) -> Int {
            let traits = title["traits"] as? [String] ?? []
            if title["is_primary"] as? Bool == true { return 0 }
            if traits.contains("official") { return 1 }
            if traits.contains("native") { return 2 }
            return 3
        }
        for language in titleLanguages {
            if let best = titles.filter({ $0.string("language") == language }).min(by: { rank($0) < rank($1) }), let title = best.string("title") {
                return title
            }
        }
        return titles.first?.string("title") ?? "ID: \(item.int64("id") ?? 0)"
    }

    private static func searchResult(_ item: [String: Any]) -> TrackSearch {
        let id = item.int64("id") ?? 0
        return TrackSearch(
            remoteId: id, title: bestTitle(item),
            coverURL: item.dict("cover")?.dict("x250")?.string("x1").flatMap(URL.init(string:)),
            summary: (item.string("description") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            publishingStatus: item.string("status") ?? "", publishingType: (item.string("type") ?? "").capitalized,
            startDate: item.dict("published")?.string("start_date") ?? "",
            score: item.double("rating").map { ($0 * 100).rounded() / 100 } ?? -1,
            authors: item["authors"] as? [String] ?? [], artists: item["artists"] as? [String] ?? [],
            trackingURL: "\(site)/\(id)"
        )
    }

    private static let apiStatuses = [
        reading: "reading", completed: "completed", paused: "paused", dropped: "dropped",
        planToRead: "plan_to_read", rereading: "rereading", considering: "considering",
    ]

    private func findEntry(_ track: TrackRecord) async throws -> TrackRecord? {
        let entry: [String: Any]
        do {
            entry = try await http.object(authorized(libraryURL(track.remoteId))).dict("data") ?? [:]
        } catch TrackerError.notFound {
            return nil
        }
        let series = try await http.object(authorized(URL(string: "\(Self.api)/series/\(track.remoteId)")!)).dict("data") ?? [:]
        var found = track
        found.title = Self.bestTitle(series)
        found.status = Self.apiStatuses.first { $0.value == entry.string("state") }?.key ?? Self.reading
        found.score = entry.double("rating") ?? 0
        found.startDate = TrackDates.parse(entry.string("start_date"))
        found.finishDate = TrackDates.parse(entry.string("finish_date"))
        found.lastChapterRead = entry.double("progress_chapter") ?? 0
        found.isPrivate = entry["is_private"] as? Bool ?? false
        return found
    }

    private func body(_ track: TrackRecord) -> [String: Any] {
        func orNull(_ value: Any?) -> Any { value ?? NSNull() }
        return [
            "state": Self.apiStatuses[track.status] ?? "reading", "is_private": track.isPrivate,
            "progress_chapter": orNull(track.lastChapterRead > 0 ? track.lastChapterRead : nil),
            "rating": orNull(track.score > 0 ? min(max(Int(track.score), 0), 100) : nil),
            "start_date": orNull(track.startDate.map { TrackDates.iso($0) }),
            "finish_date": orNull(track.finishDate.map { TrackDates.iso($0) }),
        ]
    }

    func bind(_ track: TrackRecord, hasReadChapters: Bool) async throws -> TrackRecord {
        if var remote = try await findEntry(track) {
            // Android keeps the app's private setting when linking.
            remote.isPrivate = track.isPrivate
            if remote.status != Self.completed, remote.status != Self.rereading, hasReadChapters { remote.status = Self.reading }
            return try await update(remote, didReadChapter: false)
        }
        var track = track
        track.status = hasReadChapters ? Self.reading : Self.planToRead
        track.score = 0
        _ = try await http.json(authorized(libraryURL(track.remoteId), method: "POST", body: body(track)))
        return track
    }

    func update(_ track: TrackRecord, didReadChapter: Bool) async throws -> TrackRecord {
        var track = track
        applyReading(&track, didReadChapter: didReadChapter)
        _ = try await http.json(authorized(libraryURL(track.remoteId), method: "PUT", body: body(track)))
        return track
    }

    func refresh(_ track: TrackRecord) async throws -> TrackRecord {
        guard let remote = try await findEntry(track) else { throw TrackerError.notFound }
        return remote
    }

    func delete(_ track: TrackRecord) async throws {
        _ = try await http.json(authorized(libraryURL(track.remoteId), method: "DELETE"))
    }
}
