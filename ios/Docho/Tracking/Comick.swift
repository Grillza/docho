import Foundation
import Synchronization

/// Port of Android's `Comick`: the integrations API at api.comick.dev, signed in with OAuth and
/// an S256 PKCE challenge. Comick keys titles by an 8-character "hid", kept as the 48-bit number
/// it encodes so the track's `remoteId` matches Android's.
final class Comick: Tracker {
    static let id: Int64 = 12
    private static let clientId = "SGrUojDvbgqfhSCQbwfCjUPIccYMJdBH"
    private static let redirect = "app.mihon://comick-auth"
    private static let oauth = "https://comick.dev/api/auth/oauth2"
    private static let resource = "https://api.comick.dev/integrations/v1"
    private static let scopes = "library:read library:write offline_access"

    static let reading = 1, completed = 2, onHold = 3, dropped = 4, planToRead = 5

    let id: Int64 = Comick.id
    let name = "Comick"
    let brandColor: UInt32 = 0x1F2937
    let supportsReadingDates = false
    let callbackScheme = "app.mihon"
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
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirect), URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "resource", value: Self.resource), URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
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
        let pkce = pkce.withLock { $0 }
        let code = try pkce.code(from: callback)
        let reply = try await http.object(request(TrackerHTTP.form(URL(string: "\(Self.oauth)/token")!, [
            "grant_type": "authorization_code", "client_id": Self.clientId, "code": code,
            "redirect_uri": Self.redirect, "code_verifier": pkce.verifier, "resource": Self.resource,
        ])))
        // As Android: without these, progress can't be kept up to date.
        guard reply["refresh_token"] != nil else {
            throw TrackerError.server(String(localized: "Permission for ongoing synchronisation is required."))
        }
        guard (reply.string("scope") ?? "").contains("library:write") else {
            throw TrackerError.server(String(localized: "Permission to add/remove manga from your library is required."))
        }
        guard let token = OAuthToken(json: reply) else { throw TrackerError.notSignedIn }
        credentials.token = token.encoded
        do {
            let user = try await get("me")
            credentials.username = "user"
            credentials.displayName = user.string("username") ?? user.string("id") ?? ""
        } catch {
            signOut()
            throw error
        }
    }

    func signOut() {
        credentials.clear()
    }

    private func accessToken() async throws -> String {
        try await credentials.accessToken { refresh in
            try await http.object(request(TrackerHTTP.form(URL(string: "\(Self.oauth)/token")!, [
                "grant_type": "refresh_token", "client_id": Self.clientId, "refresh_token": refresh, "resource": Self.resource,
            ])))
        }
    }

    /// Comick asks for an identifying User-Agent, as Android sends.
    private func request(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(TrackerHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func authorized(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> URLRequest {
        let token = try await accessToken()
        var request = if let body { try TrackerHTTP.jsonBody(url, method: method, body, token: token) } else { TrackerHTTP.get(url, token: token) }
        request.httpMethod = method
        return self.request(request)
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        var components = URLComponents(string: "\(Self.resource)/\(path)")!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return try await http.object(authorized(components.url!))
    }

    private func libraryURL(_ remoteId: Int64) throws -> URL {
        URL(string: "\(Self.resource)/me/library/\(try Self.hid(remoteId))")!
    }

    func search(_ query: String) async throws -> [TrackSearch] {
        if query.hasPrefix("id:") {
            let hid = query.dropFirst(3).trimmingCharacters(in: .whitespaces)
            do {
                return [try Self.searchResult(await get("titles/\(hid)").dict("data") ?? [:])]
            } catch TrackerError.notFound {
                return []
            }
        }
        // Comick refuses queries over 100 characters.
        let reply = try await get("titles", ["q": String(query.prefix(100)), "media_type": "manga", "limit": "20"])
        return try (reply["data"] as? [[String: Any]] ?? []).map(Self.searchResult)
    }

    private static func searchResult(_ item: [String: Any]) throws -> TrackSearch {
        let status = switch item["status"] as? Int {
        case 1: "Ongoing"
        case 2: "Completed"
        case 3: "Cancelled"
        case 4: "Hiatus"
        default: ""
        }
        let type = switch item.string("country") {
        case "kr": "Manhwa"
        case "cn": "Manhua"
        case "fr": "Manfra"
        default: "Manga"
        }
        return TrackSearch(
            remoteId: try remoteId(item.string("hid") ?? ""), title: item.string("title") ?? "",
            coverURL: item.string("cover_url").flatMap(URL.init(string:)), summary: item.string("description") ?? "",
            publishingStatus: status, publishingType: type, startDate: (item["year"] as? Int).map(String.init) ?? "",
            score: item.double("bayesian_rating") ?? -1, trackingURL: item.string("url") ?? ""
        )
    }

    /// Android's progress number: up to two decimals, without trailing zeros.
    private static func progress(_ chapter: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: chapter)) ?? String(chapter)
    }

    private func findEntry(_ track: TrackRecord) async throws -> TrackRecord? {
        let reply: [String: Any]
        do {
            reply = try await http.object(authorized(libraryURL(track.remoteId)))
        } catch TrackerError.notFound {
            return nil
        }
        guard let data = reply.dict("data") else { return nil }
        var found = track
        found.title = data.string("title") ?? track.title
        found.status = data["status"] as? Int ?? Self.reading
        found.lastChapterRead = data.dict("progress")?.double("number") ?? 0
        found.score = data.double("rating") ?? 0
        return found
    }

    func bind(_ track: TrackRecord, hasReadChapters: Bool) async throws -> TrackRecord {
        if let remote = try await findEntry(track) {
            return try await update(remote, didReadChapter: false)
        }
        var track = track
        track.status = hasReadChapters ? Self.reading : Self.planToRead
        track.score = 0
        let progress: Any = track.lastChapterRead > 0 ? ["number": Self.progress(track.lastChapterRead)] : NSNull()
        _ = try await http.json(authorized(libraryURL(track.remoteId), method: "PUT", body: ["status": track.status, "progress": progress]))
        return track
    }

    func update(_ track: TrackRecord, didReadChapter: Bool) async throws -> TrackRecord {
        var track = track
        // Comick's own rule: reading starts the series, but never completes it.
        if track.status != Self.completed, track.status != Self.reading, didReadChapter {
            track.status = Self.reading
        }
        let rating: Any = Int(track.score) > 0 ? Int(track.score) : NSNull()
        let body: [String: Any] = ["rating": rating, "status": track.status, "progress": ["number": Self.progress(track.lastChapterRead)]]
        _ = try await http.json(authorized(libraryURL(track.remoteId), method: "PATCH", body: body))
        return track
    }

    func refresh(_ track: TrackRecord) async throws -> TrackRecord {
        guard let remote = try await findEntry(track) else { throw TrackerError.notFound }
        return remote
    }

    func delete(_ track: TrackRecord) async throws {
        _ = try await http.json(authorized(libraryURL(track.remoteId), method: "DELETE"))
    }

    // MARK: hid ↔ number

    /// The 48-bit number an 8-character hid encodes (URL-safe Base64 of 6 bytes), as Android.
    static func remoteId(_ hid: String) throws -> Int64 {
        var base64 = hid.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard hid.count == 8, let data = Data(base64Encoded: base64) else {
            throw TrackerError.server(String(localized: "Comick returned an unexpected id"))
        }
        return data.reduce(Int64(0)) { ($0 << 8) | Int64($1) }
    }

    static func hid(_ remoteId: Int64) throws -> String {
        guard (0..<(Int64(1) << 48)).contains(remoteId) else { throw TrackerError.notFound }
        return PKCE.base64URL(Data((0..<6).map { UInt8(truncatingIfNeeded: remoteId >> (8 * (5 - $0))) }))
    }
}
