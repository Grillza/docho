import Foundation

/// A source from an extension installed on the device (Part G), run by the extension host.
/// Pages and covers are `docho-ext://` URLs, which `ExtensionImageProtocol` (and the download
/// queue) fetch through the host, so the extension's headers and interceptors apply.
struct ExtensionSource: MangaSource {
    let host: ExtensionHost
    let info: ExtensionRPC.Source

    var id: Int64 { Int64(info.id) ?? 0 }
    var name: String { info.name }
    var lang: String { info.lang }
    var supportsLatest: Bool { info.supportsLatest }
    var isConfigured: Bool { true }

    func popular(page: Int) async throws -> MangasPage {
        MangasPage(try await host.popular(info.id, page: page))
    }

    func latest(page: Int) async throws -> MangasPage {
        MangasPage(try await host.latest(info.id, page: page))
    }

    func search(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        MangasPage(try await host.search(info.id, page: page, query: query, filters: filters.isEmpty ? nil : filters.map(ExtensionRPC.Filter.init)))
    }

    func filterList() async -> [SourceFilter] {
        (try? await host.filters(info.id).map(\.sourceFilter)) ?? []
    }

    func update(_ manga: SManga, details: Bool, chapters: Bool) async throws -> (manga: SManga, chapters: [SChapter]?) {
        let update = try await host.mangaUpdate(info.id, manga: .init(manga), chapters: [], details: details, fetchChapters: chapters)
        var result = update.manga.smanga
        if !details { result = manga }
        // Extensions list chapters newest first; the app stores reading order.
        return (result, chapters ? update.chapters.reversed().map(\.schapter) : nil)
    }

    func pages(_ chapter: SChapter) async throws -> [SourcePage] {
        let pages = try await host.pages(info.id, chapter: .init(chapter))
        guard !pages.isEmpty else { throw SourceError.noPages }
        return pages.compactMap { page in
            ExtensionImageURL.page(source: info.id, page: page).map { SourcePage(index: page.index, imageURL: $0) }
        }
    }

    func coverRequest(_ manga: SManga) -> URLRequest? {
        guard let thumbnail = manga.thumbnailURL, !thumbnail.isEmpty else { return nil }
        return ExtensionImageURL.cover(source: info.id, url: thumbnail).map { URLRequest(url: $0) }
    }

    func webURL(_ manga: SManga) -> URL? {
        if let url = URL(string: manga.url), url.scheme != nil { return url }
        guard let base = info.baseUrl else { return nil }
        return URL(string: base + manga.url)
    }
}

extension MangasPage {
    init(_ page: ExtensionRPC.MangasPage) {
        self.init(mangas: page.mangas.map(\.smanga), hasNextPage: page.hasNextPage)
    }
}

/// `docho-ext://page?source=…&page=…` and `docho-ext://cover?source=…&url=…`: images an extension
/// fetches. The page is its JSON, so the extension gets back exactly what it gave.
enum ExtensionImageURL {
    static let scheme = "docho-ext"

    enum Target {
        case page(source: String, page: ExtensionRPC.Page)
        case cover(source: String, url: String)
    }

    static func page(source: String, page: ExtensionRPC.Page) -> URL? {
        guard let json = try? JSONEncoder().encode(page) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "page"
        components.queryItems = [URLQueryItem(name: "source", value: source), URLQueryItem(name: "page", value: String(decoding: json, as: UTF8.self))]
        return components.url
    }

    static func cover(source: String, url: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "cover"
        components.queryItems = [URLQueryItem(name: "source", value: source), URLQueryItem(name: "url", value: url)]
        return components.url
    }

    static func target(of url: URL) -> Target? {
        guard url.scheme == scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }) { first, _ in first }
        guard let source = items["source"] else { return nil }
        switch components.host {
        case "page":
            guard let json = items["page"], let page = try? JSONDecoder().decode(ExtensionRPC.Page.self, from: Data(json.utf8)) else { return nil }
            return .page(source: source, page: page)
        case "cover":
            return items["url"].map { .cover(source: source, url: $0) }
        default:
            return nil
        }
    }

    /// The image `url` names, fetched by its extension.
    static func fetch(_ url: URL, host: ExtensionHost) async throws -> (data: Data, mimeType: String?) {
        switch target(of: url) {
        case .page(let source, let page): try await host.image(source, page: page)
        case .cover(let source, let cover): try await host.cover(source, url: cover)
        case nil: throw URLError(.unsupportedURL)
        }
    }
}

/// Serves `docho-ext://` URLs to URLSession (the image pipeline) from the extension host.
final class ExtensionImageProtocol: URLProtocol, @unchecked Sendable {
    /// The host images come from; set when extensions are turned on.
    nonisolated(unsafe) static var host: ExtensionHost?

    private var loading: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == ExtensionImageURL.scheme }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = Self.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        // URLSession calls the client back on any thread; the protocol object outlives the task.
        let parts = Loading(me: self, client: client)
        loading = Task {
            let me = parts.me, client = parts.client
            do {
                let (data, mimeType) = try await ExtensionImageURL.fetch(url, host: host)
                let response = URLResponse(url: url, mimeType: mimeType ?? "image/jpeg", expectedContentLength: data.count, textEncodingName: nil)
                client?.urlProtocol(me, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(me, didLoad: data)
                client?.urlProtocolDidFinishLoading(me)
            } catch {
                client?.urlProtocol(me, didFailWithError: error)
            }
        }
    }

    /// What the loading task needs from URLSession's thread; URLSession keeps both alive.
    private struct Loading: @unchecked Sendable {
        let me: ExtensionImageProtocol
        let client: (any URLProtocolClient)?
    }

    override func stopLoading() {
        loading?.cancel()
    }
}
