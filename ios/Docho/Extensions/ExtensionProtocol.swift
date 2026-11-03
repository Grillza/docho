import Foundation

/// The extension host's JSON-RPC protocol (`Vendor/docho-runtime/extension-host/host-core/…/rpc/Protocol.kt`).
/// The protocol only grows: fields and calls are added, never changed or removed. Every type here
/// is checked against `Vendor/docho-runtime/contract/fixtures` by `ExtensionContractTests`.
enum ExtensionRPC {
    static let protocolVersion = 1

    // MARK: Envelope

    struct Request: Codable, Sendable {
        var id: String
        var method: String
        var params: SyncJSON
    }

    struct Response: Codable, Sendable {
        var id: String
        var result: SyncJSON?
        var error: RPCError?
    }

    struct Event: Codable, Sendable {
        var event: String
        var data: SyncJSON
    }

    struct RPCError: Codable, Sendable, Error, LocalizedError, Equatable {
        /// INVALID_PARAMS, SOURCE_NOT_FOUND, HTTP, NETWORK, TIMEOUT, CLOUDFLARE, SOURCE_EXCEPTION,
        /// UNSUPPORTED_LIB, UNTRUSTED, DEX2JAR_FAILED, CANCELLED, INTERNAL, … (Kotlin's `ErrorCode`).
        var code: String
        var message: String
        var retryable: Bool = false
        var httpStatus: Int?
        var url: String?
        var sourceId: String?
        var stack: String?

        var errorDescription: String? { message }

        init(code: String, message: String, retryable: Bool = false) {
            self.code = code
            self.message = message
            self.retryable = retryable
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decode(String.self, forKey: .code)
            message = try c.decode(String.self, forKey: .message)
            retryable = try c.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
            httpStatus = try c.decodeIfPresent(Int.self, forKey: .httpStatus)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId)
            stack = try c.decodeIfPresent(String.self, forKey: .stack)
        }
    }

    // MARK: host.*

    struct Hello: Codable, Sendable, Equatable {
        var protocolVersion: Int
        var hostVersion: String
        var libVersionMin: Double
        var libVersionMax: Double
        var jvm: String
        var capabilities: [String]
        var engines: [String: String]?
    }

    struct InitParams: Codable, Sendable, Equatable {
        var userAgent: String?
        var replaceAndroidUserAgents: Bool?
        var bypassEnabled: Bool?
        var nativeNet: Bool?
        var webView: Bool?
    }

    struct Toast: Codable, Sendable, Equatable {
        var text: String
        var long: Bool?
    }

    // MARK: net.*

    struct NetFetch: Codable, Sendable, Equatable {
        var id: String
        var url: String
        var method: String
        /// Name/value pairs, in order; a name may repeat.
        var headers: [[String]]
        var bodyBase64: String?
        var timeoutMillis: Int64
    }

    struct NetFetchResult: Codable, Sendable, Equatable {
        var id: String
        var code: Int = 0
        var message: String = ""
        var headers: [[String]] = []
        var bodyBase64: String?
        var `protocol`: String?
        var error: RPCError?
    }

    struct Cookie: Codable, Sendable, Equatable {
        var name: String
        var value: String
        var domain: String
        var path: String = "/"
        var expiresAt: Int64?
        var secure: Bool = false
        var httpOnly: Bool = false
        var hostOnly: Bool = false

        init(name: String, value: String, domain: String, path: String = "/", expiresAt: Int64? = nil, secure: Bool = false, httpOnly: Bool = false, hostOnly: Bool = false) {
            self.name = name
            self.value = value
            self.domain = domain
            self.path = path
            self.expiresAt = expiresAt
            self.secure = secure
            self.httpOnly = httpOnly
            self.hostOnly = hostOnly
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            value = try c.decode(String.self, forKey: .value)
            domain = try c.decode(String.self, forKey: .domain)
            path = try c.decodeIfPresent(String.self, forKey: .path) ?? "/"
            expiresAt = try c.decodeIfPresent(Int64.self, forKey: .expiresAt)
            secure = try c.decodeIfPresent(Bool.self, forKey: .secure) ?? false
            httpOnly = try c.decodeIfPresent(Bool.self, forKey: .httpOnly) ?? false
            hostOnly = try c.decodeIfPresent(Bool.self, forKey: .hostOnly) ?? false
        }
    }

    struct ChallengeRequired: Codable, Sendable, Equatable {
        var challengeId: String
        var url: String
        var host: String
        var userAgent: String?
    }

    struct ChallengeResolved: Codable, Sendable, Equatable {
        var challengeId: String
        var solved: Bool
        var reason: String?
        var cookies: [Cookie] = []
    }

    struct Accepted: Codable, Sendable, Equatable {
        var accepted: Bool
    }

    // MARK: repo.* and ext.*

    struct Repo: Codable, Sendable, Equatable, Identifiable {
        var indexUrl: String
        var name: String
        var badgeLabel: String
        var signingKeyFingerprint: String
        var website: String
        var discord: String?
        var isLegacy: Bool
        var enabled: Bool?

        var id: String { indexUrl }
        var isEnabled: Bool { enabled ?? true }
    }

    struct RepoRefresh: Codable, Sendable, Equatable {
        var repos: [Repo]
        var extensionCount: Int
        var failedRepos: [String]
    }

    enum ContentWarning: String, Codable, Sendable {
        case safe = "SAFE", mixed = "MIXED", nsfw = "NSFW"
    }

    struct AvailableSource: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var lang: String
        var homeUrl: String?
    }

    struct AvailableExtension: Codable, Sendable, Equatable, Identifiable {
        var pkgName: String
        var name: String
        var versionName: String
        var versionCode: Int64
        var libVersion: String
        var lang: String
        var contentWarning: ContentWarning
        var repoIndexUrl: String
        var apkUrl: String
        var jarUrl: String?
        var iconUrl: String
        var sources: [AvailableSource]

        var id: String { pkgName }
    }

    struct Source: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var lang: String
        var pkgName: String
        var baseUrl: String?
        var supportsLatest: Bool
        var isConfigurable: Bool
        var contentWarning: ContentWarning
        var versionId: Int?
    }

    struct InstalledExtension: Codable, Sendable, Equatable, Identifiable {
        var pkgName: String
        var name: String
        var versionName: String
        var versionCode: Int64
        var libVersion: String
        var lang: String
        var contentWarning: ContentWarning
        var repoIndexUrl: String?
        var signatureHash: String?
        var isTrusted: Bool
        var hasUpdate: Bool
        var isObsolete: Bool
        var iconPath: String?
        var sources: [Source]

        var id: String { pkgName }
    }

    enum InstallPhase: String, Codable, Sendable {
        case queued = "QUEUED", download = "DOWNLOAD", verify = "VERIFY", convert = "CONVERT", load = "LOAD", done = "DONE", failed = "FAILED"
    }

    struct ExtensionProgress: Codable, Sendable, Equatable {
        var jobId: String
        var pkgName: String?
        var phase: InstallPhase
        var fraction: Double?
        var error: RPCError?
        var extension_: InstalledExtension?

        enum CodingKeys: String, CodingKey {
            case jobId, pkgName, phase, fraction, error
            case extension_ = "extension"
        }
    }

    struct Job: Codable, Sendable, Equatable {
        var jobId: String
    }

    struct Icon: Codable, Sendable, Equatable {
        var path: String?
    }

    // MARK: source.*

    struct Manga: Codable, Sendable, Equatable {
        var url: String
        var title: String
        var artist: String?
        var author: String?
        var description: String?
        var genre: String?
        var status: Int = 0
        var thumbnailUrl: String?
        var updateStrategy: String = "ALWAYS_UPDATE"
        var initialized: Bool = false
        var memo: [String: SyncJSON] = [:]

        init(url: String, title: String, artist: String? = nil, author: String? = nil, description: String? = nil, genre: String? = nil,
             status: Int = 0, thumbnailUrl: String? = nil, updateStrategy: String = "ALWAYS_UPDATE", initialized: Bool = false,
             memo: [String: SyncJSON] = [:]) {
            self.url = url
            self.title = title
            self.artist = artist
            self.author = author
            self.description = description
            self.genre = genre
            self.status = status
            self.thumbnailUrl = thumbnailUrl
            self.updateStrategy = updateStrategy
            self.initialized = initialized
            self.memo = memo
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            title = try c.decode(String.self, forKey: .title)
            artist = try c.decodeIfPresent(String.self, forKey: .artist)
            author = try c.decodeIfPresent(String.self, forKey: .author)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            genre = try c.decodeIfPresent(String.self, forKey: .genre)
            status = try c.decodeIfPresent(Int.self, forKey: .status) ?? 0
            thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
            updateStrategy = try c.decodeIfPresent(String.self, forKey: .updateStrategy) ?? "ALWAYS_UPDATE"
            initialized = try c.decodeIfPresent(Bool.self, forKey: .initialized) ?? false
            memo = try c.decodeIfPresent([String: SyncJSON].self, forKey: .memo) ?? [:]
        }
    }

    struct Chapter: Codable, Sendable, Equatable {
        var url: String
        var name: String
        var dateUpload: Int64 = 0
        var chapterNumber: Double = -1
        var scanlator: String?
        var memo: [String: SyncJSON] = [:]

        init(url: String, name: String, dateUpload: Int64 = 0, chapterNumber: Double = -1, scanlator: String? = nil, memo: [String: SyncJSON] = [:]) {
            self.url = url
            self.name = name
            self.dateUpload = dateUpload
            self.chapterNumber = chapterNumber
            self.scanlator = scanlator
            self.memo = memo
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            name = try c.decode(String.self, forKey: .name)
            dateUpload = try c.decodeIfPresent(Int64.self, forKey: .dateUpload) ?? 0
            chapterNumber = try c.decodeIfPresent(Double.self, forKey: .chapterNumber) ?? -1
            scanlator = try c.decodeIfPresent(String.self, forKey: .scanlator)
            memo = try c.decodeIfPresent([String: SyncJSON].self, forKey: .memo) ?? [:]
        }
    }

    struct Page: Codable, Sendable, Equatable {
        var index: Int
        var url: String = ""
        var imageUrl: String?

        init(index: Int, url: String = "", imageUrl: String? = nil) {
            self.index = index
            self.url = url
            self.imageUrl = imageUrl
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            index = try c.decode(Int.self, forKey: .index)
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
            imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        }
    }

    struct MangasPage: Codable, Sendable, Equatable {
        var mangas: [Manga]
        var hasNextPage: Bool
    }

    struct MangaUpdate: Codable, Sendable, Equatable {
        var manga: Manga
        var chapters: [Chapter]
    }

    struct ImageFile: Codable, Sendable, Equatable {
        var path: String
        var mimeType: String?
        var size: Int64
    }

    struct URLValue: Codable, Sendable, Equatable {
        var url: String
    }

    struct Headers: Codable, Sendable, Equatable {
        var headers: [String: String]
    }

    struct Related: Codable, Sendable, Equatable {
        var supported: Bool
        var mangas: [Manga]?
        var disabled: Bool?
        var searchDisabled: Bool?
    }

    struct SetPreferenceResult: Codable, Sendable, Equatable {
        var accepted: Bool
        var preferences: [Preference]
    }

    struct Imported: Codable, Sendable, Equatable {
        var imported: Int
    }
}

// MARK: - Filters

extension ExtensionRPC {
    /// A source's filter list, a positional tree: search sends it back in the same shape.
    indirect enum Filter: Codable, Sendable, Equatable {
        case header(name: String)
        case separator(name: String)
        case select(name: String, values: [String], state: Int)
        case text(name: String, state: String)
        case checkBox(name: String, state: Bool)
        case triState(name: String, state: Int)
        case group(name: String, state: [Filter])
        case sort(name: String, values: [String], state: SortSelection?)

        struct SortSelection: Codable, Sendable, Equatable {
            var index: Int
            var ascending: Bool
        }

        private enum CodingKeys: String, CodingKey { case type, name, values, state }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            switch try c.decode(String.self, forKey: .type) {
            case "header": self = .header(name: name)
            case "separator": self = .separator(name: name)
            case "select": self = .select(name: name, values: try c.decode([String].self, forKey: .values), state: try c.decode(Int.self, forKey: .state))
            case "text": self = .text(name: name, state: try c.decode(String.self, forKey: .state))
            case "checkbox": self = .checkBox(name: name, state: try c.decode(Bool.self, forKey: .state))
            case "tristate": self = .triState(name: name, state: try c.decode(Int.self, forKey: .state))
            case "group": self = .group(name: name, state: try c.decode([Filter].self, forKey: .state))
            case "sort":
                self = .sort(name: name, values: try c.decode([String].self, forKey: .values),
                             state: try c.decodeIfPresent(SortSelection.self, forKey: .state))
            case let type:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown filter type \(type)")
            }
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .header(let name):
                try c.encode("header", forKey: .type); try c.encode(name, forKey: .name)
            case .separator(let name):
                try c.encode("separator", forKey: .type); try c.encode(name, forKey: .name)
            case .select(let name, let values, let state):
                try c.encode("select", forKey: .type); try c.encode(name, forKey: .name)
                try c.encode(values, forKey: .values); try c.encode(state, forKey: .state)
            case .text(let name, let state):
                try c.encode("text", forKey: .type); try c.encode(name, forKey: .name); try c.encode(state, forKey: .state)
            case .checkBox(let name, let state):
                try c.encode("checkbox", forKey: .type); try c.encode(name, forKey: .name); try c.encode(state, forKey: .state)
            case .triState(let name, let state):
                try c.encode("tristate", forKey: .type); try c.encode(name, forKey: .name); try c.encode(state, forKey: .state)
            case .group(let name, let state):
                try c.encode("group", forKey: .type); try c.encode(name, forKey: .name); try c.encode(state, forKey: .state)
            case .sort(let name, let values, let state):
                try c.encode("sort", forKey: .type); try c.encode(name, forKey: .name)
                try c.encode(values, forKey: .values); try c.encodeIfPresent(state, forKey: .state)
            }
        }
    }
}

// MARK: - Source preferences

extension ExtensionRPC {
    /// One entry of an extension's preference screen (the androidx.preference subset extensions use).
    struct Preference: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable {
            case editText, list, multiSelectList, `switch`, checkBox
        }

        var type: Kind
        var key: String?
        var title: String?
        var summary: String?
        var visible: Bool
        var enabled: Bool
        var dialogTitle: String?
        var dialogMessage: String?
        var text: String?
        var entries: [String]?
        var entryValues: [String]?
        /// String, list of strings or bool, by kind.
        var `default`: SyncJSON?
        var value: SyncJSON?
    }
}

// MARK: - Conversions to the app's source types

extension ExtensionRPC.Manga {
    init(_ manga: SManga) {
        self.init(
            url: manga.url, title: manga.title, artist: manga.artist, author: manga.author, description: manga.description,
            genre: manga.genre, status: manga.status.rawValue, thumbnailUrl: manga.thumbnailURL, initialized: manga.initialized
        )
    }

    var smanga: SManga {
        SManga(
            url: url, title: title, artist: artist, author: author, description: description, genre: genre,
            status: MangaStatus(rawValue: status) ?? .unknown, thumbnailURL: thumbnailUrl, initialized: initialized
        )
    }
}

extension ExtensionRPC.Chapter {
    init(_ chapter: SChapter) {
        self.init(
            url: chapter.url, name: chapter.name,
            dateUpload: chapter.dateUpload.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0,
            chapterNumber: chapter.number, scanlator: chapter.scanlator
        )
    }

    var schapter: SChapter {
        SChapter(
            url: url, name: name, dateUpload: dateUpload > 0 ? Date(timeIntervalSince1970: Double(dateUpload) / 1000) : nil,
            number: chapterNumber, scanlator: scanlator
        )
    }
}

extension ExtensionRPC.Filter {
    init(_ filter: SourceFilter) {
        switch filter {
        case .header(let name): self = .header(name: name)
        case .separator: self = .separator(name: "")
        case .select(let name, let values, let state): self = .select(name: name, values: values, state: state)
        case .text(let name, let state): self = .text(name: name, state: state)
        case .checkBox(let name, let state): self = .checkBox(name: name, state: state)
        case .triState(let name, let state): self = .triState(name: name, state: state)
        case .group(let name, let filters): self = .group(name: name, state: filters.map(Self.init))
        case .sort(let name, let values, let selection):
            self = .sort(name: name, values: values, state: selection.map { .init(index: $0.index, ascending: $0.ascending) })
        }
    }

    var sourceFilter: SourceFilter {
        switch self {
        case .header(let name): .header(name)
        case .separator: .separator
        case .select(let name, let values, let state): .select(name: name, values: values, state: state)
        case .text(let name, let state): .text(name: name, state: state)
        case .checkBox(let name, let state): .checkBox(name: name, state: state)
        case .triState(let name, let state): .triState(name: name, state: state)
        case .group(let name, let state): .group(name: name, filters: state.map(\.sourceFilter))
        case .sort(let name, let values, let state):
            .sort(name: name, values: values, selection: state.map { .init(index: $0.index, ascending: $0.ascending) })
        }
    }
}
