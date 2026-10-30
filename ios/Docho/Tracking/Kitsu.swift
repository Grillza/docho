import Foundation

/// Port of Android's `Kitsu`: GraphQL at kitsu.app, signed in with a username and password
/// (the password grant), the token refreshed when it runs out. Scores are Kitsu's 2–20.
final class Kitsu: Tracker {
    static let id: Int64 = 3
    private static let clientId = "dd031b32d2f56c990b1425efe6c42ad847e7fe3ab46bf1299f05ecd856bdb7dd"
    private static let clientSecret = "54d7307928f63414defd96399fc31ba847961ceaecef3a5fd93144e960c0e151"
    private static let loginURL = URL(string: "https://kitsu.app/api/oauth/token")!
    private static let api = URL(string: "https://kitsu.app/api/graphql")!

    static let reading = 1, completed = 2, onHold = 3, dropped = 4, planToRead = 5

    let id: Int64 = Kitsu.id
    let name = "Kitsu"
    let brandColor: UInt32 = 0xF75239
    let signIn = TrackerSignIn.password
    let supportsPrivate = true
    private let credentials: TrackerCredentials
    private let http: TrackerHTTP

    init(session: URLSession = .shared, defaults: UserDefaults = .standard, keychainService: String = "io.github.grillza.docho") {
        credentials = TrackerCredentials(trackerId: Self.id, defaults: defaults, keychainService: keychainService)
        http = TrackerHTTP(session: session)
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

    /// The user's rating system on Kitsu: simple (smileys), regular (stars) or advanced (0.5 steps).
    var ratingSystem: String {
        get { credentials.string("kitsu_rating_system").isEmpty ? "advanced" : credentials.string("kitsu_rating_system") }
        set { credentials.setString("kitsu_rating_system", newValue) }
    }

    private var scale: (scores: [String], twenty: [Int]) {
        func format(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
        switch ratingSystem {
        case "simple": return (["-", "😡", "😐", "😊", "😀"], [2, 8, 14, 20])
        case "regular": return ((0...10).map { "\(format(Double($0) / 2)) ★" }, Array(stride(from: 2, through: 20, by: 2)))
        default: return (["0"] + (2...20).map { format(Double($0) / 2) }, Array(2...20))
        }
    }

    var scores: [String] { scale.scores }

    func indexToScore(_ index: Int) -> Double {
        index == 0 ? 0 : Double(scale.twenty[index - 1])
    }

    func displayScore(_ score: Double) -> String {
        // Rounded down to the scale, as Kitsu's site does; unset shows the first entry.
        let scale = scale
        return scale.scores[(scale.twenty.lastIndex { Double($0) <= score } ?? -1) + 1]
    }

    var isSignedIn: Bool { !credentials.token.isEmpty }
    var username: String { credentials.displayName.isEmpty ? credentials.username : credentials.displayName }
    private var userId: String { credentials.string("kitsu_user_id") }

    func signIn(username: String, password: String) async throws {
        let reply = try await http.object(TrackerHTTP.form(Self.loginURL, [
            "username": username, "password": password, "grant_type": "password",
            "client_id": Self.clientId, "client_secret": Self.clientSecret,
        ]))
        guard let token = OAuthToken(json: reply) else { throw TrackerError.notSignedIn }
        let data = try await http.graphQL(Self.api, token: token.accessToken, query: """
            query { currentAccount { id ratingSystem profile { name } } }
            """)
        guard let account = data.dict("currentAccount") else { throw TrackerError.notSignedIn }
        credentials.token = token.encoded
        credentials.username = username
        credentials.displayName = account.dict("profile")?.string("name") ?? username
        credentials.setString("kitsu_user_id", account.string("id") ?? "")
        ratingSystem = (account.string("ratingSystem") ?? "advanced").lowercased()
    }

    func signOut() {
        credentials.clear()
    }

    private func accessToken() async throws -> String? {
        guard var token = OAuthToken.load(credentials.token) else { return nil }
        if token.isExpired, let refresh = token.refreshToken {
            let reply = try await http.object(TrackerHTTP.form(Self.loginURL, [
                "grant_type": "refresh_token", "refresh_token": refresh, "client_id": Self.clientId, "client_secret": Self.clientSecret,
            ]))
            guard let renewed = OAuthToken(json: reply) else { throw TrackerError.notSignedIn }
            token = renewed
            credentials.token = token.encoded
        }
        return token.accessToken
    }

    private func signedInToken() async throws -> String {
        guard let token = try await accessToken() else { throw TrackerError.notSignedIn }
        return token
    }

    private static let mangaFields = """
        id titles { preferred } chapterCount staff(first: 5) { nodes { role person { name } } }
        posterImage { views(names: "small") { name url } original { name url } }
        description(locales: "en") status subtype startDate slug averageRating
        """

    func search(_ query: String) async throws -> [TrackSearch] {
        let token = try await accessToken()
        if query.hasPrefix("id:") {
            let id = query.dropFirst(3).trimmingCharacters(in: .whitespaces)
            let data = try await http.graphQL(Self.api, token: token, query: """
                query($id: ID!) { findMangaById(id: $id) { \(Self.mangaFields) } }
                """, variables: ["id": id])
            return data.dict("findMangaById").map { [Self.searchResult($0)] } ?? []
        }
        let data = try await http.graphQL(Self.api, token: token, query: """
            query($query: String!) { searchMangaByTitle(title: $query, first: 20) { nodes { \(Self.mangaFields) } } }
            """, variables: ["query": query])
        return (data.dict("searchMangaByTitle")?["nodes"] as? [[String: Any]] ?? []).map(Self.searchResult)
    }

    private static func searchResult(_ manga: [String: Any]) -> TrackSearch {
        let staff = manga.dict("staff")?["nodes"] as? [[String: Any]] ?? []
        func people(_ roles: [String]) -> [String] {
            staff.filter { roles.contains(($0.string("role") ?? "").lowercased()) }.compactMap { $0.dict("person")?.string("name") }
        }
        let poster = manga.dict("posterImage")
        let cover = (poster?["views"] as? [[String: Any]])?.first?.string("url") ?? poster?.dict("original")?.string("url")
        return TrackSearch(
            remoteId: manga.int64("id") ?? 0, title: manga.dict("titles")?.string("preferred") ?? "",
            coverURL: cover.flatMap(URL.init(string:)),
            summary: (manga.dict("description")?["en"] as? String) ?? "",
            totalChapters: manga["chapterCount"] as? Int ?? 0,
            publishingStatus: (manga.string("status") ?? "").replacingOccurrences(of: "_", with: " ").capitalized,
            publishingType: (manga.string("subtype") ?? "").capitalized,
            startDate: manga.string("startDate") ?? "", score: manga.double("averageRating") ?? -1,
            authors: people(["story & art", "story"]), artists: people(["story & art", "art"]),
            trackingURL: "https://kitsu.app/manga/\(manga.string("slug") ?? "")"
        )
    }

    private static func apiStatus(_ status: Int) -> String {
        switch status {
        case completed: "COMPLETED"
        case onHold: "ON_HOLD"
        case dropped: "DROPPED"
        case planToRead: "PLANNED"
        default: "CURRENT"
        }
    }

    private static func localStatus(_ status: String?) -> Int {
        switch status {
        case "COMPLETED": completed
        case "ON_HOLD": onHold
        case "DROPPED": dropped
        case "PLANNED": planToRead
        default: reading
        }
    }

    private static func isoDateTime(_ date: Date?) -> Any {
        date.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
    }

    private func findEntry(_ track: TrackRecord) async throws -> TrackRecord? {
        let data = try await http.graphQL(Self.api, token: try await signedInToken(), query: """
            query($remote_id: ID!) { findMangaById(id: $remote_id) { \(Self.mangaFields)
              myLibraryEntry { id private progress rating status startedAt finishedAt } } }
            """, variables: ["remote_id": String(track.remoteId)])
        guard let manga = data.dict("findMangaById"), let entry = manga.dict("myLibraryEntry") else { return nil }
        var found = track
        found.libraryId = entry.int64("id")
        found.title = manga.dict("titles")?.string("preferred") ?? track.title
        found.totalChapters = manga["chapterCount"] as? Int ?? track.totalChapters
        found.lastChapterRead = entry.double("progress") ?? 0
        found.score = entry.double("rating") ?? 0
        found.status = Self.localStatus(entry.string("status"))
        found.isPrivate = entry["private"] as? Bool ?? false
        found.startDate = entry.string("startedAt").flatMap { ISO8601DateFormatter().date(from: $0) }
        found.finishDate = entry.string("finishedAt").flatMap { ISO8601DateFormatter().date(from: $0) }
        return found
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
        let data = try await http.graphQL(Self.api, token: try await signedInToken(), query: """
            mutation($media_id: ID!, $status: LibraryEntryStatusEnum!, $progress: Int!, $private: Boolean!, $rating: Int) {
              libraryEntry { create(input: { mediaId: $media_id, mediaType: MANGA, status: $status, progress: $progress,
                                             private: $private, rating: $rating }) { errors { message } libraryEntry { id } } } }
            """, variables: [
                "media_id": String(track.remoteId), "status": Self.apiStatus(track.status),
                "progress": Int(track.lastChapterRead), "private": track.isPrivate, "rating": NSNull(),
            ])
        let create = data.dict("libraryEntry")?.dict("create")
        if let message = (create?["errors"] as? [[String: Any]])?.first?.string("message") { throw TrackerError.server(message) }
        track.libraryId = create?.dict("libraryEntry")?.int64("id")
        return track
    }

    func update(_ track: TrackRecord, didReadChapter: Bool) async throws -> TrackRecord {
        var track = track
        if track.libraryId == nil {
            guard let remote = try await findEntry(track) else { throw TrackerError.notFound }
            track.libraryId = remote.libraryId
        }
        applyReading(&track, didReadChapter: didReadChapter)
        let data = try await http.graphQL(Self.api, token: try await signedInToken(), query: """
            mutation($library_id: ID!, $status: LibraryEntryStatusEnum!, $progress: Int!, $private: Boolean!, $rating: Int,
                     $startedAt: ISO8601DateTime, $finishedAt: ISO8601DateTime) {
              libraryEntry { update(input: { id: $library_id, status: $status, progress: $progress, private: $private,
                                             rating: $rating, startedAt: $startedAt, finishedAt: $finishedAt }) {
                errors { message } libraryEntry { id } } } }
            """, variables: [
                "library_id": String(track.libraryId ?? 0), "status": Self.apiStatus(track.status),
                "progress": Int(track.lastChapterRead), "private": track.isPrivate,
                "rating": track.score >= 2 ? Int(track.score) as Any : NSNull(),
                "startedAt": Self.isoDateTime(track.startDate), "finishedAt": Self.isoDateTime(track.finishDate),
            ])
        if let message = (data.dict("libraryEntry")?.dict("update")?["errors"] as? [[String: Any]])?.first?.string("message") {
            throw TrackerError.server(message)
        }
        return track
    }

    func refresh(_ track: TrackRecord) async throws -> TrackRecord {
        guard var remote = try await findEntry(track) else { throw TrackerError.notFound }
        remote.id = track.id
        return remote
    }

    func delete(_ track: TrackRecord) async throws {
        guard let libraryId = track.libraryId else { return }
        _ = try await http.graphQL(Self.api, token: try await signedInToken(), query: """
            mutation($library_id: ID!) { libraryEntry { delete(input: { id: $library_id }) { errors { message } } } }
            """, variables: ["library_id": String(libraryId)])
    }
}
