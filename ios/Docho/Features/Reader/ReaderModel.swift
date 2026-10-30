import Foundation
import Observation

/// The chapter being read and the page shown. Progress is saved locally on every page change and
/// handed to `ProgressSync`, which sends it to the series' server after a short pause.
@MainActor
@Observable
final class ReaderModel {
    private(set) var series: SeriesRecord
    private(set) var chapters: [ChapterRecord]
    private(set) var chapter: ChapterRecord
    private(set) var pageCount: Int
    /// 0-based index of the page shown.
    private(set) var page: Int
    /// Paged left to right, right to left or vertical, or a long strip.
    private(set) var mode: ReaderMode
    private(set) var loadError: String?
    /// Pages are shown once the latest progress has been pulled (or that took too long).
    private(set) var isReady = false
    /// The current chapter's page list is known (from its files or its source).
    private(set) var pagesLoaded = false
    var overlayVisible = false
    /// A page the view should move to, e.g. from the slider. A new value is a new request.
    private(set) var jump: PageJump?

    struct PageJump: Equatable {
        var page: Int
        let id = UUID()
    }

    let app: AppModel
    /// The chapter's pages on the device, when it's downloaded.
    private var pageFiles: [URL] = []
    /// The chapter's pages on the server.
    private var sourcePages: [SourcePage] = []
    private var source: any MangaSource { app.source(for: series) }

    var seriesId: Int { series.id }
    var seriesName: String { series.name }

    init(app: AppModel, series: SeriesRecord, chapters: [ChapterRecord], start: ChapterRecord) {
        self.app = app
        self.series = series
        self.chapters = chapters
        chapter = start
        pageCount = start.pages
        page = Self.resumePage(start)
        pageFiles = app.downloads.store.pageFiles(seriesId: series.id, chapterId: start.id)
        mode = series.readerMode.flatMap(ReaderMode.init(rawValue:)) ?? app.readerSettings.defaultMode
    }

    /// Read chapters start again from the first page.
    static func resumePage(_ chapter: ChapterRecord) -> Int {
        chapter.read ? 0 : min(chapter.lastPageRead, max(chapter.pages - 1, 0))
    }

    var previousChapter: ChapterRecord? { neighbour(-1) }
    var nextChapter: ChapterRecord? { neighbour(1) }

    /// Neighbours in reading order, skipping read chapters if the reader setting says so.
    private func neighbour(_ offset: Int) -> ChapterRecord? {
        guard var index = chapters.firstIndex(where: { $0.id == chapter.id }) else { return nil }
        repeat {
            index += offset
            guard chapters.indices.contains(index) else { return nil }
        } while app.readerSettings.skipRead && chapters[index].read && chapters.indices.contains(index + offset)
        return chapters[index]
    }

    /// The downloaded file, or the page on the server.
    func pageRequest(_ page: Int) -> URLRequest? {
        if pageFiles.indices.contains(page) { return URLRequest(url: pageFiles[page]) }
        guard sourcePages.indices.contains(page) else { return nil }
        return source.imageRequest(sourcePages[page])
    }

    var isDownloaded: Bool { !pageFiles.isEmpty }

    /// Before the first page: picks up the page reached on another device, waiting at most
    /// `timeout` (then the pull carries on and local progress is used), and loads the page list.
    func prepare(timeout: Duration = .seconds(4)) async {
        if !isReady, app.sync.syncs(series) {
            // Whichever finishes first; the pull isn't cancelled, so it still lands in the database.
            let (finished, signal) = AsyncStream<Void>.makeStream()
            Task { [app, series, chapter] in
                await app.sync.syncSeries(series, chapterIds: [chapter.id])
                signal.yield()
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                signal.yield()
            }
            for await _ in finished { break }
            timer.cancel()
            if let stored = try? await app.database.chapterList(seriesId: seriesId),
               let current = stored.first(where: { $0.id == chapter.id }) {
                chapters = stored
                chapter = current
                if current.pages > 0 { pageCount = current.pages }
                page = Self.resumePage(current)
            }
        }
        isReady = true
        await loadPages()
        try? await app.database.touchSeries(seriesId)
    }

    /// Lists the chapter's pages from its files or its source.
    func loadPages() async {
        loadError = nil
        pagesLoaded = false
        if !pageFiles.isEmpty {
            pageCount = pageFiles.count
            sourcePages = []
            pagesLoaded = true
            return
        }
        do {
            sourcePages = try await source.pages(chapter.schapter)
            pageCount = sourcePages.count
            if pageCount == 0 {
                loadError = SourceError.noPages.localizedDescription
            } else if chapter.pages != pageCount {
                try? await app.database.setPageCount(chapterId: chapter.id, pages: pageCount)
                update { $0.pages = pageCount }
            }
            page = min(page, max(pageCount - 1, 0))
            pagesLoaded = pageCount > 0
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// The view settled on `page`: save it, and mark the chapter read on its last page.
    func pageShown(_ page: Int) async {
        guard page != self.page || !chapter.read && page == pageCount - 1 else { return }
        self.page = page
        let wasRead = chapter.read
        let read = chapter.read || page >= pageCount - 1
        update { $0.lastPageRead = page; $0.read = read }
        try? await app.database.saveProgress(
            chapterId: chapter.id, lastPageRead: page, read: read, pages: pageCount, history: !app.preferences.incognitoMode
        )
        await app.sync.pageChanged(series, chapter: chapter, page: page, pageCount: pageCount, read: read)
        if read, !wasRead { await chapterFinished() }
    }

    /// Delete after reading, and download ahead, as on Android.
    private func chapterFinished() async {
        if app.preferences.deleteAfterReading, isDownloaded {
            await app.downloads.delete(seriesId: seriesId, chapterIds: [chapter.id])
        }
        let ahead = app.preferences.downloadAhead
        if ahead > 0, let index = chapters.firstIndex(where: { $0.id == chapter.id }) {
            let next = chapters.dropFirst(index + 1).filter { !$0.read }.prefix(ahead)
            await app.downloads.download(Array(next))
        }
    }

    func jump(to page: Int) {
        guard (0..<pageCount).contains(page) else { return }
        jump = PageJump(page: page)
    }

    /// Opens the previous or next chapter: the previous at its last page, the next at its start.
    func open(_ target: ChapterRecord, atEnd: Bool) async {
        chapter = target
        pageFiles = app.downloads.store.pageFiles(seriesId: seriesId, chapterId: target.id)
        sourcePages = []
        pagesLoaded = false
        pageCount = target.pages
        page = atEnd ? max(target.pages - 1, 0) : 0
        jump = nil
        await loadPages()
        if atEnd { page = max(pageCount - 1, 0) }
    }

    /// Changes the mode for this series.
    func setMode(_ mode: ReaderMode) async {
        self.mode = mode
        series.readerMode = mode.rawValue
        try? await app.database.setReaderMode(seriesId: seriesId, mode.rawValue)
    }

    func toggleBookmark() async {
        let bookmarked = !chapter.bookmark
        update { $0.bookmark = bookmarked }
        try? await app.database.setBookmarked([chapter.id], bookmarked)
    }

    var settings: ReaderSettings { app.readerSettings }

    private func update(_ change: (inout ChapterRecord) -> Void) {
        change(&chapter)
        if let index = chapters.firstIndex(where: { $0.id == chapter.id }) {
            chapters[index] = chapter
        }
    }
}
