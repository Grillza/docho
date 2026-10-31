import Foundation
import GRDB

/// Creates and restores Mihon backups (`.tachibk`), as Android's `BackupCreator` and
/// `BackupRestorer`: the library with chapters, categories, history and tracking, series read
/// outside the library, and the app's settings.
///
/// Server details are left out, as the Android app leaves them out of its backups: they can't
/// be password protected, so Kavita, BookOrbit, Komga, KOReader and Suwayomi settings and the
/// progress sync mode move only in the settings file (Settings → Sync / Self-hosted sources),
/// and are ignored in backups that have them. Tracker sign-ins stay out too.
@MainActor
struct BackupManager {
    let app: AppModel

    static func fileName(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return "io.github.grillza.docho_\(formatter.string(from: date)).tachibk"
    }

    func create() async throws -> Data {
        var backup = try await app.database.backupContents()
        let sourceIds = Set(backup.manga.map(\.source))
        backup.sources = sourceIds.sorted().map { MihonBackup.Source(name: app.sources.source($0).name, sourceId: $0) }
        backup.preferences = Self.preferences(UserDefaults.standard)
        return try backup.fileData()
    }

    struct RestoreResult: Equatable {
        var series = 0
        var settings = 0
    }

    func restore(_ data: Data) async throws -> RestoreResult {
        let backup = try MihonBackup(fileData: data)
        let series = try await app.database.restore(backup)
        let settings = Self.restorePreferences(backup.preferences, to: UserDefaults.standard)
        return RestoreResult(series: series, settings: settings)
    }

    // MARK: Settings

    /// Android's preference keys are snake_case; keys in other forms are the system's.
    private static let excludedPrefixes = [
        "__PRIVATE_", "__APP_STATE_",
        // Server settings (Android's `SyncSettingsFile.isServerSetting`).
        "kavita_", "bookorbit_", "komga_", "koreader_", "suwayomi_", "progress_sync_",
        // Tracker sign-ins.
        "pref_mangasync_", "track_token_",
    ]
    /// This device's state rather than settings.
    private static let excludedKeys: Set<String> = ["download_queue_paused", "last_used_category"]

    static func isBackedUp(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first),
              key.unicodeScalars.allSatisfy({ CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "_" })
        else { return false }
        let name = key.hasPrefix("__PRIVATE_") ? String(key.dropFirst("__PRIVATE_".count)) : key
        return !excludedKeys.contains(key) && !excludedPrefixes.contains { key.hasPrefix($0) || name.hasPrefix($0) }
    }

    static func preferences(_ defaults: UserDefaults) -> [MihonBackup.Preference] {
        let stored = Bundle.main.bundleIdentifier.flatMap(defaults.persistentDomain(forName:)) ?? defaults.dictionaryRepresentation()
        return stored.keys.sorted().filter(isBackedUp).compactMap { key in
            let value: MihonBackup.Preference.Value
            switch stored[key] {
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): value = .bool(number.boolValue)
            case let number as NSNumber where CFNumberIsFloatType(number as CFNumber): value = .float(number.floatValue)
            case let number as NSNumber:
                let integer = number.int64Value
                value = Int64(Int32.min)...Int64(Int32.max) ~= integer ? .int(Int32(integer)) : .long(integer)
            case let text as String: value = .string(text)
            case let list as [String]: value = .stringSet(list)
            default: return nil
            }
            return MihonBackup.Preference(key: key, value: value)
        }
    }

    /// Writes the backup's settings, leaving out server settings and any value of a different
    /// type from the one this app stores under the key. Returns how many were restored.
    @discardableResult
    static func restorePreferences(_ preferences: [MihonBackup.Preference], to defaults: UserDefaults) -> Int {
        var count = 0
        for preference in preferences where isBackedUp(preference.key) {
            let value: Any = switch preference.value {
            case .int(let value): Int(value)
            case .long(let value): Int(value)
            case .float(let value): Double(value)
            case .string(let value): value
            case .bool(let value): value
            case .stringSet(let values): values
            }
            if let current = defaults.object(forKey: preference.key), !sameKind(current, value) { continue }
            defaults.set(value, forKey: preference.key)
            count += 1
        }
        return count
    }

    private static func sameKind(_ current: Any, _ new: Any) -> Bool {
        switch (current, new) {
        case (let a as NSNumber, let b as NSNumber):
            let aBool = CFGetTypeID(a) == CFBooleanGetTypeID(), bBool = CFGetTypeID(b) == CFBooleanGetTypeID()
            return aBool == bBool
        case (is String, is String), (is [String], is [String]): return true
        default: return false
        }
    }
}

// MARK: - Database

private extension Date {
    var milliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init?(milliseconds: Int64) {
        guard milliseconds > 0 else { return nil }
        self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}

extension AppDatabase {
    /// The library and series read outside it, with their chapters, categories, history and
    /// tracking, as Mihon backs them up.
    func backupContents() async throws -> MihonBackup {
        try await writer.read { db in
            var backup = MihonBackup()
            let categories = try CategoryRecord.order(Column("sort")).fetchAll(db)
            backup.categories = categories.map { MihonBackup.Category(name: $0.name, order: Int64($0.sort), id: Int64($0.id), flags: Int64($0.flags)) }
            let orderById = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, Int64($0.sort)) })

            let series = try SeriesRecord.fetchAll(db, sql: """
                SELECT * FROM series WHERE inLibrary = 1
                   OR id IN (SELECT seriesId FROM chapter WHERE read = 1 OR id IN (SELECT chapterId FROM history))
                ORDER BY id
                """)
            for record in series {
                let chapters = try ChapterRecord.filter(ChapterRecord.Columns.seriesId == record.id)
                    .order(ChapterRecord.Columns.readingOrder).fetchAll(db)
                let urlById = Dictionary(uniqueKeysWithValues: chapters.map { ($0.id, $0.url) })
                let history = try HistoryRecord.filter(urlById.keys.contains(Column("chapterId"))).fetchAll(db)
                let categoryIds = try Int.fetchAll(db, sql: "SELECT categoryId FROM seriesCategory WHERE seriesId = ?", arguments: [record.id])
                let tracks = try TrackRecord.filter(Column("seriesId") == record.id).fetchAll(db)
                let last = Int64(max(chapters.count - 1, 0))

                var manga = MihonBackup.Manga(source: record.source, url: record.url)
                manga.title = record.name
                manga.artist = record.artists
                manga.author = record.authors
                manga.description = record.summary
                manga.genres = record.genreList
                manga.status = record.status
                manga.thumbnailUrl = record.thumbnailUrl
                manga.dateAdded = record.dateAdded?.milliseconds ?? 0
                manga.favorite = record.inLibrary
                manga.initialized = record.initialized
                manga.categories = categoryIds.compactMap { orderById[$0] }
                // Mihon's source order counts from the newest chapter; ours from the first.
                manga.chapters = chapters.map { chapter in
                    MihonBackup.Chapter(
                        url: chapter.url, name: chapter.name, scanlator: chapter.scanlator, read: chapter.read,
                        bookmark: chapter.bookmark, lastPageRead: Int64(chapter.lastPageRead),
                        dateFetch: chapter.dateFetch?.milliseconds ?? 0, dateUpload: chapter.dateUpload?.milliseconds ?? 0,
                        chapterNumber: Float(chapter.number), sourceOrder: last - Int64(chapter.readingOrder),
                        memo: chapter.memo.flatMap { $0 == "{}" || $0.isEmpty ? nil : Data($0.utf8) }
                    )
                }
                manga.history = history.compactMap { entry in
                    urlById[entry.chapterId].map {
                        MihonBackup.History(url: $0, lastRead: entry.lastRead.milliseconds, readDuration: Int64(entry.timeRead) * 1000)
                    }
                }
                manga.tracking = tracks.map { track in
                    MihonBackup.Tracking(
                        syncId: Int(track.trackerId), libraryId: track.libraryId ?? 0, trackingUrl: track.remoteUrl,
                        title: track.title, lastChapterRead: Float(track.lastChapterRead), totalChapters: track.totalChapters,
                        score: Float(track.score), status: track.status,
                        startedReadingDate: track.startDate?.milliseconds ?? 0, finishedReadingDate: track.finishDate?.milliseconds ?? 0,
                        isPrivate: track.isPrivate, mediaId: track.remoteId
                    )
                }
                backup.manga.append(manga)
            }
            return backup
        }
    }

    /// Adds a backup to what's here, as Mihon's restore does: series are added (or updated in
    /// place), chapters keep the furthest reading of the two, categories are matched by name.
    /// Returns how many series were restored.
    func restore(_ backup: MihonBackup) async throws -> Int {
        try await writer.write { db in
            // The backup's categories, by their order, as categories here.
            var categoryIds: [Int64: Int] = [:]
            var existing = try CategoryRecord.fetchAll(db)
            for category in backup.categories.sorted(by: { $0.order < $1.order }) {
                if let match = existing.first(where: { $0.name == category.name }) {
                    categoryIds[category.order] = match.id
                } else {
                    let sort = (try Int.fetchOne(db, sql: "SELECT MAX(sort) FROM category") ?? -1) + 1
                    let record = CategoryRecord(id: try Self.nextId(db, table: "category"), name: category.name, sort: sort, flags: Int(category.flags))
                    try record.insert(db)
                    existing.append(record)
                    categoryIds[category.order] = record.id
                }
            }

            for manga in backup.manga where !manga.url.isEmpty {
                let details = SManga(
                    url: manga.url, title: manga.title.isEmpty ? manga.url : manga.title, artist: manga.artist,
                    author: manga.author, description: manga.description,
                    genre: manga.genres.isEmpty ? nil : manga.genres.joined(separator: ", "),
                    status: MangaStatus(rawValue: manga.status) ?? .unknown, thumbnailURL: manga.thumbnailUrl,
                    initialized: manga.initialized
                )
                var series = try Self.localSeries(db, source: manga.source, manga: details)
                if !series.initialized, manga.initialized { series.apply(details) }
                if manga.favorite, !series.inLibrary {
                    series.inLibrary = true
                    series.dateAdded = Date(milliseconds: manga.dateAdded) ?? Date()
                }
                try series.update(db)
                let seriesId = series.id

                for order in manga.categories {
                    guard manga.favorite, let categoryId = categoryIds[order] else { continue }
                    try db.execute(sql: "INSERT OR IGNORE INTO seriesCategory (seriesId, categoryId) VALUES (?, ?)", arguments: [seriesId, categoryId])
                }

                // Chapters: the furthest reading of the two wins.
                var chapters = Dictionary(
                    try ChapterRecord.filter(ChapterRecord.Columns.seriesId == seriesId).fetchAll(db).map { ($0.url, $0) }
                ) { first, _ in first }
                let newest = manga.chapters.map(\.sourceOrder).max() ?? 0
                for backed in manga.chapters where !backed.url.isEmpty {
                    let memo = backed.memo.map { String(decoding: $0, as: UTF8.self) }.flatMap { $0 == "{}" ? nil : $0 }
                    if var chapter = chapters[backed.url] {
                        let before = chapter
                        if backed.read { chapter.read = true }
                        if backed.bookmark { chapter.bookmark = true }
                        if !chapter.read { chapter.lastPageRead = max(chapter.lastPageRead, Int(clamping: max(backed.lastPageRead, 0))) }
                        if chapter != before { try chapter.update(db) }
                    } else {
                        let chapter = ChapterRecord(
                            id: try Self.nextId(db, table: "chapter"), seriesId: seriesId, url: backed.url, name: backed.name,
                            number: Double(backed.chapterNumber), scanlator: backed.scanlator,
                            readingOrder: Int(clamping: newest - backed.sourceOrder), pages: 0, read: backed.read,
                            bookmark: backed.bookmark, lastPageRead: Int(clamping: max(backed.lastPageRead, 0)),
                            dateUpload: Date(milliseconds: backed.dateUpload),
                            dateFetch: Date(milliseconds: backed.dateFetch) ?? Date(timeIntervalSince1970: 0),
                            isDownloaded: false, memo: memo
                        )
                        try chapter.insert(db)
                        chapters[backed.url] = chapter
                    }
                }

                for entry in manga.history {
                    guard let chapter = chapters[entry.url], let lastRead = Date(milliseconds: entry.lastRead) else { continue }
                    let seconds = Int(clamping: max(entry.readDuration, 0) / 1000)
                    try db.execute(sql: """
                        INSERT INTO history (chapterId, lastRead, timeRead) VALUES (?, ?, ?)
                        ON CONFLICT(chapterId) DO UPDATE SET lastRead = MAX(lastRead, excluded.lastRead),
                                                             timeRead = MAX(timeRead, excluded.timeRead)
                        """, arguments: [chapter.id, lastRead, seconds])
                }

                for tracking in manga.tracking {
                    let current = try TrackRecord
                        .filter(Column("seriesId") == seriesId && Column("trackerId") == Int64(tracking.syncId)).fetchOne(db)
                    // The one read further is kept, as Mihon's `TrackRestorer`.
                    if let current, current.lastChapterRead >= Double(tracking.lastChapterRead) { continue }
                    let track = TrackRecord(
                        id: current?.id, seriesId: seriesId, trackerId: Int64(tracking.syncId), remoteId: tracking.mediaId,
                        libraryId: tracking.libraryId == 0 ? nil : tracking.libraryId, title: tracking.title,
                        lastChapterRead: Double(tracking.lastChapterRead), totalChapters: tracking.totalChapters,
                        status: tracking.status, score: Double(tracking.score), remoteUrl: tracking.trackingUrl,
                        startDate: Date(milliseconds: tracking.startedReadingDate),
                        finishDate: Date(milliseconds: tracking.finishedReadingDate), isPrivate: tracking.isPrivate
                    )
                    try track.save(db)
                }
            }
            return backup.manga.count
        }
    }
}
