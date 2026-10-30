import Foundation
import Observation

/// One series and its chapters: shown from the database, refreshed from Kavita.
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
        await app.downloads.download(chapters.filter { ids.contains($0.id) })
    }

    func downloadUnread() async {
        await app.downloads.download(chapters.filter { !$0.read })
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

    /// Fetches the series, its metadata and its chapters from Kavita and stores them.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let series = app.kavita.series(id: seriesId)
            async let metadata = app.kavita.seriesMetadata(seriesId: seriesId)
            async let volumes = app.kavita.volumes(seriesId: seriesId)
            let (fetched, details, remote) = try await (series, KavitaSeriesDetails(metadata), volumes)
            try await app.database.saveSeries(
                fetched, details: details, chapters: KavitaChapterList.build(remote), seedProgress: app.settings.syncProgress
            )
            refreshError = nil
            await app.sync.syncSeries(seriesId, volumes: remote)
        } catch {
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            refreshError = error.localizedDescription
        }
    }

    func setInLibrary(_ inLibrary: Bool) async {
        try? await app.database.setInLibrary(seriesId: seriesId, inLibrary)
    }

    /// Marks chapters by hand: saved locally, then sent to Kavita as is (see `KavitaSync`).
    func setRead(_ chapterIds: some Collection<Int>, _ read: Bool) async {
        let ids = Array(chapterIds)
        do {
            try await app.database.setChaptersRead(ids, read: read)
            await app.sync.readStatusChanged(try await app.database.chapters(ids: ids), read: read)
        } catch {}
    }

    func markPreviousRead(_ chapter: ChapterRecord) async {
        guard let ids = try? await app.database.unreadChapterIds(before: chapter) else { return }
        await setRead(ids, true)
    }
}

enum PublicationStatus {
    /// Display name of Kavita's `publicationStatus`, mapped as Android does; nil when unknown.
    static func title(_ status: Int?) -> String? {
        switch status {
        case KavitaConstants.statusOngoing: String(localized: "Ongoing")
        case KavitaConstants.statusHiatus: String(localized: "On hiatus")
        case KavitaConstants.statusCompleted, KavitaConstants.statusEnded: String(localized: "Completed")
        case KavitaConstants.statusCancelled: String(localized: "Cancelled")
        default: nil
        }
    }
}
