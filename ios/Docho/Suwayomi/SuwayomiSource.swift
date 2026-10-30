import Foundation

/// One of the server's sources (an installed extension's), browsed and read through Suwayomi.
/// It keeps the extension's own source id and URLs, so its series are the same as Mihon's.
struct SuwayomiSource: MangaSource {
    let info: SuwayomiSourceInfo
    let client: SuwayomiClient

    var id: Int64 { info.id }
    var name: String { info.name }
    var lang: String { info.lang }
    var supportsLatest: Bool { info.supportsLatest }
    var isConfigured: Bool { client.settings.isConfigured }
    var iconURL: URL? { client.url(info.iconPath) }

    func popular(page: Int) async throws -> MangasPage {
        try await client.fetchSourceManga(source: id, type: "POPULAR", page: page, query: nil, filters: [])
    }

    func latest(page: Int) async throws -> MangasPage {
        try await client.fetchSourceManga(source: id, type: "LATEST", page: page, query: nil, filters: [])
    }

    func search(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        let defaults = await filterList()
        return try await client.fetchSourceManga(
            source: id, type: "SEARCH", page: page, query: query, filters: SuwayomiClient.changes(filters, defaults: defaults)
        )
    }

    func filterList() async -> [SourceFilter] {
        (try? await client.filters(source: id)) ?? []
    }

    func update(_ manga: SManga, details: Bool, chapters: Bool) async throws -> (manga: SManga, chapters: [SChapter]?) {
        let (updated, list) = try await client.fetch(source: id, manga: manga, details: details, chapters: chapters)
        return (updated, list)
    }

    func pages(_ chapter: SChapter) async throws -> [SourcePage] {
        let paths = try await client.pages(chapterId: try await client.chapterId(chapter))
        let urls = paths.compactMap(client.url)
        guard !urls.isEmpty else { throw SourceError.noPages }
        return urls.enumerated().map { SourcePage(index: $0.offset, imageURL: $0.element) }
    }

    func imageRequest(_ page: SourcePage) -> URLRequest {
        var request = URLRequest(url: page.imageURL)
        if let authorization = client.authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        // The server fetches the page from the site on first request; that can take a while.
        request.timeoutInterval = 90
        return request
    }

    func coverRequest(_ manga: SManga) -> URLRequest? {
        manga.thumbnailURL.flatMap(client.request)
    }
}

/// The server's sources and extensions, for Browse. Sources are remembered between launches so
/// series from them open before the server has answered.
@MainActor
@Observable
final class SuwayomiModel {
    let client: SuwayomiClient
    private let sources: SourceManager
    private let defaults: UserDefaults
    private static let cacheKey = "suwayomi_sources_cache"

    private(set) var sourceInfos: [SuwayomiSourceInfo] = []
    private(set) var extensions: [SuwayomiExtension] = []
    private(set) var stores: [SuwayomiStore] = []
    private(set) var isLoading = false
    private(set) var error: String?
    /// Packages being installed, updated or removed.
    private(set) var working: Set<String> = []

    init(client: SuwayomiClient, sources: SourceManager, defaults: UserDefaults = .standard) {
        self.client = client
        self.sources = sources
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([SuwayomiSourceInfo].self, from: data) {
            apply(cached)
        }
    }

    var isConfigured: Bool { client.settings.isConfigured }

    private func apply(_ infos: [SuwayomiSourceInfo]) {
        sourceInfos = infos
        sources.setDynamic(client.settings.isConfigured ? infos.map { SuwayomiSource(info: $0, client: client) } : [])
    }

    /// Asks the server for its sources (after setup, or an extension change).
    func refreshSources() async {
        guard isConfigured else {
            apply([])
            return
        }
        do {
            let infos = try await client.sources()
            apply(infos)
            defaults.set(try? JSONEncoder().encode(infos), forKey: Self.cacheKey)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Loads the extension list; `refresh` asks the stores for their newest lists first.
    func loadExtensions(refresh: Bool) async {
        guard isConfigured else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            extensions = try await client.extensions(refresh: refresh)
            stores = try await client.stores()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func change(_ ext: SuwayomiExtension, _ change: SuwayomiClient.ExtensionChange) async {
        working.insert(ext.pkgName)
        defer { working.remove(ext.pkgName) }
        do {
            try await client.change(ext.pkgName, change)
            extensions = try await client.extensions(refresh: false)
            await refreshSources()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addStore(_ url: String) async throws {
        try await client.addStore(url.trimmingCharacters(in: .whitespacesAndNewlines))
        await loadExtensions(refresh: true)
    }

    func removeStore(_ store: SuwayomiStore) async {
        do {
            try await client.removeStore(store.indexURL)
            await loadExtensions(refresh: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// After the server address changes: forget what the old one had.
    func serverChanged() async {
        extensions = []
        stores = []
        await refreshSources()
    }
}
