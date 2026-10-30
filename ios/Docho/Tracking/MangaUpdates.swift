import Foundation

/// Port of Android's `MangaUpdates`: the v1 REST API, signed in with a username and password
/// for a session token. Statuses are MangaUpdates' list ids; scores 0–10 in tenths.
final class MangaUpdates: Tracker {
    static let id: Int64 = 7
    private static let api = "https://api.mangaupdates.com/v1"

    static let readingList = 0, wishList = 1, completeList = 2, unfinishedList = 3, onHoldList = 4

    let id: Int64 = MangaUpdates.id
    let name = "MangaUpdates"
    let brandColor: UInt32 = 0xF39C12
    let signIn = TrackerSignIn.password
    let supportsReadingDates = false
    private let credentials: TrackerCredentials
    private let http: TrackerHTTP

    init(session: URLSession = .shared, defaults: UserDefaults = .standard, keychainService: String = "io.github.grillza.docho") {
        credentials = TrackerCredentials(trackerId: Self.id, defaults: defaults, keychainService: keychainService)
        http = TrackerHTTP(session: session)
    }

    var statuses: [(id: Int, title: String)] {
        [
            (Self.readingList, String(localized: "Reading list")), (Self.completeList, String(localized: "Complete list")),
            (Self.onHoldList, String(localized: "On hold list")), (Self.unfinishedList, String(localized: "Unfinished list")),
            (Self.wishList, String(localized: "Wish list")),
        ]
    }

    var readingStatus: Int { Self.readingList }
    var completedStatus: Int { Self.completeList }

    var scores: [String] {
        ["-"] + (1...9).flatMap { whole in (0...9).map { "\(whole).\($0)" } } + ["10.0"]
    }

    func indexToScore(_ index: Int) -> Double {
        index == 0 ? 0 : Double(scores[index]) ?? 0
    }

    func displayScore(_ score: Double) -> String {
        score <= 0 ? "-" : String(format: "%.1f", score)
    }

    var isSignedIn: Bool { !credentials.token.isEmpty }
    var username: String { credentials.username }

    func signIn(username: String, password: String) async throws {
        let reply = try await http.object(TrackerHTTP.jsonBody(
            URL(string: "\(Self.api)/account/login")!, method: "PUT", ["username": username, "password": password]
        ))
        guard let token = reply.dict("context")?.string("session_token") else {
            throw TrackerError.server(reply.string("reason") ?? String(localized: "Couldn't sign in"))
        }
        credentials.token = token
        let profile = try? await http.object(TrackerHTTP.get(URL(string: "\(Self.api)/account/profile")!, token: token))
        credentials.username = profile?.string("username") ?? username
    }

    func signOut() {
        credentials.clear()
    }

    private var token: String {
        get throws {
            let token = credentials.token
            guard !token.isEmpty else { throw TrackerError.notSignedIn }
            return token
        }
    }

    func search(_ query: String) async throws -> [TrackSearch] {
        if query.hasPrefix("id:"), let id = Int64(query.dropFirst(3).trimmingCharacters(in: .whitespaces)) {
            let record = try? await http.object(TrackerHTTP.get(URL(string: "\(Self.api)/series/\(id)")!, token: nil))
            return record.map { [Self.searchResult($0)] } ?? []
        }
        let reply = try await http.object(TrackerHTTP.jsonBody(
            URL(string: "\(Self.api)/series/search")!, ["search": query, "filter_types": ["drama cd", "novel"]]
        ))
        return (reply["results"] as? [[String: Any]] ?? []).compactMap { $0.dict("record") }.map(Self.searchResult)
    }

    private static func searchResult(_ record: [String: Any]) -> TrackSearch {
        let authors = record["authors"] as? [[String: Any]] ?? []
        return TrackSearch(
            remoteId: record.int64("series_id") ?? 0,
            title: HTMLText.plain(record.string("title") ?? ""),
            coverURL: record.dict("image")?.dict("url")?.string("original").flatMap(URL.init(string:)),
            summary: HTMLText.plain(record.string("description") ?? ""),
            publishingType: record.string("type") ?? "", startDate: record.string("year") ?? "",
            score: record.double("bayesian_rating").flatMap { $0 > 0 ? $0 : nil } ?? -1,
            authors: authors.filter { $0.string("type") == "Author" }.compactMap { $0.string("name") },
            artists: authors.filter { $0.string("type") == "Artist" }.compactMap { $0.string("name") },
            trackingURL: record.string("url") ?? ""
        )
    }

    /// The series on the user's lists, or nil if it isn't on one.
    private func findEntry(_ track: TrackRecord) async throws -> TrackRecord? {
        let item: [String: Any]
        do {
            item = try await http.object(TrackerHTTP.get(URL(string: "\(Self.api)/lists/series/\(track.remoteId)")!, token: try token))
        } catch TrackerError.notFound {
            return nil
        }
        var found = track
        found.status = item["list_id"] as? Int ?? Self.readingList
        found.lastChapterRead = item.dict("status")?.double("chapter") ?? 0
        let rating = try? await http.object(TrackerHTTP.get(URL(string: "\(Self.api)/series/\(track.remoteId)/rating")!, token: try token))
        found.score = rating?.double("rating") ?? 0
        return found
    }

    func bind(_ track: TrackRecord, hasReadChapters: Bool) async throws -> TrackRecord {
        if var remote = try await findEntry(track) {
            if remote.status != Self.completeList, hasReadChapters { remote.status = Self.readingList }
            return try await update(remote, didReadChapter: false)
        }
        var track = track
        track.status = hasReadChapters ? Self.readingList : Self.wishList
        _ = try await http.json(TrackerHTTP.jsonBody(
            URL(string: "\(Self.api)/lists/series")!, [["series": ["id": track.remoteId], "list_id": track.status]], token: try token
        ))
        return track
    }

    func update(_ track: TrackRecord, didReadChapter: Bool) async throws -> TrackRecord {
        var track = track
        if track.status != Self.completeList, didReadChapter {
            track.status = Self.readingList
        }
        _ = try await http.json(TrackerHTTP.jsonBody(URL(string: "\(Self.api)/lists/series/update")!, [[
            "series": ["id": track.remoteId], "list_id": track.status, "status": ["chapter": Int(track.lastChapterRead)],
        ]], token: try token))
        let ratingURL = URL(string: "\(Self.api)/series/\(track.remoteId)/rating")!
        if track.score > 0 {
            _ = try await http.json(TrackerHTTP.jsonBody(ratingURL, method: "PUT", ["rating": track.score], token: try token))
        } else if track.score == 0 {
            var request = TrackerHTTP.get(ratingURL, token: try token)
            request.httpMethod = "DELETE"
            _ = try? await http.json(request)
        }
        return track
    }

    func refresh(_ track: TrackRecord) async throws -> TrackRecord {
        guard let remote = try await findEntry(track) else { throw TrackerError.notFound }
        return remote
    }

    func delete(_ track: TrackRecord) async throws {
        _ = try await http.json(TrackerHTTP.jsonBody(URL(string: "\(Self.api)/lists/series/delete")!, [track.remoteId], token: try token))
    }
}
