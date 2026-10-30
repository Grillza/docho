import XCTest
@testable import Docho

/// Against a real Suwayomi server: run with `TEST_RUNNER_DOCHO_SUWAYOMI_URL=http://localhost:4567`
/// (`scripts/test-servers.sh` starts one, with a comic in its local folder). Skipped otherwise.
@MainActor
final class SuwayomiLiveTests: XCTestCase {
    private var client: SuwayomiClient!

    override func setUp() async throws {
        guard let url = ProcessInfo.processInfo.environment["DOCHO_SUWAYOMI_URL"] else {
            throw XCTSkip("No Suwayomi server (DOCHO_SUWAYOMI_URL)")
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "io.github.grillza.docho.tests.suwayomi.\(UUID())"))
        let settings = SuwayomiSettings(store: ServerSettings(prefix: "suwayomi", defaults: defaults, keychainService: "io.github.grillza.docho.tests.suwayomi"))
        settings.serverURL = url
        client = SuwayomiClient(settings: settings)
    }

    func testBrowsesAndReadsThroughTheServer() async throws {
        let about = try await client.about()
        XCTAssertTrue(about.hasPrefix("Suwayomi"))
        // Suwayomi's own Local source (id 0) holds the test comic.
        let page = try await client.fetchSourceManga(source: 0, type: "POPULAR", page: 1, query: nil, filters: [])
        let manga = try XCTUnwrap(page.mangas.first { $0.title == "Docho Test" })
        XCTAssertEqual(manga.thumbnailURL?.hasPrefix("/api/v1/manga/"), true)

        let source = SuwayomiSource(
            info: SuwayomiSourceInfo(id: 0, name: "Local", lang: "other", supportsLatest: false, iconPath: "", isNSFW: false), client: client
        )
        let (details, chapters) = try await source.update(manga, details: true, chapters: true)
        XCTAssertTrue(details.initialized)
        let list = try XCTUnwrap(chapters)
        XCTAssertEqual(list.map(\.name), ["v01", "v02", "v10"], "reading order")
        XCTAssertNotNil(list[0].memo.int(SuwayomiClient.chapterIdKey))

        let pages = try await source.pages(list[0])
        XCTAssertEqual(pages.count, 12)
        let (data, response) = try await URLSession.shared.data(for: source.imageRequest(pages[0]))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertNotNil(UIImage(data: data))
        let cover = try XCTUnwrap(source.coverRequest(details))
        let coverResponse = try await URLSession.shared.data(for: cover).1
        XCTAssertEqual(coverResponse.mimeType, "image/jpeg")
    }

    func testInstallsAnExtensionAndListsItsSource() async throws {
        let all = try await client.extensions(refresh: true)
        guard let mangadex = all.first(where: { $0.pkgName == "eu.kanade.tachiyomi.extension.all.mangadex" }) else {
            throw XCTSkip("The server has no extension repo with MangaDex")
        }
        if !mangadex.isInstalled { try await client.change(mangadex.pkgName, .install) }
        let installed = try await client.extensions(refresh: false).first { $0.pkgName == mangadex.pkgName }
        XCTAssertEqual(installed?.isInstalled, true)
        let sources = try await client.sources()
        let english = try XCTUnwrap(sources.first { $0.name == "MangaDex" && $0.lang == "en" })
        XCTAssertFalse(sources.contains { $0.id == 0 }, "Suwayomi's Local source stays out; Dōchō has its own")

        let filters = try await client.filters(source: english.id)
        XCTAssertFalse(filters.isEmpty)
        XCTAssertEqual(SuwayomiClient.changes(filters, defaults: filters).count, 0, "no changes from the defaults")
    }
}
