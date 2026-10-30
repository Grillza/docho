import AuthenticationServices
import Foundation
import GRDB
import UIKit

/// A series linked to an entry on a tracking site (Android's `Track`, table `manga_sync`). Ids,
/// statuses and score scales are Android's, so a backup's tracks mean the same here.
struct TrackRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable, Hashable {
    static let databaseTableName = "track"

    var id: Int64?
    var seriesId: Int
    var trackerId: Int64
    var remoteId: Int64
    /// The entry in the user's list, for sites that key it apart from the series (AniList, Kitsu).
    var libraryId: Int64?
    var title: String
    var lastChapterRead: Double = 0
    var totalChapters: Int = 0
    var status: Int = 0
    /// In the site's own scale (AniList 0–100, MyAnimeList 0–10, Kitsu 2–20, MangaUpdates 0–10).
    var score: Double = 0
    var remoteUrl: String = ""
    var startDate: Date?
    var finishDate: Date?
    var isPrivate = false

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A search result to link a series to (Android's `TrackSearch`).
struct TrackSearch: Sendable, Identifiable, Hashable {
    var id: Int64 { remoteId }
    var remoteId: Int64
    var title: String
    var coverURL: URL?
    var summary: String = ""
    var totalChapters: Int = 0
    var publishingStatus: String = ""
    var publishingType: String = ""
    var startDate: String = ""
    var score: Double = -1
    var authors: [String] = []
    var artists: [String] = []
    var trackingURL: String = ""

    func track(seriesId: Int, trackerId: Int64) -> TrackRecord {
        TrackRecord(
            seriesId: seriesId, trackerId: trackerId, remoteId: remoteId, title: title,
            totalChapters: totalChapters, remoteUrl: trackingURL
        )
    }
}

enum TrackerError: LocalizedError {
    case notSignedIn
    case notFound
    case server(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notSignedIn: String(localized: "Sign in to the tracker in Settings → Tracking")
        case .notFound: String(localized: "Not found on the tracker")
        case .server(let message): message
        case .cancelled: String(localized: "Sign-in cancelled")
        }
    }
}

/// A tracking site (Android's `Tracker`).
protocol Tracker: AnyObject, Sendable {
    var id: Int64 { get }
    var name: String { get }
    /// The site's brand colour, behind its initial (Android shows the logo).
    var brandColor: UInt32 { get }
    var signIn: TrackerSignIn { get }
    var supportsReadingDates: Bool { get }
    var supportsPrivate: Bool { get }

    /// Status ids in Android's order, with their names.
    var statuses: [(id: Int, title: String)] { get }
    var readingStatus: Int { get }
    var rereadingStatus: Int? { get }
    var completedStatus: Int { get }
    /// The scores to choose from, as shown; `indexToScore` turns one into the stored value.
    var scores: [String] { get }
    func indexToScore(_ index: Int) -> Double
    func displayScore(_ score: Double) -> String

    var isSignedIn: Bool { get }
    var username: String { get }
    func signIn(callback: URL) async throws
    func signIn(username: String, password: String) async throws
    func signOut()

    func search(_ query: String) async throws -> [TrackSearch]
    /// Links the series: takes the entry from the user's list if it's there, else adds it.
    func bind(_ track: TrackRecord, hasReadChapters: Bool) async throws -> TrackRecord
    func update(_ track: TrackRecord, didReadChapter: Bool) async throws -> TrackRecord
    func refresh(_ track: TrackRecord) async throws -> TrackRecord
    /// Takes the entry off the user's list on the site.
    func delete(_ track: TrackRecord) async throws
}

enum TrackerSignIn {
    /// Signed in on the site's page; it returns to `mihon://<host>` with the token or code.
    case oauth(URL)
    case password
}

extension Tracker {
    var supportsReadingDates: Bool { true }
    var supportsPrivate: Bool { false }
    var rereadingStatus: Int? { nil }

    func signIn(callback: URL) async throws {}
    func signIn(username: String, password: String) async throws {}

    func statusTitle(_ status: Int) -> String {
        statuses.first { $0.id == status }?.title ?? ""
    }

    /// The index in `scores` that shows `score`.
    func scoreIndex(_ score: Double) -> Int {
        scores.firstIndex(of: displayScore(score)) ?? 0
    }

    /// Android's shared update rule: reading a chapter starts the series (setting the start
    /// date at chapter 1) and reading the last completes it.
    func applyReading(_ track: inout TrackRecord, didReadChapter: Bool) {
        guard track.status != completedStatus, didReadChapter else { return }
        if Int(track.lastChapterRead) == track.totalChapters, track.totalChapters > 0 {
            track.status = completedStatus
            track.finishDate = .now
        } else if track.status != rereadingStatus {
            track.status = readingStatus
            if track.lastChapterRead == 1 { track.startDate = .now }
        }
    }
}

// MARK: - Storage

/// A tracker's sign-in, kept as Android names it (`pref_mangasync_username_<id>` and so on),
/// with the token and password in the Keychain.
final class TrackerCredentials: Sendable {
    private let store: ServerSettings
    private let trackerId: Int64

    init(trackerId: Int64, defaults: UserDefaults = .standard, keychainService: String = "io.github.grillza.docho") {
        self.trackerId = trackerId
        store = ServerSettings(prefix: "pref_mangasync", defaults: defaults, keychainService: keychainService)
    }

    var username: String {
        get { store.string("username_\(trackerId)") }
        set { store.setString("username_\(trackerId)", newValue) }
    }

    var displayName: String {
        get { store.string("display_username_\(trackerId)") }
        set { store.setString("display_username_\(trackerId)", newValue) }
    }

    var password: String {
        get { store.secret("password_\(trackerId)") }
        set { store.setSecret("password_\(trackerId)", newValue) }
    }

    /// The OAuth token as JSON, as Android's `track_token_<id>`.
    var token: String {
        get { store.secret("token_\(trackerId)") }
        set { store.setSecret("token_\(trackerId)", newValue) }
    }

    func string(_ key: String) -> String { store.string("\(key)_\(trackerId)") }
    func setString(_ key: String, _ value: String) { store.setString("\(key)_\(trackerId)", value) }

    func clear() {
        store.reset(plain: ["username_\(trackerId)", "display_username_\(trackerId)"], secret: ["password_\(trackerId)", "token_\(trackerId)"])
    }
}

/// An OAuth token with its expiry, stored as JSON.
struct OAuthToken: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date

    var isExpired: Bool { expiresAt.timeIntervalSinceNow < 60 }

    init(accessToken: String, refreshToken: String?, expiresIn: Double) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        expiresAt = Date.now.addingTimeInterval(expiresIn)
    }

    /// From a token endpoint's JSON reply.
    init?(json: [String: Any]) {
        guard let access = json["access_token"] as? String else { return nil }
        self.init(accessToken: access, refreshToken: json["refresh_token"] as? String, expiresIn: json.double("expires_in") ?? 3600)
    }

    static func load(_ text: String) -> OAuthToken? {
        try? JSONDecoder().decode(OAuthToken.self, from: Data(text.utf8))
    }

    var encoded: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

// MARK: - HTTP

/// JSON requests for the trackers, which all speak JSON (or GraphQL over it).
struct TrackerHTTP: Sendable {
    let session: URLSession

    func json(_ request: URLRequest) async throws -> Any {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = data.isEmpty ? [String: Any]() : try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard (200..<300).contains(status) else {
            if status == 401 { throw TrackerError.notSignedIn }
            if status == 404 { throw TrackerError.notFound }
            let message = (body as? [String: Any]).flatMap { $0["message"] as? String ?? $0["error"] as? String ?? $0["reason"] as? String }
            throw TrackerError.server(message ?? String(localized: "The tracker returned an error (\(status))"))
        }
        return body
    }

    func object(_ request: URLRequest) async throws -> [String: Any] {
        try await json(request) as? [String: Any] ?? [:]
    }

    /// A GraphQL call; the errors in a 200 reply are thrown too.
    func graphQL(_ url: URL, token: String?, query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let reply = try await object(request)
        if let errors = reply["errors"] as? [[String: Any]], let first = errors.first {
            let message = first["message"] as? String ?? "GraphQL error"
            if (first["status"] as? Int) == 401 || message.localizedCaseInsensitiveContains("unauthorized") {
                throw TrackerError.notSignedIn
            }
            throw TrackerError.server(message)
        }
        return reply["data"] as? [String: Any] ?? [:]
    }

    static func form(_ url: URL, method: String = "POST", _ fields: [String: String], token: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" alone, which a form body would read as a space.
        request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return request
    }

    static func jsonBody(_ url: URL, method: String = "POST", _ body: Any, token: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func get(_ url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
}

extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func string(_ key: String) -> String? { self[key] as? String }

    func double(_ key: String) -> Double? {
        switch self[key] {
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text)
        default: nil
        }
    }

    func int64(_ key: String) -> Int64? {
        switch self[key] {
        case let number as NSNumber: number.int64Value
        case let text as String: Int64(text)
        default: nil
        }
    }
}

// MARK: - Signing in on the web

/// Shows a tracker's sign-in page and returns the URL it sends back (`mihon://…`, the address
/// Mihon's apps are registered with on each site).
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("mihon")) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: TrackerError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? TrackerError.cancelled)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            session.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}

// MARK: - Dates

enum TrackDates {
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }

    /// "2024-03-05", "2024-03" or "2024".
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let format = switch text.prefix(10).count {
        case 10: "yyyy-MM-dd"
        case 7: "yyyy-MM"
        case 4: "yyyy"
        default: ""
        }
        return format.isEmpty ? nil : formatter(format).date(from: String(text.prefix(10)))
    }

    static func iso(_ date: Date?) -> String {
        date.map { formatter("yyyy-MM-dd").string(from: $0) } ?? ""
    }

    /// AniList's `{year, month, day}`.
    static func fuzzy(_ date: Date?) -> [String: Any] {
        guard let date else { return ["year": NSNull(), "month": NSNull(), "day": NSNull()] }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return ["year": parts.year ?? 0, "month": parts.month ?? 0, "day": parts.day ?? 0]
    }

    static func fromFuzzy(_ value: [String: Any]?) -> Date? {
        guard let value, let year = value["year"] as? Int else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: value["month"] as? Int ?? 1, day: value["day"] as? Int ?? 1))
    }
}
