import XCTest
@testable import Docho

/// Browse → a source's listing: paging, restarting, de-duplication and errors, through Kavita.
@MainActor
final class BrowseSourceModelTests: XCTestCase {
    private var app: AppModel!
    private var model: BrowseSourceModel!

    override func setUp() async throws {
        app = try TestApp.make("browse").app
        model = BrowseSourceModel(app: app, source: app.kavitaSource, listing: .popular)
    }

    nonisolated private static let signIn = StubURLProtocol.Response.json(#"{"username": "josh", "token": "t1"}"#)

    /// Serves `pages` series pages; each page's ids are listed, and Pagination says how many pages exist.
    private func serve(_ pages: [[Int]]) {
        StubURLProtocol.reset { request in
            if request.path.hasSuffix("/Plugin/authenticate") { return Self.signIn }
            let page = Int(request.query("pageNumber") ?? "1") ?? 1
            let ids = pages.indices.contains(page - 1) ? pages[page - 1] : []
            let body = "[" + ids.map { #"{"id": \#($0), "name": "S\#($0)", "libraryId": 2}"# }.joined(separator: ",") + "]"
            return .json(body, headers: ["Pagination": #"{"currentPage": \#(page), "totalPages": \#(pages.count)}"#])
        }
    }

    private var urls: [String] { model.items.map(\.url) }

    func testLoadsPagesUntilTheLast() async throws {
        serve([[1, 2], [3, 4], [5]])

        await model.restart(.popular)
        XCTAssertEqual(urls, ["/library/2/series/1", "/library/2/series/2"])
        XCTAssertTrue(model.hasNextPage)

        await model.loadMore()
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.name), ["S1", "S2", "S3", "S4", "S5"])
        XCTAssertFalse(model.hasNextPage)
        XCTAssertFalse(model.isLoading)
    }

    func testListingsAreStoredWithStableLocalIds() async throws {
        serve([[1, 2]])
        await model.restart(.popular)
        let first = model.items.map(\.id)
        await model.restart(.popular)
        XCTAssertEqual(model.items.map(\.id), first)
        XCTAssertEqual(Set(model.items.map(\.source)), [KavitaSource.id])
    }

    func testRestartStartsAgainFromPageOne() async throws {
        serve([[1, 2], [3]])
        await model.restart(.popular)
        await model.loadMore()

        await model.restart(.search("x"))

        XCTAssertEqual(model.items.map(\.name), ["S1", "S2"])
        let lastSearch = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(lastSearch.query("pageNumber"), "1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: lastSearch.body) as? [String: Any])
        let statements = try XCTUnwrap(body["statements"] as? [[String: Any]])
        XCTAssertTrue(statements.contains { $0["value"] as? String == "x" && $0["field"] as? Int == 1 })
    }

    func testDropsSeriesAlreadyShown() async throws {
        serve([[1, 2], [2, 3]])
        await model.restart(.popular)
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.name), ["S1", "S2", "S3"])
    }

    func testUnreadUsesKavitasReadProgressFilter() async throws {
        serve([[1]])
        await model.restart(.unread)
        let request = try XCTUnwrap(StubURLProtocol.requests.last { $0.path.hasSuffix("/Series/all-v2") })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let statements = try XCTUnwrap(body["statements"] as? [[String: Any]])
        XCTAssertTrue(statements.contains { $0["comparison"] as? Int == 9 && $0["field"] as? Int == 20 && $0["value"] as? String == "100" })
        let sort = try XCTUnwrap(body["sortOptions"] as? [String: Any])
        XCTAssertEqual(sort["sortField"] as? Int, 4)
        XCTAssertEqual(sort["isAscending"] as? Bool, false)
    }

    func testShowsAnErrorAndRetries() async throws {
        StubURLProtocol.reset { request in
            request.path.hasSuffix("/Plugin/authenticate") ? Self.signIn : .json("", status: 500)
        }
        await model.restart(.popular)
        XCTAssertEqual(model.error, "HTTP 500")
        XCTAssertEqual(model.items, [])

        serve([[1]])
        await model.restart(.popular)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.items.count, 1)
    }
}
