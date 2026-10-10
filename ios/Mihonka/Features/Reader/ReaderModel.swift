import Foundation
import Observation

/// How pages are laid out. Stored per series in `series.readerMode`; milestone 7 adds webtoon
/// mode and a default in Settings.
enum ReadingDirection: String, CaseIterable, Identifiable, Sendable {
    case leftToRight = "ltr"
    case rightToLeft = "rtl"

    /// Mihon's default.
    static let `default` = ReadingDirection.rightToLeft

    var id: Self { self }

    var title: String {
        switch self {
        case .leftToRight: String(localized: "Left to right")
        case .rightToLeft: String(localized: "Right to left")
        }
    }
}

/// The chapter being read and the page shown. Progress is saved locally on every page change;
/// milestone 6 sends it to Kavita.
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
    private(set) var direction: ReadingDirection
    private(set) var loadError: String?
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
        direction = readerMode.flatMap(ReadingDirection.init(rawValue:)) ?? .default
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

    func setDirection(_ direction: ReadingDirection) async {
        self.direction = direction
        try? await app.database.setReaderMode(seriesId: seriesId, direction.rawValue)
    }

    private func update(_ change: (inout ChapterRecord) -> Void) {
        change(&chapter)
        if let index = chapters.firstIndex(where: { $0.id == chapter.id }) {
            chapters[index] = chapter
        }
    }
}
