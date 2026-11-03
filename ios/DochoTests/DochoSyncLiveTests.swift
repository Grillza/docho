import XCTest
@testable import Docho

/// Devices syncing through a real Dōchō Server. Runs when `DOCHO_SYNC_TEST_URL` points at one with
/// no login (its jar from `server/`, run with a fresh data folder).
@MainActor
final class DochoSyncLiveTests: XCTestCase {
    private struct Device {
        let database: AppDatabase
        let renames: ChapterRenames
        let edits: SeriesEdits
        let sync: DochoSync
    }

    /// Every test syncs as the server's one account, so each uses its own series and chapters.
    private let seriesURL = "/series/\(UUID().uuidString.prefix(8))"
    private var c1: String { "\(seriesURL)/c/1" }
    private var c2: String { "\(seriesURL)/c/2" }

    private func device(_ name: String, url: String) throws -> Device {
        let suite = "docho-sync-test-\(name)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let server = SuwayomiSettings(store: ServerSettings(prefix: "suwayomi", defaults: defaults, keychainService: suite))
        server.serverURL = url
        let settings = DochoSyncSettings(store: ServerSettings(prefix: "docho_sync", defaults: defaults, keychainService: suite), server: server)
        let database = try AppDatabase.inMemory()
        let renames = ChapterRenames(defaults: defaults)
        let edits = SeriesEdits(defaults: defaults)
        let client = DochoSyncClient(settings: settings, session: .shared)
        let sync = DochoSync(
            settings: settings, client: client, database: database, renames: renames, seriesEdits: edits,
            stateURL: FileManager.default.temporaryDirectory.appending(path: "\(suite).json")
        ) { _ in }
        return Device(database: database, renames: renames, edits: edits, sync: sync)
    }

    private func addSeries(_ device: Device, chapters: [String]) async throws -> SeriesRecord {
        let series = try await device.database.localSeries(source: KavitaSource.id, manga: SManga(url: seriesURL, title: "Kaiju No. 8"))
        try await device.database.setInLibrary(seriesId: series.id, true)
        if !chapters.isEmpty {
            _ = try await device.database.saveFromSource(
                seriesId: series.id, manga: nil, chapters: chapters.map { SChapter(url: $0, name: $0) }
            )
        }
        return series
    }

    func testTwoDevicesShareLibraryReadStateAndRenames() async throws {
        guard let url = ProcessInfo.processInfo.environment["DOCHO_SYNC_TEST_URL"] else { throw XCTSkip("No test server") }
        let a = try device("a", url: url)
        let b = try device("b", url: url)

        // A has a series with one chapter read and one renamed, and makes the account
        let seriesA = try await addSeries(a, chapters: [c1, c2])
        let chaptersA = try await a.database.chapterList(seriesId: seriesA.id)
        let first = try XCTUnwrap(chaptersA.first { $0.url == c1 })
        try await a.database.setChaptersRead([first.id], read: true)
        a.renames.put(source: KavitaSource.id, oldURL: c2, newURL: c2, .init(name: "Vol. 2", number: 2, original: "c2", at: 1))
        guard case .done = await a.sync.sync() else { return XCTFail("a first sync") }

        // B starts empty: it gets the series, and the chapter states once its chapters arrive
        guard case .done = await b.sync.sync() else { return XCTFail("b first sync") }
        let libraryB = try await b.database.librarySeriesRecords()
        let seriesB = try XCTUnwrap(libraryB.first { $0.url == seriesURL })
        XCTAssertEqual(b.renames.renames["\(KavitaSource.id)|\(c2)"]?.name, "Vol. 2")
        _ = try await b.database.saveFromSource(seriesId: seriesB.id, manga: nil, chapters: [c1, c2].map { SChapter(url: $0, name: $0) })
        guard case .done = await b.sync.sync() else { return XCTFail("b second sync") }
        let chaptersB = try await b.database.chapterList(seriesId: seriesB.id)
        XCTAssertEqual(chaptersB.first { $0.url == c1 }?.read, true)
        XCTAssertEqual(chaptersB.first { $0.url == c2 }?.read, false)

        // B marks the first unread and reads the second; A picks both up
        let b1 = try XCTUnwrap(chaptersB.first { $0.url == c1 })
        let b2 = try XCTUnwrap(chaptersB.first { $0.url == c2 })
        try await b.database.setChaptersRead([b1.id], read: false)
        try await b.database.setChaptersRead([b2.id], read: true)
        guard case .done(let sent, _) = await b.sync.sync() else { return XCTFail("b third sync") }
        XCTAssertGreaterThanOrEqual(sent, 2)
        guard case .done = await a.sync.sync() else { return XCTFail("a second sync") }
        let after = try await a.database.chapterList(seriesId: seriesA.id)
        XCTAssertEqual(after.first { $0.url == c1 }?.read, false)
        XCTAssertEqual(after.first { $0.url == c2 }?.read, true)

        // Nothing changed: nothing is sent back and forth
        guard case .done(let quiet, _) = await a.sync.sync() else { return XCTFail("a quiet sync") }
        XCTAssertEqual(quiet, 0)

        // B takes it out of the library; A follows
        try await b.database.setInLibrary(seriesId: seriesB.id, false)
        _ = await b.sync.sync()
        _ = await a.sync.sync()
        let libraryA = try await a.database.librarySeriesRecords()
        XCTAssertFalse(libraryA.contains { $0.url == seriesURL })
    }

    func testDetailsEditedOnTheServerReachTheSeries() async throws {
        guard let url = ProcessInfo.processInfo.environment["DOCHO_SYNC_TEST_URL"] else { throw XCTSkip("No test server") }
        let a = try device("a", url: url)
        let series = try await addSeries(a, chapters: [c1])
        guard case .done = await a.sync.sync() else { return XCTFail("first sync") }

        // Dōchō Server sends a "details" record after its WebUI edits the series
        let server = try device("server", url: url)
        let details = SyncJSON.object([
            "title": .string("Kaiju No. 8 (Edited)"), "author": .string("Naoya Matsumoto"), "description": .string("Edited"),
            "genres": .array([.string("Action"), .string("Sci-Fi")]), "status": .int(2),
        ])
        do {
            _ = try await server.sync.client.sync(since: 0, changes: [SyncRecord(
                kind: SyncValues.details, key: SyncValues.key(KavitaSource.id, seriesURL), value: details,
                updatedAt: Int64(Date().timeIntervalSince1970 * 1000), device: nil
            )])
        } catch let error as DochoSyncError where error.message.hasPrefix("Unknown kind") {
            throw XCTSkip("Only Dōchō Server takes details records")
        }

        guard case .done = await a.sync.sync() else { return XCTFail("second sync") }
        let edited = try await a.database.writer.read { db in try SeriesRecord.fetchOne(db, key: series.id) }
        XCTAssertEqual(edited?.name, "Kaiju No. 8 (Edited)")
        XCTAssertEqual(edited?.authors, "Naoya Matsumoto")
        XCTAssertEqual(edited?.summary, "Edited")
        XCTAssertEqual(edited?.genres, "Action, Sci-Fi")
        XCTAssertEqual(edited?.status, 2)
    }

    func testDetailsEditedOnOneDeviceReachTheOtherAndSurviveARefresh() async throws {
        guard let url = ProcessInfo.processInfo.environment["DOCHO_SYNC_TEST_URL"] else { throw XCTSkip("No test server") }
        let a = try device("a", url: url)
        let b = try device("b", url: url)
        _ = try await addSeries(a, chapters: [])
        let seriesB = try await addSeries(b, chapters: [])
        guard case .done = await a.sync.sync() else { return XCTFail("a first sync") }
        guard case .done = await b.sync.sync() else { return XCTFail("b first sync") }
        do {
            _ = try await a.sync.client.sync(since: 0, changes: [SyncRecord(
                kind: SyncValues.details, key: SyncValues.key(KavitaSource.id, "/probe"), value: nil, updatedAt: 1, device: nil
            )])
        } catch let error as DochoSyncError where error.message.hasPrefix("Unknown kind") {
            throw XCTSkip("This server doesn't take details records (before 0.32)")
        }

        // A edits the title and genres only
        a.edits.put(source: KavitaSource.id, url: seriesURL, .init(title: "Kaiju No. 8 (Mine)", genres: ["Action"]))
        guard case .done = await a.sync.sync() else { return XCTFail("a second sync") }
        guard case .done = await b.sync.sync() else { return XCTFail("b second sync") }
        XCTAssertEqual(b.edits.get(source: KavitaSource.id, url: seriesURL)?.title, "Kaiju No. 8 (Mine)")
        let edited = try await b.database.writer.read { db in try SeriesRecord.fetchOne(db, key: seriesB.id) }
        XCTAssertEqual(edited?.name, "Kaiju No. 8 (Mine)")
        XCTAssertEqual(edited?.genres, "Action")

        // A refresh from the source keeps the edited fields and takes the others
        let fromSource = b.edits.apply(
            source: KavitaSource.id,
            SManga(url: seriesURL, title: "Kaiju No. 8", author: "Naoya Matsumoto", genre: "Sci-Fi", initialized: true)
        )
        XCTAssertEqual(fromSource.title, "Kaiju No. 8 (Mine)")
        XCTAssertEqual(fromSource.genre, "Action")
        XCTAssertEqual(fromSource.author, "Naoya Matsumoto")

        // A resets; B unlocks
        a.edits.put(source: KavitaSource.id, url: seriesURL, nil)
        _ = await a.sync.sync()
        _ = await b.sync.sync()
        XCTAssertNil(b.edits.get(source: KavitaSource.id, url: seriesURL))
    }

    func testEditedDetailsDontStopSyncWithAnOlderServer() async throws {
        guard let url = ProcessInfo.processInfo.environment["DOCHO_SYNC_TEST_URL"] else { throw XCTSkip("No test server") }
        let a = try device("a", url: url)
        let b = try device("b", url: url)
        let seriesA = try await addSeries(a, chapters: [c1])
        // An edit and a read chapter go out together; a server without "details" still takes the chapter
        a.edits.put(source: KavitaSource.id, url: seriesURL, .init(title: "Edited"))
        let chaptersA = try await a.database.chapterList(seriesId: seriesA.id)
        let chapter = try XCTUnwrap(chaptersA.first)
        try await a.database.setChaptersRead([chapter.id], read: true)
        guard case .done = await a.sync.sync() else { return XCTFail("a sync") }
        guard case .done = await b.sync.sync() else { return XCTFail("b sync") }
        let libraryB = try await b.database.librarySeriesRecords()
        let seriesB = try XCTUnwrap(libraryB.first { $0.url == seriesURL })
        _ = try await b.database.saveFromSource(seriesId: seriesB.id, manga: nil, chapters: [SChapter(url: c1, name: c1)])
        guard case .done = await b.sync.sync() else { return XCTFail("b second sync") }
        let chaptersB = try await b.database.chapterList(seriesId: seriesB.id)
        XCTAssertEqual(chaptersB.first?.read, true)
    }

    func testStateFromTheOldSyncServerStartsOver() async throws {
        guard let url = ProcessInfo.processInfo.environment["DOCHO_SYNC_TEST_URL"] else { throw XCTSkip("No test server") }
        let a = try device("a", url: url)
        let b = try device("b", url: url)
        let seriesA = try await addSeries(a, chapters: [c1])
        let chaptersA = try await a.database.chapterList(seriesId: seriesA.id)
        try await a.database.saveProgress(chapterId: try XCTUnwrap(chaptersA.first).id, lastPageRead: 239, read: false)
        // A synced with the standalone sync server before: far ahead in its numbering, and
        // remembering the page as sent.
        a.sync.settings.since = 1_000_000
        a.sync.settings.epoch = 0
        guard case .done = await a.sync.sync() else { return XCTFail("a sync") }
        XCTAssertEqual(a.sync.settings.epoch, DochoSyncSettings.serverEpoch)

        guard case .done = await b.sync.sync() else { return XCTFail("b sync") }
        let libraryB = try await b.database.librarySeriesRecords()
        let seriesB = try XCTUnwrap(libraryB.first { $0.url == seriesURL })
        _ = try await b.database.saveFromSource(seriesId: seriesB.id, manga: nil, chapters: [SChapter(url: c1, name: c1)])
        guard case .done = await b.sync.sync() else { return XCTFail("b second sync") }
        let chaptersB = try await b.database.chapterList(seriesId: seriesB.id)
        XCTAssertEqual(chaptersB.first?.lastPageRead, 239)
    }
}
