import Foundation
import Observation

/// The chapter being read and the page shown. Progress is saved locally on every page change and
/// handed to `KavitaSync`, which sends it to Kavita after a short pause.
@MainActor
@Observable
final class ReaderModel {
    let seriesId: Int
    let seriesName: String
    private(set) var chapters: [ChapterRecord]
    private(set) var chapter: ChapterRecord
    private(set) var pageCount: Int
    /// 0-based index of the page shown.
    private(set) var page: Int
    /// Paged left to right or right to left, or webtoon.
    private(set) var mode: ReaderMode
    private(set) var loadError: String?
    /// Pages are shown once the latest progress has been pulled (or that took too long).
    private(set) var isReady = false
    var overlayVisible = false
    /// A page the view should move to, e.g. from the slider. A new value is a new request.
    private(set) var jump: PageJump?

    struct PageJump: Equatable {
        var page: Int
        let id = UUID()
    }

    private let app: AppModel

    init(app: AppModel, seriesId: Int, seriesName: String, readerMode: String?, chapters: [ChapterRecord], start: ChapterRecord) {
        self.app = app
        self.seriesId = seriesId
        self.seriesName = seriesName
        self.chapters = chapters
        chapter = start
        pageCount = start.pages
        page = Self.resumePage(start)
        mode = readerMode.flatMap(ReaderMode.init(rawValue:)) ?? app.readerSettings.defaultMode
    }

    /// Read chapters start again from the first page.
    static func resumePage(_ chapter: ChapterRecord) -> Int {
        chapter.read ? 0 : min(chapter.lastPageRead, max(chapter.pages - 1, 0))
    }

    var previousChapter: ChapterRecord? { neighbour(-1) }
    var nextChapter: ChapterRecord? { neighbour(1) }

    private func neighbour(_ offset: Int) -> ChapterRecord? {
        guard let index = chapters.firstIndex(where: { $0.id == chapter.id }) else { return nil }
        return chapters.indices.contains(index + offset) ? chapters[index + offset] : nil
    }

    func pageURL(_ page: Int) -> URL? {
        try? app.kavita.pageImageURL(chapterId: chapter.id, page: page)
    }

    /// Before the first page: picks up the page reached on another device, waiting at most
    /// `timeout` (then the pull carries on and local progress is used), and fetches the page
    /// count if it's missing.
    func prepare(timeout: Duration = .seconds(4)) async {
        if !isReady, app.sync.isEnabled {
            // Whichever finishes first; the pull isn't cancelled, so it still lands in the database.
            let (finished, signal) = AsyncStream<Void>.makeStream()
            Task { [app, seriesId] in
                await app.sync.syncSeries(seriesId)
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
        await loadPageCount()
    }

    /// Fetches the page count when the chapter list didn't have it.
    func loadPageCount() async {
        guard pageCount == 0 else { return }
        do {
            pageCount = try await app.kavita.chapter(id: chapter.id).pages
            loadError = pageCount == 0 ? String(localized: "This chapter has no pages.") : nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// The view settled on `page`: save it, and mark the chapter read on its last page.
    func pageShown(_ page: Int) async {
        guard page != self.page || !chapter.read && page == pageCount - 1 else { return }
        self.page = page
        let read = chapter.read || page >= pageCount - 1
        update { $0.lastPageRead = page; $0.read = read }
        try? await app.database.saveProgress(chapterId: chapter.id, lastPageRead: page, read: read)
        await app.sync.pageChanged(chapter, page: page, pageCount: pageCount, read: read)
    }

    func jump(to page: Int) {
        guard (0..<pageCount).contains(page) else { return }
        jump = PageJump(page: page)
    }

    /// Opens the previous or next chapter: the previous at its last page, the next at its start.
    func open(_ target: ChapterRecord, atEnd: Bool) async {
        chapter = target
        pageCount = target.pages
        page = atEnd ? max(target.pages - 1, 0) : 0
        jump = nil
        loadError = nil
        await loadPageCount()
        if atEnd { page = max(pageCount - 1, 0) }
    }

    /// Changes the mode for this series.
    func setMode(_ mode: ReaderMode) async {
        self.mode = mode
        try? await app.database.setReaderMode(seriesId: seriesId, mode.rawValue)
    }

    var settings: ReaderSettings { app.readerSettings }

    private func update(_ change: (inout ChapterRecord) -> Void) {
        change(&chapter)
        if let index = chapters.firstIndex(where: { $0.id == chapter.id }) {
            chapters[index] = chapter
        }
    }
}
