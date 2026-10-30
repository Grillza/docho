import XCTest
@testable import Doki

/// Runs against a real Kavita server, and is skipped unless one is given:
/// `TEST_RUNNER_KAVITA_LIVE_URL=… TEST_RUNNER_KAVITA_LIVE_KEY=… xcodebuild test …`
final class KavitaLiveTests: XCTestCase {
    private var client: KavitaClient!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["KAVITA_LIVE_URL"], let key = env["KAVITA_LIVE_KEY"] else {
            throw XCTSkip("Set KAVITA_LIVE_URL and KAVITA_LIVE_KEY to run against a real server")
        }
        let credentials = TestCredentials(serverURL: url, apiKey: key)
        client = KavitaClient { credentials.current }
    }

    func testConnectsAndReadsTheServer() async throws {
        let connection = await client.checkConnection()
        guard case .connected(let username, let version) = connection else {
            return XCTFail("not connected: \(connection)")
        }
        print("live: connected as \(username) to Kavita \(version ?? "?")")

        let libraries = try await client.libraries()
        print("live: libraries \(libraries.map(\.name))")

        let filter = KavitaFilter(statements: [
            KavitaFilterStatement(
                comparison: KavitaConstants.comparisonNotContains,
                field: KavitaConstants.fieldFormats,
                value: String(KavitaConstants.formatEpub)
            ),
        ])
        let page = try await client.seriesPage(filter: filter, page: 1)
        print("live: first page \(page.series.count) series, more: \(page.hasNextPage)")
        XCTAssertFalse(page.series.contains { $0.format == KavitaConstants.formatEpub })

        guard let series = page.series.first else { return }
        let metadata = try await client.seriesMetadata(seriesId: series.id)
        let volumes = try await client.volumes(seriesId: series.id)
        print("live: \(series.name ?? "?"): \(volumes.count) volumes, \(metadata.genres.compactMap(\.label))")
        if let chapter = volumes.first?.chapters.first {
            let pagesRead = try await client.pagesRead(seriesId: series.id, chapterId: chapter.id)
            print("live: chapter \(chapter.id) pagesRead \(pagesRead) of \(chapter.pages)")
        }
    }
}
