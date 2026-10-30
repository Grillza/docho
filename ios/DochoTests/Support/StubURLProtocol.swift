import Foundation
import Synchronization
@testable import Docho

/// A fake server for URLSession: tests set `handler` and read back `requests`. State is static
/// because URLSession instantiates the protocol itself, so tests using it must not run in parallel.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ string: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            let headers = headers.merging(["Content-Type": "application/json"]) { mine, _ in mine }
            return Response(status: status, headers: headers, body: Data(string.utf8))
        }
    }

    /// A request as the server saw it, with the body read out of the stream URLSession uses.
    struct Request: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data

        var path: String { url.path() }

        func query(_ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }
    }

    typealias Handler = @Sendable (Request) throws -> Response

    private static let state = Mutex<(handler: Handler?, requests: [Request])>((nil, []))

    static func reset(_ handler: @escaping Handler) {
        state.withLock { $0 = (handler, []) }
    }

    static var requests: [Request] {
        state.withLock { $0.requests }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Request(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        )
        let handler = Self.state.withLock { state in
            state.requests.append(recorded)
            return state.handler
        }
        do {
            guard let handler else { throw URLError(.cannotConnectToHost) }
            let response = try handler(recorded)
            // Answer asynchronously, like a real server, so concurrent requests overlap.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { [self] in
                let http = HTTPURLResponse(
                    url: recorded.url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers
                )!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: response.body)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Credentials the test can change while a client is using them.
final class TestCredentials: Sendable {
    private let value: Mutex<KavitaCredentials>

    init(serverURL: String = "https://kavita.test", apiKey: String = "key-1") {
        value = Mutex(KavitaCredentials(serverURL: serverURL, apiKey: apiKey))
    }

    var current: KavitaCredentials {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
