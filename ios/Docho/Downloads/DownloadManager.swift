import Foundation
import os

/// Downloads chapters for offline reading, one chapter at a time and a few pages at once.
/// The queue is the `download` table, so it survives the app stopping; `resume()` picks it up.
actor DownloadManager {
    static let concurrentPages = 3

    nonisolated let store: DownloadStore
    private let database: AppDatabase
    private let kavita: KavitaClient
    private let fetcher: any PageFetcher
    private var worker: Task<Void, Never>?
    private var current: (chapterId: Int, task: Task<Void, Never>)?
    private let log = Logger(subsystem: "io.github.grillza.docho", category: "downloads")

    init(database: AppDatabase, kavita: KavitaClient, store: DownloadStore, fetcher: any PageFetcher) {
        self.database = database
        self.kavita = kavita
        self.store = store
        self.fetcher = fetcher
    }

    /// Picks up the queue left when the app last stopped.
    func resume() async {
        try? await database.requeueDownloads()
        startWorker()
    }

    func download(_ chapters: [ChapterRecord]) async {
        _ = try? await database.queueDownloads(chapters)
        startWorker()
    }

    /// Tries failed downloads again.
    func retryFailed() async {
        try? await database.requeueDownloads(failed: true)
        startWorker()
    }

    /// Takes chapters out of the queue and throws away what they had downloaded so far.
    func cancel(_ chapters: [(seriesId: Int, chapterId: Int)]) async {
        let ids = chapters.map(\.chapterId)
        try? await database.removeDownloads(ids)
        if let current, ids.contains(current.chapterId) {
            current.task.cancel()
            await current.task.value
        }
        for chapter in chapters {
            try? FileManager.default.removeItem(at: store.partialDirectory(seriesId: chapter.seriesId, chapterId: chapter.chapterId))
        }
    }

    /// Deletes downloaded chapters (and cancels any still in the queue).
    func delete(seriesId: Int, chapterIds: [Int]) async {
        await cancel(chapterIds.map { (seriesId, $0) })
        for chapterId in chapterIds {
            store.delete(seriesId: seriesId, chapterId: chapterId)
        }
        try? await database.setDownloaded(chapterIds, false)
    }

    /// Deletes a series' downloads; only the chapters already read when `readOnly` is set.
    func deleteSeries(_ seriesId: Int, readOnly: Bool = false) async {
        guard let ids = try? await database.downloadedChapterIds(seriesId: seriesId, readOnly: readOnly) else { return }
        await delete(seriesId: seriesId, chapterIds: ids)
    }

    /// Waits until the queue has been worked through (for tests).
    func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    // MARK: - Worker

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task {
            while let next = try? await database.nextQueuedDownload() {
                let task = Task { await download(next) }
                current = (next.chapterId, task)
                await task.value
                current = nil
            }
            worker = nil
        }
    }

    private func download(_ entry: DownloadRecord) async {
        let chapterId = entry.chapterId
        let seriesId = entry.seriesId
        do {
            try await database.updateDownload(chapterId) { $0.state = .downloading; $0.error = nil }
            var pageCount = entry.pagesTotal
            if pageCount <= 0 {
                pageCount = try await kavita.chapter(id: chapterId).pages
                try await database.updateDownload(chapterId) { [pageCount] in $0.pagesTotal = pageCount }
            }
            let partial = try store.preparePartial(seriesId: seriesId, chapterId: chapterId)
            // Pages fetched before an interruption are kept.
            let present = Set(store.pages(in: partial).keys)
            let missing = (0..<pageCount).filter { !present.contains($0) }
            var done = present.count
            try await database.updateDownload(chapterId) { [done] in $0.pagesDone = done }

            try await withThrowingTaskGroup(of: Void.self) { group in
                var pages = missing.makeIterator()
                func addNext() throws {
                    guard let page = pages.next() else { return }
                    let url = try kavita.pageImageURL(chapterId: chapterId, page: page)
                    group.addTask { [fetcher, store] in
                        let fetched = try await fetcher.fetch(url)
                        try store.storePage(fetched.file, page: page, mimeType: fetched.mimeType, in: partial)
                    }
                }
                for _ in 0..<Self.concurrentPages { try addNext() }
                while try await group.next() != nil {
                    done += 1
                    try await database.updateDownload(chapterId) { [done] in $0.pagesDone = done }
                    try addNext()
                }
            }
            try Task.checkCancellation()
            try store.complete(seriesId: seriesId, chapterId: chapterId)
            try await database.finishDownload(chapterId)
            log.info("Downloaded chapter \(chapterId): \(pageCount) pages")
        } catch {
            // A cancelled download has already left the queue.
            guard !Task.isCancelled else { return }
            log.warning("Download of chapter \(chapterId) failed: \(error)")
            let message = error.localizedDescription
            try? await database.updateDownload(chapterId) { $0.state = .failed; $0.error = message }
        }
    }
}
