import Synchronization
import XCTest
@testable import Docho

// MARK: - KOReader

/// A kosync server holding positions by document, plus a Kavita answering for series 7.
private final class FakeKosync: Sendable {
    let positions = Mutex<[String: (progress: String, percentage: Double)]>([:])
    let known: Set<String>

    init(known: Set<String>) {
        self.known = known
    }

    func handle(_ request: StubURLProtocol.Request) throws -> StubURLProtocol.Response {
        if request.path.hasSuffix("/Plugin/authenticate") { return .json(#"{"username": "u", "token": "t"}"#) }
        guard request.url.host() == "sync.test" else { return .json("", status: 404) }
        guard request.headers["x-auth-user"] == "reader", request.headers["x-auth-key"] == KoreaderClient.md5("secret") else {
            return .json("", status: 401)
        }
        switch (request.method, request.path) {
        case ("GET", "/users/auth"):
            return .json(#"{"authorized": "OK"}"#)
        case ("GET", let path) where path.hasPrefix("/syncs/progress/"):
            let document = String(path.dropFirst("/syncs/progress/".count))
            guard let position = positions.withLock({ $0[document] }) else { return .json("{}") }
            return .json(#"{"document": "\#(document)", "progress": "\#(position.progress)", "percentage": \#(position.percentage)}"#)
        case ("PUT", "/syncs/progress"):
            let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:]
            let document = body["document"] as? String ?? ""
            guard known.contains(document) else { return .json("", status: 404) }
            positions.withLock { $0[document] = (body["progress"] as? String ?? "", body["percentage"] as? Double ?? 0) }
            return .json("")
        default:
            return .json("", status: 404)
        }
    }
}

@MainActor
final class KoreaderTests: XCTestCase {
    private var app: AppModel!
    private var server: FakeKosync!
    private var series: SeriesRecord!

    override func setUp() async throws {
        app = try TestApp.make("koreader").app
        app.koreaderSettings.serverURL = "sync.test/"
        app.koreaderSettings.username = "reader"
        app.koreaderSettings.password = "secret"
        app.syncSettings.mode = .koreader
        let server = FakeKosync(known: ["aaa", "bbb"])
        self.server = server
        StubURLProtocol.reset { try server.handle($0) }
        // Kavita chapters whose memo carries KOReader's hash, as the chapter list stores it.
        series = try await app.seedKavitaSeries(chapters: [(10, 20), (11, 20), (12, 20)])
        try await app.database.writer.write { db in
            for (id, hash) in [(10, "aaa"), (11, "bbb"), (12, "ccc")] {
                guard var chapter = try ChapterRecord.filter(sql: "url = ?", arguments: [KavitaSource.chapterURL(id)]).fetchOne(db) else { continue }
                var memo = chapter.chapterMemo
                memo[KavitaSource.memoKoreaderHash] = .string(hash)
                chapter.chapterMemo = memo
                try chapter.update(db)
            }
        }
    }

    private func chapter(_ id: Int) async throws -> ChapterRecord {
        let chapter = try await app.kavitaChapter(id)
        return try XCTUnwrap(chapter)
    }

    func testPartialMD5MatchesKoreaders() async throws {
        let data = Data((0..<3_000_000).map { UInt8(($0 * 31 + 7) % 251) })
        XCTAssertEqual(KoreaderHash.compute(data: data), "951d6ad62a386c5d5e49f4c898e5c6c2")
        XCTAssertEqual(KoreaderHash.compute(data: Data(0..<100)), "7acedd1a84a4cfcb6e7a16003242945e")

        let ranged = try await KoreaderHash.compute { offset, length in
            let start = Int(offset)
            return (data[start..<min(start + length, data.count)], Int64(data.count))
        }
        XCTAssertEqual(ranged, "951d6ad62a386c5d5e49f4c898e5c6c2")

        let stream = AsyncStream<UInt8> { continuation in
            for byte in data { continuation.yield(byte) }
            continuation.finish()
        }
        let streamed = try await KoreaderHash.compute(stream: stream, size: nil)
        XCTAssertEqual(streamed, "951d6ad62a386c5d5e49f4c898e5c6c2", "a stream of unknown length gives the same hash")
        XCTAssertEqual(KoreaderClient.md5("secret"), "5ebe2294ecd0e0f08eab7690d2a6ee69")
    }

    func testSignsInWithTheUsernameAndPasswordHash() async {
        let connected = await app.koreader.checkConnection()
        XCTAssertEqual(connected, .connected("reader"))
        app.koreaderSettings.password = "wrong"
        let rejected = await app.koreader.checkConnection()
        XCTAssertEqual(rejected, .failed("The sync server rejected the username or password."))
    }

    func testModeSwitchingRoutesTheSeries() {
        XCTAssertTrue(app.koreaderSync.syncs(series))
        XCTAssertFalse(app.kavitaSync.syncs(series), "Kavita's own sync stands down")
        app.syncSettings.mode = .source
        XCTAssertFalse(app.koreaderSync.syncs(series))
        XCTAssertTrue(app.kavitaSync.syncs(series))
    }

    func testPushesPagesAsKoreaderPositions() async throws {
        await app.sync.pageChanged(series, chapter: try await chapter(10), page: 4, pageCount: 20, read: false)
        try await Task.sleep(for: .milliseconds(300))
        let position = server.positions.withLock { $0["aaa"] }
        XCTAssertEqual(position?.progress, "5")
        XCTAssertEqual(position?.percentage ?? 0, 0.25, accuracy: 0.001)
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { !$0.path.hasSuffix("/Reader/progress") }, "nothing goes to Kavita")
    }

    func testPullsFurtherPositionsAndPushesWhatsFurtherHere() async throws {
        server.positions.withLock { $0 = ["aaa": ("9", 0.45), "bbb": ("20", 1)] }
        try await app.database.writer.write { db in
            try db.execute(sql: "UPDATE chapter SET lastPageRead = 6 WHERE url = '/chapter/12'")
        }

        await app.sync.syncSeries(series)

        let ten = try await chapter(10)
        XCTAssertEqual(ten.lastPageRead, 8, "KOReader page 9 is index 8")
        let eleven = try await chapter(11)
        XCTAssertTrue(eleven.read)
        // ccc: further here, but the server has no such book, so it's dropped, not retried.
        let queue = try await app.database.syncQueue(engine: KoreaderSync.engine)
        XCTAssertEqual(queue, [])
    }

    func testHandMarksGoThroughEvenWhenTheServerIsFurther() async throws {
        server.positions.withLock { $0["aaa"] = ("20", 1) }
        await app.sync.readStatusChanged(series, chapters: [try await chapter(10)], read: false)
        let position = server.positions.withLock { $0["aaa"] }
        XCTAssertEqual(position?.progress, "1", "KOReader has no page 0")
        XCTAssertEqual(position?.percentage, 0)
    }

    func testPositionsFromPercentages() {
        XCTAssertEqual(KoreaderSync.position(nil, pages: 10), 0)
        XCTAssertEqual(KoreaderSync.position(KoreaderProgress(progress: "4", percentage: 0.4), pages: 10), 4)
        XCTAssertEqual(KoreaderSync.position(KoreaderProgress(progress: "xpointer", percentage: 0.5), pages: 10), 5)
        XCTAssertEqual(KoreaderSync.position(KoreaderProgress(progress: "3", percentage: 1), pages: 10), 10)
    }
}

// MARK: - BookOrbit

/// A BookOrbit server with one series (5) of two comic books and an ebook.
private final class FakeBookOrbit: Sendable {
    struct State {
        var logins = 0
        var refreshes = 0
        var token = "access-1"
        var progress: [Int: (page: Int?, percentage: Double)] = [:]
        var status: [Int: String] = [:]
    }

    let state = Mutex(State())

    func handle(_ request: StubURLProtocol.Request) throws -> StubURLProtocol.Response {
        try state.withLock { state in
            switch (request.method, request.path) {
            case ("POST", "/api/v1/auth/login"):
                let body = try JSONSerialization.jsonObject(with: request.body) as? [String: String] ?? [:]
                guard body["password"] == "pw", body["clientKind"] == "native" else { return .json("", status: 401) }
                state.logins += 1
                return .json(#"{"accessToken": "\#(state.token)", "refreshToken": "refresh-1"}"#)
            case ("POST", "/api/v1/auth/refresh"):
                state.refreshes += 1
                let body = try JSONSerialization.jsonObject(with: request.body) as? [String: String] ?? [:]
                guard body["refreshToken"] == "refresh-1" else { return .json("", status: 401) }
                return .json(#"{"accessToken": "\#(state.token)", "refreshToken": "refresh-1"}"#)
            default:
                break
            }
            guard request.headers["Authorization"] == "Bearer \(state.token)" else { return .json("", status: 401) }
            switch (request.method, request.path) {
            case ("GET", "/api/v1/auth/me"):
                return .json(#"{"username": "orbit"}"#)
            case ("GET", "/api/v1/series/5/books"):
                func book(_ id: Int, file: Int, format: String) -> String {
                    let progress = state.progress[file].map { #", "readingProgress": \#($0.percentage)"# } ?? ""
                    let status = state.status[id].map { #", "readStatus": {"status": "\#($0)"}"# } ?? ""
                    return #"{"id": \#(id), "title": "Book \#(id)", "seriesIndex": "\#(id)", "files": [{"id": \#(file), "format": "\#(format)"}]\#(progress)\#(status)}"#
                }
                let books = [book(1, file: 11, format: "cbz"), book(2, file: 12, format: "CBR"), book(3, file: 13, format: "epub")]
                return .json(#"{"items": [\#(books.joined(separator: ","))], "total": 3, "seriesInfo": {"id": 5, "name": "Orbit", "authors": ["A"]}}"#)
            case ("GET", let path) where path.hasPrefix("/api/v1/cbz/files/") && path.hasSuffix("/pages"):
                return .json(#"{"pageCount": 10}"#)
            case ("GET", let path) where path.hasSuffix("/progress"):
                let file = Int(path.components(separatedBy: "/")[5]) ?? 0
                let progress = state.progress[file]
                return .json(#"{"pageNumber": \#(progress?.page.map(String.init) ?? "null"), "percentage": \#(progress?.percentage ?? 0)}"#)
            case ("POST", let path) where path.hasSuffix("/progress"):
                let file = Int(path.components(separatedBy: "/")[5]) ?? 0
                let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:]
                state.progress[file] = (body["pageNumber"] as? Int, body["percentage"] as? Double ?? 0)
                return .json("")
            case ("DELETE", let path) where path.hasSuffix("/progress"):
                state.progress[Int(path.components(separatedBy: "/")[5]) ?? 0] = nil
                return .json("")
            case ("PATCH", let path) where path.hasSuffix("/status"):
                let body = try JSONSerialization.jsonObject(with: request.body) as? [String: String] ?? [:]
                state.status[Int(path.components(separatedBy: "/")[4]) ?? 0] = body["status"]
                return .json("")
            default:
                return .json("", status: 404)
            }
        }
    }
}

@MainActor
final class BookOrbitTests: XCTestCase {
    private var app: AppModel!
    private var server: FakeBookOrbit!

    override func setUp() async throws {
        app = try TestApp.make("bookorbit", kavita: nil).app
        app.bookOrbitSettings.serverURL = "http://orbit.test"
        app.bookOrbitSettings.username = "orbit"
        app.bookOrbitSettings.password = "pw"
        let server = FakeBookOrbit()
        self.server = server
        StubURLProtocol.reset { try server.handle($0) }
    }

    private func openSeries() async throws -> SeriesRecord {
        let series = try await app.database.localSeries(source: BookOrbitSource.id, manga: SManga(url: "/series/5", title: "Orbit"))
        let (manga, chapters) = try await app.bookOrbitSource.update(series.manga, details: true, chapters: true)
        try await app.database.saveFromSource(seriesId: series.id, manga: manga, chapters: chapters)
        let stored = try await app.database.seriesRecord(id: series.id)
        return try XCTUnwrap(stored)
    }

    func testSignsInOnceAsANativeClientAndKeepsTheRefreshToken() async throws {
        let first = await app.bookOrbit.checkConnection()
        XCTAssertEqual(first, .connected("orbit"))
        await app.bookOrbit.checkConnection()
        XCTAssertEqual(server.state.withLock { $0.logins }, 1, "one session, not one per request")
        XCTAssertEqual(app.bookOrbitSettings.refreshToken, "refresh-1")

        // A new token on the server: the old one is refused, the refresh token renews it.
        server.state.withLock { $0.token = "access-2" }
        let again = await app.bookOrbit.checkConnection()
        XCTAssertEqual(again, .connected("orbit"))
        XCTAssertEqual(server.state.withLock { $0.refreshes }, 1)
        XCTAssertEqual(server.state.withLock { $0.logins }, 1)
    }

    func testAWrongPasswordIsReported() async {
        app.bookOrbitSettings.password = "nope"
        let result = await app.bookOrbit.checkConnection()
        XCTAssertEqual(result, .failed("BookOrbit rejected the username or password."))
    }

    func testComicBooksBecomeChaptersAndEbooksAreLeftOut() async throws {
        let series = try await openSeries()
        XCTAssertEqual(series.name, "Orbit")
        XCTAssertEqual(series.authors, "A")
        let chapters = try await app.database.chapterList(seriesId: series.id)
        XCTAssertEqual(chapters.map(\.name), ["Vol. 1 - Book 1", "Vol. 2 - Book 2"])
        XCTAssertEqual(chapters.map(\.url), ["/book/1/file/11", "/book/2/file/12"])
    }

    func testProgressIsSentAsBookOrbitsPageAndPercentage() async throws {
        let series = try await openSeries()
        let first = try await app.database.chapterList(seriesId: series.id).first
        let chapter = try XCTUnwrap(first)
        await app.sync.pageChanged(series, chapter: chapter, page: 4, pageCount: 10, read: false)
        try await Task.sleep(for: .milliseconds(300))
        let progress = server.state.withLock { $0.progress[11] }
        XCTAssertEqual(progress?.page, 5)
        XCTAssertEqual(progress?.percentage, 50)
    }

    func testReconcilesWithTheServer() async throws {
        let series = try await openSeries()
        _ = app.bookOrbitSource.progressCache.take(5) // the list fetched before the server changed
        server.state.withLock { $0.progress = [11: (7, 70)]; $0.status = [2: "read"] }

        await app.sync.syncSeries(series)

        let chapters = try await app.database.chapterList(seriesId: series.id)
        XCTAssertEqual(chapters[0].lastPageRead, 6)
        XCTAssertTrue(chapters[1].read)

        await app.sync.readStatusChanged(series, chapters: [chapters[0]], read: false)
        XCTAssertNil(server.state.withLock { $0.progress[11] }, "marking unread clears the position")
        XCTAssertEqual(server.state.withLock { $0.status[1] }, "unread")
    }

    func testChapterNames() {
        XCTAssertEqual(BookOrbitSource.chapterName(title: "T", seriesIndex: "3"), "Vol. 3 - T")
        XCTAssertEqual(BookOrbitSource.chapterName(title: nil, seriesIndex: "3"), "Vol. 3")
        XCTAssertEqual(BookOrbitSource.chapterName(title: " T ", seriesIndex: nil), "T")
        XCTAssertEqual(BookOrbitSource.chapterName(title: nil, seriesIndex: nil), "Untitled")
    }
}
