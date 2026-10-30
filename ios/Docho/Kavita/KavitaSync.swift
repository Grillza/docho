import Foundation
import os

/// Port of `KavitaSync.kt`: two-way, page-level reading progress sync with Kavita.
///
/// `lastPageRead` and Kavita's `pagesRead` are both the index of the page being viewed, and
/// Kavita counts a chapter read once `pagesRead` reaches its page count, so the two map onto each
/// other directly.
///
/// The side that has read further wins, so reading on another device while this one was offline
/// is never undone. The one exception is marking chapters read or unread by hand, which is a
/// deliberate choice and is sent as is.
///
/// - **Push:** page turns in the reader (debounced) and hand marks are queued in the database
///   (`pendingProgress`, keyed by Kavita chapter id), then sent. A page is only sent if it's
///   further than the server's. Whatever can't be delivered stays queued; `retryRequests` asks
///   `SyncTriggers` to try again later.
/// - **Pull:** `syncSeries` runs when a series is refreshed, when the reader opens, and in
///   library sync. A chapter read on either side ends up read on both; otherwise the higher page
///   is kept on both.
actor KavitaSync: SyncEngine {
    static let pageDebounce: Duration = .milliseconds(1500)
    static let engine = "kavita"

    nonisolated let retryRequests: AsyncStream<Void>
    private let retryContinuation: AsyncStream<Void>.Continuation

    private let source: KavitaSource
    private let database: AppDatabase
    private let settings: KavitaSettings
    private let syncSettings: SyncSettings
    private let pageDebounce: Duration
    private var debounces: [Int: Task<Void, Never>] = [:]
    private var waitingPages: [Int: PageChange] = [:]
    private let log = Logger(subsystem: "io.github.grillza.docho", category: "sync")

    private var kavita: KavitaClient { source.client }

    init(
        source: KavitaSource, database: AppDatabase, settings: KavitaSettings, syncSettings: SyncSettings,
        pageDebounce: Duration = KavitaSync.pageDebounce
    ) {
        self.source = source
        self.database = database
        self.settings = settings
        self.syncSettings = syncSettings
        self.pageDebounce = pageDebounce
        (retryRequests, retryContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    nonisolated var engine: String { Self.engine }

    nonisolated var isEnabled: Bool {
        settings.syncProgress && settings.credentials.isConfigured
    }

    /// While progress goes to a KOReader server, `KoreaderSync` does it instead.
    nonisolated func syncs(_ series: SeriesRecord) -> Bool {
        series.source == KavitaSource.id && isEnabled && !syncSettings.usesKoreader
    }

    // MARK: - Rules

    /// A deliberate read/unread mark always goes through; a page only if it's further than the server's.
    static func shouldSend(_ entry: PendingProgress, serverPagesRead: Int) -> Bool {
        entry.markedByUser || entry.pageNum > serverPagesRead
    }

    /// A page read after marking a chapter by hand keeps the mark's priority until it's delivered,
    /// so reading on from "mark unread" isn't overruled by the server.
    static func mergePending(_ previous: PendingProgress?, _ progress: KavitaProgress, markedByUser: Bool) -> PendingProgress {
        PendingProgress(progress, markedByUser: markedByUser || previous?.markedByUser == true)
    }

    // MARK: - Push

    /// Called by the reader on every page change; the latest page per chapter is sent after a short pause.
    func pageChanged(_ series: SeriesRecord, chapter: ChapterRecord, page: Int, pageCount: Int, read: Bool) {
        guard syncs(series) else { return }
        waitingPages[chapter.id] = PageChange(series: series, chapter: chapter, page: page, pageCount: pageCount, read: read)
        debounces[chapter.id]?.cancel()
        debounces[chapter.id] = Task {
            try? await Task.sleep(for: pageDebounce)
            guard !Task.isCancelled else { return }
            debounces[chapter.id] = nil
            await sendPage(chapter.id)
        }
    }

    func sendWaitingPages() async {
        for chapterId in waitingPages.keys {
            debounces.removeValue(forKey: chapterId)?.cancel()
            await sendPage(chapterId)
        }
    }

    private struct PageChange {
        var series: SeriesRecord
        var chapter: ChapterRecord
        var page: Int
        var pageCount: Int
        var read: Bool
    }

    private func sendPage(_ chapterId: Int) async {
        guard let change = waitingPages.removeValue(forKey: chapterId),
              let target = await target(series: change.series, chapter: change.chapter, pageCount: change.pageCount)
        else { return }
        do {
            let entries = try await database.enqueue([target.progress(change.read ? target.pages : change.page)], markedByUser: false)
            _ = await deliver(entries[0], serverPagesRead: nil)
        } catch {
            log.error("Could not queue progress for chapter \(chapterId): \(error)")
        }
    }

    /// Pushes chapters marked read or unread by hand, in one request.
    func readStatusChanged(_ series: SeriesRecord, chapters: [ChapterRecord], read: Bool) async {
        guard syncs(series), let seriesId = KavitaSource.seriesId(series.url) else { return }
        var targets: [Target] = []
        for chapter in chapters {
            debounces.removeValue(forKey: chapter.id)?.cancel()
            waitingPages[chapter.id] = nil
            if let target = await target(series: series, chapter: chapter, pageCount: nil) { targets.append(target) }
        }
        guard !targets.isEmpty else { return }
        do {
            let entries = try await database.enqueue(targets.map { $0.progress(read ? $0.pages : 0) }, markedByUser: true)
            do {
                try await kavita.setChaptersRead(seriesId: seriesId, chapterIds: targets.map(\.chapterId), read: read)
                try await database.removePending(entries)
            } catch {
                log.warning("Could not mark \(entries.count) chapters read=\(read), queued: \(error)")
                requestRetry()
            }
        } catch {
            log.error("Could not queue read marks: \(error)")
        }
    }

    // MARK: - Pull

    func syncSeries(_ series: SeriesRecord, chapterIds: Set<Int>?) async {
        await syncSeries(series, volumes: nil)
    }

    /// Delivers this series' queued changes, then reconciles it. `volumes` may carry data that
    /// was just fetched; otherwise the source's cache from the last refresh, or the server.
    func syncSeries(_ series: SeriesRecord, volumes: [KavitaVolume]?) async {
        guard syncs(series), let seriesId = KavitaSource.seriesId(series.url) else { return }
        do {
            let remoteVolumes = if let volumes = volumes ?? source.progressCache.take(seriesId) {
                volumes
            } else {
                try await kavita.volumes(seriesId: seriesId)
            }
            let remote = Dictionary(remoteVolumes.flatMap(\.chapters).map { ($0.id, $0) }) { first, _ in first }
            let skip = try await deliverQueued(seriesId: seriesId, remote: remote)
            let local = try await database.chapterList(seriesId: series.id).filter { chapter in
                KavitaSource.chapterId(chapter.url).map { !skip.contains($0) } ?? false
            }
            let plan = Reconciliation(
                local: local, remote: remote, seriesId: seriesId, libraryId: KavitaSource.libraryId(series.url)
            )

            try await database.applyPulled(plan.pulled)
            try await push(plan, seriesId: seriesId)
            if !plan.isEmpty {
                log.info("Synced series \(seriesId): \(plan.pulled.count) pulled, \(plan.pushCount) pushed")
            }
        } catch {
            log.warning("Progress sync failed for series \(seriesId): \(error)")
        }
    }

    /// Queued changes go first, judged against what the server has right now. Returns the Kavita
    /// chapters to leave out of the comparison: those sent, and those still queued. Those the
    /// server has overtaken were dropped and are pulled like any other chapter.
    private func deliverQueued(seriesId: Int, remote: [Int: KavitaChapter]) async throws -> Set<Int> {
        var sent = Set<Int>()
        for entry in try await database.pendingProgress(seriesId: seriesId) {
            let delivery = await deliver(entry, serverPagesRead: remote[entry.chapterId]?.pagesRead)
            if delivery == .sent { sent.insert(entry.chapterId) }
            if delivery == .failed { break }
        }
        return sent.union(try await database.pendingProgress(seriesId: seriesId).map(\.chapterId))
    }

    /// Sends what this device has read further. Queued before sending, so nothing is lost if the
    /// connection drops halfway.
    private func push(_ plan: Reconciliation, seriesId: Int) async throws {
        guard plan.pushCount > 0 else { return }
        let entries = try await database.enqueue(plan.readOnServer.map { $0.progress($0.pages) } + plan.partialPushes, markedByUser: false)
        do {
            if !plan.readOnServer.isEmpty {
                try await kavita.setChaptersRead(seriesId: seriesId, chapterIds: plan.readOnServer.map(\.chapterId), read: true)
            }
            for progress in plan.partialPushes {
                try await kavita.saveProgress(progress)
            }
            try await database.removePending(entries)
        } catch {
            requestRetry()
            throw error
        }
    }

    /// The comparison of local chapters with the server's, by the pull rules.
    struct Reconciliation {
        /// Read here, not there: pushed as read.
        var readOnServer: [Target] = []
        /// Read there, or further there: pulled (by local chapter id).
        var pulled: [PulledProgress] = []
        /// Further here: pushed, but never as far as marking the chapter read.
        var partialPushes: [KavitaProgress] = []

        init(local: [ChapterRecord], remote: [Int: KavitaChapter], seriesId: Int, libraryId: Int) {
            for local in local {
                guard let kavitaId = KavitaSource.chapterId(local.url), let server = remote[kavitaId], server.pages > 0 else { continue }
                let target = Target(
                    seriesId: seriesId, libraryId: local.chapterMemo.int(KavitaSource.memoLibraryId) ?? libraryId,
                    volumeId: server.volumeId, chapterId: kavitaId, pages: server.pages
                )
                let serverRead = server.pagesRead >= server.pages
                if local.read {
                    if !serverRead { readOnServer.append(target) }
                } else if serverRead {
                    pulled.append(PulledProgress(chapterId: local.id, read: true))
                } else if server.pagesRead > local.lastPageRead {
                    pulled.append(PulledProgress(chapterId: local.id, lastPageRead: server.pagesRead))
                } else if local.lastPageRead > server.pagesRead {
                    partialPushes.append(target.progress(min(local.lastPageRead, server.pages - 1)))
                }
            }
        }

        var pushCount: Int { readOnServer.count + partialPushes.count }
        var isEmpty: Bool { pulled.isEmpty && pushCount == 0 }
    }

    /// Reconciles every Kavita series in the library, then delivers what's left in the queue.
    @discardableResult
    func syncLibrary() async -> Int {
        guard isEnabled, !syncSettings.usesKoreader, let library = try? await database.librarySeriesRecords() else { return 0 }
        let series = library.filter(syncs)
        for item in series {
            await syncSeries(item, volumes: nil)
        }
        await flushPending()
        return series.count
    }

    /// Delivers everything queued and reconciles the series it belonged to, so progress made on
    /// other devices meanwhile comes down too. Returns whether the queue is now empty.
    ///
    /// Differs from Android on purpose: every series with queued changes is reconciled, not only
    /// library ones, because series opened from Browse keep their chapters locally here too.
    @discardableResult
    func syncQueued() async -> Bool {
        guard isEnabled, !syncSettings.usesKoreader else { return true }
        guard let pending = try? await database.pendingProgress(), !pending.isEmpty else { return true }
        let queued = Set(pending.map(\.seriesId))
        let stored = (try? await database.seriesRecords(source: KavitaSource.id)) ?? []
        for series in stored where KavitaSource.seriesId(series.url).map(queued.contains) == true {
            await syncSeries(series, volumes: nil)
        }
        await flushPending()
        return (try? await database.pendingProgress().isEmpty) ?? false
    }

    /// Delivers queued changes; stops at the first failure since the server is likely unreachable.
    private func flushPending() async {
        guard let pending = try? await database.pendingProgress() else { return }
        for entry in pending {
            let delivery = await deliver(entry, serverPagesRead: nil)
            if delivery == .failed { return }
        }
    }

    // MARK: - Delivery

    enum Delivery: Equatable {
        case sent
        case dropped
        case failed
    }

    /// Sends one queued change unless the server has already read further, in which case it's
    /// dropped and the next pull brings the server's progress down instead.
    private func deliver(_ entry: PendingProgress, serverPagesRead: Int?) async -> Delivery {
        do {
            let onServer = if entry.markedByUser {
                0
            } else if let serverPagesRead {
                serverPagesRead
            } else {
                try await kavita.pagesRead(seriesId: entry.seriesId, chapterId: entry.chapterId)
            }
            let send = Self.shouldSend(entry, serverPagesRead: onServer)
            if send {
                try await kavita.saveProgress(entry.progress)
            }
            try await database.removePending([entry])
            return send ? .sent : .dropped
        } catch {
            log.warning("Could not send progress for chapter \(entry.chapterId), queued: \(error)")
            requestRetry()
            return .failed
        }
    }

    private func requestRetry() {
        retryContinuation.yield()
    }

    // MARK: - Targets

    /// The ids Kavita wants with a progress update.
    struct Target {
        var seriesId: Int
        var libraryId: Int
        var volumeId: Int
        var chapterId: Int
        var pages: Int

        func progress(_ pageNum: Int) -> KavitaProgress {
            KavitaProgress(
                volumeId: volumeId, chapterId: chapterId, pageNum: min(max(pageNum, 0), pages),
                seriesId: seriesId, libraryId: libraryId
            )
        }
    }

    /// The stored chapter's memo has the ids; one with no page count costs a request.
    private func target(series: SeriesRecord, chapter: ChapterRecord, pageCount: Int?) async -> Target? {
        guard let chapterId = KavitaSource.chapterId(chapter.url), let seriesId = KavitaSource.seriesId(series.url) else { return nil }
        let memo = chapter.chapterMemo
        var pages = chapter.pages > 0 ? chapter.pages : pageCount ?? memo.int(KavitaSource.memoPages) ?? 0
        var volumeId = memo.int(KavitaSource.memoVolumeId)
        if pages <= 0 || volumeId == nil {
            do {
                let fetched = try await kavita.chapter(id: chapterId)
                pages = fetched.pages
                volumeId = fetched.volumeId
            } catch {
                log.warning("Could not look up chapter \(chapterId): \(error)")
                return nil
            }
        }
        return Target(
            seriesId: seriesId, libraryId: memo.int(KavitaSource.memoLibraryId) ?? KavitaSource.libraryId(series.url),
            volumeId: volumeId ?? 0, chapterId: chapterId, pages: pages
        )
    }
}
