import XCTest
@testable import Doki

@MainActor
final class KavitaBrowseModelTests: XCTestCase {
    private var model: KavitaBrowseModel!

    override func setUp() async throws {
        let credentials = TestCredentials()
        model = KavitaBrowseModel(client: KavitaClient(session: StubURLProtocol.session()) { credentials.current })
    }

    nonisolated private static let signIn = StubURLProtocol.Response.json(#"{"username": "josh", "token": "t1"}"#)

    /// Serves `pages` series pages; each page's ids are listed, and Pagination says how many pages exist.
    private func serve(_ pages: [[Int]]) {
        StubURLProtocol.reset { request in
            if request.path.hasSuffix("/Plugin/authenticate") { return Self.signIn }
            let page = Int(request.query("pageNumber") ?? "1") ?? 1
            let ids = pages.indices.contains(page - 1) ? pages[page - 1] : []
            let body = "[" + ids.map { #"{"id": \#($0), "name": "S\#($0)"}"# }.joined(separator: ",") + "]"
            return .json(body, headers: ["Pagination": #"{"currentPage": \#(page), "totalPages": \#(pages.count)}"#])
        }
    }

    func testLoadsPagesUntilTheLast() async throws {
        serve([[1, 2], [3, 4], [5]])

        await model.reload()
        XCTAssertEqual(model.series.map(\.id), [1, 2])
        XCTAssertTrue(model.hasNextPage)

        await model.loadNextPage()
        await model.loadNextPage()
        XCTAssertEqual(model.series.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertFalse(model.hasNextPage)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertFalse(model.isLoading)
    }

    func testReloadStartsAgainFromPageOne() async throws {
        serve([[1, 2], [3]])
        await model.reload()
        await model.loadNextPage()

        model.request.query = "x"
        await model.reload()

        XCTAssertEqual(model.series.map(\.id), [1, 2])
        XCTAssertEqual(model.loadedRequest, model.request)
        let lastSearch = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(lastSearch.query("pageNumber"), "1")
    }

    func testDropsSeriesAlreadyShown() async throws {
        serve([[1, 2], [2, 3]])
        await model.reload()
        await model.loadNextPage()
        XCTAssertEqual(model.series.map(\.id), [1, 2, 3])
    }

    func testResultsForAnOlderRequestAreDropped() async throws {
        serve([[1, 2]])
        let stale = Task { await model.reload() }
        await Task.yield()
        model.request.query = "new"
        await model.reload()
        await stale.value

        XCTAssertEqual(model.series.map(\.id), [1, 2])
        XCTAssertEqual(model.loadedRequest?.query, "new")
    }

    func testShowsAnErrorAndRetries() async throws {
        StubURLProtocol.reset { request in
            request.path.hasSuffix("/Plugin/authenticate") ? Self.signIn : .json("", status: 500)
        }
        await model.reload()
        XCTAssertEqual(model.error, "HTTP 500")
        XCTAssertEqual(model.series, [])

        serve([[1]])
        await model.reload()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.series.map(\.id), [1])
    }

    func testLoadsMoreOnlyNearTheEnd() async throws {
        serve([Array(1...30), [31]])
        await model.reload()

        await model.loadMoreIfNeeded(after: model.series[0])
        XCTAssertEqual(model.series.count, 30)
        await model.loadMoreIfNeeded(after: model.series[27])
        XCTAssertEqual(model.series.count, 31)
    }
}
