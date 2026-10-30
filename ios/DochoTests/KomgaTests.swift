import Synchronization
import XCTest
@testable import Docho

/// A Komga server with one series ("s1") of three books, for the source and sync tests.
private final class FakeKomga: Sendable {
    struct State {
        /// Page reached (1-based) and completed, by book id.
        var progress: [String: (page: Int, completed: Bool)] = [:]
        var down = false
    }

    let pages = 10
    let state = Mutex(State())

    func set(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    func progress(_ book: String) -> (page: Int, completed: Bool)? {
        state.withLock { $0.progress[book] }
    }

    private func book(_ id: String, number: String, title: String, profile: String = "DIVINA", state: State) -> String {
        let progress = state.progress[id].map { #", "readProgress": {"page": \#($0.page), "completed": \#($0.completed)}"# } ?? ""
        return #"""
        {"id": "\#(id)", "seriesId": "s1", "name": "\#(title)", "url": "/data/S1/\#(title).cbz",
         "media": {"status": "READY", "pagesCount": \#(pages), "mediaProfile": "\#(profile)"},
         "metadata": {"title": "\#(title)", "number": "\#(number)", "numberSort": \#(number)}\#(progress)}
        """#
    }

    func handle(_ request: StubURLProtocol.Request) throws -> StubURLProtocol.Response {
        guard request.headers["X-API-Key"] == "komga-key" else { return .json("", status: 401) }
        return try state.withLock { state in
            if state.down { return .json("", status: 500) }
            switch (request.method, request.path) {
            case ("GET", "/api/v2/users/me"):
                return .json(#"{"email": "me@komga.test"}"#)
            case ("POST", "/api/v1/series/list"):
                return .json(#"{"content": [{"id": "s1", "name": "S1", "metadata": {"title": "Series One"}}], "last": true}"#)
            case ("GET", "/api/v1/series/s1"):
                return .json(#"""
                {"id": "s1", "name": "S1", "metadata": {"title": "Series One", "summary": "", "status": "ENDED", "genres": ["Drama"], "tags": ["Old"]},
                 "booksMetadata": {"summary": "From books", "authors": [{"name": "Ann", "role": "writer"}, {"name": "Bo", "role": "penciller"}]}}
                """#)
            case ("POST", "/api/v1/books/list"):
                let books = [
                    book("b1", number: "1", title: "1", state: state),
                    book("b2", number: "2", title: "The Second", state: state),
                    book("b3", number: "3", title: "Novel", profile: "EPUB", state: state),
                ]
                return .json(#"{"content": [\#(books.joined(separator: ","))], "last": true}"#)
            case ("GET", let path) where path.hasPrefix("/api/v1/books/") && path.hasSuffix("/pages"):
                return .json("[" + (1...pages).map { #"{"number": \#($0)}"# }.joined(separator: ",") + "]")
            case ("GET", let path) where path.hasPrefix("/api/v1/books/"):
                let id = String(path.dropFirst("/api/v1/books/".count))
                return .json(book(id, number: "1", title: id, state: state))
            case ("PATCH", let path) where path.hasSuffix("/read-progress"):
                let id = path.components(separatedBy: "/")[4]
                let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:]
                if body["completed"] as? Bool == true {
                    state.progress[id] = (pages, true)
                } else if let page = body["page"] as? Int {
                    state.progress[id] = (page, page >= pages)
                }
                return .json("")
            case ("DELETE", let path) where path.hasSuffix("/read-progress"):
                state.progress[path.components(separatedBy: "/")[4]] = nil
                return .json("")
            default:
                return .json("", status: 404)
            }
        }
    }
}

@MainActor
final class KomgaTests: XCTestCase {
    private var app: AppModel!
    private var server: FakeKomga!

    override func setUp() async throws {
        app = try TestApp.make("komga", kavita: nil).app
        app.komgaSettings.serverURL = "komga.test:25600/"
        app.komgaSettings.apiKey = "komga-key"
        let server = FakeKomga()
        self.server = server
        StubURLProtocol.reset { try server.handle($0) }
    }

    private func requests(_ method: String, _ path: String) -> [StubURLProtocol.Request] {
        StubURLProtocol.requests.filter { $0.method == method && $0.path == path }
    }

    private func body(_ request: StubURLProtocol.Request) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    /// Stores the series and its chapters from the source, as opening it would.
    private func openSeries() async throws -> SeriesRecord {
        let series = try await app.database.localSeries(source: KomgaSource.id, manga: SManga(url: "/series/s1", title: "S1"))
        let (manga, chapters) = try await app.komgaSource.update(series.manga, details: true, chapters: true)
        try await app.database.saveFromSource(seriesId: series.id, manga: manga, chapters: chapters)
        let stored = try await app.database.seriesRecord(id: series.id)
        return try XCTUnwrap(stored)
    }

    private func chapter(_ book: String, in series: SeriesRecord) async throws -> ChapterRecord {
        let chapters = try await app.database.chapterList(seriesId: series.id)
        return try XCTUnwrap(chapters.first { $0.url == "/book/\(book)" })
    }

    // MARK: Connection and browsing

    func testAddressesAreNormalised() {
        XCTAssertEqual(KomgaClient.normalizeApiURL("komga.lan:25600"), "http://komga.lan:25600/api")
        XCTAssertEqual(KomgaClient.normalizeApiURL("https://example.com/komga/api/v1/"), "https://example.com/komga/api")
        XCTAssertNil(KomgaClient.normalizeApiURL("  "))
    }

    func testConnectsWithTheApiKeyAndReportsARejectedKey() async {
        let connected = await app.komga.checkConnection()
        XCTAssertEqual(connected, .connected("me@komga.test"))
        XCTAssertEqual(StubURLProtocol.requests.last?.headers["X-API-Key"], "komga-key")

        app.komgaSettings.apiKey = "wrong"
        let rejected = await app.komga.checkConnection()
        XCTAssertEqual(rejected, .failed("Komga rejected the API key."))
    }

    func testBrowseListingsSendKomgasSearchBodies() async throws {
        let popular = try await app.komgaSource.popular(page: 1)
        XCTAssertEqual(popular.mangas.map(\.title), ["Series One"])
        XCTAssertEqual(popular.mangas.first?.url, "/series/s1")
        XCTAssertFalse(popular.hasNextPage)
        var request = try XCTUnwrap(requests("POST", "/api/v1/series/list").last)
        XCTAssertEqual(request.query("page"), "0", "Komga counts pages from 0")
        XCTAssertEqual(request.query("sort"), "metadata.titleSort,asc")

        _ = try await app.komgaSource.unread(page: 1)
        request = try XCTUnwrap(requests("POST", "/api/v1/series/list").last)
        XCTAssertEqual(request.query("sort"), "lastModified,desc")
        let unread = try body(request)
        let all = try XCTUnwrap((unread["condition"] as? [String: Any])?["allOf"] as? [[String: Any]])
        XCTAssertTrue(all.contains { $0["deleted"] != nil })
        let anyOf = try XCTUnwrap(all.compactMap { $0["anyOf"] as? [[String: [String: String]]] }.first)
        XCTAssertEqual(Set(anyOf.compactMap { $0["readStatus"]?["value"] }), ["UNREAD", "IN_PROGRESS"])

        _ = try await app.komgaSource.search(page: 1, query: " berserk ", filters: [])
        request = try XCTUnwrap(requests("POST", "/api/v1/series/list").last)
        XCTAssertEqual(try body(request)["fullTextSearch"] as? String, "berserk")
    }

    func testDetailsAndChapters() async throws {
        let series = try await openSeries()
        XCTAssertEqual(series.name, "Series One")
        XCTAssertEqual(series.summary, "From books")
        XCTAssertEqual(series.authors, "Ann")
        XCTAssertEqual(series.artists, "Bo")
        XCTAssertEqual(series.genres, "Drama, Old")
        XCTAssertEqual(series.mangaStatus, .completed)

        let chapters = try await app.database.chapterList(seriesId: series.id)
        XCTAssertEqual(chapters.map(\.name), ["#1", "#2 - The Second"], "text EPUBs are left out")
        XCTAssertEqual(chapters.map(\.url), ["/book/b1", "/book/b2"])
        XCTAssertEqual(chapters.first?.chapterMemo.string(ChapterMemo.fileName), "1.cbz")
        XCTAssertEqual(chapters.first?.pages, 10)
    }

    func testChapterNames() {
        XCTAssertEqual(KomgaSource.chapterName(title: "Title", number: "3"), "#3 - Title")
        XCTAssertEqual(KomgaSource.chapterName(title: "3", number: "3"), "#3")
        XCTAssertEqual(KomgaSource.chapterName(title: "Title", number: ""), "Title")
        XCTAssertEqual(KomgaSource.chapterName(title: "", number: ""), "Untitled")
    }

    func testPagesAreNumberedFromOneAndCarryTheKey() async throws {
        let pages = try await app.komgaSource.pages(SChapter(url: "/book/b1", name: ""))
        XCTAssertEqual(pages.count, 10)
        XCTAssertEqual(pages[0].imageURL.absoluteString, "http://komga.test:25600/api/v1/books/b1/pages/1")
        XCTAssertEqual(app.komgaSource.imageRequest(pages[0]).value(forHTTPHeaderField: "X-API-Key"), "komga-key")
    }

    // MARK: Sync

    func testAPageReadHereIsSentOneBased() async throws {
        let series = try await openSeries()
        await app.sync.pageChanged(series, chapter: try await chapter("b1", in: series), page: 4, pageCount: 10, read: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.progress("b1")?.page, 5)
        let queue = try await app.database.syncQueue(engine: KomgaSync.engine)
        XCTAssertEqual(queue, [])
    }

    func testReconcilingFollowsTheRules() async throws {
        let series = try await openSeries()
        _ = app.komgaSource.progressCache.take("s1") // the list fetched before the server changed
        // b1 further there → pulled; b2 further here → pushed.
        server.set { $0.progress = ["b1": (7, false), "b2": (2, false)] }
        try await app.database.writer.write { db in
            try db.execute(sql: "UPDATE chapter SET lastPageRead = 5 WHERE url = '/book/b2'")
        }

        await app.sync.syncSeries(series)

        let b1 = try await chapter("b1", in: series)
        XCTAssertEqual(b1.lastPageRead, 6, "Komga's page 7 is index 6")
        XCTAssertEqual(server.progress("b2")?.page, 6)

        // Read there → read here; read here → pushed as read.
        server.set { $0.progress["b1"] = (10, true) }
        let b2 = try await chapter("b2", in: series)
        try await app.database.setChaptersRead([b2.id], read: true)
        await app.sync.syncSeries(series)
        let b1Read = try await chapter("b1", in: series).read
        XCTAssertTrue(b1Read)
        XCTAssertEqual(server.progress("b2")?.completed, true)
    }

    func testAPageNeverUndoesFurtherProgressElsewhere() async throws {
        let series = try await openSeries()
        server.set { $0.progress["b1"] = (8, false) }
        await app.sync.pageChanged(series, chapter: try await chapter("b1", in: series), page: 2, pageCount: 10, read: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.progress("b1")?.page, 8)
        XCTAssertTrue(requests("PATCH", "/api/v1/books/b1/read-progress").isEmpty)
    }

    func testHandMarksGoThroughAndUnreadClearsProgress() async throws {
        let series = try await openSeries()
        server.set { $0.progress["b1"] = (10, true) }
        let b1 = try await chapter("b1", in: series)

        await app.sync.readStatusChanged(series, chapters: [b1], read: false)

        XCTAssertNil(server.progress("b1"), "marking unread deletes the read progress")
        XCTAssertEqual(requests("DELETE", "/api/v1/books/b1/read-progress").count, 1)

        await app.sync.readStatusChanged(series, chapters: [b1], read: true)
        XCTAssertEqual(server.progress("b1")?.completed, true)
    }

    func testTheQueueSurvivesFailuresAndIsDeliveredLater() async throws {
        let series = try await openSeries()
        server.set { $0.down = true }
        await app.sync.pageChanged(series, chapter: try await chapter("b2", in: series), page: 3, pageCount: 10, read: false)
        try await Task.sleep(for: .milliseconds(300))
        var queue = try await app.database.syncQueue(engine: KomgaSync.engine)
        XCTAssertEqual(queue.map(\.key), ["b2"])

        server.set { $0.down = false }
        let done = await app.komgaSync.syncQueued()
        XCTAssertTrue(done)
        XCTAssertEqual(server.progress("b2")?.page, 4)
        queue = try await app.database.syncQueue(engine: KomgaSync.engine)
        XCTAssertEqual(queue, [])
    }

    func testKoreaderModeStandsKomgaSyncDown() async throws {
        let series = try await openSeries()
        app.syncSettings.mode = .koreader
        XCTAssertFalse(app.komgaSync.syncs(series))
        app.syncSettings.mode = .source
        XCTAssertTrue(app.komgaSync.syncs(series))
    }
}
