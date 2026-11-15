import Foundation
import os

/// Port of `BookOrbitSync.kt`: two-way, page-level progress sync with BookOrbit, by the same
/// rules as Kavita. Positions are BookOrbit's: a 1-based page number and a percentage from 0 to
/// 100, as its own comic reader writes them. A series' books carry their read status and
/// percentage, so reconciling only asks for the exact page of books that are part read.
///
/// Time spent in the reader goes to BookOrbit's Reading Log as reading sessions, queued until
/// the server can be reached.
actor BookOrbitSync: SyncEngine {
    static let engine = "bookorbit"
    /// BookOrbit stores percentages with some rounding, so tiny differences aren't "further".
    private static let percentEpsilon = 0.01
    /// BookOrbit doesn't record sessions shorter than this, so they aren't sent.
    static let minSessionSeconds = 10
    /// A long time offline keeps the latest sessions, not an ever-growing list.
    private static let maxQueuedSessions = 500

    nonisolated let retryRequests: AsyncStream<Void>
    private let retryContinuation: AsyncStream<Void>.Continuation
    private let source: BookOrbitSource
    private let database: AppDatabase
    private let settings: BookOrbitSettings
    private let syncSettings: SyncSettings
    private let pageDebounce: Duration
    private var debounces: [Int: Task<Void, Never>] = [:]
    private var waiting: [Int: Pending] = [:]
    /// Page counts by file id, learned from the reader or asked for when a page has to be sent.
    private var pageCounts: [Int: Int] = [:]
    private var sendingSessions = false
    private let log = Logger(subsystem: "io.github.grillza.docho", category: "bookorbit-sync")

    private var client: BookOrbitClient { source.client }

    init(source: BookOrbitSource, database: AppDatabase, settings: BookOrbitSettings, syncSettings: SyncSettings, pageDebounce: Duration = KavitaSync.pageDebounce) {
        self.source = source
        self.database = database
        self.settings = settings
        self.syncSettings = syncSettings
        self.pageDebounce = pageDebounce
        (retryRequests, retryContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    nonisolated var engine: String { Self.engine }
    nonisolated var isEnabled: Bool { settings.syncProgress && settings.isConfigured }

    nonisolated func syncs(_ series: SeriesRecord) -> Bool {
        series.source == BookOrbitSource.id && isEnabled && !syncSettings.usesKoreader
    }

    /// A position waiting to reach BookOrbit: `page` of `pages`, 1-based, where 0 means unread.
    /// A chapter marked read before its page count was known has `read` set and no pages.
    struct Pending: Codable, Sendable, Equatable {
        var seriesId: Int
        var bookId: Int
        var fileId: Int
        var page: Int
        var pages: Int
        var read = false

        /// The position as BookOrbit's percentage, which is how its comic reader computes it.
        var percentage: Double {
            if read { return 100 }
            guard pages > 0, page > 0 else { return 0 }
            return Double(min(page, pages)) * 100 / Double(pages)
        }
    }

    static func shouldSend(_ entry: Pending, markedByUser: Bool, serverPercentage: Double) -> Bool {
        markedByUser || entry.percentage > serverPercentage + percentEpsilon
    }

    // MARK: Push

    func pageChanged(_ series: SeriesRecord, chapter: ChapterRecord, page: Int, pageCount: Int, read: Bool) {
        guard syncs(series), pageCount > 0, let seriesId = BookOrbitSource.seriesId(series.url),
              let bookId = BookOrbitSource.bookId(chapter.url), let fileId = BookOrbitSource.fileId(chapter.url)
        else { return }
        pageCounts[fileId] = pageCount
        waiting[fileId] = Pending(seriesId: seriesId, bookId: bookId, fileId: fileId, page: read ? pageCount : page + 1, pages: pageCount, read: read)
        debounces[fileId]?.cancel()
        debounces[fileId] = Task {
            try? await Task.sleep(for: pageDebounce)
            guard !Task.isCancelled else { return }
            debounces[fileId] = nil
            await sendWaiting(fileId)
        }
    }

    func sendWaitingPages() async {
        for fileId in waiting.keys {
            debounces.removeValue(forKey: fileId)?.cancel()
            await sendWaiting(fileId)
        }
    }

    private func sendWaiting(_ fileId: Int) async {
        guard let pending = waiting.removeValue(forKey: fileId), let entry = try? await enqueue([pending], markedByUser: false).first else { return }
        if await deliver(entry, serverPercentage: nil) == .failed { requestRetry() }
    }

    func readStatusChanged(_ series: SeriesRecord, chapters: [ChapterRecord], read: Bool) async {
        guard syncs(series), let seriesId = BookOrbitSource.seriesId(series.url) else { return }
        let progress = chapters.compactMap { chapter -> Pending? in
            guard let bookId = BookOrbitSource.bookId(chapter.url), let fileId = BookOrbitSource.fileId(chapter.url) else { return nil }
            debounces.removeValue(forKey: fileId)?.cancel()
            waiting[fileId] = nil
            let pages = pageCounts[fileId] ?? chapter.pages
            return Pending(seriesId: seriesId, bookId: bookId, fileId: fileId, page: read ? pages : 0, pages: pages, read: read)
        }
        guard let entries = try? await enqueue(progress, markedByUser: true) else { return }
        for entry in entries where await deliver(entry, serverPercentage: nil) == .failed {
            break
        }
    }

    // MARK: Reading sessions

    /// A reading session waiting to reach BookOrbit.
    struct PendingSession: Codable, Sendable, Equatable {
        var fileId: Int
        var session: BookOrbitSession
    }

    /// A stretch of reading ended: the reader closed or went to the background, or moved on to
    /// another chapter. Positions are 0-based page indexes, as the reader keeps them.
    func readingSession(
        _ series: SeriesRecord, chapter: ChapterRecord, startedAt: Date, endedAt: Date,
        startPage: Int, startRead: Bool, endPage: Int, endRead: Bool, pageCount: Int
    ) async {
        guard syncs(series), pageCount > 0, let fileId = BookOrbitSource.fileId(chapter.url),
              let session = Self.session(
                id: UUID().uuidString, startedAt: startedAt, endedAt: endedAt,
                startPercentage: Self.percentage(page: startPage, read: startRead, pageCount: pageCount),
                endPercentage: Self.percentage(page: endPage, read: endRead, pageCount: pageCount)
              )
        else { return }
        writeSessions(Array((readSessions() + [PendingSession(fileId: fileId, session: session)]).suffix(Self.maxQueuedSessions)))
        await sendSessions()
    }

    /// Sends queued sessions, oldest first, and stops at the first that can't be sent since the
    /// server is likely unreachable. One the server turns down is dropped, as sending it again
    /// won't change the answer. Returns whether the queue is now empty.
    @discardableResult
    private func sendSessions() async -> Bool {
        guard !sendingSessions else { return readSessions().isEmpty }
        sendingSessions = true
        defer { sendingSessions = false }
        // Sessions that arrive while sending are picked up too.
        while let entry = readSessions().first {
            do {
                try await client.saveSession(fileId: entry.fileId, entry.session)
            } catch HTTPError.status(let code) where Self.isRejected(code) {
                log.warning("BookOrbit: dropped reading session for file \(entry.fileId): HTTP \(code)")
            } catch {
                log.warning("BookOrbit: could not send reading session for file \(entry.fileId), queued: \(error)")
                requestRetry()
                return false
            }
            writeSessions(readSessions().filter { $0 != entry })
        }
        return true
    }

    private func readSessions() -> [PendingSession] {
        let raw = settings.pendingSessions
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([PendingSession].self, from: data)) ?? []
    }

    private func writeSessions(_ sessions: [PendingSession]) {
        settings.pendingSessions = sessions.isEmpty ? "" : (try? JSONEncoder().encode(sessions)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// A 0-based page index as BookOrbit's percentage, the same way `Pending` works it out.
    static func percentage(page: Int, read: Bool, pageCount: Int) -> Double {
        Pending(seriesId: 0, bookId: 0, fileId: 0, page: page + 1, pages: pageCount, read: read).percentage
    }

    /// The session to send, or nil when it's too short for BookOrbit to keep.
    static func session(id: String, startedAt: Date, endedAt: Date, startPercentage: Double, endPercentage: Double) -> BookOrbitSession? {
        let seconds = Int(endedAt.timeIntervalSince(startedAt).rounded(.down))
        guard seconds >= minSessionSeconds else { return nil }
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        return BookOrbitSession(
            sessionId: id, startedAt: startedAt.formatted(format), endedAt: endedAt.formatted(format), durationSeconds: seconds,
            progressDelta: round(endPercentage - startPercentage), endProgress: round(endPercentage)
        )
    }

    private static func round(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// Answers that sending the same session again won't change: bad request, no access, gone.
    static func isRejected(_ code: Int) -> Bool { (400...499).contains(code) && ![401, 408, 429].contains(code) }

    // MARK: Pull

    func syncSeries(_ series: SeriesRecord, chapterIds: Set<Int>?) async {
        guard syncs(series), let seriesId = BookOrbitSource.seriesId(series.url) else { return }
        do {
            let fetched = if let cached = source.progressCache.take(seriesId) { cached } else { try await client.seriesBooks(seriesId).items }
            var books: [Int: BookOrbitBook] = [:]
            for book in fetched { if let file = book.comicFile { books[file.id] = book } }

            var sent = Set<String>()
            for entry in try await database.syncQueue(engine: Self.engine, seriesKey: String(seriesId)) {
                let delivery = await deliver(entry, serverPercentage: nil)
                if delivery == .sent { sent.insert(entry.key) }
                if delivery == .failed { break }
            }
            let skip = sent.union(try await database.syncQueue(engine: Self.engine, seriesKey: String(seriesId)).map(\.key))

            var pulled: [PulledProgress] = []
            var pushes: [(Pending, Double)] = []
            for local in try await database.chapterList(seriesId: series.id) {
                guard let fileId = BookOrbitSource.fileId(local.url), let book = books[fileId], !skip.contains(String(fileId)) else { continue }
                let serverRead = book.isRead
                let serverPercentage = serverRead ? 100 : book.readingProgress ?? 0
                if local.read && !serverRead {
                    let pages = pageCounts[fileId] ?? local.pages
                    pushes.append((Pending(seriesId: seriesId, bookId: book.id, fileId: fileId, page: pages, pages: pages, read: true), serverPercentage))
                } else if !local.read && serverRead {
                    pulled.append(PulledProgress(chapterId: local.id, read: true))
                } else if !local.read, serverPercentage > 0 || local.lastPageRead > 0 {
                    // Part read on at least one side: compare exact pages.
                    let serverPage = serverPercentage > 0 ? (try await client.progress(fileId: fileId).pageNumber ?? 0) : 0
                    let serverLastPageRead = max(serverPage - 1, 0)
                    if serverLastPageRead > local.lastPageRead {
                        pulled.append(PulledProgress(chapterId: local.id, lastPageRead: serverLastPageRead))
                    } else if local.lastPageRead > serverLastPageRead {
                        let pages = try await pageCount(fileId, known: local.pages)
                        pushes.append((
                            Pending(seriesId: seriesId, bookId: book.id, fileId: fileId, page: min(local.lastPageRead + 1, pages), pages: pages),
                            serverPercentage
                        ))
                    }
                }
            }
            try await database.applyPulled(pulled)
            if !pushes.isEmpty {
                let entries = try await enqueue(pushes.map(\.0), markedByUser: false)
                for (entry, push) in zip(entries, pushes) where await deliver(entry, serverPercentage: push.1) == .failed {
                    break
                }
            }
            if !pulled.isEmpty || !pushes.isEmpty {
                log.info("BookOrbit: synced '\(series.name)': \(pulled.count) pulled, \(pushes.count) pushed")
            }
        } catch {
            log.warning("BookOrbit: progress sync failed for '\(series.name)': \(error)")
        }
    }

    private func pageCount(_ fileId: Int, known: Int) async throws -> Int {
        if let count = pageCounts[fileId] { return count }
        if known > 0 { return known }
        let count = try await client.pageCount(fileId: fileId)
        pageCounts[fileId] = count
        return count
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
        let sessionsSent = await sendSessions()
        guard let queued = try? await database.syncQueue(engine: Self.engine), !queued.isEmpty else { return sessionsSent }
        let seriesKeys = Set(queued.map(\.seriesKey))
        let stored = (try? await database.seriesRecords(source: BookOrbitSource.id)) ?? []
        for series in stored where BookOrbitSource.seriesId(series.url).map({ seriesKeys.contains(String($0)) }) == true {
            await syncSeries(series, chapterIds: nil)
        }
        await flush()
        let progressSent = (try? await database.syncQueue(engine: Self.engine).isEmpty) ?? false
        return sessionsSent && progressSent
    }

    private func flush() async {
        guard let queued = try? await database.syncQueue(engine: Self.engine) else { return }
        for entry in queued where await deliver(entry, serverPercentage: nil) == .failed {
            return
        }
    }

    // MARK: Delivery

    enum Delivery { case sent, dropped, failed }

    private func enqueue(_ entries: [Pending], markedByUser: Bool) async throws -> [SyncQueueRecord] {
        try await database.enqueueSync(
            engine: Self.engine, entries.map { (key: String($0.fileId), seriesKey: String($0.seriesId), entry: $0) }, markedByUser: markedByUser
        )
    }

    private func deliver(_ record: SyncQueueRecord, serverPercentage: Double?) async -> Delivery {
        guard let entry = record.decode(Pending.self) else {
            try? await database.removeSync([record])
            return .dropped
        }
        do {
            let onServer = if record.markedByUser { 0.0 } else if let serverPercentage { serverPercentage } else {
                try await client.progress(fileId: entry.fileId).percentage
            }
            let send = Self.shouldSend(entry, markedByUser: record.markedByUser, serverPercentage: onServer)
            if send {
                if entry.read {
                    try await client.saveProgress(fileId: entry.fileId, BookOrbitProgress(pageNumber: entry.pages > 0 ? entry.pages : nil, percentage: 100))
                    // Reaching 100% normally marks the book read; a mark by hand makes sure of it.
                    if record.markedByUser { try await client.setStatus(bookId: entry.bookId, BookOrbitBook.statusRead) }
                } else if entry.page <= 0 {
                    try await client.markUnread(bookId: entry.bookId, fileId: entry.fileId)
                } else {
                    try await client.saveProgress(fileId: entry.fileId, BookOrbitProgress(pageNumber: entry.page, percentage: entry.percentage))
                }
            }
            try await database.removeSync([record])
            return send ? .sent : .dropped
        } catch {
            log.warning("BookOrbit: could not send progress for file \(entry.fileId), queued: \(error)")
            requestRetry()
            return .failed
        }
    }

    private func requestRetry() { retryContinuation.yield() }
}
