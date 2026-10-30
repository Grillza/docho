import XCTest
@testable import Doki

/// The milestone 6 acceptance checks against a real Kavita server, with "another device" played
/// by direct API calls. Skipped unless `TEST_RUNNER_KAVITA_LIVE_URL` and `…_KEY` are set. The
/// chapter's server progress is put back afterwards.
@MainActor
final class KavitaSyncLiveTests: XCTestCase {
    private var app: AppModel!
    private var other: KavitaClient!
    private var serverURL = ""
    private var defaultsSuite = ""

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["KAVITA_LIVE_URL"], let key = env["KAVITA_LIVE_KEY"] else {
            throw XCTSkip("Set KAVITA_LIVE_URL and KAVITA_LIVE_KEY to run against a real server")
        }
        serverURL = url
        defaultsSuite = "app.doki.tests.synclive.\(UUID())"
        let settings = KavitaSettings(
            defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuite)), keychainService: "app.doki.tests.synclive"
        )
        settings.serverURL = url
        settings.apiKey = key
        app = AppModel(settings: settings, database: try .inMemory(), pageDebounce: .milliseconds(50))
        let credentials = TestCredentials(serverURL: url, apiKey: key)
        other = KavitaClient { credentials.current }
    }

    override func tearDown() async throws {
        app?.settings.apiKey = ""
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    // swiftlint:disable:next function_body_length
    func testProgressMovesBetweenDevicesAndIsNeverUndone() async throws {
        // A series with a chapter long enough to move around in.
        let filter = KavitaBrowseRequest().filter
        let page = try await other.seriesPage(filter: filter, page: 1)
        var found: (series: KavitaSeries, chapter: KavitaChapter)?
        for series in page.series.prefix(10) {
            let volumes = try await other.volumes(seriesId: series.id)
            if let chapter = volumes.flatMap(\.chapters).first(where: { $0.pages >= 12 }) {
                found = (series, chapter)
                break
            }
        }
        let (series, chapter) = try XCTUnwrap(found, "no chapter with 12+ pages")
        let original = try await other.pagesRead(seriesId: series.id, chapterId: chapter.id)
        let progress = { @Sendable (page: Int) in
            KavitaProgress(
                volumeId: chapter.volumeId, chapterId: chapter.id, pageNum: page, seriesId: series.id, libraryId: series.libraryId
            )
        }
        addTeardownBlock { [other] in
            try? await other!.setChaptersRead(seriesId: series.id, chapterIds: [chapter.id], read: false)
            if original > 0 { try? await other!.saveProgress(progress(original)) }
        }
        print("live sync: series \(series.id) chapter \(chapter.id), \(chapter.pages) pages, was at \(original)")

        // 1. Read on another device, open the series here → this device shows that page.
        try await other.setChaptersRead(seriesId: series.id, chapterIds: [chapter.id], read: false)
        try await other.saveProgress(progress(3))
        await SeriesModel(app: app, seriesId: series.id).refresh()
        var local = try await stored(chapter.id)
        XCTAssertEqual(local.lastPageRead, 3)

        // 2. Read further here while offline; back online → the server gets this page.
        app.settings.serverURL = "http://127.0.0.1:9"
        try await app.database.saveProgress(chapterId: chapter.id, lastPageRead: 6, read: false)
        await app.sync.pageChanged(local, page: 6, pageCount: chapter.pages, read: false)
        let queued = await eventually { (try? await self.app.database.pendingProgress().first?.pageNum) == 6 }
        XCTAssertTrue(queued, "not queued while offline")
        try await Task.sleep(for: .milliseconds(300)) // let the failed delivery finish
        var stillQueued = try await app.database.pendingProgress()
        XCTAssertEqual(stillQueued.count, 1)

        app.settings.serverURL = serverURL
        let delivered = await app.sync.syncQueued()
        XCTAssertTrue(delivered)
        let onServer = try await other.pagesRead(seriesId: series.id, chapterId: chapter.id)
        XCTAssertEqual(onServer, 6)

        // 3. Meanwhile the other device reads further; a smaller page queued here never undoes it.
        try await other.saveProgress(progress(10))
        app.settings.serverURL = "http://127.0.0.1:9"
        local = try await stored(chapter.id)
        await app.sync.pageChanged(local, page: 7, pageCount: chapter.pages, read: false)
        try await app.database.saveProgress(chapterId: chapter.id, lastPageRead: 7, read: false)
        _ = await eventually { (try? await self.app.database.pendingProgress().first?.pageNum) == 7 }
        try await Task.sleep(for: .milliseconds(300))
        app.settings.serverURL = serverURL
        await app.sync.syncQueued()

        let kept = try await other.pagesRead(seriesId: series.id, chapterId: chapter.id)
        XCTAssertEqual(kept, 10, "the other device's progress was undone")
        await app.sync.syncSeries(series.id)
        local = try await stored(chapter.id)
        XCTAssertEqual(local.lastPageRead, 10, "the further page wasn't pulled")
        stillQueued = try await app.database.pendingProgress()
        XCTAssertEqual(stillQueued, [])
    }

    private func stored(_ chapterId: Int) async throws -> ChapterRecord {
        let chapters = try await app.database.chapters(ids: [chapterId])
        return try XCTUnwrap(chapters.first)
    }

    private func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }
}
