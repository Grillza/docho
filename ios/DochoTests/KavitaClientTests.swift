import Synchronization
import XCTest
@testable import Docho

/// Engine tests against a fake server (StubURLProtocol).
final class KavitaClientTests: XCTestCase {
    private var credentials: TestCredentials!
    private var client: KavitaClient!

    override func setUp() {
        credentials = TestCredentials()
        let credentials = credentials!
        client = KavitaClient(session: StubURLProtocol.session(), appVersion: "1.2.3") { credentials.current }
    }

    private static let signIn = StubURLProtocol.Response.json(#"{"username": "josh", "token": "t1", "kavitaVersion": "0.8.4"}"#)

    private var signIns: [StubURLProtocol.Request] {
        StubURLProtocol.requests.filter { $0.path.hasSuffix("/Plugin/authenticate") }
    }

    func testSignsInWithThePluginFlowAndSendsTheToken() async throws {
        StubURLProtocol.reset { request in
            request.path.hasSuffix("/Plugin/authenticate") ? Self.signIn : .json(#"[{"id": 1, "name": "Manga", "type": 0}]"#)
        }

        let libraries = try await client.libraries()

        XCTAssertEqual(libraries, [KavitaLibrary(id: 1, name: "Manga")])
        let auth = try XCTUnwrap(signIns.first)
        XCTAssertEqual(auth.method, "POST")
        XCTAssertEqual(auth.url.absoluteString, "https://kavita.test/api/Plugin/authenticate?apiKey=key-1&pluginName=Docho")
        XCTAssertEqual(String(bytes: auth.body, encoding: .utf8), "{}")
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.path, "/api/Library/libraries")
        XCTAssertEqual(request.headers["Authorization"], "Bearer t1")
        XCTAssertEqual(request.headers["User-Agent"], "Docho-iOS v1.2.3 (io.github.grillza.docho)")
        XCTAssertNil(request.query("apiKey"))
    }

    func testConcurrentRequestsShareOneSignIn() async throws {
        StubURLProtocol.reset { request in
            request.path.hasSuffix("/Plugin/authenticate") ? Self.signIn : .json("[]")
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { [client] in _ = try await client!.libraries() }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(signIns.count, 1)
    }

    func testSignsInAgainOnceOn401AndRetries() async throws {
        let refused = Atomic(false)
        StubURLProtocol.reset { request in
            if request.path.hasSuffix("/Plugin/authenticate") {
                return refused.load(ordering: .relaxed)
                    ? .json(#"{"username": "josh", "token": "t2"}"#)
                    : Self.signIn
            }
            if request.headers["Authorization"] == "Bearer t1" {
                refused.store(true, ordering: .relaxed)
                return .json("", status: 401)
            }
            return .json("[]")
        }

        _ = try await client.libraries()

        XCTAssertEqual(signIns.count, 2)
        XCTAssertEqual(StubURLProtocol.requests.last?.headers["Authorization"], "Bearer t2")
    }

    func testReportsTheRejectedKeyWhenSigningInAgainFails() async throws {
        let first = Atomic(true)
        StubURLProtocol.reset { request in
            if request.path.hasSuffix("/Plugin/authenticate") {
                return first.exchange(false, ordering: .relaxed) ? Self.signIn : .json("", status: 401)
            }
            return .json("", status: 401)
        }

        do {
            _ = try await client.libraries()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? KavitaError, .authRejected)
            XCTAssertEqual(error.localizedDescription, "Kavita rejected the API key.")
        }
        XCTAssertEqual(signIns.count, 2)
    }

    func testSignsInAgainWhenTheSettingsChange() async throws {
        StubURLProtocol.reset { request in
            request.path.hasSuffix("/Plugin/authenticate") ? Self.signIn : .json("[]")
        }

        _ = try await client.libraries()
        _ = try await client.libraries()
        credentials.current.apiKey = "key-2"
        _ = try await client.libraries()

        XCTAssertEqual(signIns.map { $0.query("apiKey") }, ["key-1", "key-2"])
    }

    func testThrowsServerErrors() async {
        StubURLProtocol.reset { request in
            request.path.hasSuffix("/Plugin/authenticate") ? Self.signIn : .json("", status: 500)
        }
        do {
            _ = try await client.series(id: 1)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? KavitaError, .http(status: 500))
        }
    }

    func testRequiresConfiguration() async {
        credentials.current = KavitaCredentials(serverURL: "", apiKey: "")
        do {
            _ = try await client.libraries()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? KavitaError, .notConfigured)
        }
    }

    func testSeriesPageReadsThePaginationHeader() async throws {
        let filter = KavitaFilter(statements: [KavitaFilterStatement(comparison: 8, field: 21, value: "3")])
        StubURLProtocol.reset { request in
            if request.path.hasSuffix("/Plugin/authenticate") { return Self.signIn }
            return .json(#"[{"id": 1}, {"id": 2}]"#, headers: ["Pagination": #"{"currentPage": 1, "totalPages": 3}"#])
        }

        let page = try await client.seriesPage(filter: filter, page: 1)

        XCTAssertEqual(page.series.map(\.id), [1, 2])
        XCTAssertTrue(page.hasNextPage)
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.query("pageNumber"), "1")
        XCTAssertEqual(request.query("pageSize"), "30")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["combination"] as? Int, 1)
    }

    func testSeriesPageWithoutPaginationAssumesMoreWhenFull() async throws {
        StubURLProtocol.reset { request in
            request.path.hasSuffix("/Plugin/authenticate") ? Self.signIn : .json(#"[{"id": 1}, {"id": 2}]"#)
        }
        let full = try await client.seriesPage(filter: KavitaFilter(), page: 1, pageSize: 2)
        let partial = try await client.seriesPage(filter: KavitaFilter(), page: 1, pageSize: 3)
        XCTAssertTrue(full.hasNextPage)
        XCTAssertFalse(partial.hasNextPage)
    }

    func testPagesReadFallsBackToVolumesOn404() async throws {
        StubURLProtocol.reset { request in
            if request.path.hasSuffix("/Plugin/authenticate") { return Self.signIn }
            if request.path.hasSuffix("/Reader/get-progress") { return .json("", status: 404) }
            return .json(#"[{"id": 1, "chapters": [{"id": 10, "pagesRead": 3}, {"id": 11, "pagesRead": 7}]}]"#)
        }

        let pagesRead = try await client.pagesRead(seriesId: 5, chapterId: 11)

        XCTAssertEqual(pagesRead, 7)
        XCTAssertEqual(StubURLProtocol.requests.last?.query("seriesId"), "5")
    }

    func testPagesReadUsesGetProgress() async throws {
        StubURLProtocol.reset { request in
            request.path.hasSuffix("/Plugin/authenticate") ? Self.signIn : .json(#"{"pageNum": 12}"#)
        }
        let pagesRead = try await client.pagesRead(seriesId: 5, chapterId: 11)
        XCTAssertEqual(pagesRead, 12)
    }

    func testMarksChaptersInOneRequest() async throws {
        StubURLProtocol.reset { request in
            request.path.hasSuffix("/Plugin/authenticate") ? Self.signIn : .json("")
        }

        try await client.setChaptersRead(seriesId: 5, chapterIds: [10, 11], read: false)

        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.path, "/api/Reader/mark-multiple-unread")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["seriesId"] as? Int, 5)
        XCTAssertEqual(body["volumeIds"] as? [Int], [])
        XCTAssertEqual(body["chapterIds"] as? [Int], [10, 11])
    }

    func testCheckConnectionReportsUserAndVersion() async {
        StubURLProtocol.reset { _ in Self.signIn }
        let result = await client.checkConnection()
        XCTAssertEqual(result, .connected(username: "josh", version: "0.8.4"))
    }

    func testCheckConnectionReportsARejectedKey() async {
        StubURLProtocol.reset { _ in .json("", status: 401) }
        let result = await client.checkConnection()
        XCTAssertEqual(result, .failed(reason: "Kavita rejected the API key."))
    }

    func testCheckConnectionIsUnknownWhenNotConfigured() async {
        credentials.current = KavitaCredentials(serverURL: "https://kavita.test", apiKey: " ")
        let result = await client.checkConnection()
        XCTAssertEqual(result, .unknown)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty || signIns.isEmpty)
    }

    func testCheckConnectionPublishesToTheStream() async {
        StubURLProtocol.reset { _ in Self.signIn }
        var changes = client.connectionChanges.makeAsyncIterator()
        await client.checkConnection()
        // The stream keeps only the newest value.
        let latest = await changes.next()
        XCTAssertEqual(latest, .connected(username: "josh", version: "0.8.4"))
    }
}
