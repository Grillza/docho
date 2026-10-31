import Foundation

/// Mihon's backup (`Backup.kt` and the models beside it), with Mihon's field numbers, so a
/// `.tachibk` file moves between Mihon, the Android app and this one. Times are milliseconds
/// since 1970, as there.
struct MihonBackup: Equatable {
    var manga: [Manga] = []
    var categories: [Category] = []
    var sources: [Source] = []
    var preferences: [Preference] = []
    /// Extension settings, kept as they came so a restore can pass them on; not used here.
    var sourcePreferences: [Data] = []

    struct Manga: Equatable {
        var source: Int64
        var url: String
        var title = ""
        var artist: String?
        var author: String?
        var description: String?
        var genres: [String] = []
        var status = 0
        var thumbnailUrl: String?
        var dateAdded: Int64 = 0
        var viewer = 0
        var chapters: [Chapter] = []
        /// The `order` of each category it's in.
        var categories: [Int64] = []
        var tracking: [Tracking] = []
        var favorite = true
        var chapterFlags = 0
        var viewerFlags: Int?
        var history: [History] = []
        var notes = ""
        var initialized = false
        var memo: Data?
    }

    struct Chapter: Equatable {
        var url: String
        var name: String
        var scanlator: String?
        var read = false
        var bookmark = false
        var lastPageRead: Int64 = 0
        var dateFetch: Int64 = 0
        var dateUpload: Int64 = 0
        var chapterNumber: Float = 0
        var sourceOrder: Int64 = 0
        var memo: Data?
    }

    struct Category: Equatable {
        var name: String
        var order: Int64 = 0
        var id: Int64 = 0
        var flags: Int64 = 0
    }

    struct Tracking: Equatable {
        var syncId: Int
        var libraryId: Int64 = 0
        var trackingUrl = ""
        var title = ""
        var lastChapterRead: Float = 0
        var totalChapters = 0
        var score: Float = 0
        var status = 0
        var startedReadingDate: Int64 = 0
        var finishedReadingDate: Int64 = 0
        var isPrivate = false
        var mediaId: Int64 = 0
    }

    struct History: Equatable {
        var url: String
        var lastRead: Int64
        var readDuration: Int64 = 0
    }

    struct Source: Equatable {
        var name = ""
        var sourceId: Int64
    }

    struct Preference: Equatable {
        var key: String
        var value: Value

        enum Value: Equatable {
            case int(Int32)
            case long(Int64)
            case float(Float)
            case string(String)
            case bool(Bool)
            case stringSet([String])
        }
    }

    enum BackupError: LocalizedError {
        case invalid

        var errorDescription: String? { String(localized: "That isn't a Mihon backup") }
    }
}

// MARK: - Writing

extension MihonBackup {
    /// The `.tachibk` file: the backup, gzipped.
    func fileData() throws -> Data {
        try Gzip.compress(encoded())
    }

    func encoded() -> Data {
        var writer = ProtoWriter()
        for manga in manga { writer.message(1) { manga.write(&$0) } }
        for category in categories { writer.message(2) { category.write(&$0) } }
        for source in sources {
            writer.message(101) {
                $0.string(1, source.name)
                $0.int(2, source.sourceId)
            }
        }
        for preference in preferences { writer.message(104) { preference.write(&$0) } }
        for preferences in sourcePreferences { writer.bytes(105, preferences) }
        return writer.data
    }
}

private extension MihonBackup.Manga {
    func write(_ writer: inout ProtoWriter) {
        writer.int(1, source, always: true)
        writer.string(2, url, always: true)
        writer.string(3, title)
        writer.string(4, artist)
        writer.string(5, author)
        writer.string(6, description)
        for genre in genres { writer.string(7, genre, always: true) }
        writer.int(8, status)
        writer.string(9, thumbnailUrl)
        writer.int(13, dateAdded)
        writer.int(14, viewer)
        for chapter in chapters { writer.message(16) { chapter.write(&$0) } }
        for category in categories { writer.int(17, category, always: true) }
        for track in tracking { writer.message(18) { track.write(&$0) } }
        writer.bool(100, favorite, default: true)
        writer.int(101, chapterFlags)
        if let viewerFlags { writer.int(103, viewerFlags, always: true) }
        for entry in history { writer.message(104) { entry.write(&$0) } }
        writer.string(110, notes)
        writer.bool(111, initialized)
        if let memo { writer.bytes(112, memo) }
    }
}

private extension MihonBackup.Chapter {
    func write(_ writer: inout ProtoWriter) {
        writer.string(1, url, always: true)
        writer.string(2, name, always: true)
        writer.string(3, scanlator)
        writer.bool(4, read)
        writer.bool(5, bookmark)
        writer.int(6, lastPageRead)
        writer.int(7, dateFetch)
        writer.int(8, dateUpload)
        writer.float(9, chapterNumber)
        writer.int(10, sourceOrder)
        if let memo { writer.bytes(13, memo) }
    }
}

private extension MihonBackup.Category {
    func write(_ writer: inout ProtoWriter) {
        writer.string(1, name, always: true)
        writer.int(2, order)
        writer.int(3, id)
        writer.int(100, flags)
    }
}

private extension MihonBackup.Tracking {
    func write(_ writer: inout ProtoWriter) {
        writer.int(1, syncId, always: true)
        writer.int(2, libraryId, always: true)
        writer.string(4, trackingUrl)
        writer.string(5, title)
        writer.float(6, lastChapterRead)
        writer.int(7, totalChapters)
        writer.float(8, score)
        writer.int(9, status)
        writer.int(10, startedReadingDate)
        writer.int(11, finishedReadingDate)
        writer.bool(12, isPrivate)
        writer.int(100, mediaId)
    }
}

private extension MihonBackup.History {
    func write(_ writer: inout ProtoWriter) {
        writer.string(1, url, always: true)
        writer.int(2, lastRead, always: true)
        writer.int(3, readDuration)
    }
}

private extension MihonBackup.Preference {
    /// kotlinx writes a sealed class as its serial name and the value's own message.
    static let typePrefix = "eu.kanade.tachiyomi.data.backup.models."

    func write(_ writer: inout ProtoWriter) {
        writer.string(1, key, always: true)
        writer.message(2) { message in
            switch value {
            case .int(let value):
                message.string(1, Self.typePrefix + "IntPreferenceValue")
                message.message(2) { $0.int(1, Int64(value)) }
            case .long(let value):
                message.string(1, Self.typePrefix + "LongPreferenceValue")
                message.message(2) { $0.int(1, value) }
            case .float(let value):
                message.string(1, Self.typePrefix + "FloatPreferenceValue")
                message.message(2) { $0.float(1, value) }
            case .string(let value):
                message.string(1, Self.typePrefix + "StringPreferenceValue")
                message.message(2) { $0.string(1, value) }
            case .bool(let value):
                message.string(1, Self.typePrefix + "BooleanPreferenceValue")
                message.message(2) { $0.bool(1, value) }
            case .stringSet(let values):
                message.string(1, Self.typePrefix + "StringSetPreferenceValue")
                message.message(2) { inner in for value in values { inner.string(1, value, always: true) } }
            }
        }
    }
}

// MARK: - Reading

extension MihonBackup {
    /// Reads a `.tachibk` file (gzipped) or a bare backup.
    init(fileData data: Data) throws {
        let raw = Gzip.isGzip(data) ? try Gzip.decompress(data) : data
        try self.init(encoded: raw)
    }

    init(encoded data: Data) throws {
        do {
            for field in try ProtoReader(data).fields() {
                switch field.number {
                case 1: manga.append(try Manga(field.message))
                case 2: categories.append(try Category(field.message))
                case 101:
                    var source = Source(sourceId: 0)
                    for inner in try field.message.fields() {
                        if inner.number == 1 { source.name = inner.string }
                        if inner.number == 2 { source.sourceId = inner.int64 }
                    }
                    sources.append(source)
                case 104: if let preference = try Preference(field.message) { preferences.append(preference) }
                case 105: sourcePreferences.append(field.bytes)
                default: break
                }
            }
        } catch is ProtoError {
            throw BackupError.invalid
        }
    }
}

private extension MihonBackup.Manga {
    init(_ reader: ProtoReader) throws {
        self.init(source: 0, url: "")
        for field in try reader.fields() {
            switch field.number {
            case 1: source = field.int64
            case 2: url = field.string
            case 3: title = field.string
            case 4: artist = field.string
            case 5: author = field.string
            case 6: description = field.string
            case 7: genres.append(field.string)
            case 8: status = field.int
            case 9: thumbnailUrl = field.string
            case 13: dateAdded = field.int64
            case 14: viewer = field.int
            case 16: chapters.append(try MihonBackup.Chapter(field.message))
            case 17: categories += field.packedInts
            case 18: tracking.append(try MihonBackup.Tracking(field.message))
            case 100: favorite = field.bool
            case 101: chapterFlags = field.int
            case 103: viewerFlags = field.int
            case 104: history.append(try MihonBackup.History(field.message))
            case 110: notes = field.string
            case 111: initialized = field.bool
            case 112: memo = field.bytes
            default: break
            }
        }
    }
}

private extension MihonBackup.Chapter {
    init(_ reader: ProtoReader) throws {
        self.init(url: "", name: "")
        for field in try reader.fields() {
            switch field.number {
            case 1: url = field.string
            case 2: name = field.string
            case 3: scanlator = field.string
            case 4: read = field.bool
            case 5: bookmark = field.bool
            case 6: lastPageRead = field.int64
            case 7: dateFetch = field.int64
            case 8: dateUpload = field.int64
            case 9: chapterNumber = field.float
            case 10: sourceOrder = field.int64
            case 13: memo = field.bytes
            default: break
            }
        }
    }
}

private extension MihonBackup.Category {
    init(_ reader: ProtoReader) throws {
        self.init(name: "")
        for field in try reader.fields() {
            switch field.number {
            case 1: name = field.string
            case 2: order = field.int64
            case 3: id = field.int64
            case 100: flags = field.int64
            default: break
            }
        }
    }
}

private extension MihonBackup.Tracking {
    init(_ reader: ProtoReader) throws {
        self.init(syncId: 0)
        var mediaIdInt: Int64 = 0
        for field in try reader.fields() {
            switch field.number {
            case 1: syncId = field.int
            case 2: libraryId = field.int64
            case 3: mediaIdInt = field.int64
            case 4: trackingUrl = field.string
            case 5: title = field.string
            case 6: lastChapterRead = field.float
            case 7: totalChapters = field.int
            case 8: score = field.float
            case 9: status = field.int
            case 10: startedReadingDate = field.int64
            case 11: finishedReadingDate = field.int64
            case 12: isPrivate = field.bool
            case 100: mediaId = field.int64
            default: break
            }
        }
        // Older backups keep the id in the 1.x field, as Android's `getTrackImpl` reads it.
        if mediaIdInt != 0 { mediaId = mediaIdInt }
    }
}

private extension MihonBackup.History {
    init(_ reader: ProtoReader) throws {
        self.init(url: "", lastRead: 0)
        for field in try reader.fields() {
            switch field.number {
            case 1: url = field.string
            case 2: lastRead = field.int64
            case 3: readDuration = field.int64
            default: break
            }
        }
    }
}

private extension MihonBackup.Preference {
    /// nil for a value of a type it doesn't know.
    init?(_ reader: ProtoReader) throws {
        var key = ""
        var type = ""
        var valueFields: [ProtoReader.Field] = []
        for field in try reader.fields() {
            if field.number == 1 { key = field.string }
            if field.number == 2 {
                for inner in try field.message.fields() {
                    if inner.number == 1 { type = inner.string }
                    if inner.number == 2 { valueFields = try inner.message.fields() }
                }
            }
        }
        let first = valueFields.first { $0.number == 1 }
        let value: Value
        switch type.split(separator: ".").last ?? "" {
        case "IntPreferenceValue": value = .int(Int32(truncatingIfNeeded: first?.int64 ?? 0))
        case "LongPreferenceValue": value = .long(first?.int64 ?? 0)
        case "FloatPreferenceValue": value = .float(first?.float ?? 0)
        case "StringPreferenceValue": value = .string(first?.string ?? "")
        case "BooleanPreferenceValue": value = .bool(first?.bool ?? false)
        case "StringSetPreferenceValue": value = .stringSet(valueFields.filter { $0.number == 1 }.map(\.string))
        default: return nil
        }
        self.init(key: key, value: value)
    }
}
