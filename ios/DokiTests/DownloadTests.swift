import GRDB
import Synchronization
import XCTest
@testable import Doki

@MainActor
final class DownloadTests: XCTestCase {
    private var app: AppModel!
    private var root: URL!
    private var defaultsSuite = ""

    override func setUp() async throws {
        defaultsSuite = "app.doki.tests.downloads.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        let settings = KavitaSettings(defaults: defaults, keychainService: "app.doki.tests.downloads")
        settings.serverURL = "https://kavita.test"
        settings.apiKey = "key-1"
        settings.syncProgress = false
        root = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID())")
        app = AppModel(
            settings: settings, session: StubURLProtocol.session(), database: try .inMemory(),
            readerSettings: ReaderSettings(defaults: defaults), downloadStore: DownloadStore(root: root),
            pageFetcher: SessionPageFetcher(session: StubURLProtocol.session())
        )
        StubURLProtocol.reset(Self.server())

        let series = try JSONDecoder().decode(KavitaSeries.self, from: Data(#"{"id": 7, "name": "S", "libraryId": 2}"#.utf8))
        let details = KavitaSeriesDetails(try JSONDecoder().decode(KavitaSeriesMetadata.self, from: Data("{}".utf8)))
        let entries = [(10, 4), (11, 3), (12, 0)].map { id, pages in
            KavitaChapterEntry(
                chapterId: id, volumeId: 1, name: "Ch. \(id)", number: Double(id), pages: pages, pagesRead: 0, dateUpload: nil
            )
        }
        try await app.database.saveSeries(series, details: details, chapters: entries, seedProgress: false)
    }

    override func tearDown() async throws {
        app.settings.apiKey = ""
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

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
                return .json(#"{"id": 12, "pages": 2, "volumeId": 1}"#)
            default:
                return .json("", status: 404)
            }
        }
    }

    private func chapters() async throws -> [ChapterRecord] {
        try await app.database.chapterList(seriesId: 7)
    }

    private func queue() async throws -> [DownloadRecord] {
        try await app.database.writer.read { try DownloadRecord.fetchAll($0) }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func imageRequests() -> [StubURLProtocol.Request] {
        StubURLProtocol.requests.filter { $0.path == "/api/Reader/image" }
    }

    func testDownloadsEveryPageIntoTheChapterFolder() async throws {
        let chapter = try await chapters()[0]
        await app.downloads.download([chapter])
        await app.downloads.waitUntilIdle()

        let files = app.downloads.store.pageFiles(seriesId: 7, chapterId: 10)
        XCTAssertEqual(files.map(\.lastPathComponent), ["000.webp", "001.jpg", "002.webp", "003.jpg"])
        XCTAssertEqual(try String(contentsOf: files[2], encoding: .utf8), "c10p2")
        XCTAssertTrue(imageRequests().allSatisfy { $0.query("apiKey") == "key-1" })
        let stored = try await chapters()[0]
        XCTAssertTrue(stored.isDownloaded)
        let queued = try await queue()
        XCTAssertEqual(queued, [])
        XCTAssertFalse(exists(app.downloads.store.partialDirectory(seriesId: 7, chapterId: 10)))
        let backup = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(backup.isExcludedFromBackup, true)
    }

    func testChaptersDownloadOneAfterAnotherAndUnknownPageCountsAreFetched() async throws {
        await app.downloads.download(try await chapters())
        await app.downloads.waitUntilIdle()

        XCTAssertEqual(app.downloads.store.pageFiles(seriesId: 7, chapterId: 11).count, 3)
        XCTAssertEqual(app.downloads.store.pageFiles(seriesId: 7, chapterId: 12).count, 2, "page count from GET /Chapter")
        let downloaded = try await chapters().map(\.isDownloaded)
        XCTAssertEqual(downloaded, [true, true, true])
    }

    func testAFailedPageFailsTheChapterUntilRetried() async throws {
        StubURLProtocol.reset(Self.server(failing: ["10/2"]))
        await app.downloads.download([try await chapters()[0]])
        await app.downloads.waitUntilIdle()

        var queued = try await queue()
        XCTAssertEqual(queued.map(\.state), [.failed])
        XCTAssertEqual(queued.first?.error, "HTTP 500")
        XCTAssertEqual(app.downloads.store.pageFiles(seriesId: 7, chapterId: 10), [], "never looks complete")
        let notYet = try await chapters()[0].isDownloaded
        XCTAssertFalse(notYet)

        // A retry fetches only the pages that are missing.
        StubURLProtocol.reset(Self.server())
        await app.downloads.retryFailed()
        await app.downloads.waitUntilIdle()

        XCTAssertEqual(app.downloads.store.pageFiles(seriesId: 7, chapterId: 10).count, 4)
        // Page 3 may have been in flight when page 2 failed; pages 0 and 1 were kept.
        let refetched = Set(imageRequests().compactMap { $0.query("page") })
        XCTAssertTrue(refetched.contains("2"))
        XCTAssertTrue(refetched.isSubset(of: ["2", "3"]), "\(refetched)")
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
        try await Task.sleep(for: .milliseconds(100))

        await app.downloads.cancel([(7, 10)])
        await app.downloads.waitUntilIdle()

        let queued = try await queue()
        XCTAssertEqual(queued, [])
        XCTAssertFalse(exists(app.downloads.store.partialDirectory(seriesId: 7, chapterId: 10)))
        XCTAssertEqual(app.downloads.store.pageFiles(seriesId: 7, chapterId: 10), [])
    }

    func testDeletingAllOrOnlyReadChapters() async throws {
        await app.downloads.download(try await chapters())
        await app.downloads.waitUntilIdle()
        try await app.database.setChaptersRead([11], read: true)

        await app.downloads.deleteSeries(7, readOnly: true)
        var downloaded = try await chapters().map(\.isDownloaded)
        XCTAssertEqual(downloaded, [true, false, true])
        XCTAssertEqual(app.downloads.store.pageFiles(seriesId: 7, chapterId: 11), [])

        await app.downloads.deleteSeries(7)
        downloaded = try await chapters().map(\.isDownloaded)
        XCTAssertEqual(downloaded, [false, false, false])
        XCTAssertFalse(exists(app.downloads.store.seriesDirectory(7)))
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
        try await app.database.updateDownload(11) { $0.state = .downloading }

        await app.downloads.resume()
        await app.downloads.waitUntilIdle()

        XCTAssertEqual(app.downloads.store.pageFiles(seriesId: 7, chapterId: 11).count, 3)
    }

    func testTheReaderUsesDownloadedPagesWithoutTheServer() async throws {
        await app.downloads.download([try await chapters()[0]])
        await app.downloads.waitUntilIdle()
        StubURLProtocol.reset { _ in throw URLError(.notConnectedToInternet) }
        try await app.database.writer.write { try $0.execute(sql: "UPDATE chapter SET pages = 0 WHERE id = 10") }

        let chapters = try await chapters()
        let reader = ReaderModel(app: app, seriesId: 7, seriesName: "S", readerMode: nil, chapters: chapters, start: chapters[0])
        await reader.prepare()

        XCTAssertNil(reader.loadError)
        XCTAssertEqual(reader.pageCount, 4, "counted from the files")
        XCTAssertEqual(reader.pageURL(1)?.isFileURL, true)
        XCTAssertEqual(reader.pageURL(1)?.lastPathComponent, "001.jpg")
        XCTAssertTrue(reader.isDownloaded)
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
