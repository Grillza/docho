import Foundation
import Observation

/// One series and its chapters: shown from the database, refreshed from its source.
@MainActor
@Observable
final class SeriesModel {
    let seriesId: Int
    private(set) var series: SeriesRecord?
    private(set) var chapters: [ChapterRecord] = []
    /// Chapters in the download queue, by id.
    private(set) var downloads: [Int: DownloadRecord] = [:]
    private(set) var isRefreshing = false
    private(set) var refreshError: String?

    private let app: AppModel

    init(app: AppModel, seriesId: Int) {
        self.app = app
        self.seriesId = seriesId
    }

    var source: any MangaSource { series.map(app.source(for:)) ?? StubSource(id: 0) }

    var display: ChapterDisplay { series?.chapterDisplay ?? ChapterDisplay() }

    /// The chapter list as shown: filtered and sorted per the series' chapter settings.
    var displayedChapters: [ChapterRecord] {
        // Local comics count as downloaded, as on Android.
        chapters.displayed(display, downloaded: app.preferences.downloadedOnly && series?.source != LocalSource.id)
    }

    /// The chapter the Start/Resume button opens.
    var nextChapter: ChapterRecord? {
        if let started = chapters.first(where: \.inProgress) { return started }
        let lastRead = chapters.lastIndex(where: \.read)
        let after = lastRead.map { chapters[($0 + 1)...] } ?? chapters[...]
        return after.first { !$0.read } ?? chapters.first { !$0.read }
    }

    var hasStarted: Bool { chapters.contains { $0.read || $0.inProgress } }

    /// Follows the stored series until cancelled.
    func observeSeries() async {
        do {
            for try await series in app.database.series(id: seriesId) { self.series = series }
        } catch {}
    }

    /// Follows the stored chapters until cancelled.
    func observeChapters() async {
        do {
            for try await chapters in app.database.chapters(seriesId: seriesId) { self.chapters = chapters }
        } catch {}
    }

    /// Follows this series' download queue until cancelled.
    func observeDownloads() async {
        do {
            for try await downloads in app.database.downloads(seriesId: seriesId) { self.downloads = downloads }
        } catch {}
    }

    func download(_ chapterIds: some Collection<Int>) async {
        let ids = Set(chapterIds)
        await app.userDownload(chapters.filter { ids.contains($0.id) })
    }

    /// Mihon's download menu: the next n unread chapters, or all unread, or all.
    func downloadNext(_ count: Int?) async {
        let unread = chapters.filter { !$0.read && !$0.isDownloaded }
        await app.userDownload(count.map { Array(unread.prefix($0)) } ?? unread)
    }

    func downloadAll() async {
        await app.userDownload(chapters.filter { !$0.isDownloaded })
    }

    func cancelDownload(_ chapterId: Int) async {
        await app.downloads.cancel([(seriesId, chapterId)])
    }

    func deleteDownloads(_ chapterIds: some Collection<Int>) async {
        await app.downloads.delete(seriesId: seriesId, chapterIds: Array(chapterIds))
    }

    func deleteAllDownloads(readOnly: Bool) async {
        await app.downloads.deleteSeries(seriesId, readOnly: readOnly)
    }

    func retryDownloads() async {
        await app.downloads.retryFailed()
    }

    /// Fetches the series and its chapters from its source, stores them, and syncs progress.
    func refresh() async {
        guard let series else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await app.library.refresh(series, details: true)
            refreshError = nil
        } catch {
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            refreshError = error.localizedDescription
        }
    }

    /// Opening a series refreshes it if it's never been fetched, else just syncs progress.
    func load() async {
        while series == nil {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
        }
        guard let series else { return }
        if !series.initialized || chapters.isEmpty {
            await refresh()
        } else {
            await app.sync.syncSeries(series)
        }
    }

    /// Adds to the library (into `categories`, or the default category) or removes it.
    func setInLibrary(_ inLibrary: Bool, categories: [Int]? = nil) async {
        try? await app.database.setInLibrary(seriesId: seriesId, inLibrary, categories: categories)
    }

    /// Marks chapters by hand: saved locally, then sent to the series' server as is.
    func setRead(_ chapterIds: some Collection<Int>, _ read: Bool) async {
        let ids = Array(chapterIds)
        guard let series else { return }
        do {
            try await app.database.setChaptersRead(ids, read: read)
            let changed = try await app.database.chapters(ids: ids)
            await app.sync.readStatusChanged(series, chapters: changed, read: read)
            if read, !app.preferences.incognitoMode, let highest = changed.map(\.number).max() {
                await app.trackers.chapterRead(seriesId: seriesId, number: highest)
            }
            if read, app.preferences.deleteAfterMarkedRead {
                let downloaded = changed.filter(\.isDownloaded).map(\.id)
                if !downloaded.isEmpty { await deleteDownloads(downloaded) }
            }
        } catch {}
    }

    func setBookmarked(_ chapterIds: some Collection<Int>, _ bookmarked: Bool) async {
        try? await app.database.setBookmarked(Array(chapterIds), bookmarked)
    }

    func markPreviousRead(_ chapter: ChapterRecord) async {
        guard let ids = try? await app.database.unreadChapterIds(before: chapter) else { return }
        await setRead(ids, true)
    }

    func setDisplay(_ display: ChapterDisplay) async {
        try? await app.database.setChapterDisplay(seriesId: seriesId, display)
    }
}
