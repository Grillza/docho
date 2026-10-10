import Foundation

/*
 * Port of app/src/main/java/mihonka/kavita/KavitaModels.kt.
 * Only the fields Mihonka reads are declared, and unknown keys are ignored. Every field has a
 * default and a value of the wrong type falls back to it, so older servers that lack some
 * fields still decode.
 */

struct KavitaUser: Decodable, Sendable, Equatable {
    var username: String
    var token: String
    var kavitaVersion: String?

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        username = values.lenient(.username, default: "")
        // A sign-in without a token is useless, so this one field is required.
        token = try values.decode(String.self, forKey: .token)
        kavitaVersion = values.lenient(.kavitaVersion, default: nil)
    }

    private enum CodingKeys: String, CodingKey {
        case username, token, kavitaVersion
    }
}

struct KavitaLibrary: Decodable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var type: Int

    init(id: Int, name: String, type: Int = 0) {
        self.id = id
        self.name = name
        self.type = type
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        name = values.lenient(.name, default: "")
        type = values.lenient(.type, default: 0)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type
    }
}

struct KavitaSeries: Decodable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String?
    var originalName: String?
    var localizedName: String?
    var pages: Int
    var pagesRead: Int
    var format: Int
    var libraryId: Int
    var libraryName: String?

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        name = values.lenient(.name, default: nil)
        originalName = values.lenient(.originalName, default: nil)
        localizedName = values.lenient(.localizedName, default: nil)
        pages = values.lenient(.pages, default: 0)
        pagesRead = values.lenient(.pagesRead, default: 0)
        format = values.lenient(.format, default: KavitaConstants.formatUnknown)
        libraryId = values.lenient(.libraryId, default: 0)
        libraryName = values.lenient(.libraryName, default: nil)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, originalName, localizedName, pages, pagesRead, format, libraryId, libraryName
    }
}

struct KavitaNamed: Decodable, Sendable, Equatable {
    var title: String?
    var name: String?

    var label: String? {
        guard let value = title ?? name, !value.isBlank else { return nil }
        return value
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = values.lenient(.title, default: nil)
        name = values.lenient(.name, default: nil)
    }

    private enum CodingKeys: String, CodingKey {
        case title, name
    }
}

struct KavitaSeriesMetadata: Decodable, Sendable, Equatable {
    var summary: String?
    var genres: [KavitaNamed]
    var tags: [KavitaNamed]
    var writers: [KavitaNamed]
    var coverArtists: [KavitaNamed]
    var pencillers: [KavitaNamed]
    var publicationStatus: Int

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        summary = values.lenient(.summary, default: nil)
        genres = values.lenient(.genres, default: [])
        tags = values.lenient(.tags, default: [])
        writers = values.lenient(.writers, default: [])
        coverArtists = values.lenient(.coverArtists, default: [])
        pencillers = values.lenient(.pencillers, default: [])
        publicationStatus = values.lenient(.publicationStatus, default: -1)
    }

    private enum CodingKeys: String, CodingKey {
        case summary, genres, tags, writers, coverArtists, pencillers, publicationStatus
    }
}

struct KavitaVolume: Decodable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var minNumber: Double?
    var number: Double?
    var pages: Int
    var pagesRead: Int
    var seriesId: Int
    var chapters: [KavitaChapter]

    var volumeNumber: Double { minNumber ?? number ?? 0 }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        name = values.lenient(.name, default: "")
        minNumber = values.lenient(.minNumber, default: nil)
        number = values.lenient(.number, default: nil)
        pages = values.lenient(.pages, default: 0)
        pagesRead = values.lenient(.pagesRead, default: 0)
        seriesId = values.lenient(.seriesId, default: 0)
        chapters = values.lenient(.chapters, default: [])
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, minNumber, number, pages, pagesRead, seriesId, chapters
    }
}

struct KavitaChapter: Decodable, Sendable, Equatable, Identifiable {
    var id: Int
    var range: String?
    var number: String?
    var minNumber: Double?
    var maxNumber: Double?
    var pages: Int
    var pagesRead: Int
    var isSpecial: Bool
    var title: String?
    var titleName: String?
    var volumeId: Int
    var created: String?
    var releaseDate: String?
    var files: [KavitaFile]

    var chapterNumber: Double {
        minNumber
            ?? number.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
            ?? KavitaConstants.defaultChapterNumber
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        range = values.lenient(.range, default: nil)
        // Kavita sends this as a string; accept a JSON number too.
        let numberString: String? = values.lenient(.number, default: nil)
        let numberValue: Double? = values.lenient(.number, default: nil)
        number = numberString ?? numberValue.map(formatNumber)
        minNumber = values.lenient(.minNumber, default: nil)
        maxNumber = values.lenient(.maxNumber, default: nil)
        pages = values.lenient(.pages, default: 0)
        pagesRead = values.lenient(.pagesRead, default: 0)
        isSpecial = values.lenient(.isSpecial, default: false)
        title = values.lenient(.title, default: nil)
        titleName = values.lenient(.titleName, default: nil)
        volumeId = values.lenient(.volumeId, default: 0)
        created = values.lenient(.created, default: nil)
        releaseDate = values.lenient(.releaseDate, default: nil)
        files = values.lenient(.files, default: [])
    }

    private enum CodingKeys: String, CodingKey {
        case id, range, number, minNumber, maxNumber, pages, pagesRead, isSpecial, title, titleName
        case volumeId, created, releaseDate, files
    }
}

struct KavitaFile: Decodable, Sendable, Equatable {
    var format: Int

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = values.lenient(.format, default: KavitaConstants.formatUnknown)
    }

    private enum CodingKeys: String, CodingKey {
        case format
    }
}

struct KavitaReadPosition: Decodable, Sendable {
    var pageNum: Int

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pageNum = values.lenient(.pageNum, default: 0)
    }

    private enum CodingKeys: String, CodingKey {
        case pageNum
    }
}

struct KavitaPagination: Decodable, Sendable {
    var currentPage: Int
    var totalPages: Int

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        currentPage = values.lenient(.currentPage, default: 1)
        totalPages = values.lenient(.totalPages, default: 1)
    }

    private enum CodingKeys: String, CodingKey {
        case currentPage, totalPages
    }
}

// MARK: - Request bodies
// Synthesized `Encodable` writes every stored property, defaults included. Kavita reads a
// missing filter `combination` as "or", which would turn a search into "everything".

struct KavitaProgress: Encodable, Sendable, Equatable {
    var volumeId: Int
    var chapterId: Int
    var pageNum: Int
    var seriesId: Int
    var libraryId: Int
}

struct KavitaMarkChapters: Encodable, Sendable, Equatable {
    var seriesId: Int
    var volumeIds: [Int]
    var chapterIds: [Int]
}

struct KavitaFilter: Encodable, Sendable, Equatable {
    var statements: [KavitaFilterStatement] = []
    var combination: Int = 1 // And
    var sortOptions = KavitaSortOptions()
    var limitTo: Int = 0
}

struct KavitaFilterStatement: Encodable, Sendable, Equatable {
    var comparison: Int
    var field: Int
    var value: String
}

struct KavitaSortOptions: Encodable, Sendable, Equatable {
    var sortField: Int = KavitaConstants.sortName
    var isAscending: Bool = true
}

struct KavitaSeriesPage: Sendable, Equatable {
    var series: [KavitaSeries]
    var hasNextPage: Bool
}

enum KavitaConstants {
    /// Volume holding chapters that belong to no volume (Kavita 0.8+).
    static let looseLeafVolumeNumber: Double = -100_000
    /// Volume holding the specials (Kavita 0.8+).
    static let specialVolumeNumber: Double = 100_000
    /// Chapter number of a file that is a whole volume (Kavita 0.8+).
    static let defaultChapterNumber: Double = -100_000

    // MangaFormat
    static let formatUnknown = 2
    static let formatEpub = 3

    // FilterComparison
    static let comparisonContains = 5
    static let comparisonMatches = 7
    static let comparisonNotContains = 8

    // SeriesFilterField
    static let fieldSeriesName = 1
    static let fieldLibraries = 19
    static let fieldFormats = 21

    // SeriesSortField
    static let sortName = 1
    static let sortCreated = 2
    static let sortLastChapterAdded = 4
    static let sortReadProgress = 7

    // PublicationStatus
    static let statusOngoing = 0
    static let statusHiatus = 1
    static let statusCompleted = 2
    static let statusCancelled = 3
    static let statusEnded = 4
}

/// Whole numbers without a decimal (`3`, not `3.0`).
func formatNumber(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
}

extension String {
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when it's missing, null or of the wrong type.
    func lenient<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
