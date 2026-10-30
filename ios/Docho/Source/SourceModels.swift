import Foundation

/// A series as a source describes it (Tachiyomi's `SManga`). `url` is the source's own key for it,
/// unique within the source; Docho never shows it.
struct SManga: Sendable, Equatable, Hashable {
    var url: String
    var title: String
    var artist: String?
    var author: String?
    var description: String?
    var genre: String?
    var status: MangaStatus = .unknown
    var thumbnailURL: String?
    /// Whether the details (description, genres, status) have been fetched.
    var initialized = false

    var genres: [String] {
        genre?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
    }
}

/// Tachiyomi's publication statuses, with the same raw values so backups line up.
enum MangaStatus: Int, Sendable, Codable, CaseIterable {
    case unknown = 0
    case ongoing = 1
    case completed = 2
    case licensed = 3
    case publishingFinished = 4
    case cancelled = 5
    case onHiatus = 6

    var title: String {
        switch self {
        case .unknown: String(localized: "Unknown")
        case .ongoing: String(localized: "Ongoing")
        case .completed: String(localized: "Completed")
        case .licensed: String(localized: "Licensed")
        case .publishingFinished: String(localized: "Publishing finished")
        case .cancelled: String(localized: "Cancelled")
        case .onHiatus: String(localized: "On hiatus")
        }
    }

    /// The Material Symbol Mihon shows next to the status on the series screen.
    var icon: String {
        switch self {
        case .ongoing: "schedule"
        case .completed, .publishingFinished: "done_all"
        case .licensed: "attach_money"
        case .cancelled: "close"
        case .onHiatus: "hourglass_empty"
        case .unknown: "block"
        }
    }
}

/// A chapter as a source describes it (Tachiyomi's `SChapter`).
struct SChapter: Sendable, Equatable, Hashable {
    var url: String
    var name: String
    var dateUpload: Date?
    /// The chapter number; built-in sources use exact numbers, below -2 for volumes and specials.
    var number: Double = -1
    var scanlator: String?
    /// Extra values a source keeps with the chapter: the ids progress sync needs, file names and hashes.
    var memo = ChapterMemo()
}

/// Android's chapter memo: a small JSON object stored with the chapter.
struct ChapterMemo: Sendable, Equatable, Hashable, Codable {
    var values: [String: MemoValue] = [:]

    static let fileName = "fileName"

    enum MemoValue: Sendable, Equatable, Hashable, Codable {
        case int(Int)
        case double(Double)
        case string(String)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int.self) {
                self = .int(int)
            } else if let double = try? container.decode(Double.self) {
                self = .double(double)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let value): try container.encode(value)
            case .double(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            }
        }
    }

    init(_ values: [String: MemoValue] = [:]) {
        self.values = values
    }

    init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: MemoValue].self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    func int(_ key: String) -> Int? {
        switch values[key] {
        case .int(let value): value
        case .double(let value): Int(value)
        case .string(let value): Int(value)
        case nil: nil
        }
    }

    func string(_ key: String) -> String? {
        switch values[key] {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case nil: nil
        }
    }

    subscript(key: String) -> MemoValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// As stored in the database.
    var json: String? {
        guard !values.isEmpty, let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    init(json: String?) {
        guard let json, let memo = try? JSONDecoder().decode(ChapterMemo.self, from: Data(json.utf8)) else { return }
        self = memo
    }
}

/// One page of a chapter: an image to fetch.
struct SourcePage: Sendable, Equatable {
    var index: Int
    var imageURL: URL
}

/// One page of a source's series listing.
struct MangasPage: Sendable, Equatable {
    var mangas: [SManga]
    var hasNextPage: Bool
}

/// Tachiyomi's source filters. Sources describe them, Browse renders them, and the source reads
/// back the states it gets in `search`.
enum SourceFilter: Sendable, Equatable, Identifiable {
    case header(String)
    case separator
    case select(name: String, values: [String], state: Int)
    case text(name: String, state: String)
    case checkBox(name: String, state: Bool)
    /// 0 ignore, 1 include, 2 exclude.
    case triState(name: String, state: Int)
    case group(name: String, filters: [SourceFilter])
    case sort(name: String, values: [String], selection: SortSelection?)

    struct SortSelection: Sendable, Equatable {
        var index: Int
        var ascending: Bool
    }

    var id: String {
        switch self {
        case .header(let name): "header:\(name)"
        case .separator: "separator"
        case .select(let name, _, _): "select:\(name)"
        case .text(let name, _): "text:\(name)"
        case .checkBox(let name, _): "check:\(name)"
        case .triState(let name, _): "tri:\(name)"
        case .group(let name, _): "group:\(name)"
        case .sort(let name, _, _): "sort:\(name)"
        }
    }

    var name: String {
        switch self {
        case .header(let name), .select(let name, _, _), .text(let name, _), .checkBox(let name, _),
             .triState(let name, _), .group(let name, _), .sort(let name, _, _): name
        case .separator: ""
        }
    }

    /// Whether this filter differs from `initial` (for the "Reset" button and the active filter icon).
    func isChanged(from initial: SourceFilter) -> Bool { self != initial }
}

extension Array where Element == SourceFilter {
    /// The selected index of the select filter called `name`.
    func selectState(_ name: String) -> Int? {
        for filter in self {
            if case .select(name, _, let state) = filter { return state }
        }
        return nil
    }

    func sortState(_ name: String) -> SourceFilter.SortSelection? {
        for filter in self {
            if case .sort(name, _, let selection) = filter { return selection }
        }
        return nil
    }
}
