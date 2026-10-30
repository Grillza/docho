import Foundation
import os

/// Port of `KomgaSync.kt`: two-way, page-level progress sync with Komga, by the same rules as
/// Kavita (the side that has read further wins, except hand marks; an offline queue).
///
/// Komga keeps one position per book: the page reached, counting from 1, and whether the book is
/// finished. A series' book list carries every book's position, so reconciling takes one request.
actor KomgaSync: SyncEngine {
    static let engine = "komga"

    nonisolated let retryRequests: AsyncStream<Void>
    private let retryContinuation: AsyncStream<Void>.Continuation
    private let source: KomgaSource
    private let database: AppDatabase
    private let settings: KomgaSettings
    private let syncSettings: SyncSettings
    private let pageDebounce: Duration
    private var debounces: [String: Task<Void, Never>] = [:]
    private var waiting: [String: Pending] = [:]
    /// Page counts by book id, learned from the reader or the book list.
    private var pageCounts: [String: Int] = [:]
    private let log = Logger(subsystem: "io.github.grillza.docho", category: "komga-sync")

    private var client: KomgaClient { source.client }

    init(source: KomgaSource, database: AppDatabase, settings: KomgaSettings, syncSettings: SyncSettings, pageDebounce: Duration = KavitaSync.pageDebounce) {
        self.source = source
        self.database = database
        self.settings = settings
        self.syncSettings = syncSettings
        self.pageDebounce = pageDebounce
        (retryRequests, retryContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    nonisolated var engine: String { Self.engine }
    nonisolated var isEnabled: Bool { settings.syncProgress && settings.isConfigured }

    /// Komga books only take part in KOReader mode through `KoreaderSync`.
    nonisolated func syncs(_ series: SeriesRecord) -> Bool {
        series.source == KomgaSource.id && isEnabled && !syncSettings.usesKoreader
    }

    /// A position waiting to reach Komga: `page` of `pages`, counting from 1, where 0 means unread.
    struct Pending: Codable, Sendable, Equatable {
        var seriesId: String
        var bookId: String
        var page: Int
        var pages: Int
        var read = false

        /// How far this is, comparable with `serverPosition`: a finished book beats any page.
        var position: Int { read ? .max : page }
    }

    /// How far a book is on the server, in the same terms as `Pending.position`.
    static func serverPosition(_ book: KomgaBook) -> Int {
        guard let progress = book.readProgress else { return 0 }
        return progress.completed ? .max : progress.page
    }

    /// A deliberate read/unread mark always goes through; a page only if it's further than the server's.
    static func shouldSend(_ entry: Pending, markedByUser: Bool, serverPosition: Int) -> Bool {
        markedByUser || entry.position > serverPosition
    }

    // MARK: Push

    func pageChanged(_ series: SeriesRecord, chapter: ChapterRecord, page: Int, pageCount: Int, read: Bool) {
        guard syncs(series), pageCount > 0, let bookId = KomgaSource.bookIdOrNil(chapter.url) else { return }
        pageCounts[bookId] = pageCount
        waiting[bookId] = Pending(
            seriesId: KomgaSource.seriesId(series.url), bookId: bookId, page: read ? pageCount : page + 1, pages: pageCount, read: read
        )
        debounces[bookId]?.cancel()
        debounces[bookId] = Task {
            try? await Task.sleep(for: pageDebounce)
            guard !Task.isCancelled else { return }
            debounces[bookId] = nil
            await sendWaiting(bookId)
        }
    }

    func sendWaitingPages() async {
        for bookId in waiting.keys {
            debounces.removeValue(forKey: bookId)?.cancel()
            await sendWaiting(bookId)
        }
    }

    private func sendWaiting(_ bookId: String) async {
        guard let pending = waiting.removeValue(forKey: bookId),
              let entry = try? await enqueue([pending], markedByUser: false).first
        else { return }
        if await deliver(entry, serverPosition: nil) == .failed { requestRetry() }
    }

    func readStatusChanged(_ series: SeriesRecord, chapters: [ChapterRecord], read: Bool) async {
        guard syncs(series) else { return }
        let seriesId = KomgaSource.seriesId(series.url)
        let progress = chapters.compactMap { chapter -> Pending? in
            guard let bookId = KomgaSource.bookIdOrNil(chapter.url) else { return nil }
            debounces.removeValue(forKey: bookId)?.cancel()
            waiting[bookId] = nil
            let pages = pageCounts[bookId] ?? chapter.pages
            return Pending(seriesId: seriesId, bookId: bookId, page: read ? pages : 0, pages: pages, read: read)
        }
        guard let entries = try? await enqueue(progress, markedByUser: true) else { return }
        for entry in entries where await deliver(entry, serverPosition: nil) == .failed {
            break
        }
    }

    // MARK: Pull

    func syncSeries(_ series: SeriesRecord, chapterIds: Set<Int>?) async {
        guard syncs(series) else { return }
        let seriesId = KomgaSource.seriesId(series.url)
        do {
            let fetched = if let cached = source.progressCache.take(seriesId) { cached } else { try await client.seriesBooks(seriesId) }
            let books = Dictionary(fetched.filter(\.hasPages).map { ($0.id, $0) }) { first, _ in first }
            for book in books.values { pageCounts[book.id] = book.media.pagesCount }

            // Queued changes first, judged against the positions just fetched.
            var sent = Set<String>()
            for entry in try await database.syncQueue(engine: Self.engine, seriesKey: seriesId) {
                let delivery = await deliver(entry, serverPosition: books[entry.key].map(Self.serverPosition))
                if delivery == .sent { sent.insert(entry.key) }
                if delivery == .failed { break }
            }
            let skip = sent.union(try await database.syncQueue(engine: Self.engine, seriesKey: seriesId).map(\.key))

            var pulled: [PulledProgress] = []
            var pushes: [(Pending, Int)] = []
            for local in try await database.chapterList(seriesId: series.id) {
                guard let bookId = KomgaSource.bookIdOrNil(local.url), let book = books[bookId], !skip.contains(bookId) else { continue }
                let pages = book.media.pagesCount
                let serverPage = book.readProgress?.page ?? 0
                if local.read && !book.isRead {
                    pushes.append((Pending(seriesId: seriesId, bookId: bookId, page: pages, pages: pages, read: true), Self.serverPosition(book)))
                } else if !local.read && book.isRead {
                    pulled.append(PulledProgress(chapterId: local.id, read: true))
                } else if !local.read, serverPage > 0 || local.lastPageRead > 0 {
                    let serverLastPageRead = max(serverPage - 1, 0)
                    if serverLastPageRead > local.lastPageRead {
                        pulled.append(PulledProgress(chapterId: local.id, lastPageRead: serverLastPageRead))
                    } else if local.lastPageRead > serverLastPageRead {
                        pushes.append((
                            Pending(seriesId: seriesId, bookId: bookId, page: min(local.lastPageRead + 1, pages), pages: pages),
                            Self.serverPosition(book)
                        ))
                    }
                }
            }
            try await database.applyPulled(pulled)
            if !pushes.isEmpty {
                // Queued before sending, so nothing is lost if the connection drops halfway.
                let entries = try await enqueue(pushes.map(\.0), markedByUser: false)
                for (entry, push) in zip(entries, pushes) where await deliver(entry, serverPosition: push.1) == .failed {
                    break
                }
            }
            if !pulled.isEmpty || !pushes.isEmpty {
                log.info("Komga: synced '\(series.name)': \(pulled.count) pulled, \(pushes.count) pushed")
            }
        } catch {
            log.warning("Komga: progress sync failed for '\(series.name)': \(error)")
        }
    }

    @discardableResult
    func syncLibrary() async -> Int {
        guard isEnabled, let library = try? await database.librarySeriesRecords() else { return 0 }
        let series = library.filter(syncs)
        for item in series { await syncSeries(item, chapterIds: nil) }
        await flush()
        return series.count
    }

    @discardableResult
    func syncQueued() async -> Bool {
        guard isEnabled, !syncSettings.usesKoreader else { return true }
        guard let queued = try? await database.syncQueue(engine: Self.engine), !queued.isEmpty else { return true }
        let seriesKeys = Set(queued.map(\.seriesKey))
        let stored = (try? await database.seriesRecords(source: KomgaSource.id)) ?? []
        for series in stored where seriesKeys.contains(KomgaSource.seriesId(series.url)) {
            await syncSeries(series, chapterIds: nil)
        }
        await flush()
        return (try? await database.syncQueue(engine: Self.engine).isEmpty) ?? false
    }

    private func flush() async {
        guard let queued = try? await database.syncQueue(engine: Self.engine) else { return }
        for entry in queued where await deliver(entry, serverPosition: nil) == .failed {
            return
        }
    }

    // MARK: Delivery

    enum Delivery { case sent, dropped, failed }

    private func enqueue(_ entries: [Pending], markedByUser: Bool) async throws -> [SyncQueueRecord] {
        try await database.enqueueSync(
            engine: Self.engine, entries.map { (key: $0.bookId, seriesKey: $0.seriesId, entry: $0) }, markedByUser: markedByUser
        )
    }

    /// Sends one queued change unless the server has already read further, in which case it is
    /// dropped and the next pull brings the server's position down instead.
    private func deliver(_ record: SyncQueueRecord, serverPosition: Int?) async -> Delivery {
        guard let entry = record.decode(Pending.self) else {
            try? await database.removeSync([record])
            return .dropped
        }
        do {
            let onServer = if record.markedByUser { 0 } else if let serverPosition { serverPosition } else {
                Self.serverPosition(try await client.book(entry.bookId))
            }
            let send = Self.shouldSend(entry, markedByUser: record.markedByUser, serverPosition: onServer)
            if send {
                if entry.read {
                    try await client.markRead(entry.bookId)
                } else if entry.page <= 0 {
                    try await client.markUnread(entry.bookId)
                } else {
                    try await client.saveProgress(entry.bookId, page: entry.page)
                }
            }
            try await database.removeSync([record])
            return send ? .sent : .dropped
        } catch {
            log.warning("Komga: could not send progress for book \(entry.bookId), queued: \(error)")
            requestRetry()
            return .failed
        }
    }

    private func requestRetry() { retryContinuation.yield() }
}
