import XCTest
@testable import Docho

/// Two devices syncing through a real Dōchō Sync server. Runs when `DOCHO_SYNC_TEST_URL` points
/// at one started fresh, e.g. `DOCHO_SYNC_DATA=$(mktemp -d) python3 sync-server/server.py`.
@MainActor
final class DochoSyncLiveTests: XCTestCase {
    private struct Device {
        let database: AppDatabase
        let renames: ChapterRenames
        let sync: DochoSync
    }

    private func device(_ name: String, url: String, user: String) throws -> Device {
        let suite = "docho-sync-test-\(name)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = DochoSyncSettings(store: ServerSettings(prefix: "docho_sync", defaults: defaults, keychainService: suite))
        settings.serverURL = url
        settings.username = user
        settings.password = "password123"
        let database = try AppDatabase.inMemory()
        let renames = ChapterRenames(defaults: defaults)
        let client = DochoSyncClient(settings: settings, session: .shared)
        let sync = DochoSync(
            settings: settings, client: client, database: database, renames: renames,
            stateURL: FileManager.default.temporaryDirectory.appending(path: "\(suite).json")
        ) { _ in }
        return Device(database: database, renames: renames, sync: sync)
    }

    private func addSeries(_ device: Device, chapters: [String]) async throws -> SeriesRecord {
        let series = try await device.database.localSeries(source: KavitaSource.id, manga: SManga(url: "/series/7", title: "Kaiju No. 8"))
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
        let user = "user\(Int.random(in: 0..<1_000_000))"
        let a = try device("a", url: url, user: user)
        let b = try device("b", url: url, user: user)

        // A has a series with one chapter read and one renamed, and makes the account
        let seriesA = try await addSeries(a, chapters: ["/c/1", "/c/2"])
        let chaptersA = try await a.database.chapterList(seriesId: seriesA.id)
        let first = try XCTUnwrap(chaptersA.first { $0.url == "/c/1" })
        try await a.database.setChaptersRead([first.id], read: true)
        a.renames.put(source: KavitaSource.id, oldURL: "/c/2", newURL: "/c/2", .init(name: "Vol. 2", number: 2, original: "c2", at: 1))
        guard case .connected = await a.sync.client.signIn(register: true) else { return XCTFail("register") }
        guard case .done = await a.sync.sync() else { return XCTFail("a first sync") }

        // B starts empty: it gets the series, and the chapter states once its chapters arrive
        guard case .done = await b.sync.sync() else { return XCTFail("b first sync") }
        let libraryB = try await b.database.librarySeriesRecords()
        let seriesB = try XCTUnwrap(libraryB.first { $0.url == "/series/7" })
        XCTAssertEqual(b.renames.renames["\(KavitaSource.id)|/c/2"]?.name, "Vol. 2")
        _ = try await b.database.saveFromSource(seriesId: seriesB.id, manga: nil, chapters: ["/c/1", "/c/2"].map { SChapter(url: $0, name: $0) })
        guard case .done = await b.sync.sync() else { return XCTFail("b second sync") }
        let chaptersB = try await b.database.chapterList(seriesId: seriesB.id)
        XCTAssertEqual(chaptersB.first { $0.url == "/c/1" }?.read, true)
        XCTAssertEqual(chaptersB.first { $0.url == "/c/2" }?.read, false)

        // B marks the first unread and reads the second; A picks both up
        let b1 = try XCTUnwrap(chaptersB.first { $0.url == "/c/1" })
        let b2 = try XCTUnwrap(chaptersB.first { $0.url == "/c/2" })
        try await b.database.setChaptersRead([b1.id], read: false)
        try await b.database.setChaptersRead([b2.id], read: true)
        guard case .done(let sent, _) = await b.sync.sync() else { return XCTFail("b third sync") }
        XCTAssertGreaterThanOrEqual(sent, 2)
        guard case .done = await a.sync.sync() else { return XCTFail("a second sync") }
        let after = try await a.database.chapterList(seriesId: seriesA.id)
        XCTAssertEqual(after.first { $0.url == "/c/1" }?.read, false)
        XCTAssertEqual(after.first { $0.url == "/c/2" }?.read, true)

        // Nothing changed: nothing is sent back and forth
        guard case .done(let quiet, _) = await a.sync.sync() else { return XCTFail("a quiet sync") }
        XCTAssertEqual(quiet, 0)

        // B takes it out of the library; A follows
        try await b.database.setInLibrary(seriesId: seriesB.id, false)
        _ = await b.sync.sync()
        _ = await a.sync.sync()
        let libraryA = try await a.database.librarySeriesRecords()
        XCTAssertTrue(libraryA.isEmpty)
    }

    func testDetailsEditedOnTheServerReachTheSeries() async throws {
        guard let url = ProcessInfo.processInfo.environment["DOCHO_SYNC_TEST_URL"] else { throw XCTSkip("No test server") }
        let user = "user\(Int.random(in: 0..<1_000_000))"
        let a = try device("a", url: url, user: user)
        let series = try await addSeries(a, chapters: ["/c/1"])
        guard case .connected = await a.sync.client.signIn(register: true) else { return XCTFail("register") }
        guard case .done = await a.sync.sync() else { return XCTFail("first sync") }

        // Dōchō Server sends a "details" record after its WebUI edits the series
        let server = try device("server", url: url, user: user)
        guard case .connected = await server.sync.client.signIn() else { return XCTFail("server sign-in") }
        let details = SyncJSON.object([
            "title": .string("Kaiju No. 8 (Edited)"), "author": .string("Naoya Matsumoto"), "description": .string("Edited"),
            "genres": .array([.string("Action"), .string("Sci-Fi")]), "status": .int(2),
        ])
        do {
            _ = try await server.sync.client.sync(since: 0, changes: [SyncRecord(
                kind: SyncValues.details, key: SyncValues.key(KavitaSource.id, "/series/7"), value: details,
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
}
