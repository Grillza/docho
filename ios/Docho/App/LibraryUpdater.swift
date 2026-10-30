import BackgroundTasks
import Foundation
import Observation
import os

/// Fetches series from their sources (Mihon's `LibraryUpdateJob` and the series screen's
/// refresh). A library update checks every library series for new chapters, skipping those the
/// smart update settings leave out, then syncs progress and downloads new chapters if asked to.
@MainActor
@Observable
final class LibraryUpdater {
    private(set) var isRunning = false
    /// Series done and total in the running update.
    private(set) var progress: (done: Int, total: Int) = (0, 0)
    private(set) var lastError: String?

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let sources: SourceManager
    @ObservationIgnored private let sync: ProgressSync
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let log = Logger(subsystem: "io.github.grillza.docho", category: "library-update")

    static let taskIdentifier = "io.github.grillza.docho.library-update"

    /// Asks iOS for a background update in about a day; it runs when iOS decides (usually
    /// overnight while charging), which is as close to Android's schedule as iOS allows.
    static func scheduleBackgroundUpdate() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    init(database: AppDatabase, sources: SourceManager, sync: ProgressSync, downloads: DownloadManager, preferences: AppPreferences) {
        self.database = database
        self.sources = sources
        self.sync = sync
        self.downloads = downloads
        self.preferences = preferences
    }

    /// Fetches one series' details (when asked or never fetched) and chapters, stores them and
    /// syncs its progress. Returns the chapters that are new.
    @discardableResult
    func refresh(_ series: SeriesRecord, details: Bool = true) async throws -> [ChapterRecord] {
        let source = sources.source(series.source)
        let (manga, chapters) = try await source.update(series.manga, details: details || !series.initialized, chapters: true)
        let added = try await database.saveFromSource(seriesId: series.id, manga: manga, chapters: chapters)
        if let stored = try await database.seriesRecord(id: series.id) {
            await sync.syncSeries(stored)
        }
        return added
    }

    /// Updates the library, or one category of it. New chapters are downloaded if the setting
    /// is on, for series in the library.
    func update(category: Int? = nil) async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        defer { isRunning = false }

        let items = (try? await database.libraryItemsOnce()) ?? []
        let candidates = items.filter { item in
            if let category {
                let inCategory = category == CategoryRecord.defaultId ? item.categoryIds.isEmpty : item.categoryIds.contains(category)
                if !inCategory { return false }
            }
            if preferences.smartUpdateSkipCompleted, item.series.mangaStatus == .completed { return false }
            if preferences.smartUpdateSkipUnread, item.unreadCount > 0 { return false }
            if preferences.smartUpdateSkipNotStarted, item.totalChapters > 0, !item.hasStarted { return false }
            return sources.source(item.series.source).isConfigured
        }
        // Sources with the most entries first, as Mihon 0.21.3 does.
        let bySource = Dictionary(grouping: candidates, by: \.series.source).values.sorted { $0.count > $1.count }.flatMap { $0 }
        progress = (0, bySource.count)
        var newChapters: [ChapterRecord] = []
        for item in bySource {
            do {
                newChapters += try await refresh(item.series, details: false)
            } catch {
                log.warning("Could not update '\(item.series.name)': \(error)")
                lastError = error.localizedDescription
            }
            progress.done += 1
        }
        if preferences.downloadNewChapters, !newChapters.isEmpty {
            await downloads.download(newChapters)
        }
        log.info("Library update: \(bySource.count) series, \(newChapters.count) new chapters")
    }
}

extension AppDatabase {
    func libraryItemsOnce() async throws -> [LibraryItem] {
        try await writer.read { db in try LibraryItem.fetchAll(db, sql: Self.librarySQLForUpdate) }
    }

    fileprivate static let librarySQLForUpdate = """
        SELECT series.*,
               COUNT(chapter.id) AS totalChapters,
               COALESCE(SUM(chapter.read), 0) AS readCount,
               COALESCE(SUM(chapter.bookmark), 0) AS bookmarkCount,
               COALESCE(SUM(chapter.isDownloaded), 0) AS downloadCount,
               MAX(chapter.dateUpload) AS latestUpload,
               MAX(chapter.dateFetch) AS chapterFetchedAt,
               NULL AS lastRead,
               (SELECT GROUP_CONCAT(categoryId) FROM seriesCategory WHERE seriesId = series.id) AS categoryIds
        FROM series
        LEFT JOIN chapter ON chapter.seriesId = series.id
        WHERE series.inLibrary
        GROUP BY series.id
        """
}
