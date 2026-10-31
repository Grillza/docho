import CryptoKit
import Foundation

/// Port of Android's `Hikka`: api.hikka.io, signed in through Hikka's own OAuth (the redirect
/// carries a request reference, traded for a token with the client secret). Hikka keys manga by
/// slug, kept as the number Android derives from it, with the slug in the tracking URL.
final class Hikka: Tracker {
    static let id: Int64 = 10
    private static let clientReference = "598ef1f5-b9d2-4e66-8b65-06949d5e14fc"
    private static let clientSecret = "OKwzrNOZxq40psFgfcCUYddnvaeZWDnd34rt7fdcB5GmHoBBQuNTWX"
        + "61sZs8KECEWVXtMUDtq8QC4t9WX4DwWWYLXEVlgnlUXGT1fWCb-18c"
        + "Zd2m8Co-8HN6JQcjoP-B"
    private static let site = "https://hikka.io"
    private static let api = "https://api.hikka.io"

    static let reading = 0, completed = 1, onHold = 2, dropped = 3, planToRead = 4, rereading = 5

    let id: Int64 = Hikka.id
    let name = "Hikka"
    let brandColor: UInt32 = 0x000000
    private let credentials: TrackerCredentials
    private let http: TrackerHTTP

    init(session: URLSession = .shared, defaults: UserDefaults = .standard, keychainService: String = "io.github.grillza.docho") {
        credentials = TrackerCredentials(trackerId: Self.id, defaults: defaults, keychainService: keychainService)
        http = TrackerHTTP(session: session)
    }

    var signIn: TrackerSignIn {
        var components = URLComponents(string: "\(Self.site)/oauth")!
        components.queryItems = [
            URLQueryItem(name: "reference", value: Self.clientReference), URLQueryItem(name: "scope", value: "readlist,read:user-details"),
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
        guard let reference = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "reference" })?.value
        else { throw TrackerError.cancelled }
        let reply = try await http.object(TrackerHTTP.jsonBody(URL(string: "\(Self.api)/auth/token")!, [
            "request_reference": reference, "client_secret": Self.clientSecret,
        ]))
        guard let secret = reply.string("secret") else { throw TrackerError.notSignedIn }
        let expiration = Date(timeIntervalSince1970: reply.double("expiration") ?? 0)
        credentials.token = OAuthToken(accessToken: secret, refreshToken: nil, expiresAt: expiration).encoded
        do {
            let user = try await http.object(authorized(URL(string: "\(Self.api)/user/me")!))
            credentials.username = user.string("reference") ?? ""
            credentials.displayName = user.string("username") ?? ""
        } catch {
            signOut()
            throw error
        }
    }

    func signOut() {
        credentials.clear()
    }

    /// Hikka's token, which a request extends as it nears its end; `auth/token/info` then gives
    /// the new expiry, as Android's `HikkaInterceptor`.
    private func accessToken() async throws -> String {
        guard var token = OAuthToken.load(credentials.token) else { throw TrackerError.notSignedIn }
        if token.expiresAt.timeIntervalSinceNow < 5 * 60 {
            var touch = URLRequest(url: URL(string: "\(Self.api)/user/me")!)
            touch.setValue(token.accessToken, forHTTPHeaderField: "auth")
            do {
                _ = try await http.object(touch)
            } catch {
                signOut()
                throw TrackerError.notSignedIn
            }
            var info = URLRequest(url: URL(string: "\(Self.api)/auth/token/info")!)
            info.setValue(token.accessToken, forHTTPHeaderField: "auth")
            let reply = try await http.object(info)
            if let expiration = reply.double("expiration") {
                token.expiresAt = Date(timeIntervalSince1970: expiration)
                credentials.token = token.encoded
            }
        }
        return token.accessToken
    }

    private func authorized(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> URLRequest {
        var request = if let body { try TrackerHTTP.jsonBody(url, method: method, body) } else { URLRequest(url: url) }
        request.httpMethod = method
        request.setValue(try await accessToken(), forHTTPHeaderField: "auth")
        return request
    }

    func search(_ query: String) async throws -> [TrackSearch] {
        if query.hasPrefix("id:") {
            let slug = query.dropFirst(3).trimmingCharacters(in: .whitespaces)
            do {
                return [Self.searchResult(try await http.object(authorized(Self.mangaURL(slug))))]
            } catch TrackerError.notFound {
                return []
            }
        }
        let body: [String: Any] = [
            "media_type": [], "status": [], "only_translated": false, "magazines": [], "genres": [],
            "score": [0, 10], "query": query, "sort": ["score:desc", "scored_by:desc"],
        ]
        let reply = try await http.object(authorized(URL(string: "\(Self.api)/manga?page=1&size=50")!, method: "POST", body: body))
        return (reply["list"] as? [[String: Any]] ?? []).map(Self.searchResult)
    }

    private static func mangaURL(_ slug: String) -> URL {
        URL(string: "\(api)/manga/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)")!
    }

    private static func readURL(_ slug: String) -> URL {
        URL(string: "\(api)/read/manga/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)")!
    }

    private static func title(_ manga: [String: Any]) -> String {
        manga.string("title_ua") ?? manga.string("title_en") ?? manga.string("title_original") ?? ""
    }

    private static func searchResult(_ manga: [String: Any]) -> TrackSearch {
        let slug = manga.string("slug") ?? ""
        var startDate = ""
        if let start = manga.double("start_date"), start != 0 {
            startDate = TrackDates.iso(Date(timeIntervalSince1970: start))
        }
        return TrackSearch(
            remoteId: remoteId(slug: slug), title: title(manga), coverURL: manga.string("image").flatMap(URL.init(string:)),
            totalChapters: manga["chapters"] as? Int ?? 0, publishingStatus: manga.string("status") ?? "",
            publishingType: (manga.string("media_type") ?? "").replacingOccurrences(of: "_", with: " "),
            startDate: startDate, score: manga.double("score") ?? -1, trackingURL: "\(site)/manga/\(slug)"
        )
    }

    /// The slug at the end of the tracking URL (`https://hikka.io/manga/<slug>`).
    private static func slug(_ track: TrackRecord) throws -> String {
        guard let slug = URL(string: track.remoteUrl)?.lastPathComponent, !slug.isEmpty, slug != "/" else { throw TrackerError.notFound }
        return slug
    }

    private static func localStatus(_ status: String?) -> Int {
        switch status {
        case "completed": completed
        case "on_hold": onHold
        case "dropped": dropped
        case "planned": planToRead
        default: reading
        }
    }

    private static func apiStatus(_ status: Int) -> String {
        switch status {
        case completed: "completed"
        case onHold: "on_hold"
        case dropped: "dropped"
        case planToRead: "planned"
        default: "reading"
        }
    }

    private static func date(_ seconds: Double?) -> Date? {
        seconds.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }

    /// The user's entry for the series, or nil when it isn't on their list.
    private func read(_ track: TrackRecord) async throws -> [String: Any]? {
        do {
            return try await http.object(authorized(Self.readURL(Self.slug(track))))
        } catch TrackerError.notFound {
            return nil
        }
    }

    private static func apply(_ read: [String: Any], to track: inout TrackRecord) {
        track.score = read.double("score") ?? 0
        track.lastChapterRead = read.double("chapters") ?? 0
        track.status = localStatus(read.string("status"))
        track.startDate = date(read.double("start_date"))
        track.finishDate = date(read.double("end_date"))
    }

    func bind(_ track: TrackRecord, hasReadChapters: Bool) async throws -> TrackRecord {
        var track = track
        let manga = try await http.object(authorized(Self.mangaURL(Self.slug(track))))
        track.title = Self.title(manga)
        track.totalChapters = manga["chapters"] as? Int ?? track.totalChapters
        track.libraryId = track.remoteId
        if let read = try await read(track) {
            Self.apply(read, to: &track)
            if track.status != Self.completed, hasReadChapters { track.status = Self.reading }
        } else {
            track.status = hasReadChapters ? Self.reading : Self.planToRead
            track.score = 0
        }
        return try await update(track, didReadChapter: false)
    }

    func update(_ track: TrackRecord, didReadChapter: Bool) async throws -> TrackRecord {
        var track = track
        applyReading(&track, didReadChapter: didReadChapter)
        let current = try await read(track)
        var rereads = current?["rereads"] as? Int ?? 0
        if track.status == Self.rereading, rereads == 0 { rereads = 1 }
        func seconds(_ date: Date?) -> Any { date.map { Int($0.timeIntervalSince1970) } ?? NSNull() }
        let body: [String: Any] = [
            "note": "", "chapters": Int(track.lastChapterRead), "volumes": 0, "rereads": rereads, "score": Int(track.score),
            "status": Self.apiStatus(track.status), "start_date": seconds(track.startDate), "end_date": seconds(track.finishDate),
        ]
        let reply = try await http.object(authorized(Self.readURL(Self.slug(track)), method: "PUT", body: body))
        let status = track.status
        Self.apply(reply, to: &track)
        // Hikka stores rereading as reading with a reread count.
        if status == Self.rereading, track.status == Self.reading { track.status = Self.rereading }
        return track
    }

    func refresh(_ track: TrackRecord) async throws -> TrackRecord {
        var track = track
        let manga = try await http.object(authorized(Self.mangaURL(Self.slug(track))))
        track.totalChapters = manga["chapters"] as? Int ?? track.totalChapters
        guard let read = try await read(track) else { throw TrackerError.notFound }
        Self.apply(read, to: &track)
        return track
    }

    func delete(_ track: TrackRecord) async throws {
        _ = try await http.json(authorized(Self.readURL(Self.slug(track)), method: "DELETE"))
    }

    /// Android's `stringToNumber`: the top 63 bits of Java's `UUID.nameUUIDFromBytes(slug)`
    /// (an MD5 name-based UUID), so a slug gets the same id on both apps.
    static func remoteId(slug: String) -> Int64 {
        var bytes = Array(Insecure.MD5.hash(data: Data(slug.utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x30
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let high = bytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int64(bitPattern: high & UInt64(Int64.max))
    }
}
