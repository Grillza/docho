import GRDB
import XCTest
@testable import Docho

@MainActor
final class BackupTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mihon-sample.tachibk", withExtension: nil), "mihon-sample.tachibk in the test bundle")
        return try Data(contentsOf: url)
    }

    func testGzipRoundTripsAndChecksItsCRC() throws {
        let text = Data(String(repeating: "Dōchō backups ", count: 200).utf8)
        let packed = try Gzip.compress(text)
        XCTAssertTrue(Gzip.isGzip(packed))
        XCTAssertLessThan(packed.count, text.count)
        XCTAssertEqual(try Gzip.decompress(packed), text)
        XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)

        var corrupt = packed
        corrupt[corrupt.count - 6] ^= 0xFF
        XCTAssertThrowsError(try Gzip.decompress(corrupt))
    }

    func testReadsMihonsBackup() throws {
        let backup = try MihonBackup(fileData: fixture())
        XCTAssertEqual(backup.manga.count, 2)
        let frieren = backup.manga[0]
        XCTAssertEqual(frieren.source, 7_266_875_667_263_635_239)
        XCTAssertEqual(frieren.title, "Frieren: Beyond Journey's End")
        XCTAssertEqual(frieren.genres, ["Adventure", "Fantasy"])
        XCTAssertEqual(frieren.dateAdded, 1_700_000_000_000)
        XCTAssertEqual(frieren.categories, [1])
        XCTAssertTrue(frieren.favorite)
        XCTAssertEqual(frieren.chapters.map(\.url), ["/chapter/1", "/chapter/2"])
        XCTAssertEqual(frieren.chapters[0].chapterNumber, 1)
        XCTAssertEqual(frieren.chapters[1].chapterNumber, 2.5)
        XCTAssertTrue(frieren.chapters[0].read)
        XCTAssertEqual(frieren.chapters[0].memo, Data(#"{"cid":"a1"}"#.utf8))
        XCTAssertEqual(frieren.tracking.first?.syncId, 2)
        XCTAssertEqual(frieren.tracking.first?.mediaId, 12345)
        XCTAssertEqual(frieren.tracking.first?.score, 8.5)
        XCTAssertEqual(frieren.history.first?.readDuration, 60000)
        XCTAssertFalse(backup.manga[1].favorite, "favorite = false is written explicitly")
        XCTAssertEqual(backup.categories.map(\.name), ["Reading", "Plan to read"])
        XCTAssertEqual(backup.categories[1].flags, 64)
        XCTAssertEqual(backup.sources.map(\.name), ["MangaDex", "Kavita"])
        XCTAssertEqual(backup.preferences.first, MihonBackup.Preference(key: "pref_library_columns_portrait_key", value: .int(3)))
        XCTAssertFalse(backup.sourcePreferences.isEmpty)
    }

    func testWritingAndReadingAgainGivesTheSameBackup() throws {
        var backup = try MihonBackup(fileData: fixture())
        backup.preferences += [
            .init(key: "a_long", value: .long(1 << 40)), .init(key: "a_float", value: .float(0.75)),
            .init(key: "a_flag", value: .bool(true)), .init(key: "a_set", value: .stringSet(["x", "y"])),
            .init(key: "negative", value: .int(-1)),
        ]
        XCTAssertEqual(try MihonBackup(fileData: backup.fileData()), backup)
    }

    func testRejectsAFileThatIsntABackup() {
        XCTAssertThrowsError(try MihonBackup(fileData: Data([0x1F, 0x8B] + Array(repeating: 0, count: 30))))
        XCTAssertThrowsError(try MihonBackup(fileData: Data([0x0A, 0xFF, 0xFF])))
    }

    func testRestoresIntoTheLibraryAndBacksItUpAgain() async throws {
        let database = try AppDatabase.inMemory()
        let count = try await database.restore(MihonBackup(fileData: fixture()))
        XCTAssertEqual(count, 2)

        let library = try await database.librarySeriesRecords()
        XCTAssertEqual(library.map(\.name), ["Frieren: Beyond Journey's End"])
        let frieren = try XCTUnwrap(library.first)
        XCTAssertEqual(frieren.genres, "Adventure, Fantasy")
        let chapters = try await database.chapterList(seriesId: frieren.id)
        XCTAssertEqual(chapters.map(\.url), ["/chapter/1", "/chapter/2"], "Mihon's source order counts from the newest; ours from the first")
        XCTAssertEqual(chapters.first { $0.url == "/chapter/1" }?.read, true)
        XCTAssertEqual(chapters.first { $0.url == "/chapter/1" }?.chapterMemo.string("cid"), "a1")
        let categories = try await database.categoryList()
        XCTAssertEqual(categories.map(\.name), ["Reading", "Plan to read"])
        let reading = try XCTUnwrap(categories.first { $0.name == "Reading" })
        let frierenCategories = try await database.categoryIds(seriesId: frieren.id)
        XCTAssertEqual(frierenCategories, [reading.id])
        let tracks = try await database.tracks(seriesId: frieren.id)
        XCTAssertEqual(tracks.map(\.trackerId), [2])
        XCTAssertEqual(tracks.first?.remoteId, 12345)

        // Restoring again changes nothing, and what's here backs up as it came.
        _ = try await database.restore(MihonBackup(fileData: fixture()))
        let again = try await database.chapterList(seriesId: frieren.id)
        XCTAssertEqual(again.count, 2)
        let backup = try await database.backupContents()
        XCTAssertEqual(backup.manga.count, 2, "the read series outside the library is kept too")
        let backed = try XCTUnwrap(backup.manga.first { $0.favorite })
        XCTAssertEqual(backed.chapters.first { $0.url == "/chapter/1" }?.sourceOrder, 1)
        XCTAssertEqual(backed.history.first?.lastRead, 1_700_000_100_000)
        XCTAssertEqual(backed.history.first?.readDuration, 60000)
        XCTAssertEqual(backed.categories, [reading.sort].map(Int64.init))
        XCTAssertEqual(backed.tracking.first?.mediaId, 12345)
    }

    func testRestoringKeepsTheFurthestReading() async throws {
        let database = try AppDatabase.inMemory()
        var backup = MihonBackup()
        var manga = MihonBackup.Manga(source: KavitaSource.id, url: "/series/1", title: "One")
        manga.chapters = [MihonBackup.Chapter(url: "/c/1", name: "1", lastPageRead: 4)]
        backup.manga = [manga]
        _ = try await database.restore(backup)
        backup.manga[0].chapters[0].lastPageRead = 2
        _ = try await database.restore(backup)
        let library = try await database.librarySeriesRecords()
        let series = try XCTUnwrap(library.first)
        let chapters = try await database.chapterList(seriesId: series.id)
        XCTAssertEqual(chapters.first?.lastPageRead, 4)
    }

    func testServerSettingsAndSignInsStayOutOfBackups() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "io.github.grillza.docho.tests.backup.\(UUID())"))
        for key in ["kavita_server_url", "__PRIVATE_komga_api_key", "suwayomi_username", "progress_sync_mode",
                    "pref_mangasync_username_2", "AppleLanguages", "download_queue_paused"] {
            XCTAssertFalse(BackupManager.isBackedUp(key), key)
        }
        XCTAssertTrue(BackupManager.isBackedUp("pref_display_mode_library"))

        defaults.set(true, forKey: "display_unread_badge")
        let restored = BackupManager.restorePreferences([
            .init(key: "pref_library_columns_portrait_key", value: .int(4)),
            .init(key: "kavita_server_url", value: .string("http://server")),
            // Android keeps this as a number; a Bool here isn't replaced by it.
            .init(key: "display_unread_badge", value: .int(3)),
        ], to: defaults)
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(defaults.integer(forKey: "pref_library_columns_portrait_key"), 4)
        XCTAssertNil(defaults.object(forKey: "kavita_server_url"))
        XCTAssertEqual(defaults.object(forKey: "display_unread_badge") as? Bool, true)
    }

    // MARK: Tracker ids, as Android derives them

    func testComickHidsAreTheNumberTheyEncode() throws {
        XCTAssertEqual(try Comick.remoteId("Ab-_3xY0"), 1_923_069_449_780)
        XCTAssertEqual(try Comick.hid(1_923_069_449_780), "Ab-_3xY0")
        XCTAssertThrowsError(try Comick.remoteId("short"))
    }

    func testHikkaSlugsGetJavasNameUUIDNumber() {
        // java.util.UUID.nameUUIDFromBytes("berserk-6a1f".getBytes()).mostSignificantBits & Long.MAX_VALUE
        XCTAssertEqual(Hikka.remoteId(slug: "berserk-6a1f"), 6_731_046_286_802_959_962)
    }

    func testPKCEChallengeIsTheVerifiersHash() throws {
        let pkce = PKCE()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertFalse(pkce.challenge.contains("="))
        let callback = try XCTUnwrap(URL(string: "mihon://mangabaka-auth?code=abc&state=\(pkce.state)"))
        XCTAssertEqual(try pkce.code(from: callback), "abc")
        let forged = try XCTUnwrap(URL(string: "mihon://mangabaka-auth?code=abc&state=other"))
        XCTAssertThrowsError(try pkce.code(from: forged))
    }
}
