import Foundation
import os

/// The app's side of the extension host (PLAN-2, Part G): typed JSON-RPC calls over a transport,
/// and the services the host asks the app for. Extension HTTP is performed with URLSession
/// (`ExtensionNetwork`). Cloudflare challenges and extension WebViews come in part G6; until then a
/// challenge is answered as unsolved, so the source reports Cloudflare's error.
actor ExtensionHost {
    typealias RPC = ExtensionRPC

    let transport: any ExtensionTransport
    private let network = ExtensionNetwork()
    private let log = Logger(subsystem: "io.github.grillza.docho", category: "extensions")
    private var nextId = 0
    private var started: Task<RPC.Hello, Error>?
    private var eventLoop: Task<Void, Never>?
    private var fetches: [String: Task<Void, Never>] = [:]
    private var progressListeners: [UUID: AsyncStream<RPC.ExtensionProgress>.Continuation] = [:]
    private var toastHandler: (@Sendable (String) -> Void)?

    /// The user agent extensions see (Mihon's default is a desktop Chrome one; the host replaces
    /// Android WebView ones with it).
    static let userAgent = "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Runs once before the first call: starts the embedded JVM (blocking, off the actor).
    private let prepare: @Sendable () throws -> Void

    init(transport: any ExtensionTransport, prepare: @escaping @Sendable () throws -> Void = {}) {
        self.transport = transport
        self.prepare = prepare
    }

    // MARK: Start-up

    /// Connects to the host the first time it's needed: listens for its events, checks the
    /// protocol and sets it up. Later calls wait for the same start.
    @discardableResult
    func start() async throws -> RPC.Hello {
        if let started { return try await started.value }
        if eventLoop == nil {
            let events = transport.events()
            eventLoop = Task { [weak self] in
                for await event in events { await self?.handle(event) }
            }
        }
        let prepare = prepare
        let task = Task<RPC.Hello, Error> {
            try await Task.detached(priority: .userInitiated) { try prepare() }.value
            let hello: RPC.Hello = try await self.rawCall("host.hello", SyncJSON.object([:]))
            guard hello.protocolVersion >= RPC.protocolVersion else {
                throw RPC.RPCError(code: "INTERNAL", message: "The extension host speaks protocol \(hello.protocolVersion), the app \(RPC.protocolVersion)")
            }
            let params = RPC.InitParams(userAgent: Self.userAgent, replaceAndroidUserAgents: true, bypassEnabled: true, nativeNet: true, webView: false)
            let _: SyncJSON? = try await self.rawCall("host.init", params)
            return hello
        }
        started = task
        do {
            return try await task.value
        } catch {
            started = nil
            throw error
        }
    }

    func onToast(_ handler: @escaping @Sendable (String) -> Void) {
        toastHandler = handler
    }

    /// Install and update progress, for as long as the stream is read.
    func progress() -> AsyncStream<RPC.ExtensionProgress> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: RPC.ExtensionProgress.self)
        progressListeners[id] = continuation
        continuation.onTermination = { _ in Task { await self.removeListener(id) } }
        return stream
    }

    private func removeListener(_ id: UUID) {
        progressListeners[id] = nil
    }

    // MARK: Calls

    private func rawCall<T: Decodable>(_ method: String, _ params: some Encodable) async throws -> T {
        nextId += 1
        let request = RPC.Request(id: String(nextId), method: method, params: try SyncJSON(encoding: params))
        let data = try await transport.call(JSONEncoder().encode(request))
        let response = try JSONDecoder().decode(RPC.Response.self, from: data)
        if let error = response.error { throw error }
        return try (response.result ?? .null).decoded(T.self)
    }

    /// Calls `method` once the host is started.
    func call<T: Decodable>(_ method: String, _ params: some Encodable = SyncJSON.object([:]), as type: T.Type = T.self) async throws -> T {
        try await start()
        return try await rawCall(method, params)
    }

    // MARK: Repos and extensions

    func repos() async throws -> [RPC.Repo] { try await call("repo.list") }
    func addRepo(_ url: String) async throws -> RPC.Repo { try await call("repo.add", ["url": url]) }
    func removeRepo(_ url: String) async throws { let _: SyncJSON? = try await call("repo.remove", ["url": url]) }
    func refreshRepos() async throws -> RPC.RepoRefresh { try await call("repo.refresh") }

    func availableExtensions(includeNsfw: Bool) async throws -> [RPC.AvailableExtension] {
        try await call("ext.listAvailable", SyncJSON.object(["includeNsfw": .bool(includeNsfw)]))
    }

    func installedExtensions() async throws -> [RPC.InstalledExtension] { try await call("ext.listInstalled") }

    /// Starts an install; follow it with `progress()`.
    func install(_ pkgName: String, repo: String?) async throws -> RPC.Job {
        var params: [String: SyncJSON] = ["pkgName": .string(pkgName)]
        if let repo { params["repoIndexUrl"] = .string(repo) }
        return try await call("ext.install", SyncJSON.object(params))
    }

    func update(_ pkgName: String) async throws -> RPC.Job { try await call("ext.update", ["pkgName": pkgName]) }
    func uninstall(_ pkgName: String) async throws { let _: SyncJSON? = try await call("ext.uninstall", ["pkgName": pkgName]) }

    func trust(_ ext: RPC.InstalledExtension) async throws -> RPC.InstalledExtension {
        try await call("ext.trust", SyncJSON.object([
            "pkgName": .string(ext.pkgName), "versionCode": .int(ext.versionCode), "signatureHash": .string(ext.signatureHash ?? ""),
        ]))
    }

    func icon(_ pkgName: String) async throws -> Data? {
        let icon: RPC.Icon = try await call("ext.icon", ["pkgName": pkgName])
        guard let path = icon.path else { return nil }
        return try await transport.readFile(path)
    }

    // MARK: Sources

    func sources() async throws -> [RPC.Source] { try await call("source.list") }

    func popular(_ sourceId: String, page: Int) async throws -> RPC.MangasPage {
        try await call("source.popular", SyncJSON.object(["sourceId": .string(sourceId), "page": .int(Int64(page))]))
    }

    func latest(_ sourceId: String, page: Int) async throws -> RPC.MangasPage {
        try await call("source.latest", SyncJSON.object(["sourceId": .string(sourceId), "page": .int(Int64(page))]))
    }

    func search(_ sourceId: String, page: Int, query: String, filters: [RPC.Filter]?) async throws -> RPC.MangasPage {
        var params: [String: SyncJSON] = ["sourceId": .string(sourceId), "page": .int(Int64(page)), "query": .string(query)]
        if let filters { params["filters"] = try SyncJSON(encoding: filters) }
        return try await call("source.search", SyncJSON.object(params))
    }

    func filters(_ sourceId: String) async throws -> [RPC.Filter] { try await call("source.filters", ["sourceId": sourceId]) }

    func mangaUpdate(_ sourceId: String, manga: RPC.Manga, chapters: [RPC.Chapter], details: Bool, fetchChapters: Bool) async throws -> RPC.MangaUpdate {
        try await call("source.mangaUpdate", SyncJSON.object([
            "sourceId": .string(sourceId), "manga": try SyncJSON(encoding: manga), "chapters": try SyncJSON(encoding: chapters),
            "fetchDetails": .bool(details), "fetchChapters": .bool(fetchChapters),
        ]))
    }

    func pages(_ sourceId: String, chapter: RPC.Chapter) async throws -> [RPC.Page] {
        try await call("source.pages", SyncJSON.object(["sourceId": .string(sourceId), "chapter": try SyncJSON(encoding: chapter)]))
    }

    /// A page's image, fetched by the extension (with its headers and interceptors).
    func image(_ sourceId: String, page: RPC.Page) async throws -> (data: Data, mimeType: String?) {
        let file: RPC.ImageFile = try await call("source.fetchImage", SyncJSON.object(["sourceId": .string(sourceId), "page": try SyncJSON(encoding: page)]))
        return (try await transport.readFile(file.path), file.mimeType)
    }

    func cover(_ sourceId: String, url: String) async throws -> (data: Data, mimeType: String?) {
        let file: RPC.ImageFile = try await call("source.fetchCover", SyncJSON.object(["sourceId": .string(sourceId), "url": .string(url)]))
        return (try await transport.readFile(file.path), file.mimeType)
    }

    func mangaURL(_ sourceId: String, manga: RPC.Manga) async throws -> String {
        let url: RPC.URLValue = try await call("source.mangaUrl", SyncJSON.object(["sourceId": .string(sourceId), "manga": try SyncJSON(encoding: manga)]))
        return url.url
    }

    func preferences(_ sourceId: String) async throws -> [RPC.Preference] { try await call("source.preferences", ["sourceId": sourceId]) }

    func setPreference(_ sourceId: String, index: Int, key: String?, value: SyncJSON) async throws -> RPC.SetPreferenceResult {
        var params: [String: SyncJSON] = ["sourceId": .string(sourceId), "index": .int(Int64(index)), "value": value]
        if let key { params["key"] = .string(key) }
        return try await call("source.setPreference", SyncJSON.object(params))
    }

    // MARK: Events

    private func handle(_ event: ExtensionHostEvent) {
        switch event {
        case .fetch(let fetch, let body):
            let network = network
            let transport = transport
            fetches[fetch.id] = Task {
                let (result, data) = await network.perform(fetch, body: body)
                await transport.respond(result, body: data)
                self.finishFetch(fetch.id)
            }
        case .fetchCancel(let id):
            fetches.removeValue(forKey: id)?.cancel()
        case .other(let event):
            switch event.event {
            case "ext.progress":
                if let progress = try? event.data.decoded(RPC.ExtensionProgress.self) {
                    for listener in progressListeners.values { listener.yield(progress) }
                }
            case "host.toast":
                if let toast = try? event.data.decoded(RPC.Toast.self) { toastHandler?(toast.text) }
            case "net.challengeRequired":
                // Part G6 shows Cloudflare's challenge in a WKWebView; until then it isn't solved.
                if let challenge = try? event.data.decoded(RPC.ChallengeRequired.self) {
                    Task {
                        let resolved = RPC.ChallengeResolved(challengeId: challenge.challengeId, solved: false, reason: "Not supported yet")
                        let _: SyncJSON? = try? await self.rawCall("net.challengeResolved", resolved)
                    }
                }
            default:
                log.debug("Extension host event \(event.event) not handled")
            }
        }
    }

    private func finishFetch(_ id: String) {
        fetches[id] = nil
    }
}
