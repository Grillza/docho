import Foundation
import Synchronization

/// The Suwayomi server's address and sign-in. Suwayomi runs Mihon's extensions on a computer
/// or server; Dōchō browses and reads through it, so extensions work on iOS without running
/// their code on the device.
final class SuwayomiSettings: Sendable {
    let store: ServerSettings

    init(store: ServerSettings = ServerSettings(prefix: "suwayomi")) {
        self.store = store
    }

    /// The server as opened in a browser, e.g. `http://192.168.1.20:4567`.
    var serverURL: String {
        get { store.string("server_url") }
        set { store.setString("server_url", newValue) }
    }

    /// For servers with basic authentication turned on; empty when it's off.
    var username: String {
        get { store.string("username") }
        set { store.setString("username", newValue) }
    }

    var password: String {
        get { store.secret("password") }
        set { store.setSecret("password", newValue) }
    }

    /// Whether NSFW extensions and sources are listed.
    var showNSFW: Bool {
        get { store.bool("show_nsfw", default: false) }
        set { store.setBool("show_nsfw", newValue) }
    }

    var isConfigured: Bool { baseURL != nil }

    var baseURL: URL? {
        ServerAddress.normalize(serverURL, apiPath: "").flatMap(URL.init(string:))
    }

    func reset() {
        store.reset(plain: ["server_url", "username", "show_nsfw"], secret: ["password"])
    }
}

enum SuwayomiError: LocalizedError, Equatable {
    case notConfigured
    case authRejected
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "Suwayomi is not set up. Add your server in Settings → Sync / Self-hosted sources.")
        case .authRejected: String(localized: "Suwayomi rejected the username or password.")
        case .server(let message): message
        }
    }
}

/// A source on the server (Suwayomi's `SourceType`), as kept between launches.
struct SuwayomiSourceInfo: Codable, Sendable, Equatable, Hashable {
    var id: Int64
    var name: String
    var lang: String
    var supportsLatest: Bool
    var iconPath: String
    var isNSFW: Bool
}

/// An extension on the server (Suwayomi's `ExtensionType`).
struct SuwayomiExtension: Sendable, Equatable, Identifiable, Hashable {
    var id: String { pkgName }
    var pkgName: String
    var name: String
    var lang: String
    var versionName: String
    var iconPath: String
    var isInstalled: Bool
    var hasUpdate: Bool
    var isObsolete: Bool
    var isNSFW: Bool
    var storeName: String?
}

struct SuwayomiStore: Sendable, Equatable, Identifiable, Hashable {
    var id: String { indexURL }
    var indexURL: String
    var name: String
}

/// Suwayomi-Server's GraphQL API (`/api/graphql`), with basic authentication when set.
final class SuwayomiClient: Sendable {
    let settings: SuwayomiSettings
    private let session: URLSession
    /// Suwayomi's own manga ids, by source and URL: listings and details are keyed by them.
    private let mangaIds = Mutex<[String: Int]>([:])

    init(settings: SuwayomiSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    // MARK: Requests

    /// The `Authorization` header, for API calls and images alike.
    var authorization: String? {
        let username = settings.username
        guard !username.isEmpty else { return nil }
        return "Basic " + Data("\(username):\(settings.password)".utf8).base64EncodedString()
    }

    /// A server path such as `/api/v1/manga/3/thumbnail` as a full URL.
    func url(_ path: String) -> URL? {
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        guard let base = settings.baseURL else { return nil }
        return URL(string: base.absoluteString + (path.hasPrefix("/") ? path : "/" + path))
    }

    func request(_ path: String) -> URLRequest? {
        guard let url = url(path) else { return nil }
        var request = URLRequest(url: url)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.setValue(ServerAddress.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    func graphQL(_ query: String, _ variables: [String: Any] = [:]) async throws -> [String: Any] {
        guard var request = request("/api/graphql") else { throw SuwayomiError.notConfigured }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        // Extensions fetch from their sites while answering; give slow ones time.
        request.timeoutInterval = 90
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw SuwayomiError.authRejected }
        guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SuwayomiError.server(String(localized: "Suwayomi returned an error (\(status))"))
        }
        if let errors = reply["errors"] as? [[String: Any]], let first = errors.first {
            throw SuwayomiError.server(first["message"] as? String ?? "GraphQL error")
        }
        return reply["data"] as? [String: Any] ?? [:]
    }

    // MARK: Server

    func about() async throws -> String {
        let data = try await graphQL("query { aboutServer { name version } }")
        let about = data.dict("aboutServer")
        return "\(about?.string("name") ?? "Suwayomi") \(about?.string("version") ?? "")"
    }

    func sources() async throws -> [SuwayomiSourceInfo] {
        let data = try await graphQL("""
            query { sources { nodes { id name lang supportsLatest iconUrl isNsfw: contentWarning } } }
            """)
        return (data.dict("sources")?["nodes"] as? [[String: Any]] ?? []).compactMap { node in
            guard let id = node.int64("id"), id != 0 else { return nil }  // Its Local source; Dōchō has its own.
            return SuwayomiSourceInfo(
                id: id, name: node.string("name") ?? "", lang: node.string("lang") ?? "other",
                supportsLatest: node["supportsLatest"] as? Bool ?? false, iconPath: node.string("iconUrl") ?? "",
                isNSFW: node.string("isNsfw") == "NSFW"
            )
        }
    }

    // MARK: Extensions

    private static let extensionFields = "pkgName name lang versionName iconUrl isInstalled hasUpdate isObsolete contentWarning extensionStore { name }"

    /// Fetches the stores' lists afresh and returns every extension.
    func extensions(refresh: Bool) async throws -> [SuwayomiExtension] {
        let data: [String: Any]
        let nodes: [[String: Any]]
        if refresh {
            data = try await graphQL("mutation { fetchExtensions(input: {}) { extensions { \(Self.extensionFields) } } }")
            nodes = data.dict("fetchExtensions")?["extensions"] as? [[String: Any]] ?? []
        } else {
            data = try await graphQL("query { extensions { nodes { \(Self.extensionFields) } } }")
            nodes = data.dict("extensions")?["nodes"] as? [[String: Any]] ?? []
        }
        return nodes.map { node in
            SuwayomiExtension(
                pkgName: node.string("pkgName") ?? "", name: node.string("name") ?? "", lang: node.string("lang") ?? "",
                versionName: node.string("versionName") ?? "", iconPath: node.string("iconUrl") ?? "",
                isInstalled: node["isInstalled"] as? Bool ?? false, hasUpdate: node["hasUpdate"] as? Bool ?? false,
                isObsolete: node["isObsolete"] as? Bool ?? false,
                isNSFW: node.string("contentWarning") == "NSFW",
                storeName: node.dict("extensionStore")?.string("name")
            )
        }
    }

    enum ExtensionChange: String {
        case install, uninstall, update
    }

    func change(_ pkgName: String, _ change: ExtensionChange) async throws {
        _ = try await graphQL("""
            mutation($id: String!, $patch: UpdateExtensionPatchInput!) { updateExtension(input: { id: $id, patch: $patch }) { clientMutationId } }
            """, ["id": pkgName, "patch": [change.rawValue: true]])
    }

    func stores() async throws -> [SuwayomiStore] {
        let data = try await graphQL("query { extensionStores { nodes { indexUrl name } } }")
        return (data.dict("extensionStores")?["nodes"] as? [[String: Any]] ?? []).map {
            SuwayomiStore(indexURL: $0.string("indexUrl") ?? "", name: $0.string("name") ?? "")
        }
    }

    func addStore(_ indexURL: String) async throws {
        _ = try await graphQL("""
            mutation($url: String!) { addExtensionStore(input: { indexUrl: $url }) { clientMutationId } }
            """, ["url": indexURL])
    }

    func removeStore(_ indexURL: String) async throws {
        _ = try await graphQL("""
            mutation($url: String!) { removeExtensionStore(input: { indexUrl: $url }) { clientMutationId } }
            """, ["url": indexURL])
    }

    // MARK: Browsing and reading

    private static let mangaFields = "id url title thumbnailUrl artist author description genre status initialized"

    /// A page of a source's listing; `type` is POPULAR, LATEST or SEARCH.
    func fetchSourceManga(source: Int64, type: String, page: Int, query: String?, filters: [[String: Any]]) async throws -> MangasPage {
        var variables: [String: Any] = ["source": String(source), "type": type, "page": page]
        if let query { variables["query"] = query }
        if !filters.isEmpty { variables["filters"] = filters }
        let data = try await graphQL("""
            mutation($source: LongString!, $type: FetchSourceMangaType!, $page: Int!, $query: String, $filters: [FilterChangeInput!]) {
              fetchSourceManga(input: { source: $source, type: $type, page: $page, query: $query, filters: $filters }) {
                hasNextPage mangas { \(Self.mangaFields) } } }
            """, variables)
        let payload = data.dict("fetchSourceManga")
        let nodes = payload?["mangas"] as? [[String: Any]] ?? []
        return MangasPage(mangas: nodes.map { manga(source: source, $0) }, hasNextPage: payload?["hasNextPage"] as? Bool ?? false)
    }

    /// The listing entry as an `SManga`, remembering Suwayomi's id for it.
    private func manga(source: Int64, _ node: [String: Any]) -> SManga {
        let url = node.string("url") ?? ""
        if let id = node["id"] as? Int { mangaIds.withLock { $0["\(source)|\(url)"] = id } }
        return SManga(
            url: url, title: node.string("title") ?? "", artist: node.string("artist"), author: node.string("author"),
            description: node.string("description"), genre: (node["genre"] as? [String]).map { $0.joined(separator: ", ") },
            status: Self.status(node.string("status")), thumbnailURL: node.string("thumbnailUrl"),
            initialized: node["initialized"] as? Bool ?? false
        )
    }

    private static func status(_ value: String?) -> MangaStatus {
        switch value {
        case "ONGOING": .ongoing
        case "COMPLETED": .completed
        case "LICENSED": .licensed
        case "PUBLISHING_FINISHED": .publishingFinished
        case "CANCELLED": .cancelled
        case "ON_HIATUS": .onHiatus
        default: .unknown
        }
    }

    /// Suwayomi's id for a series, looked up by source and URL if it hasn't been listed this launch.
    func mangaId(source: Int64, url: String) async throws -> Int {
        if let id = mangaIds.withLock({ $0["\(source)|\(url)"] }) { return id }
        let data = try await graphQL("""
            query($source: LongString!, $url: String!) { mangas(condition: { sourceId: $source, url: $url }) { nodes { id } } }
            """, ["source": String(source), "url": url])
        guard let id = (data.dict("mangas")?["nodes"] as? [[String: Any]])?.first?["id"] as? Int else {
            throw SuwayomiError.server(String(localized: "Suwayomi doesn't know this series yet. Find it in the source's listing first."))
        }
        mangaIds.withLock { $0["\(source)|\(url)"] = id }
        return id
    }

    /// Fetches the series from the source through the server: its details, its chapters, or both.
    func fetch(source: Int64, manga: SManga, details: Bool, chapters: Bool) async throws -> (SManga, [SChapter]?) {
        let id = try await mangaId(source: source, url: manga.url)
        let data = try await graphQL("""
            mutation($id: Int!, $manga: Boolean!, $chapters: Boolean!) {
              fetchMangaAndChapters(input: { id: $id, fetchManga: $manga, fetchChapters: $chapters }) {
                manga { \(Self.mangaFields) }
                chapters { id url name chapterNumber scanlator uploadDate sourceOrder pageCount } } }
            """, ["id": id, "manga": details, "chapters": chapters])
        let payload = data.dict("fetchMangaAndChapters")
        var updated = manga
        if details, let node = payload?.dict("manga") {
            updated = self.manga(source: source, node)
            updated.initialized = true
        }
        guard chapters else { return (updated, nil) }
        // Suwayomi's sourceOrder counts up from the oldest chapter: reading order, as Dōchō stores it.
        let list = (payload?["chapters"] as? [[String: Any]] ?? [])
            .sorted { ($0["sourceOrder"] as? Int ?? 0) < ($1["sourceOrder"] as? Int ?? 0) }
            .map { node in
                var chapter = SChapter(
                    url: node.string("url") ?? "", name: node.string("name") ?? "",
                    dateUpload: node.double("uploadDate").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil },
                    number: node.double("chapterNumber") ?? -1, scanlator: node.string("scanlator")
                )
                if let id = node["id"] as? Int { chapter.memo.values[Self.chapterIdKey] = .int(id) }
                return chapter
            }
        return (updated, list)
    }

    static let chapterIdKey = "suwayomiChapterId"

    /// The chapter's page images, as server paths.
    func pages(chapterId: Int) async throws -> [String] {
        let data = try await graphQL("""
            mutation($id: Int!) { fetchChapterPages(input: { chapterId: $id }) { pages } }
            """, ["id": chapterId])
        return data.dict("fetchChapterPages")?["pages"] as? [String] ?? []
    }

    /// The chapter's Suwayomi id, from its memo or looked up by URL.
    func chapterId(_ chapter: SChapter) async throws -> Int {
        if let id = chapter.memo.int(Self.chapterIdKey) { return id }
        let data = try await graphQL("""
            query($url: String!) { chapters(condition: { url: $url }) { nodes { id } } }
            """, ["url": chapter.url])
        guard let id = (data.dict("chapters")?["nodes"] as? [[String: Any]])?.first?["id"] as? Int else { throw SourceError.noPages }
        return id
    }

    // MARK: Filters

    func filters(source: Int64) async throws -> [SourceFilter] {
        // Filter is a union: each member is asked for its own fields.
        let fields = """
            __typename
            ... on HeaderFilter { name }
            ... on SeparatorFilter { name }
            ... on CheckBoxFilter { name checkDefault: default }
            ... on SelectFilter { name selectDefault: default values }
            ... on TriStateFilter { name triDefault: default }
            ... on TextFilter { name textDefault: default }
            ... on SortFilter { name sortDefault: default { index ascending } values }
            """
        let data = try await graphQL("""
            query($id: LongString!) { source(id: $id) { filters { \(fields) ... on GroupFilter { name filters { \(fields) } } } } }
            """, ["id": String(source)])
        return (data.dict("source")?["filters"] as? [[String: Any]] ?? []).map(Self.filter)
    }

    private static func filter(_ node: [String: Any]) -> SourceFilter {
        let name = node.string("name") ?? ""
        switch node.string("__typename") {
        case "HeaderFilter": return .header(name)
        case "SeparatorFilter": return .separator
        case "CheckBoxFilter": return .checkBox(name: name, state: node["checkDefault"] as? Bool ?? false)
        case "SelectFilter": return .select(name: name, values: node["values"] as? [String] ?? [], state: node["selectDefault"] as? Int ?? 0)
        case "TriStateFilter":
            let state = switch node.string("triDefault") { case "INCLUDE": 1; case "EXCLUDE": 2; default: 0 }
            return .triState(name: name, state: state)
        case "TextFilter": return .text(name: name, state: node.string("textDefault") ?? "")
        case "SortFilter":
            let selection = node.dict("sortDefault").map {
                SourceFilter.SortSelection(index: $0["index"] as? Int ?? 0, ascending: $0["ascending"] as? Bool ?? false)
            }
            return .sort(name: name, values: node["values"] as? [String] ?? [], selection: selection)
        case "GroupFilter": return .group(name: name, filters: (node["filters"] as? [[String: Any]] ?? []).map(filter))
        default: return .header(name)
        }
    }

    /// The changes from the defaults as Suwayomi's `FilterChangeInput`s, by position.
    static func changes(_ filters: [SourceFilter], defaults: [SourceFilter]) -> [[String: Any]] {
        var changes: [[String: Any]] = []
        for (position, filter) in filters.enumerated() {
            let initial = position < defaults.count ? defaults[position] : nil
            guard initial == nil || filter != initial! else { continue }
            if case .group(_, let children) = filter {
                var initialChildren: [SourceFilter] = []
                if case .group(_, let defaults)? = initial { initialChildren = defaults }
                for change in Self.changes(children, defaults: initialChildren) {
                    changes.append(["position": position, "groupChange": change])
                }
            } else if let change = Self.change(filter) {
                changes.append(change.merging(["position": position]) { $1 })
            }
        }
        return changes
    }

    private static func change(_ filter: SourceFilter) -> [String: Any]? {
        switch filter {
        case .checkBox(_, let state): ["checkBoxState": state]
        case .select(_, _, let state): ["selectState": state]
        case .text(_, let state): ["textState": state]
        case .triState(_, let state): ["triState": state == 1 ? "INCLUDE" : state == 2 ? "EXCLUDE" : "IGNORE"]
        case .sort(_, _, let selection):
            selection.map { ["sortState": ["index": $0.index, "ascending": $0.ascending]] }
        default: nil
        }
    }
}
