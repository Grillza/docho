import XCTest
@testable import Docho

/// The extension host client against a scripted transport: start-up, typed calls, errors.
final class ExtensionHostTests: XCTestCase {
    /// Answers each method with a canned result and records what was asked.
    final class FakeTransport: ExtensionTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _methods: [String] = []
        var methods: [String] { lock.withLock { _methods } }
        let answers: [String: String]
        let (stream, continuation) = AsyncStream.makeStream(of: ExtensionHostEvent.self)
        private var _responded: [ExtensionRPC.NetFetchResult] = []
        var responded: [ExtensionRPC.NetFetchResult] { lock.withLock { _responded } }

        init(answers: [String: String]) {
            self.answers = answers
        }

        func call(_ request: Data) async throws -> Data {
            let request = try JSONDecoder().decode(ExtensionRPC.Request.self, from: request)
            lock.withLock { _methods.append(request.method) }
            let result = answers[request.method] ?? "null"
            return Data(#"{"id":"\#(request.id)",\#(result.hasPrefix("{\"code\"") ? "\"error\"" : "\"result\""):\#(result)}"#.utf8)
        }

        func events() -> AsyncStream<ExtensionHostEvent> { stream }

        func respond(_ result: ExtensionRPC.NetFetchResult, body: Data?) async {
            lock.withLock { _responded.append(result) }
        }

        func readFile(_ path: String) async throws -> Data { Data(path.utf8) }
    }

    private static let hello = #"{"protocolVersion":1,"hostVersion":"0.1.0","libVersionMin":1.3,"libVersionMax":1.6,"jvm":"OpenJ9","capabilities":[]}"#

    func testStartsOnceThenCalls() async throws {
        let transport = FakeTransport(answers: [
            "host.hello": Self.hello,
            "source.popular": #"{"mangas":[{"url":"/m/1","title":"One","status":1}],"hasNextPage":true}"#,
        ])
        let host = ExtensionHost(transport: transport)
        let page = try await host.popular("42", page: 1)
        _ = try await host.popular("42", page: 2)
        XCTAssertEqual(transport.methods, ["host.hello", "host.init", "source.popular", "source.popular"])
        XCTAssertEqual(page.mangas.first?.smanga.title, "One")
        XCTAssertEqual(page.mangas.first?.smanga.status, .ongoing)
        XCTAssertTrue(page.hasNextPage)
    }

    func testErrorsComeBackAsRPCErrors() async throws {
        let transport = FakeTransport(answers: [
            "host.hello": Self.hello,
            "source.pages": #"{"code":"CLOUDFLARE","message":"Blocked by Cloudflare","retryable":true}"#,
        ])
        let host = ExtensionHost(transport: transport)
        do {
            _ = try await host.pages("42", chapter: .init(url: "/c/1", name: "1"))
            XCTFail("expected an error")
        } catch let error as ExtensionRPC.RPCError {
            XCTAssertEqual(error.code, "CLOUDFLARE")
            XCTAssertEqual(error.localizedDescription, "Blocked by Cloudflare")
        }
    }

    func testAnOldHostIsRefused() async throws {
        let transport = FakeTransport(answers: ["host.hello": Self.hello.replacingOccurrences(of: #""protocolVersion":1"#, with: #""protocolVersion":0"#)])
        do {
            try await ExtensionHost(transport: transport).start()
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(transport.methods, ["host.hello"])
    }

    func testFetchEventsAreAnswered() async throws {
        let transport = FakeTransport(answers: ["host.hello": Self.hello])
        let host = ExtensionHost(transport: transport)
        try await host.start()
        // An unusable URL still gets an answer, so the extension isn't left waiting.
        transport.continuation.yield(.fetch(.init(id: "f1", url: "notaurl://", method: "GET", headers: [], timeoutMillis: 1000), body: nil))
        for _ in 0..<50 where transport.responded.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(transport.responded.first?.id, "f1")
        XCTAssertNotNil(transport.responded.first?.error)
    }

    func testImageURLsRoundTrip() throws {
        let page = ExtensionRPC.Page(index: 3, url: "/p/3?x=1&y=2", imageUrl: "https://cdn.example/3.webp?token=a+b")
        let url = try XCTUnwrap(ExtensionImageURL.page(source: "-123", page: page))
        guard case .page(let source, let back) = ExtensionImageURL.target(of: url) else { return XCTFail("not a page") }
        XCTAssertEqual(source, "-123")
        XCTAssertEqual(back, page)

        let cover = try XCTUnwrap(ExtensionImageURL.cover(source: "7", url: "https://cdn.example/c.jpg?a=1&b=2"))
        guard case .cover(_, let coverURL) = ExtensionImageURL.target(of: cover) else { return XCTFail("not a cover") }
        XCTAssertEqual(coverURL, "https://cdn.example/c.jpg?a=1&b=2")
    }

    func testCookiesGoBackOnePerLine() throws {
        let url = URL(string: "https://site.test/x")!
        let joined = "a=1; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT, cf_clearance=x; Domain=.site.test; Path=/; Secure; HttpOnly"
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": joined], for: url)
        let lines = cookies.map(ExtensionNetwork.setCookieLine)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("a=1; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT"))
        XCTAssertFalse(lines[0].contains("Domain"))
        XCTAssertEqual(lines[1], "cf_clearance=x; Domain=.site.test; Path=/; Secure; HttpOnly")
    }
}
