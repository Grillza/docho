import GRDB
import Synchronization
import XCTest
@testable import Docho

@MainActor
final class DownloadTests: XCTestCase {
    private var app: AppModel!
    private var defaults: UserDefaults!
    private var root: URL!
    private var series: SeriesRecord!
    /// Local chapter ids of Kavita chapters 10, 11 and 12.
    private var ids: [Int] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID())")
        let parts = try TestApp.make("downloads", downloadStore: DownloadStore(root: root))
        app = parts.app
        defaults = parts.defaults
        app.settings.syncProgress = false
        StubURLProtocol.reset(Self.server())
        series = try await app.seedKavitaSeries(chapters: [(10, 4), (11, 3), (12, 0)])
        ids = try await chapters().map(\.id)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    nonisolated private static let pageCounts = ["10": 4, "11": 3, "12": 2]

    /// Pages are "c<chapter>p<page>"; even pages are webp, odd ones jpeg. `failing` pages answer 500.
    private nonisolated static func server(failing: Set<String> = []) -> StubURLProtocol.Handler {
        { request in
            switch request.path {
            case let path where path.hasSuffix("/Plugin/authenticate"):
                return .json(#"{"username": "u", "token": "t"}"#)
            case "/api/Reader/image":
                let chapter = request.query("chapterId") ?? "?"
                let page = Int(request.query("page") ?? "") ?? 0
                if failing.contains("\(chapter)/\(page)") { return .json("", status: 500) }
                let type = page.isMultiple(of: 2) ? "image/webp" : "image/jpeg"
                return StubURLProtocol.Response(headers: ["Content-Type": type], body: Data("c\(chapter)p\(page)".utf8))
            case "/api/Chapter":
                let id = request.query("chapterId") ?? "0"
                return .json(#"{"id": \#(id), "pages": \#(pageCounts[id] ?? 0), "volumeId": 1}"#)
            default:
                return .json("", status: 404)
            }
        }
    }

    private func chapters() async throws -> [ChapterRecord] {
        try await app.database.chapterList(seriesId: series.id)
    }

    private func queue() async throws -> [DownloadRecord] {
        try await app.database.writer.read { try DownloadRecord.fetchAll($0) }
    }

    private func files(_ index: Int) -> [URL] {
        app.downloads.store.pageFiles(seriesId: series.id, chapterId: ids[index])
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func imageRequests() -> [StubURLProtocol.Request] {
        StubURLProtocol.requests.filter { $0.path == "/api/Reader/image" }
    }

    func testDownloadsEveryPageIntoTheChapterFolder() async throws {
        await app.downloads.download([try await chapters()[0]])
        await app.downloads.waitUntilIdle()

        let files = files(0)
        XCTAssertEqual(files.map(\.lastPathComponent), ["000.webp", "001.jpg", "002.webp", "003.jpg"])
        XCTAssertEqual(try String(contentsOf: files[2], encoding: .utf8), "c10p2")
        XCTAssertTrue(imageRequests().allSatisfy { $0.query("apiKey") == "key-1" })
        let stored = try await chapters()[0]
        XCTAssertTrue(stored.isDownloaded)
        let queued = try await queue()
        XCTAssertEqual(queued, [])
        XCTAssertFalse(exists(app.downloads.store.partialDirectory(seriesId: series.id, chapterId: ids[0])))
        let backup = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(backup.isExcludedFromBackup, true)
    }

    func testChaptersDownloadOneAfterAnotherWithPageListsFromTheSource() async throws {
        await app.downloads.download(try await chapters())
        await app.downloads.waitUntilIdle()

        XCTAssertEqual(files(1).count, 3)
        XCTAssertEqual(files(2).count, 2, "page count from the source's page list")
        let stored = try await chapters()
        XCTAssertEqual(stored.map(\.isDownloaded), [true, true, true])
        XCTAssertEqual(stored[2].pages, 2, "the page count learned is stored")
    }

    func testAFailedPageFailsTheChapterUntilRetried() async throws {
        StubURLProtocol.reset(Self.server(failing: ["10/2"]))
        await app.downloads.download([try await chapters()[0]])
        await app.downloads.waitUntilIdle()

        var queued = try await queue()
        XCTAssertEqual(queued.map(\.state), [.failed])
        XCTAssertEqual(queued.first?.error, "HTTP 500")
        XCTAssertEqual(files(0), [], "never looks complete")
        let notYet = try await chapters()[0].isDownloaded
        XCTAssertFalse(notYet)

        // A retry fetches only the pages that are missing.
        let partial = app.downloads.store.partialDirectory(seriesId: series.id, chapterId: ids[0])
        let kept = Set(app.downloads.store.pages(in: partial).keys.map(String.init))
        StubURLProtocol.reset(Self.server())
        await app.downloads.retryFailed()
        await app.downloads.waitUntilIdle()

        XCTAssertEqual(files(0).count, 4)
        // Pages stored before the failure are kept; only the rest are fetched again.
        let refetched = Set(imageRequests().compactMap { $0.query("page") })
        XCTAssertTrue(refetched.contains("2"))
        XCTAssertTrue(refetched.isDisjoint(with: kept), "refetched \(refetched), kept \(kept)")
        queued = try await queue()
        XCTAssertEqual(queued, [])
    }

    func testCancellingRemovesTheChapterFromTheQueueAndItsPartialPages() async throws {
        let gate = Mutex(true)
        StubURLProtocol.reset { request in
            if request.path == "/api/Reader/image", gate.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.3) }
            return try Self.server()(request)
        }
        await app.downloads.download([try await chapters()[0]])
        try await Task.sleep(for: .milliseconds(150))

        await app.downloads.cancel([(series.id, ids[0])])
        await app.downloads.waitUntilIdle()

        let queued = try await queue()
        XCTAssertEqual(queued, [])
        XCTAssertFalse(exists(app.downloads.store.partialDirectory(seriesId: series.id, chapterId: ids[0])))
        XCTAssertEqual(files(0), [])
    }

    /// Part A: pausing finishes the pages in flight, starts no more, and survives a relaunch.
    func testPausingKeepsTheQueueAndResumingFinishesIt() async throws {
        StubURLProtocol.reset { request in
            if request.path == "/api/Reader/image" { Thread.sleep(forTimeInterval: 0.1) }
            return try Self.server()(request)
        }
        await app.downloads.download(try await chapters())
        try await Task.sleep(for: .milliseconds(60))
        await app.downloads.setPaused(true)

        var queued = try await queue()
        XCTAssertEqual(queued.count, 3, "nothing is dropped")
        XCTAssertTrue(queued.allSatisfy { $0.state == .queued }, "\(queued.map(\.state))")
        XCTAssertTrue(DownloadPreferences.current(defaults).paused, "kept across launches")
        let requestsWhilePaused = imageRequests().count
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(imageRequests().count, requestsWhilePaused, "no new pages while paused")

        // A relaunch doesn't start a paused queue.
        await app.downloads.resume()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(imageRequests().count, requestsWhilePaused)

        await app.downloads.setPaused(false)
        await app.downloads.waitUntilIdle()
        queued = try await queue()
        XCTAssertEqual(queued, [])
        XCTAssertEqual(files(0).count, 4)
        XCTAssertEqual(imageRequests().filter { $0.query("chapterId") == "10" }.count, 4, "pages kept from before the pause")
    }

    func testDeletingAllOrOnlyReadChapters() async throws {
        await app.downloads.download(try await chapters())
        await app.downloads.waitUntilIdle()
        try await app.database.setChaptersRead([ids[1]], read: true)

        await app.downloads.deleteSeries(series.id, readOnly: true)
        var downloaded = try await chapters().map(\.isDownloaded)
        XCTAssertEqual(downloaded, [true, false, true])
        XCTAssertEqual(files(1), [])

        await app.downloads.deleteSeries(series.id)
        downloaded = try await chapters().map(\.isDownloaded)
        XCTAssertEqual(downloaded, [false, false, false])
        XCTAssertFalse(exists(app.downloads.store.seriesDirectory(series.id)))
    }

    func testQueueingSkipsChaptersAlreadyDownloadedOrQueued() async throws {
        var chapters = try await chapters()
        let added = try await app.database.queueDownloads(chapters)
        XCTAssertEqual(added, 3)
        chapters[0].isDownloaded = true
        let again = try await app.database.queueDownloads(chapters)
        XCTAssertEqual(again, 0)
    }

    func testAnInterruptedDownloadIsResumedOnLaunch() async throws {
        try await app.database.queueDownloads([try await chapters()[1]])
        try await app.database.updateDownload(ids[1]) { $0.state = .downloading }

        await app.downloads.resume()
        await app.downloads.waitUntilIdle()

        XCTAssertEqual(files(1).count, 3)
    }

    func testTheReaderUsesDownloadedPagesWithoutTheServer() async throws {
        await app.downloads.download([try await chapters()[0]])
        await app.downloads.waitUntilIdle()
        StubURLProtocol.reset { _ in throw URLError(.notConnectedToInternet) }
        try await app.database.writer.write { try $0.execute(sql: "UPDATE chapter SET pages = 0") }

        let chapters = try await chapters()
        let reader = ReaderModel(app: app, series: series, chapters: chapters, start: chapters[0])
        await reader.prepare()

        XCTAssertNil(reader.loadError)
        XCTAssertEqual(reader.pageCount, 4, "counted from the files")
        XCTAssertEqual(reader.pageRequest(1)?.url?.isFileURL, true)
        XCTAssertEqual(reader.pageRequest(1)?.url?.lastPathComponent, "001.jpg")
        XCTAssertTrue(reader.isDownloaded)
    }

    /// Part A: what the download bar shows for the queue.
    func testDownloadBarState() async throws {
        XCTAssertNil(DownloadBarState(queue: [], paused: false))

        try await app.database.queueDownloads(try await chapters())
        try await app.database.updateDownload(ids[0]) { $0.state = .downloading; $0.pagesDone = 1; $0.pagesTotal = 4 }
        var queue: [DownloadQueueItem] = []
        for try await items in app.database.downloadQueue() {
            queue = items
            break
        }

        let downloading = try XCTUnwrap(DownloadBarState(queue: queue, paused: false))
        XCTAssertEqual(downloading.title, "S - Ch. 10")
        XCTAssertEqual(downloading.subtitle, "Page 1 of 4 • +2 queued")
        XCTAssertEqual(downloading.progress, 0.25)

        let paused = try XCTUnwrap(DownloadBarState(queue: queue, paused: true))
        XCTAssertEqual(paused.subtitle, "Paused • +2 queued")
        XCTAssertTrue(paused.paused)

        try await app.database.updateDownload(ids[0]) { $0.state = .failed }
        for try await items in app.database.downloadQueue() {
            queue = items
            break
        }
        XCTAssertEqual(DownloadBarState(queue: queue, paused: false)?.subtitle, "Waiting • +2 queued", "the next chapter waiting is shown")
    }

    func testFileExtensionsFollowTheContentType() {
        XCTAssertEqual(DownloadStore.fileExtension(mimeType: "image/webp"), "webp")
        XCTAssertEqual(DownloadStore.fileExtension(mimeType: "image/jpeg"), "jpg")
        XCTAssertEqual(DownloadStore.fileExtension(mimeType: "image/png; charset=binary"), "png")
        XCTAssertEqual(DownloadStore.fileExtension(mimeType: "image/avif"), "avif")
        XCTAssertEqual(DownloadStore.fileExtension(mimeType: "application/json"), "jpg")
        XCTAssertEqual(DownloadStore.fileExtension(mimeType: nil), "jpg")
    }
}
