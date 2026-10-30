import GRDB
import XCTest
@testable import Doki

final class AppDatabaseTests: XCTestCase {
    private var database: AppDatabase!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
    }

    private func series(_ id: Int, name: String? = nil, libraryId: Int = 1) throws -> KavitaSeries {
        let json = #"{"id": \#(id), "libraryId": \#(libraryId)\#(name.map { #", "name": "\#($0)""# } ?? "")}"#
        return try JSONDecoder().decode(KavitaSeries.self, from: Data(json.utf8))
    }

    private func first<T: Sendable>(_ observation: AsyncValueObservation<T>) async throws -> T {
        for try await value in observation { return value }
        throw CancellationError()
    }

    func testSavingLibrariesReplacesThemAndSortsByName() async throws {
        try await database.saveLibraries([KavitaLibrary(id: 1, name: "manga"), KavitaLibrary(id: 2, name: "Comics")])
        try await database.saveLibraries([KavitaLibrary(id: 3, name: "Webtoons"), KavitaLibrary(id: 1, name: "manga")])

        let libraries = try await first(database.libraries())
        XCTAssertEqual(libraries.map(\.name), ["manga", "Webtoons"])
    }

    func testAddingAndRemovingSeriesKeepsTheCachedRow() async throws {
        try await database.setInLibrary(series(7, name: "Berserk", libraryId: 2), true)
        var library = try await first(database.librarySeries())
        XCTAssertEqual(library.map(\.name), ["Berserk"])
        XCTAssertEqual(library.first?.libraryId, 2)

        try await database.setInLibrary(seriesId: 7, false)
        library = try await first(database.librarySeries())
        XCTAssertEqual(library, [])
        let cached = try await database.writer.read { try SeriesRecord.fetchOne($0, key: 7) }
        XCTAssertEqual(cached?.inLibrary, false)
        XCTAssertEqual(cached?.name, "Berserk")
    }

    func testAddingAgainUpdatesTheNameButKeepsOtherFields() async throws {
        try await database.setInLibrary(series(7, name: "Old"), true)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE series SET summary = 'kept', readerMode = 'webtoon' WHERE id = 7")
        }
        try await database.setInLibrary(series(7, name: "New"), true)

        let record = try await database.writer.read { try SeriesRecord.fetchOne($0, key: 7) }
        XCTAssertEqual(record?.name, "New")
        XCTAssertEqual(record?.summary, "kept")
        XCTAssertEqual(record?.readerMode, "webtoon")
    }

    func testLibraryIsSortedByNameIgnoringCase() async throws {
        try await database.setInLibrary(series(1, name: "zeta"), true)
        try await database.setInLibrary(series(2, name: "Alpha"), true)
        try await database.setInLibrary(series(3, name: "beta"), false)

        let names = try await first(database.librarySeries()).map(\.name)
        XCTAssertEqual(names, ["Alpha", "zeta"])
        let ids = try await first(database.libraryIDs())
        XCTAssertEqual(ids, [1, 2])
    }

    func testUpdatingSeriesOnlyTouchesStoredOnes() async throws {
        try await database.setInLibrary(series(1, name: "Before"), true)
        try await database.updateSeries([series(1, name: "After", libraryId: 4), series(2, name: "Unknown")])

        let all = try await database.writer.read { try SeriesRecord.fetchAll($0) }
        XCTAssertEqual(all.map(\.name), ["After"])
        XCTAssertEqual(all.first?.libraryId, 4)
    }

    func testOpensOnDiskInAFolderWithASpace() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Application Support \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try AppDatabase.onDisk(in: directory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "mihonka.sqlite").path(percentEncoded: false)))
    }
}
