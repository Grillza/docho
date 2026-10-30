import Foundation
import Synchronization

/// Port of Android's `MyAnimeList`: the v2 REST API, signed in with OAuth and a plain PKCE
/// challenge; the access token is refreshed when it runs out.
final class MyAnimeList: Tracker {
    static let id: Int64 = 1
    private static let clientId = "c46c9e24640a64dad5be5ca7a1a53a0f"
    private static let oauth = "https://myanimelist.net/v1/oauth2"
    private static let api = "https://api.myanimelist.net/v2"
    private static let searchFields = "id,title,synopsis,num_chapters,mean,main_picture,status,media_type,start_date,authors{first_name,last_name}"

    static let reading = 1, completed = 2, onHold = 3, dropped = 4, planToRead = 6, rereading = 7

    let id: Int64 = MyAnimeList.id
    let name = "MyAnimeList"
    let brandColor: UInt32 = 0x2E51A2
    private let credentials: TrackerCredentials
    private let http: TrackerHTTP
    /// The PKCE verifier for the sign-in in progress; plain, so it's also the challenge.
    private let verifier = Mutex(MyAnimeList.newVerifier())

    init(session: URLSession = .shared, defaults: UserDefaults = .standard, keychainService: String = "io.github.grillza.docho") {
        credentials = TrackerCredentials(trackerId: Self.id, defaults: defaults, keychainService: keychainService)
        http = TrackerHTTP(session: session)
    }

    private static func newVerifier() -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in characters.randomElement()! })
    }

    var signIn: TrackerSignIn {
        let challenge = verifier.withLock { value in
            value = Self.newVerifier()
            return value
        }
        var components = URLComponents(string: "\(Self.oauth)/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId), URLQueryItem(name: "code_challenge", value: challenge),
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
    var username: String { credentials.username }

    func signIn(callback: URL) async throws {
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value
        else { throw TrackerError.cancelled }
        let reply = try await http.object(TrackerHTTP.form(URL(string: "\(Self.oauth)/token")!, [
            "client_id": Self.clientId, "code": code, "code_verifier": verifier.withLock { $0 }, "grant_type": "authorization_code",
        ]))
        guard let token = OAuthToken(json: reply) else { throw TrackerError.notSignedIn }
        credentials.token = token.encoded
        let user = try await http.object(TrackerHTTP.get(URL(string: "\(Self.api)/users/@me")!, token: token.accessToken))
        credentials.username = user.string("name") ?? ""
    }

    func signOut() {
        credentials.clear()
    }

    /// A current access token, refreshed if it ran out.
    private func accessToken() async throws -> String {
        guard var token = OAuthToken.load(credentials.token) else { throw TrackerError.notSignedIn }
        if token.isExpired {
            guard let refresh = token.refreshToken else { throw TrackerError.notSignedIn }
            let reply = try await http.object(TrackerHTTP.form(URL(string: "\(Self.oauth)/token")!, [
                "client_id": Self.clientId, "refresh_token": refresh, "grant_type": "refresh_token",
            ]))
            guard let renewed = OAuthToken(json: reply) else { throw TrackerError.notSignedIn }
            token = renewed
            credentials.token = token.encoded
        }
        return token.accessToken
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        var components = URLComponents(string: "\(Self.api)/\(path)")!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return try await http.object(TrackerHTTP.get(components.url!, token: try await accessToken()))
    }

    func search(_ query: String) async throws -> [TrackSearch] {
        if query.hasPrefix("id:"), let id = Int(query.dropFirst(3).trimmingCharacters(in: .whitespaces)) {
            return [Self.searchResult(try await get("manga/\(id)", ["fields": Self.searchFields]))]
        }
        let reply = try await get("manga", ["q": String(query.prefix(64)), "nsfw": "true", "fields": Self.searchFields])
        return (reply["data"] as? [[String: Any]] ?? [])
            .compactMap { $0.dict("node") }
            .filter { !($0.string("media_type") ?? "").contains("novel") }
            .map(Self.searchResult)
    }

    private static func searchResult(_ node: [String: Any]) -> TrackSearch {
        let id = node.int64("id") ?? 0
        let authors = node["authors"] as? [[String: Any]] ?? []
        func people(_ role: String) -> [String] {
            authors.filter { ($0.string("role") ?? "").contains(role) }.compactMap { author in
                guard let person = author.dict("node") else { return nil }
                return [person.string("first_name"), person.string("last_name")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        return TrackSearch(
            remoteId: id, title: node.string("title") ?? "",
            coverURL: node.dict("main_picture")?.string("large").flatMap(URL.init(string:)),
            summary: node.string("synopsis") ?? "", totalChapters: node["num_chapters"] as? Int ?? 0,
            publishingStatus: (node.string("status") ?? "").replacingOccurrences(of: "_", with: " ").capitalized,
            publishingType: (node.string("media_type") ?? "").replacingOccurrences(of: "_", with: " ").capitalized,
            startDate: node.string("start_date") ?? "", score: node.double("mean") ?? -1,
            authors: people("Story"), artists: people("Art"), trackingURL: "https://myanimelist.net/manga/\(id)"
        )
    }

    private static func apiStatus(_ status: Int) -> String {
        switch status {
        case completed: "completed"
        case onHold: "on_hold"
        case dropped: "dropped"
        case planToRead: "plan_to_read"
        default: "reading"
        }
    }

    private static func localStatus(_ status: String?) -> Int {
        switch status {
        case "completed": completed
        case "on_hold": onHold
        case "dropped": dropped
        case "plan_to_read": planToRead
        default: reading
        }
    }

    private static func apply(_ listStatus: [String: Any], to track: inout TrackRecord) {
        track.status = listStatus["is_rereading"] as? Bool == true ? rereading : localStatus(listStatus.string("status"))
        track.lastChapterRead = listStatus.double("num_chapters_read") ?? 0
        track.score = listStatus.double("score") ?? 0
        if let start = listStatus.string("start_date") { track.startDate = TrackDates.parse(start) }
        if let finish = listStatus.string("finish_date") { track.finishDate = TrackDates.parse(finish) }
    }

    private func findEntry(_ track: TrackRecord) async throws -> TrackRecord? {
        let item = try await get("manga/\(track.remoteId)", ["fields": "num_chapters,my_list_status{start_date,finish_date}"])
        var found = track
        found.totalChapters = item["num_chapters"] as? Int ?? track.totalChapters
        guard let status = item.dict("my_list_status") else { return nil }
        Self.apply(status, to: &found)
        return found
    }

    func bind(_ track: TrackRecord, hasReadChapters: Bool) async throws -> TrackRecord {
        if var remote = try await findEntry(track) {
            if remote.status != Self.completed, hasReadChapters { remote.status = Self.reading }
            return try await update(remote, didReadChapter: false)
        }
        var track = track
        track.status = hasReadChapters ? Self.reading : Self.planToRead
        track.score = 0
        return try await update(track, didReadChapter: false)
    }

    func update(_ track: TrackRecord, didReadChapter: Bool) async throws -> TrackRecord {
        var track = track
        applyReading(&track, didReadChapter: didReadChapter)
        var fields = [
            "status": Self.apiStatus(track.status), "is_rereading": track.status == Self.rereading ? "true" : "false",
            "score": String(Int(track.score)), "num_chapters_read": String(Int(track.lastChapterRead)),
        ]
        fields["start_date"] = TrackDates.iso(track.startDate)
        fields["finish_date"] = TrackDates.iso(track.finishDate)
        let url = URL(string: "\(Self.api)/manga/\(track.remoteId)/my_list_status")!
        let reply = try await http.object(TrackerHTTP.form(url, method: "PUT", fields, token: try await accessToken()))
        Self.apply(reply, to: &track)
        return track
    }

    func refresh(_ track: TrackRecord) async throws -> TrackRecord {
        guard let remote = try await findEntry(track) else { throw TrackerError.notFound }
        return remote
    }

    func delete(_ track: TrackRecord) async throws {
        var request = TrackerHTTP.get(URL(string: "\(Self.api)/manga/\(track.remoteId)/my_list_status")!, token: try await accessToken())
        request.httpMethod = "DELETE"
        _ = try await http.json(request)
    }
}
