import XCTest
@testable import Docho

/// The app's extension client against a real extension host: the runtime's desktop dev host
/// (`./gradlew :host-desktop:shadowJar`, then run the jar; see PLAN-2 G3). Runs when
/// `DOCHO_EXTENSION_HOST_URL`, `DOCHO_EXTENSION_REPO` (an index URL) and `DOCHO_EXTENSION_PKG`
/// (an extension in it) are set; the app itself names no repos or extensions.
final class ExtensionHostLiveTests: XCTestCase {
    func testInstallsBrowsesAndReadsAnExtension() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let hostURL = env["DOCHO_EXTENSION_HOST_URL"].flatMap(URL.init(string:)),
              let repo = env["DOCHO_EXTENSION_REPO"], let pkg = env["DOCHO_EXTENSION_PKG"] else {
            throw XCTSkip("No extension host")
        }
        let host = ExtensionHost(transport: HTTPExtensionTransport(baseURL: hostURL))
        let clock = ContinuousClock()
        let started = clock.now
        let hello = try await host.start()
        print("extension host: \(hello.jvm), started in \(clock.now - started)")

        // Repo and install
        if try await !host.repos().contains(where: { $0.indexUrl == repo }) { _ = try await host.addRepo(repo) }
        let available = try await host.availableExtensions(includeNsfw: false)
        let ext = try XCTUnwrap(available.first { $0.pkgName == pkg }, "\(pkg) isn't in the repo")
        var installed = try await host.installedExtensions().first { $0.pkgName == pkg }
        if installed == nil {
            let progress = await host.progress()
            let job = try await host.install(pkg, repo: ext.repoIndexUrl)
            for await event in progress where event.jobId == job.jobId {
                if event.phase == .failed { return XCTFail("install failed: \(event.error?.message ?? "?")") }
                if event.phase == .done { break }
            }
            installed = try await host.installedExtensions().first { $0.pkgName == pkg }
        }
        var found = try XCTUnwrap(installed)
        if !found.isTrusted { found = try await host.trust(found) }
        let info = try XCTUnwrap(found.sources.first { $0.lang == "en" } ?? found.sources.first)
        let source = ExtensionSource(host: host, info: info)
        XCTAssertEqual(source.id, Int64(info.id))

        // Browse, then a series and its chapters, then a page image
        let browseStart = clock.now
        let popular = try await source.popular(page: 1)
        print("popular page 1: \(popular.mangas.count) series in \(clock.now - browseStart)")
        let manga = try XCTUnwrap(popular.mangas.first)
        let (details, chapters) = try await source.update(manga, details: true, chapters: true)
        XCTAssertFalse(details.title.isEmpty)
        let chapter = try XCTUnwrap(chapters?.last, "no chapters")
        let pages = try await source.pages(chapter)
        XCTAssertFalse(pages.isEmpty)
        let (data, mimeType) = try await ExtensionImageURL.fetch(pages[0].imageURL, host: host)
        print("page 1: \(data.count) bytes, \(mimeType ?? "?")")
        XCTAssertNotNil(UIImage(data: data), "the page isn't an image")
        if let cover = source.coverRequest(details)?.url {
            let (coverData, _) = try await ExtensionImageURL.fetch(cover, host: host)
            XCTAssertNotNil(UIImage(data: coverData), "the cover isn't an image")
        }
    }
}
