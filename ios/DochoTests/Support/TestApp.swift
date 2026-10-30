import GRDB
import Foundation
import XCTest
@testable import Docho

/// An `AppModel` whose settings live in their own UserDefaults suite and Keychain service, so
/// tests never see each other's (or the app's) servers.
@MainActor
enum TestApp {
    struct Parts {
        let app: AppModel
        let defaults: UserDefaults
        let suite: String
    }

    static func make(
        _ name: String,
        kavita: KavitaCredentials? = KavitaCredentials(serverURL: "https://kavita.test", apiKey: "key-1"),
        session: URLSession = StubURLProtocol.session(),
        database: AppDatabase? = nil,
        pageDebounce: Duration = .milliseconds(50),
        downloadStore: DownloadStore? = nil,
        pageFetcher: (any PageFetcher)? = nil
    ) throws -> Parts {
        let suite = "io.github.grillza.docho.tests.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let service = "io.github.grillza.docho.tests.\(name)"
        let settings = KavitaSettings(defaults: defaults, keychainService: service)
        settings.serverURL = kavita?.serverURL ?? ""
        settings.apiKey = kavita?.apiKey ?? ""
        let komga = KomgaSettings(store: ServerSettings(prefix: "komga", defaults: defaults, keychainService: service))
        komga.reset()
        let bookOrbit = BookOrbitSettings(store: ServerSettings(prefix: "bookorbit", defaults: defaults, keychainService: service))
        bookOrbit.reset()
        let koreader = KoreaderSettings(store: ServerSettings(prefix: "koreader", defaults: defaults, keychainService: service))
        koreader.reset()
        let store = downloadStore ?? DownloadStore(root: FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory))
        let app = AppModel(
            settings: settings, komgaSettings: komga, bookOrbitSettings: bookOrbit, koreaderSettings: koreader,
            syncSettings: SyncSettings(defaults: defaults), session: session, database: try database ?? .inMemory(),
            readerSettings: ReaderSettings(defaults: defaults), preferences: AppPreferences(defaults: defaults),
            pageDebounce: pageDebounce, downloadStore: store,
            pageFetcher: pageFetcher ?? SessionPageFetcher(session: session),
            downloadDefaults: defaults
        )
        return Parts(app: app, defaults: defaults, suite: suite)
    }
}

extension AppModel {
    /// Stores Kavita series `kavitaId` (library 2) with chapters `(Kavita chapter id, pages)`, as
    /// `KavitaSource` would. Returns the stored series.
    @discardableResult
    func seedKavitaSeries(_ kavitaId: Int = 7, name: String = "S", chapters: [(Int, Int)]) async throws -> SeriesRecord {
        let series = try await database.localSeries(
            source: KavitaSource.id, manga: SManga(url: KavitaSource.seriesURL(libraryId: 2, seriesId: kavitaId), title: name)
        )
        let list = chapters.map { id, pages in
            SChapter(
                url: KavitaSource.chapterURL(id), name: "Ch. \(id)", number: Double(id),
                memo: ChapterMemo([
                    KavitaSource.memoSeriesId: .int(kavitaId), KavitaSource.memoLibraryId: .int(2),
                    KavitaSource.memoVolumeId: .int(1), KavitaSource.memoPages: .int(pages),
                ])
            )
        }
        try await database.saveFromSource(seriesId: series.id, manga: nil, chapters: list)
        return try await database.seriesRecord(id: series.id) ?? series
    }

    /// The local chapter for a Kavita chapter id.
    func kavitaChapter(_ kavitaId: Int) async throws -> ChapterRecord? {
        try await database.writer.read { db in
            try ChapterRecord.filter(ChapterRecord.Columns.url == KavitaSource.chapterURL(kavitaId)).fetchOne(db)
        }
    }
}
