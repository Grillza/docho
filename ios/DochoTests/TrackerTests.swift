import XCTest
@testable import Docho

@MainActor
final class TrackerTests: XCTestCase {
    private var defaults: UserDefaults!
    private let service = "io.github.grillza.docho.tests.trackers"

    override func setUp() async throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: "io.github.grillza.docho.tests.trackers.\(UUID())"))
    }

    private nonisolated static func body(_ request: StubURLProtocol.Request) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
    }

    private nonisolated static func form(_ request: StubURLProtocol.Request) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: request.body, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testAniListSignsInFromTheRedirectAndBindsANewEntry() async throws {
        StubURLProtocol.reset { request in
            let query = Self.body(request)["query"] as? String ?? ""
            XCTAssertEqual(request.headers["Authorization"], "Bearer abc")
            if query.contains("Viewer") {
                return .json(#"{"data":{"Viewer":{"id":42,"name":"reader","mediaListOptions":{"scoreFormat":"POINT_5"}}}}"#)
            }
            if query.contains("mediaList(") {
                return .json(#"{"data":{"Page":{"mediaList":[]}}}"#)
            }
            if query.contains("SaveMediaListEntry(mediaId") {
                let variables = Self.body(request)["variables"] as? [String: Any]
                XCTAssertEqual(variables?["status"] as? String, "CURRENT")
                XCTAssertEqual(variables?["progress"] as? Int, 3)
                return .json(#"{"data":{"SaveMediaListEntry":{"id":777}}}"#)
            }
            return .json(#"{"errors":[{"message":"unexpected"}]}"#)
        }
        let tracker = AniList(session: StubURLProtocol.session(), defaults: defaults, keychainService: service)
        defer { tracker.signOut() }
        try await tracker.signIn(callback: XCTUnwrap(URL(string: "mihon://anilist-auth#access_token=abc&token_type=Bearer&expires_in=31536000")))
        XCTAssertTrue(tracker.isSignedIn)
        XCTAssertEqual(tracker.username, "reader")
        XCTAssertEqual(tracker.scores, ["0 ★", "1 ★", "2 ★", "3 ★", "4 ★", "5 ★"])
        XCTAssertEqual(tracker.indexToScore(4), 70)
        XCTAssertEqual(tracker.displayScore(70), "4 ★")

        var track = TrackRecord(seriesId: 1, trackerId: AniList.id, remoteId: 99, title: "Series")
        track.lastChapterRead = 3
        let bound = try await tracker.bind(track, hasReadChapters: true)
        XCTAssertEqual(bound.libraryId, 777)
        XCTAssertEqual(bound.status, AniList.reading)
    }

    func testMyAnimeListSendsTheListStatusAsAForm() async throws {
        StubURLProtocol.reset { request in
            switch (request.method, request.path) {
            case ("POST", "/v1/oauth2/token"):
                let fields = Self.form(request)
                XCTAssertEqual(fields["grant_type"], "authorization_code")
                XCTAssertEqual(fields["code"], "the-code")
                XCTAssertEqual(fields["code_verifier"]?.count, 64)
                return .json(#"{"access_token":"mal","refresh_token":"r","expires_in":3600}"#)
            case ("GET", "/v2/users/@me"):
                return .json(#"{"name":"maluser"}"#)
            case ("PUT", "/v2/manga/5/my_list_status"):
                let fields = Self.form(request)
                XCTAssertEqual(fields["status"], "completed")
                XCTAssertEqual(fields["num_chapters_read"], "10")
                XCTAssertEqual(fields["is_rereading"], "false")
                XCTAssertEqual(fields["finish_date"]?.count, 10, "finishing sets the date")
                return .json(#"{"status":"completed","num_chapters_read":10,"score":8,"is_rereading":false}"#)
            default:
                return .json("{}", status: 404)
            }
        }
        let tracker = MyAnimeList(session: StubURLProtocol.session(), defaults: defaults, keychainService: service)
        defer { tracker.signOut() }
        guard case .oauth(let url) = tracker.signIn else { return XCTFail("MAL signs in on the web") }
        XCTAssertTrue(url.absoluteString.contains("code_challenge="))
        try await tracker.signIn(callback: XCTUnwrap(URL(string: "mihon://myanimelist-auth?code=the-code")))
        XCTAssertEqual(tracker.username, "maluser")

        var track = TrackRecord(seriesId: 1, trackerId: MyAnimeList.id, remoteId: 5, title: "Series", totalChapters: 10, status: MyAnimeList.reading)
        track.lastChapterRead = 10
        let updated = try await tracker.update(track, didReadChapter: true)
        XCTAssertEqual(updated.status, MyAnimeList.completed)
        XCTAssertEqual(updated.score, 8)
    }

    func testKitsuScoresFollowTheRatingSystem() async throws {
        StubURLProtocol.reset { request in
            if request.path == "/api/oauth/token" {
                XCTAssertEqual(Self.form(request)["grant_type"], "password")
                return .json(#"{"access_token":"k","refresh_token":"r","expires_in":3600}"#)
            }
            return .json(#"{"data":{"currentAccount":{"id":"12","ratingSystem":"REGULAR","profile":{"name":"Kit"}}}}"#)
        }
        let tracker = Kitsu(session: StubURLProtocol.session(), defaults: defaults, keychainService: service)
        defer { tracker.signOut() }
        try await tracker.signIn(username: "kit@example.com", password: "pw")
        XCTAssertEqual(tracker.username, "Kit")
        XCTAssertEqual(tracker.scores.first, "0 ★")
        XCTAssertEqual(tracker.scores.last, "5 ★")
        XCTAssertEqual(tracker.indexToScore(7), 14, "3.5 stars is 14 of 20")
        XCTAssertEqual(tracker.displayScore(15), "3.5 ★", "rounded down to the scale")
        XCTAssertEqual(tracker.displayScore(0), "0 ★")
    }

    func testReadingMovesLinkedTrackersForwardOnly() async throws {
        let parts = try TestApp.make("trackers")
        let app = parts.app
        let series = try await app.seedKavitaSeries(chapters: [(1, 10)])
        StubURLProtocol.reset { request in
            if request.path == "/v1/account/login" {
                return .json(#"{"context":{"session_token":"mu","uid":1}}"#)
            }
            if request.path == "/v1/lists/series/update" {
                let entry = (try? JSONSerialization.jsonObject(with: request.body) as? [[String: Any]])?.first
                XCTAssertEqual((entry?["status"] as? [String: Any])?["chapter"] as? Int, 4)
                XCTAssertEqual(entry?["list_id"] as? Int, MangaUpdates.readingList)
                return .json("{}")
            }
            return .json("{}")
        }
        let mangaUpdates = MangaUpdates(session: StubURLProtocol.session(), defaults: defaults, keychainService: service)
        defer { mangaUpdates.signOut() }
        let manager = TrackerManager(database: app.database, defaults: defaults, trackers: [mangaUpdates])
        try await manager.signIn(mangaUpdates, username: "u", password: "p")
        var track = TrackRecord(seriesId: series.id, trackerId: MangaUpdates.id, remoteId: 8, title: "Series", status: MangaUpdates.wishList)
        track.lastChapterRead = 2
        try await app.database.saveTrack(track)

        await manager.chapterRead(seriesId: series.id, number: 1)
        XCTAssertFalse(StubURLProtocol.requests.contains { (request: StubURLProtocol.Request) in request.path == "/v1/lists/series/update" }, "behind what's tracked")
        await manager.chapterRead(seriesId: series.id, number: 4)
        let saved = try await app.database.tracks(seriesId: series.id)
        XCTAssertEqual(saved.map { (track: TrackRecord) in track.lastChapterRead }, [4])
        XCTAssertEqual(saved.first?.status, MangaUpdates.readingList)

        manager.updateAfterReading = false
        await manager.chapterRead(seriesId: series.id, number: 9)
        let after = try await app.database.tracks(seriesId: series.id)
        XCTAssertEqual(after.first?.lastChapterRead, 4)
    }
}
