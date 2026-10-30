import Foundation

/// Port of Android's `Anilist`: GraphQL at graphql.anilist.co, signed in with AniList's implicit
/// grant (the token comes back in the redirect's fragment). Scores are kept in POINT_100.
final class AniList: Tracker {
    static let id: Int64 = 2
    private static let clientId = "16329"
    private static let api = URL(string: "https://graphql.anilist.co")!

    static let reading = 1, completed = 2, onHold = 3, dropped = 4, planToRead = 5, rereading = 6

    let id: Int64 = AniList.id
    let name = "AniList"
    let brandColor: UInt32 = 0x02A9FF
    let supportsPrivate = true
    private let credentials: TrackerCredentials
    private let http: TrackerHTTP

    init(session: URLSession = .shared, defaults: UserDefaults = .standard, keychainService: String = "io.github.grillza.docho") {
        credentials = TrackerCredentials(trackerId: Self.id, defaults: defaults, keychainService: keychainService)
        http = TrackerHTTP(session: session)
    }

    var signIn: TrackerSignIn {
        var components = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize")!
        components.queryItems = [URLQueryItem(name: "client_id", value: Self.clientId), URLQueryItem(name: "response_type", value: "token")]
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

    /// The user's score format on AniList, as Android's `anilist_score_type`.
    var scoreFormat: String {
        get { credentials.string("anilist_score_type").isEmpty ? "POINT_10" : credentials.string("anilist_score_type") }
        set { credentials.setString("anilist_score_type", newValue) }
    }

    var scores: [String] {
        switch scoreFormat {
        case "POINT_100": (0...100).map(String.init)
        case "POINT_5": (0...5).map { "\($0) ★" }
        case "POINT_3": ["-", "😦", "😐", "😊"]
        case "POINT_10_DECIMAL": (0...100).map { String(Double($0) / 10) }
        default: (0...10).map(String.init)
        }
    }

    func indexToScore(_ index: Int) -> Double {
        switch scoreFormat {
        case "POINT_100", "POINT_10_DECIMAL": Double(index)
        case "POINT_5": index == 0 ? 0 : Double(index) * 20 - 10
        case "POINT_3": index == 0 ? 0 : Double(index) * 25 + 10
        default: Double(index) * 10
        }
    }

    func displayScore(_ score: Double) -> String {
        switch scoreFormat {
        case "POINT_100": String(Int(score))
        case "POINT_5": score == 0 ? "0 ★" : "\(Int((score + 10) / 20)) ★"
        case "POINT_3": score == 0 ? "-" : score <= 35 ? "😦" : score <= 60 ? "😐" : "😊"
        case "POINT_10_DECIMAL": String(Double(Int(score)) / 10)
        default: String(Int(score / 10))
        }
    }

    var isSignedIn: Bool { !credentials.token.isEmpty }
    var username: String { credentials.displayName }
    private var userId: Int { Int(credentials.username) ?? 0 }

    private var token: String {
        get throws {
            guard let token = OAuthToken.load(credentials.token), !token.isExpired else { throw TrackerError.notSignedIn }
            return token.accessToken
        }
    }

    func signIn(callback: URL) async throws {
        // mihon://anilist-auth#access_token=…&token_type=Bearer&expires_in=31536000
        var fragment = URLComponents()
        fragment.query = callback.fragment
        let items = fragment.queryItems ?? []
        guard let access = items.first(where: { $0.name == "access_token" })?.value else { throw TrackerError.cancelled }
        let expires = items.first { $0.name == "expires_in" }?.value.flatMap(Double.init) ?? 31_536_000
        let token = OAuthToken(accessToken: access, refreshToken: nil, expiresIn: expires)
        let data = try await http.graphQL(Self.api, token: access, query: """
            query { Viewer { id name mediaListOptions { scoreFormat } } }
            """)
        guard let viewer = data.dict("Viewer"), let id = viewer.int64("id") else { throw TrackerError.notSignedIn }
        credentials.token = token.encoded
        credentials.username = String(id)
        credentials.displayName = viewer.string("name") ?? ""
        scoreFormat = viewer.dict("mediaListOptions")?.string("scoreFormat") ?? "POINT_10"
    }

    func signOut() {
        credentials.clear()
    }

    private static let mangaFields = """
        id staff { edges { role node { name { userPreferred } } } } title { userPreferred } coverImage { large }
        format countryOfOrigin status chapters description startDate { year month day } averageScore
        """

    func search(_ query: String) async throws -> [TrackSearch] {
        if query.hasPrefix("id:"), let id = Int(query.dropFirst(3).trimmingCharacters(in: .whitespaces)) {
            let data = try await http.graphQL(Self.api, token: try? token, query: """
                query($id: Int!) { Page(perPage: 1) { media(id: $id, type: MANGA, format_not_in: [NOVEL]) { \(Self.mangaFields) } } }
                """, variables: ["id": id])
            return (data.dict("Page")?["media"] as? [[String: Any]] ?? []).map(Self.searchResult)
        }
        let data = try await http.graphQL(Self.api, token: try? token, query: """
            query($search: String!) { Page(perPage: 50) { media(search: $search, type: MANGA, format_not_in: [NOVEL]) { \(Self.mangaFields) } } }
            """, variables: ["search": query])
        return (data.dict("Page")?["media"] as? [[String: Any]] ?? []).map(Self.searchResult)
    }

    private static func searchResult(_ media: [String: Any]) -> TrackSearch {
        let id = media.int64("id") ?? 0
        let staff = media.dict("staff")?["edges"] as? [[String: Any]] ?? []
        func people(_ roles: [String]) -> [String] {
            staff.filter { edge in roles.contains { (edge.string("role") ?? "").contains($0) } }
                .compactMap { $0.dict("node")?.dict("name")?.string("userPreferred") }
        }
        let start = media.dict("startDate")
        return TrackSearch(
            remoteId: id, title: media.dict("title")?.string("userPreferred") ?? "",
            coverURL: media.dict("coverImage")?.string("large").flatMap(URL.init(string:)),
            summary: HTMLText.plain(media.string("description") ?? ""),
            totalChapters: media["chapters"] as? Int ?? 0,
            publishingStatus: (media.string("status") ?? "").replacingOccurrences(of: "_", with: " ").capitalized,
            publishingType: (media.string("format") ?? "").replacingOccurrences(of: "_", with: " ").capitalized,
            startDate: (start?["year"] as? Int).map(String.init) ?? "",
            score: media.double("averageScore") ?? -1,
            authors: people(["Story"]), artists: people(["Art"]),
            trackingURL: "https://anilist.co/manga/\(id)"
        )
    }

    private static func apiStatus(_ status: Int) -> String {
        switch status {
        case completed: "COMPLETED"
        case onHold: "PAUSED"
        case dropped: "DROPPED"
        case planToRead: "PLANNING"
        case rereading: "REPEATING"
        default: "CURRENT"
        }
    }

    private static func localStatus(_ status: String?) -> Int {
        switch status {
        case "COMPLETED": completed
        case "PAUSED": onHold
        case "DROPPED": dropped
        case "PLANNING": planToRead
        case "REPEATING": rereading
        default: reading
        }
    }

    /// The user's list entry for the series, if it's on their list.
    private func findEntry(_ track: TrackRecord) async throws -> TrackRecord? {
        let data = try await http.graphQL(Self.api, token: try token, query: """
            query($user_id: Int!, $manga_id: Int!) { Page { mediaList(userId: $user_id, type: MANGA, mediaId: $manga_id) {
              id status scoreRaw: score(format: POINT_100) progress private
              startedAt { year month day } completedAt { year month day } media { \(Self.mangaFields) } } } }
            """, variables: ["user_id": userId, "manga_id": track.remoteId])
        guard let entry = (data.dict("Page")?["mediaList"] as? [[String: Any]])?.first else { return nil }
        var found = track
        found.libraryId = entry.int64("id")
        found.status = Self.localStatus(entry.string("status"))
        found.score = entry.double("scoreRaw") ?? 0
        found.lastChapterRead = entry.double("progress") ?? 0
        found.isPrivate = entry["private"] as? Bool ?? false
        found.startDate = TrackDates.fromFuzzy(entry.dict("startedAt"))
        found.finishDate = TrackDates.fromFuzzy(entry.dict("completedAt"))
        if let media = entry.dict("media") {
            found.title = media.dict("title")?.string("userPreferred") ?? found.title
            found.totalChapters = media["chapters"] as? Int ?? found.totalChapters
        }
        return found
    }

    func bind(_ track: TrackRecord, hasReadChapters: Bool) async throws -> TrackRecord {
        if var remote = try await findEntry(track) {
            remote.isPrivate = track.isPrivate
            if remote.status != Self.completed, remote.status != Self.rereading, hasReadChapters {
                remote.status = Self.reading
            }
            return try await update(remote, didReadChapter: false)
        }
        var track = track
        track.status = hasReadChapters ? Self.reading : Self.planToRead
        track.score = 0
        let data = try await http.graphQL(Self.api, token: try token, query: """
            mutation($manga_id: Int!, $progress: Int!, $status: MediaListStatus!, $private: Boolean!) {
              SaveMediaListEntry(mediaId: $manga_id, progress: $progress, status: $status, private: $private) { id } }
            """, variables: [
                "manga_id": track.remoteId, "progress": Int(track.lastChapterRead),
                "status": Self.apiStatus(track.status), "private": track.isPrivate,
            ])
        track.libraryId = data.dict("SaveMediaListEntry")?.int64("id")
        return track
    }

    func update(_ track: TrackRecord, didReadChapter: Bool) async throws -> TrackRecord {
        var track = track
        if track.libraryId == nil || track.libraryId == 0 {
            guard let remote = try await findEntry(track) else { throw TrackerError.notFound }
            track.libraryId = remote.libraryId
        }
        applyReading(&track, didReadChapter: didReadChapter)
        _ = try await http.graphQL(Self.api, token: try token, query: """
            mutation($library_id: Int!, $progress: Int!, $status: MediaListStatus!, $private: Boolean!, $score: Int!,
                     $startedAt: FuzzyDateInput!, $completedAt: FuzzyDateInput!) {
              SaveMediaListEntry(id: $library_id, progress: $progress, status: $status, private: $private, scoreRaw: $score,
                                 startedAt: $startedAt, completedAt: $completedAt) { id } }
            """, variables: [
                "library_id": track.libraryId ?? 0, "progress": Int(track.lastChapterRead), "status": Self.apiStatus(track.status),
                "private": track.isPrivate, "score": Int(track.score),
                "startedAt": TrackDates.fuzzy(track.startDate), "completedAt": TrackDates.fuzzy(track.finishDate),
            ])
        return track
    }

    func refresh(_ track: TrackRecord) async throws -> TrackRecord {
        guard var remote = try await findEntry(track) else { throw TrackerError.notFound }
        remote.id = track.id
        return remote
    }

    func delete(_ track: TrackRecord) async throws {
        var libraryId = track.libraryId
        if libraryId == nil || libraryId == 0 { libraryId = try await findEntry(track)?.libraryId }
        guard let libraryId else { return }
        _ = try await http.graphQL(Self.api, token: try token, query: """
            mutation($library_id: Int!) { DeleteMediaListEntry(id: $library_id) { deleted } }
            """, variables: ["library_id": libraryId])
    }
}
