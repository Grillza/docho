import GRDB
import Synchronization
import XCTest
@testable import Docho

/// A Kavita server holding one series (7) with 20-page chapters, for the sync engine tests.
private final class FakeKavita: Sendable {
    struct State {
        var pagesRead: [Int: Int] = [:]
        var down = false
        var getProgressMissing = false
        var refuseTokenOnce = false
    }

    let chapterIds: [Int]
    let pages = 20
    let state = Mutex(State())

    init(chapterIds: [Int]) {
        self.chapterIds = chapterIds
    }

    func set(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    func pagesRead(_ chapterId: Int) -> Int {
        state.withLock { $0.pagesRead[chapterId] ?? 0 }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func handle(_ request: StubURLProtocol.Request) throws -> StubURLProtocol.Response {
        if request.path.hasSuffix("/Plugin/authenticate") {
            return .json(#"{"username": "u", "token": "t"}"#)
        }
        return try state.withLock { state in
            if state.down { return .json("", status: 500) }
            if state.refuseTokenOnce {
                state.refuseTokenOnce = false
                return .json("", status: 401)
            }
            switch (request.method, request.path) {
            case ("GET", "/api/Series/volumes"):
                let chapters = chapterIds.map { id in
                    #"{"id": \#(id), "minNumber": \#(id), "number": "\#(id)", "range": "\#(id)", "#
                        + #""pages": \#(pages), "pagesRead": \#(state.pagesRead[id] ?? 0), "volumeId": 1}"#
                }
                return .json(#"[{"id": 1, "minNumber": 1, "name": "1", "chapters": [\#(chapters.joined(separator: ","))]}]"#)
            case ("GET", "/api/Reader/get-progress"):
                if state.getProgressMissing { return .json("", status: 404) }
                let id = Int(request.query("chapterId") ?? "") ?? 0
                return .json(#"{"pageNum": \#(state.pagesRead[id] ?? 0)}"#)
            case ("POST", "/api/Reader/progress"):
                let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Int] ?? [:]
                state.pagesRead[body["chapterId"] ?? 0] = body["pageNum"]
                return .json("")
            case ("POST", "/api/Reader/mark-multiple-read"), ("POST", "/api/Reader/mark-multiple-unread"):
                let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:]
                let read = request.path.hasSuffix("-read")
                for id in body["chapterIds"] as? [Int] ?? [] {
                    state.pagesRead[id] = read ? pages : 0
                }
                return .json("")
            case ("GET", "/api/Chapter"):
                return .json(#"{"id": \#(request.query("chapterId") ?? "0"), "pages": \#(pages), "volumeId": 1}"#)
            default:
                return .json("", status: 404)
            }
        }
    }
}

/// Engine tests for `KavitaSync` against a fake server.
@MainActor
// swiftlint:disable:next type_body_length
final class KavitaSyncTests: XCTestCase {
    private var app: AppModel!
    private var server: FakeKavita!
    private var defaultsSuite = ""

    override func setUp() async throws {
        defaultsSuite = "io.github.grillza.docho.tests.sync.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        let settings = KavitaSettings(defaults: defaults, keychainService: "io.github.grillza.docho.tests.sync")
        settings.serverURL = "https://kavita.test"
        settings.apiKey = "key-1"
        app = AppModel(
            settings: settings, session: StubURLProtocol.session(), database: try .inMemory(), pageDebounce: .milliseconds(50)
        )
        let server = FakeKavita(chapterIds: [10, 11, 12, 13])
        self.server = server
        StubURLProtocol.reset { try server.handle($0) }

        let series = try JSONDecoder().decode(KavitaSeries.self, from: Data(#"{"id": 7, "name": "S", "libraryId": 2}"#.utf8))
        let details = KavitaSeriesDetails(try JSONDecoder().decode(KavitaSeriesMetadata.self, from: Data("{}".utf8)))
        let entries = server.chapterIds.map { id in
            KavitaChapterEntry(
                chapterId: id, volumeId: 1, name: "Ch. \(id)", number: Double(id), pages: 20, pagesRead: 0, dateUpload: nil
            )
        }
        try await app.database.saveSeries(series, details: details, chapters: entries, seedProgress: false)
    }

    override func tearDown() async throws {
        app.settings.apiKey = ""
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    // MARK: Helpers

    private func chapter(_ id: Int) async throws -> ChapterRecord {
        let chapters = try await app.database.chapters(ids: [id])
        return try XCTUnwrap(chapters.first)
    }

    private func setLocal(_ id: Int, read: Bool, page: Int) async throws {
        try await app.database.writer.write { db in
            try db.execute(sql: "UPDATE chapter SET read = ?, lastPageRead = ? WHERE id = ?", arguments: [read, page, id])
        }
    }

    private func queue() async throws -> [PendingProgress] {
        try await app.database.pendingProgress()
    }

    private func requests(_ path: String) -> [StubURLProtocol.Request] {
        StubURLProtocol.requests.filter { $0.path == path }
    }

    private func progressSent() throws -> [[String: Int]] {
        try requests("/api/Reader/progress").map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: Int]) }
    }

    private func eventually(timeout: Duration = .seconds(3), _ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return try await condition()
    }

    private func retryRequested() async -> Bool {
        let stream = app.sync.retryRequests
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await stream.first { _ in true } != nil }
            group.addTask { try? await Task.sleep(for: .milliseconds(500)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: Push

    func testPageTurnsAreDebouncedAndOnlyTheLastPageIsSent() async throws {
        let chapter = try await chapter(10)
        for page in 1...5 {
            await app.sync.pageChanged(chapter, page: page, pageCount: 20, read: false)
        }
        let delivered = await eventually { server.pagesRead(10) == 5 }
        XCTAssertTrue(delivered)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(try progressSent(), [["volumeId": 1, "chapterId": 10, "pageNum": 5, "seriesId": 7, "libraryId": 2]])
        let queued = try await queue()
        XCTAssertEqual(queued, [])
    }

    func testFinishingAChapterSendsItsPageCount() async throws {
        await app.sync.pageChanged(try await chapter(10), page: 19, pageCount: 20, read: true)
        let delivered = await eventually { server.pagesRead(10) == 20 }
        XCTAssertTrue(delivered)
    }

    func testAPageTheServerHasPassedIsDroppedNotSent() async throws {
        server.set { $0.pagesRead[10] = 15 }
        await app.sync.pageChanged(try await chapter(10), page: 5, pageCount: 20, read: false)

        let asked = await eventually { !requests("/api/Reader/get-progress").isEmpty }
        XCTAssertTrue(asked)
        let emptied = try await eventually { try await queue().isEmpty }
        XCTAssertTrue(emptied)
        XCTAssertEqual(try progressSent(), [])
        XCTAssertEqual(server.pagesRead(10), 15)
    }

    func testOlderServersWithoutGetProgressAreAskedThroughTheVolumes() async throws {
        server.set { $0.getProgressMissing = true; $0.pagesRead[10] = 3 }
        await app.sync.pageChanged(try await chapter(10), page: 8, pageCount: 20, read: false)

        let delivered = await eventually { server.pagesRead(10) == 8 }
        XCTAssertTrue(delivered)
        XCTAssertFalse(requests("/api/Series/volumes").isEmpty)
    }

    func testTheQueueSurvivesAFailedRequest() async throws {
        server.set { $0.down = true }
        await app.sync.pageChanged(try await chapter(10), page: 4, pageCount: 20, read: false)

        let retried = await retryRequested()
        XCTAssertTrue(retried)
        var queued = try await queue()
        XCTAssertEqual(queued.map(\.pageNum), [4])

        server.set { $0.down = false }
        let done = await app.sync.syncQueued()
        XCTAssertTrue(done)
        XCTAssertEqual(server.pagesRead(10), 4)
        queued = try await queue()
        XCTAssertEqual(queued, [])
    }

    func testFlushingStopsAtTheFirstFailure() async throws {
        let progress = [10, 11].map { KavitaProgress(volumeId: 1, chapterId: $0, pageNum: 3, seriesId: 99, libraryId: 2) }
        _ = try await app.database.enqueue(progress, markedByUser: false)
        server.set { $0.down = true }

        let done = await app.sync.syncQueued()

        XCTAssertFalse(done)
        XCTAssertEqual(requests("/api/Reader/get-progress").count, 1, "the second entry wasn't tried")
        let queued = try await queue()
        XCTAssertEqual(queued.count, 2)
    }

    func testSigningInAgainOn401StillDelivers() async throws {
        await app.kavita.checkConnection() // signed in
        server.set { $0.refuseTokenOnce = true }
        await app.sync.pageChanged(try await chapter(10), page: 6, pageCount: 20, read: false)
        let delivered = await eventually { server.pagesRead(10) == 6 }
        XCTAssertTrue(delivered)
    }

    func testNothingIsSentWhenSyncIsOff() async throws {
        app.settings.syncProgress = false
        await app.sync.pageChanged(try await chapter(10), page: 6, pageCount: 20, read: false)
        await app.sync.syncSeries(7)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    // MARK: Hand marks

    func testHandMarksAreSentAsIsInOneRequest() async throws {
        server.set { $0.pagesRead[10] = 20; $0.pagesRead[11] = 20 }
        let model = SeriesModel(app: app, seriesId: 7)

        await model.setRead([10, 11], false)

        let marks = requests("/api/Reader/mark-multiple-unread")
        XCTAssertEqual(marks.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: marks[0].body) as? [String: Any])
        XCTAssertEqual(body["seriesId"] as? Int, 7)
        XCTAssertEqual(Set(body["chapterIds"] as? [Int] ?? []), [10, 11])
        XCTAssertEqual(body["volumeIds"] as? [Int], [])
        XCTAssertEqual(server.pagesRead(10), 0)
        let queued = try await queue()
        XCTAssertEqual(queued, [])
    }

    func testAHandMarkThatFailsStaysQueuedAndWinsLater() async throws {
        server.set { $0.pagesRead[10] = 20; $0.down = true }
        try await setLocal(10, read: true, page: 0)
        let model = SeriesModel(app: app, seriesId: 7)

        await model.setRead([10], false)
        try await setLocal(10, read: false, page: 2) // as the reader would
        var queued = try await queue()
        XCTAssertEqual(queued.map(\.markedByUser), [true])

        // Reading on keeps the mark's priority; the server still says read (another device).
        await app.sync.pageChanged(try await chapter(10), page: 2, pageCount: 20, read: false)
        let merged = try await eventually { try await queue().first?.pageNum == 2 }
        XCTAssertTrue(merged)
        queued = try await queue()
        XCTAssertEqual(queued.map(\.markedByUser), [true])

        server.set { $0.down = false }
        await app.sync.syncSeries(7)

        XCTAssertEqual(server.pagesRead(10), 2)
        let local = try await chapter(10)
        XCTAssertFalse(local.read)
        XCTAssertEqual(local.lastPageRead, 2)
        queued = try await queue()
        XCTAssertEqual(queued, [])
    }

    // MARK: Pull

    func testReconcilingAppliesTheFourRules() async throws {
        // 10: read here, not there → pushed as read.   11: read there → read here.
        // 12: further there → page pulled.             13: further here → page pushed.
        try await setLocal(10, read: true, page: 0)
        try await setLocal(11, read: false, page: 2)
        try await setLocal(12, read: false, page: 3)
        try await setLocal(13, read: false, page: 9)
        server.set { $0.pagesRead = [10: 5, 11: 20, 12: 8, 13: 4] }

        await app.sync.syncSeries(7)

        let read = requests("/api/Reader/mark-multiple-read")
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(server.pagesRead(10), 20)
        let eleven = try await chapter(11)
        XCTAssertTrue(eleven.read)
        let twelve = try await chapter(12)
        XCTAssertEqual(twelve.lastPageRead, 8)
        XCTAssertFalse(twelve.read)
        XCTAssertEqual(try progressSent().map { $0["chapterId"] }, [13])
        XCTAssertEqual(server.pagesRead(13), 9)
        let queued = try await queue()
        XCTAssertEqual(queued, [])
    }

    func testAPushedPageNeverMarksTheChapterRead() async throws {
        try await setLocal(10, read: false, page: 25)
        await app.sync.syncSeries(7)
        XCTAssertEqual(server.pagesRead(10), 19, "clamped to the last page index")
    }

    func testQueuedChangesAreDeliveredBeforeComparing() async throws {
        try await setLocal(10, read: false, page: 6)
        let progress = KavitaProgress(volumeId: 1, chapterId: 10, pageNum: 6, seriesId: 7, libraryId: 2)
        _ = try await app.database.enqueue([progress], markedByUser: false)
        server.set { $0.pagesRead[10] = 2 }

        await app.sync.syncSeries(7)

        XCTAssertEqual(try progressSent().count, 1, "sent once, from the queue")
        XCTAssertTrue(requests("/api/Reader/get-progress").isEmpty, "judged against the volumes just fetched")
        XCTAssertEqual(server.pagesRead(10), 6)
    }

    func testAFailedPushStaysQueued() async throws {
        try await setLocal(13, read: false, page: 9)
        server.set { $0.pagesRead[13] = 4 }
        let server = try XCTUnwrap(server)
        StubURLProtocol.reset { request in
            request.path == "/api/Reader/progress" ? .json("", status: 503) : try server.handle(request)
        }

        await app.sync.syncSeries(7)

        let queued = try await queue()
        XCTAssertEqual(queued.map(\.chapterId), [13])
        let retried = await retryRequested()
        XCTAssertTrue(retried)
    }

    func testLibrarySyncCoversTheLibrarySeries() async throws {
        try await app.database.setInLibrary(seriesId: 7, true)
        server.set { $0.pagesRead[12] = 8 }

        let count = await app.sync.syncLibrary()

        XCTAssertEqual(count, 1)
        let twelve = try await chapter(12)
        XCTAssertEqual(twelve.lastPageRead, 8)
    }

    func testTheReaderOpensAtThePageReachedOnAnotherDevice() async throws {
        server.set { $0.pagesRead[10] = 7 }
        let chapters = try await app.database.chapterList(seriesId: 7)
        let reader = ReaderModel(app: app, seriesId: 7, seriesName: "S", readerMode: nil, chapters: chapters, start: chapters[0])
        XCTAssertEqual(reader.page, 0)

        await reader.prepare()

        XCTAssertTrue(reader.isReady)
        XCTAssertEqual(reader.page, 7)
    }

    func testTheReaderOpensWithLocalProgressWhenThePullIsSlow() async throws {
        // Both sides agree, so the pull that carries on after the test sends nothing.
        try await setLocal(10, read: false, page: 3)
        server.set { $0.pagesRead[10] = 3 }
        let server = try XCTUnwrap(server)
        StubURLProtocol.reset { request in
            if request.path == "/api/Series/volumes" { Thread.sleep(forTimeInterval: 1) }
            return try server.handle(request)
        }
        let chapters = try await app.database.chapterList(seriesId: 7)
        let reader = ReaderModel(app: app, seriesId: 7, seriesName: "S", readerMode: nil, chapters: chapters, start: chapters[0])

        let start = ContinuousClock.now
        await reader.prepare(timeout: .milliseconds(200))

        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(900))
        XCTAssertEqual(reader.page, 3)
    }
}
