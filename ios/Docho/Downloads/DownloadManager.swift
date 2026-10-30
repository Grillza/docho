import Foundation
import os

/// Downloads chapters for offline reading, one chapter at a time and a few pages at once, from
/// whichever source each series comes from. The queue is the `download` table, so it survives
/// the app stopping; `resume()` picks it up.
///
/// Pausing (Android's download notification Pause) finishes the pages in flight and starts no
/// new ones; the chapter goes back to the queue with its pages so far kept.
actor DownloadManager {
    static let defaultConcurrentPages = 3

    nonisolated let store: DownloadStore
    private let database: AppDatabase
    private let sources: SourceManager
    private let fetcher: any PageFetcher
    private let defaultsBox: SendableDefaults
    private var defaults: UserDefaults { defaultsBox.defaults }
    private var worker: Task<Void, Never>?
    private var current: (chapterId: Int, task: Task<Void, Never>)?
    /// Finished and failed chapters since the queue last emptied, for the notifications.
    nonisolated let events: AsyncStream<DownloadEvent>
    private let eventContinuation: AsyncStream<DownloadEvent>.Continuation
    private let log = Logger(subsystem: "io.github.grillza.docho", category: "downloads")

    init(database: AppDatabase, sources: SourceManager, store: DownloadStore, fetcher: any PageFetcher, defaults: SendableDefaults = SendableDefaults(.standard)) {
        self.database = database
        self.sources = sources
        self.store = store
        self.fetcher = fetcher
        self.defaultsBox = defaults
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    private var preferences: DownloadPreferences { .current(defaults) }

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

    /// Pauses or resumes the queue. A paused queue keeps its chapters.
    func setPaused(_ paused: Bool) async {
        defaults.set(paused, forKey: "download_queue_paused")
        if paused {
            // The worker notices between pages; wait for it to settle.
            await worker?.value
        } else {
            startWorker()
        }
    }

    var isPaused: Bool { preferences.paused }

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

    /// Empties the queue (Android's Cancel all).
    func cancelAll() async {
        let queued = (try? await database.queuedDownloads()) ?? []
        await cancel(queued.map { ($0.seriesId, $0.chapterId) })
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
        guard worker == nil, !preferences.paused else { return }
        worker = Task {
            while !preferences.paused, let next = try? await database.nextQueuedDownload() {
                let task = Task { await download(next) }
                current = (next.chapterId, task)
                await task.value
                current = nil
            }
            worker = nil
            if !preferences.paused, (try? await database.queuedDownloads().isEmpty) == true {
                eventContinuation.yield(.queueFinished)
            }
        }
    }

    private func download(_ entry: DownloadRecord) async {
        let chapterId = entry.chapterId
        let seriesId = entry.seriesId
        do {
            guard let chapter = try await database.chapter(id: chapterId), let series = try await database.seriesRecord(id: seriesId) else {
                try await database.removeDownloads([chapterId])
                return
            }
            let source = sources.source(series.source)
            try await database.updateDownload(chapterId) { $0.state = .downloading; $0.error = nil }
            let pages = try await source.pages(chapter.schapter)
            guard !pages.isEmpty else { throw SourceError.noPages }
            let pageCount = pages.count
            try await database.updateDownload(chapterId) { $0.pagesTotal = pageCount }
            if chapter.pages != pageCount { try await database.setPageCount(chapterId: chapterId, pages: pageCount) }

            let partial = try store.preparePartial(seriesId: seriesId, chapterId: chapterId)
            // Pages fetched before an interruption are kept.
            let present = Set(store.pages(in: partial).keys)
            let missing = pages.filter { !present.contains($0.index) }
            var done = present.count
            try await database.updateDownload(chapterId) { [done] in $0.pagesDone = done }

            let preferences = preferences
            try await withThrowingTaskGroup(of: Void.self) { group in
                var queue = missing.makeIterator()
                func addNext() {
                    // A paused queue lets the pages in flight finish and starts no more.
                    guard !self.preferences.paused else { return }
                    guard let page = queue.next() else { return }
                    var request = source.imageRequest(page)
                    request.allowsCellularAccess = !preferences.onlyOnWifi
                    request.allowsExpensiveNetworkAccess = !preferences.onlyOnWifi
                    group.addTask { [fetcher, store] in
                        let fetched = try await fetcher.fetch(request)
                        try store.storePage(fetched.file, page: page.index, mimeType: fetched.mimeType, in: partial)
                    }
                }
                for _ in 0..<preferences.concurrentPages { addNext() }
                while try await group.next() != nil {
                    done += 1
                    try await database.updateDownload(chapterId) { [done] in $0.pagesDone = done }
                    addNext()
                }
            }
            try Task.checkCancellation()
            if done < pageCount {
                try await database.updateDownload(chapterId) { $0.state = .queued }
                return
            }
            try store.complete(seriesId: seriesId, chapterId: chapterId)
            try await database.finishDownload(chapterId)
            eventContinuation.yield(.finished(seriesId: seriesId, chapterId: chapterId))
            log.info("Downloaded chapter \(chapterId): \(pageCount) pages")
        } catch {
            // A cancelled download has already left the queue.
            guard !Task.isCancelled else { return }
            log.warning("Download of chapter \(chapterId) failed: \(error)")
            let message = error.localizedDescription
            try? await database.updateDownload(chapterId) { $0.state = .failed; $0.error = message }
            eventContinuation.yield(.failed(seriesId: seriesId, chapterId: chapterId, message: message))
        }
    }
}

enum DownloadEvent: Sendable, Equatable {
    case finished(seriesId: Int, chapterId: Int)
    case failed(seriesId: Int, chapterId: Int, message: String)
    case queueFinished
}

/// UserDefaults is documented as thread-safe but isn't marked `Sendable`.
struct SendableDefaults: @unchecked Sendable {
    let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }
}
