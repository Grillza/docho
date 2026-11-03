import Foundation

/// What the host sends the app outside of answers to calls.
enum ExtensionHostEvent: Sendable {
    /// An extension HTTP request for the app to perform (`net.fetch`), with its raw body.
    case fetch(ExtensionRPC.NetFetch, body: Data?)
    /// The host no longer needs the answer to fetch `id`.
    case fetchCancel(id: String)
    /// Any other event (`ext.progress`, `host.toast`, `net.challengeRequired`, `webview.command`).
    case other(ExtensionRPC.Event)
}

/// How the app reaches the extension host: over JNI to the JVM in the app (`EmbeddedExtensionTransport`,
/// part G5), or over HTTP and Server-Sent Events to the runtime's desktop development host.
protocol ExtensionTransport: Sendable {
    /// Sends one JSON-RPC request and returns its response, both as JSON.
    func call(_ request: Data) async throws -> Data
    /// The host's events, for as long as the transport is open.
    func events() -> AsyncStream<ExtensionHostEvent>
    /// The app's answer to a `fetch` event: `net.fetchResult` without the body, and the raw body.
    func respond(_ result: ExtensionRPC.NetFetchResult, body: Data?) async
    /// A file the host wrote (a fetched image, an extension icon).
    func readFile(_ path: String) async throws -> Data
}

/// The runtime's desktop development host (`./gradlew :host-desktop:run` in
/// `Vendor/docho-runtime/extension-host`): `POST /rpc`, `GET /events` (SSE) and `GET /file`.
final class HTTPExtensionTransport: ExtensionTransport {
    let baseURL: URL
    private let token: String?
    private let session: URLSession

    init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: configuration)
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        if let token { request.setValue(token, forHTTPHeaderField: "X-Oneechan-Token") }
        return request
    }

    func call(_ body: Data) async throws -> Data {
        var request = request("rpc")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ExtensionRPC.RPCError(code: "INTERNAL", message: "The extension host answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    func events() -> AsyncStream<ExtensionHostEvent> {
        let request = request("events")
        let session = session
        return AsyncStream { continuation in
            let task = Task {
                // Reconnects while the stream is wanted: the dev host may restart.
                while !Task.isCancelled {
                    do {
                        let (bytes, _) = try await session.bytes(for: request)
                        // The host writes each event as one `data:` line of JSON.
                        for try await line in bytes.lines where line.hasPrefix("data:") {
                            if let event = Self.decode(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) {
                                continuation.yield(event)
                            }
                        }
                    } catch {}
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func decode(_ text: String) -> ExtensionHostEvent? {
        guard let event = try? JSONDecoder().decode(ExtensionRPC.Event.self, from: Data(text.utf8)) else { return nil }
        switch event.event {
        case "net.fetch":
            guard let fetch = try? event.data.decoded(ExtensionRPC.NetFetch.self) else { return nil }
            return .fetch(fetch, body: fetch.bodyBase64.flatMap { Data(base64Encoded: $0) })
        case "net.fetchCancel":
            return event.data["id"]?.string.map { .fetchCancel(id: $0) }
        default:
            return .other(event)
        }
    }

    func respond(_ result: ExtensionRPC.NetFetchResult, body: Data?) async {
        var result = result
        result.bodyBase64 = body?.base64EncodedString()
        let request = ExtensionRPC.Request(id: "fetch-\(result.id)", method: "net.fetchResult", params: (try? SyncJSON(encoding: result)) ?? .null)
        guard let data = try? JSONEncoder().encode(request) else { return }
        _ = try? await call(data)
    }

    func readFile(_ path: String) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: "file"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "consume", value: "1")]
        var request = URLRequest(url: components.url!)
        if let token { request.setValue(token, forHTTPHeaderField: "X-Oneechan-Token") }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ExtensionRPC.RPCError(code: "NOT_FOUND", message: "The extension host has no file \(path)")
        }
        return data
    }
}

extension SyncJSON {
    /// The value as `T`, through JSON.
    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    /// `value` as a JSON value.
    init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(SyncJSON.self, from: JSONEncoder().encode(value))
    }
}

// MARK: - Extension HTTP through URLSession

/// Performs extension HTTP requests for the host (its `NativeNet`): no redirects followed (OkHttp
/// follows them, so every hop gets the cookie jar's cookies), no cookies of URLSession's own (the
/// jar sends them as headers), and bodies decoded, with `Content-Encoding` left out.
final class ExtensionNetwork: NSObject, URLSessionTaskDelegate, Sendable {
    private let session: URLSession

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [:]
        session = URLSession(configuration: configuration)
        super.init()
    }

    func perform(_ fetch: ExtensionRPC.NetFetch, body: Data?) async -> (ExtensionRPC.NetFetchResult, Data?) {
        guard let url = URL(string: fetch.url) else {
            return (.init(id: fetch.id, error: .init(code: "NETWORK", message: "Bad URL \(fetch.url)")), nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = fetch.method
        request.timeoutInterval = max(1, Double(fetch.timeoutMillis) / 1000)
        request.httpShouldHandleCookies = false
        for pair in fetch.headers where pair.count == 2 {
            request.addValue(pair[1], forHTTPHeaderField: pair[0])
        }
        if let body, !["GET", "HEAD"].contains(fetch.method) { request.httpBody = body }
        do {
            let (data, response) = try await session.data(for: request, delegate: self)
            guard let http = response as? HTTPURLResponse else {
                return (.init(id: fetch.id, error: .init(code: "NETWORK", message: "No HTTP response")), nil)
            }
            var headers: [[String]] = []
            for (name, value) in http.allHeaderFields {
                guard let name = name as? String, let value = value as? String else { continue }
                // URLSession has decoded the body already.
                if ["content-encoding", "content-length", "transfer-encoding"].contains(name.lowercased()) { continue }
                // URLSession joins repeated headers with ", "; Set-Cookie must go back one per line.
                if name.lowercased() != "set-cookie" { headers.append([name, value]) }
            }
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": http.value(forHTTPHeaderField: "Set-Cookie") ?? ""], for: url) {
                headers.append(["Set-Cookie", Self.setCookieLine(cookie)])
            }
            let message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized
            return (.init(id: fetch.id, code: http.statusCode, message: message, headers: headers), data)
        } catch let error as URLError where error.code == .timedOut {
            return (.init(id: fetch.id, error: .init(code: "TIMEOUT", message: error.localizedDescription, retryable: true)), nil)
        } catch is CancellationError {
            return (.init(id: fetch.id, error: .init(code: "CANCELLED", message: "Cancelled")), nil)
        } catch let error as URLError where error.code == .cancelled {
            return (.init(id: fetch.id, error: .init(code: "CANCELLED", message: "Cancelled")), nil)
        } catch {
            return (.init(id: fetch.id, error: .init(code: "NETWORK", message: error.localizedDescription, retryable: true)), nil)
        }
    }

    /// Redirects come back to the host as they are.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }

    /// One `Set-Cookie` line for `cookie`. A host-only cookie (no leading dot) gets no Domain.
    static func setCookieLine(_ cookie: HTTPCookie) -> String {
        var line = "\(cookie.name)=\(cookie.value)"
        if cookie.domain.hasPrefix(".") { line += "; Domain=\(cookie.domain)" }
        line += "; Path=\(cookie.path)"
        if let expires = cookie.expiresDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            line += "; Expires=\(formatter.string(from: expires))"
        }
        if cookie.isSecure { line += "; Secure" }
        if cookie.isHTTPOnly { line += "; HttpOnly" }
        if let sameSite = cookie.sameSitePolicy { line += "; SameSite=\(sameSite.rawValue)" }
        return line
    }
}
