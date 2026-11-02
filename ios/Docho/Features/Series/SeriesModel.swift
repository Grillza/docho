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

    var isLocal: Bool { series?.source == LocalSource.id }

    /// Deletes Local source chapters' files from the device; the refresh then drops them from
    /// the list. Returns why it failed, if it did.
    func deleteLocalFiles(_ chapterIds: some Collection<Int>) async -> String? {
        let ids = Set(chapterIds)
        do {
            try app.localSource.deleteChapters(chapters.filter { ids.contains($0.id) }.map(\.url))
        } catch {
            await refresh()
            return error.localizedDescription
        }
        await refresh()
        return nil
    }

    /// Deletes a Local source series' folder from the device and takes it out of the library.
    func deleteLocalSeries() async -> String? {
        guard let series else { return nil }
        do {
            try app.localSource.deleteSeries(series.url)
        } catch {
            return error.localizedDescription
        }
        try? await app.database.setInLibrary(seriesId: seriesId, false)
        _ = try? await app.database.saveFromSource(seriesId: seriesId, manga: nil, chapters: [])
        return nil
    }

    /// How a rename went: `renamed` chapters were renamed in Dōchō, `failed` weren't at all, and
    /// `serverError` is why the server didn't take some, which Dōchō still shows renamed.
    struct RenameResult {
        var renamed = 0
        var failed = 0
        var serverError: String?
    }

    /// Renames chapters in Dōchō, and where the chapter lives somewhere Dōchō can change it too:
    /// the file itself for the Local source, the title and number on Komga and BookOrbit (its
    /// series index), the title on Kavita. Whether a chapter is a volume stays in Dōchō.
    func rename(_ requests: [ChapterRenameRequest]) async -> RenameResult {
        guard let series else { return RenameResult() }
        var result = RenameResult()
        for request in requests where request.changes {
            let old = request.chapter
            var url = old.url
            var name = old.name
            var number = old.number
            var memo = old.chapterMemo
            do {
                if request.renames {
                    name = request.name.trimmingCharacters(in: .whitespaces)
                    number = request.number
                    if isLocal { url = try app.localSource.renameChapter(old.url, to: name) }
                    do {
                        try await renameOnServer(source: series.source, url: old.url, name: name, number: number)
                    } catch {
                        if result.serverError == nil { result.serverError = error.localizedDescription }
                    }
                    app.renames.put(source: series.source, oldURL: old.url, newURL: url, .init(name: name, number: number))
                }
                if request.changesKind, let kind = request.kind {
                    memo[ChapterMemo.kind] = .string(kind)
                    app.renames.putKind(source: series.source, url: url, kind)
                }
                try await app.database.renameChapter(id: old.id, url: url, name: name, number: number, memo: memo)
                result.renamed += 1
            } catch {
                result.failed += 1
            }
        }
        // The Local source lists its files again, now under their new names.
        if isLocal { await refresh() }
        return result
    }

    private func renameOnServer(source: Int64, url: String, name: String, number: Double) async throws {
        switch source {
        case KavitaSource.id:
            if let id = KavitaSource.chapterId(url) { try await app.kavita.setChapterTitle(chapterId: id, title: name) }
        case KomgaSource.id:
            if let id = KomgaSource.bookIdOrNil(url) { try await app.komga.setBookTitle(id, title: name, number: number) }
        case BookOrbitSource.id:
            if let id = BookOrbitSource.bookId(url) {
                try await app.bookOrbit.setBookTitle(bookId: id, title: BookOrbitSource.title(fromChapterName: name), seriesIndex: number)
            }
        default:
            break
        }
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
