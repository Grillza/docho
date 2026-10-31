import Foundation

/// Port of Android's `Bangumi`: the v0 API at api.bgm.tv (collections of "book" subjects),
/// signed in with OAuth. Bangumi has no way to take a subject off the user's collections.
final class Bangumi: Tracker {
    static let id: Int64 = 5
    private static let clientId = "bgm291665acbd06a4c28"
    private static let clientSecret = "43e5ce36b207de16e5d3cfd3e79118db"
    private static let api = "https://api.bgm.tv/v0"
    private static let oauth = "https://bgm.tv/oauth"
    private static let redirect = "mihon://bangumi-auth"

    // Bangumi's own collection types, which Android uses as its statuses.
    static let planToRead = 1, completed = 2, reading = 3, onHold = 4, dropped = 5

    let id: Int64 = Bangumi.id
    let name = "Bangumi"
    let brandColor: UInt32 = 0xF09199
    let supportsReadingDates = false
    let supportsPrivate = true
    let supportsDelete = false
    private let credentials: TrackerCredentials
    private let http: TrackerHTTP

    init(session: URLSession = .shared, defaults: UserDefaults = .standard, keychainService: String = "io.github.grillza.docho") {
        credentials = TrackerCredentials(trackerId: Self.id, defaults: defaults, keychainService: keychainService)
        http = TrackerHTTP(session: session)
    }

    var signIn: TrackerSignIn {
        var components = URLComponents(string: "\(Self.oauth)/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirect),
        ]
        return .oauth(components.url!)
    }

    var statuses: [(id: Int, title: String)] {
        [
            (Self.reading, String(localized: "Reading")), (Self.completed, String(localized: "Completed")),
            (Self.onHold, String(localized: "On hold")), (Self.dropped, String(localized: "Dropped")),
            (Self.planToRead, String(localized: "Plan to read")),
        ]
    }

    var readingStatus: Int { Self.reading }
    var completedStatus: Int { Self.completed }
    var scores: [String] { (0...10).map(String.init) }
    func indexToScore(_ index: Int) -> Double { Double(index) }
    func displayScore(_ score: Double) -> String { String(Int(score)) }

    var isSignedIn: Bool { !credentials.token.isEmpty }
    var username: String { credentials.displayName }

    func signIn(callback: URL) async throws {
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value
        else { throw TrackerError.cancelled }
        let reply = try await http.object(request(TrackerHTTP.form(URL(string: "\(Self.oauth)/access_token")!, [
            "grant_type": "authorization_code", "client_id": Self.clientId, "client_secret": Self.clientSecret,
            "code": code, "redirect_uri": Self.redirect,
        ])))
        guard let token = OAuthToken(json: reply) else { throw TrackerError.notSignedIn }
        credentials.token = token.encoded
        do {
            // The username, once set, stands in for the numeric id in the API's paths.
            let user = try await http.object(authorized(URL(string: "\(Self.api)/me")!))
            guard let username = user["username"].map({ "\($0)" }) else { throw TrackerError.notSignedIn }
            credentials.username = username
            credentials.displayName = (user.string("nickname")).flatMap { $0.isEmpty ? nil : $0 } ?? username
        } catch {
            signOut()
            throw error
        }
    }

    func signOut() {
        credentials.clear()
    }

    /// Bangumi's API asks every app to send its own User-Agent.
    private func request(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(TrackerHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func authorized(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> URLRequest {
        let token = try await credentials.accessToken { refresh in
            try await http.object(request(TrackerHTTP.form(URL(string: "\(Self.oauth)/access_token")!, [
                "grant_type": "refresh_token", "client_id": Self.clientId, "client_secret": Self.clientSecret,
                "refresh_token": refresh, "redirect_uri": Self.redirect,
            ])))
        }
        var request = if let body { try TrackerHTTP.jsonBody(url, method: method, body, token: token) } else { TrackerHTTP.get(url, token: token) }
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return self.request(request)
    }

    func search(_ query: String) async throws -> [TrackSearch] {
        if query.hasPrefix("id:"), let id = Int(query.dropFirst(3).trimmingCharacters(in: .whitespaces)) {
            let subject = try await http.object(authorized(URL(string: "\(Self.api)/subjects/\(id)")!))
            return Self.isManga(subject) ? [Self.searchResult(subject)] : []
        }
        let body: [String: Any] = ["keyword": query, "sort": "match", "filter": ["type": [1]]]
        let reply = try await http.object(authorized(URL(string: "\(Self.api)/search/subjects?limit=20")!, method: "POST", body: body))
        return (reply["data"] as? [[String: Any]] ?? []).filter(Self.isManga).map(Self.searchResult)
    }

    /// Books on Bangumi include novels; manga's platform is 漫画.
    private static func isManga(_ subject: [String: Any]) -> Bool {
        subject["platform"] == nil || subject["platform"] is NSNull || subject.string("platform") == "漫画"
    }

    private static func searchResult(_ subject: [String: Any]) -> TrackSearch {
        let id = subject.int64("id") ?? 0
        let name = subject.string("name") ?? ""
        let chineseName = (subject.string("name_cn") ?? "").trimmingCharacters(in: .whitespaces)
        let summary = (subject.string("summary") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return TrackSearch(
            remoteId: id, title: chineseName.isEmpty ? name : chineseName,
            coverURL: subject.dict("images")?.string("common").flatMap(URL.init(string:)),
            summary: chineseName.isEmpty ? summary : "作品原名：\(name)" + (summary.isEmpty ? "" : "\n\(summary)"),
            totalChapters: subject["eps"] as? Int ?? 0, startDate: subject.string("date") ?? "",
            score: subject.dict("rating")?.double("score") ?? -1, trackingURL: "https://bangumi.tv/subject/\(id)"
        )
    }

    private func collectionURL(_ remoteId: Int64) -> URL {
        URL(string: "\(Self.api)/users/-/collections/\(remoteId)")!
    }

    private func findEntry(_ track: TrackRecord) async throws -> TrackRecord? {
        let username = credentials.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? credentials.username
        let entry: [String: Any]
        do {
            entry = try await http.object(authorized(URL(string: "\(Self.api)/users/\(username)/collections/\(track.remoteId)")!))
        } catch TrackerError.notFound {
            // "subject is not collected by user"
            return nil
        }
        var found = track
        found.status = entry["type"] as? Int ?? Self.reading
        found.lastChapterRead = entry.double("ep_status") ?? 0
        found.score = entry.double("rate") ?? 0
        found.totalChapters = entry.dict("subject")?["eps"] as? Int ?? 0
        found.isPrivate = entry["private"] as? Bool ?? false
        return found
    }

    private func body(_ track: TrackRecord) -> [String: Any] {
        ["type": track.status, "rate": min(max(Int(track.score), 0), 10), "ep_status": Int(track.lastChapterRead), "private": track.isPrivate]
    }

    func bind(_ track: TrackRecord, hasReadChapters: Bool) async throws -> TrackRecord {
        if var remote = try await findEntry(track) {
            remote.isPrivate = track.isPrivate
            if remote.status != Self.completed, hasReadChapters { remote.status = Self.reading }
            return try await update(remote, didReadChapter: false)
        }
        var track = track
        track.status = hasReadChapters ? Self.reading : Self.planToRead
        track.score = 0
        _ = try await http.json(authorized(collectionURL(track.remoteId), method: "POST", body: body(track)))
        return track
    }

    func update(_ track: TrackRecord, didReadChapter: Bool) async throws -> TrackRecord {
        var track = track
        if track.status != Self.completed, didReadChapter {
            track.status = Int(track.lastChapterRead) == track.totalChapters && track.totalChapters > 0 ? Self.completed : Self.reading
        }
        _ = try await http.json(authorized(collectionURL(track.remoteId), method: "PATCH", body: body(track)))
        return track
    }

    func refresh(_ track: TrackRecord) async throws -> TrackRecord {
        guard let remote = try await findEntry(track) else { throw TrackerError.notFound }
        return remote
    }

    func delete(_ track: TrackRecord) async throws {}
}
