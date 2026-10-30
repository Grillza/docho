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
/// - **Push:** page turns in the reader (debounced) and hand marks are queued in the database,
///   then sent. A page is only sent if it's further than the server's. Whatever can't be
///   delivered stays queued; `retryRequests` asks `SyncTriggers` to try again later.
/// - **Pull:** `syncSeries` runs when a series is refreshed, when the reader opens, and in
///   library sync. A chapter read on either side ends up read on both; otherwise the higher page
///   is kept on both.
actor KavitaSync {
    static let pageDebounce: Duration = .milliseconds(1500)

    /// Yields when something couldn't be delivered and should be retried later.
    nonisolated let retryRequests: AsyncStream<Void>
    private let retryContinuation: AsyncStream<Void>.Continuation

    private let kavita: KavitaClient
    private let database: AppDatabase
    private let settings: KavitaSettings
    private let pageDebounce: Duration
    private var debounces: [Int: Task<Void, Never>] = [:]
    private var waitingPages: [Int: PageChange] = [:]
    private let log = Logger(subsystem: "app.mihonka", category: "sync")

    init(kavita: KavitaClient, database: AppDatabase, settings: KavitaSettings, pageDebounce: Duration = KavitaSync.pageDebounce) {
        self.kavita = kavita
        self.database = database
        self.settings = settings
        self.pageDebounce = pageDebounce
        (retryRequests, retryContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    nonisolated var isEnabled: Bool {
        settings.syncProgress && settings.credentials.isConfigured
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
    func pageChanged(_ chapter: ChapterRecord, page: Int, pageCount: Int, read: Bool) {
        guard isEnabled else { return }
        waitingPages[chapter.id] = PageChange(chapter: chapter, page: page, pageCount: pageCount, read: read)
        debounces[chapter.id]?.cancel()
        debounces[chapter.id] = Task {
            try? await Task.sleep(for: pageDebounce)
            guard !Task.isCancelled else { return }
            debounces[chapter.id] = nil
            await sendPage(chapter.id)
        }
    }

    /// Sends the pages still waiting out their pause now, e.g. when the app goes to the background.
    func sendWaitingPages() async {
        for chapterId in waitingPages.keys {
            debounces.removeValue(forKey: chapterId)?.cancel()
            await sendPage(chapterId)
        }
    }

    private struct PageChange {
        var chapter: ChapterRecord
        var page: Int
        var pageCount: Int
        var read: Bool
    }

    private func sendPage(_ chapterId: Int) async {
        guard let change = waitingPages.removeValue(forKey: chapterId),
              let target = await target(for: change.chapter, pageCount: change.pageCount)
        else { return }
        do {
            let entries = try await database.enqueue([target.progress(change.read ? target.pages : change.page)], markedByUser: false)
            _ = await deliver(entries[0], serverPagesRead: nil)
        } catch {
            log.error("Could not queue progress for chapter \(chapterId): \(error)")
        }
    }

    /// Pushes chapters marked read or unread by hand, in one request.
    func readStatusChanged(_ chapters: [ChapterRecord], read: Bool) async {
        guard isEnabled, let seriesId = chapters.first?.seriesId else { return }
        var targets: [Target] = []
        for chapter in chapters {
            debounces.removeValue(forKey: chapter.id)?.cancel()
            waitingPages[chapter.id] = nil
            if let target = await target(for: chapter, pageCount: nil) { targets.append(target) }
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

    /// Delivers this series' queued changes, then reconciles it. `volumes` may carry data that
    /// was just fetched; otherwise the server is asked.
    func syncSeries(_ seriesId: Int, volumes: [KavitaVolume]? = nil) async {
        guard isEnabled else { return }
        do {
            let remoteVolumes = if let volumes { volumes } else { try await kavita.volumes(seriesId: seriesId) }
            let remote = Dictionary(remoteVolumes.flatMap(\.chapters).map { ($0.id, $0) }) { first, _ in first }
            let skip = try await deliverQueued(seriesId: seriesId, remote: remote)
            let local = try await database.chapterList(seriesId: seriesId).filter { !skip.contains($0.id) }
            let plan = Reconciliation(local: local, remote: remote)

            try await database.applyPulled(plan.pulled)
            try await push(plan, seriesId: seriesId)
            if !plan.isEmpty {
                log.info("Synced series \(seriesId): \(plan.pulled.count) pulled, \(plan.pushCount) pushed")
            }
        } catch {
            log.warning("Progress sync failed for series \(seriesId): \(error)")
        }
    }

    /// Queued changes go first, judged against what the server has right now. Returns the chapters
    /// to leave out of the comparison: those sent, and those still queued. Those the server has
    /// overtaken were dropped and are pulled like any other chapter.
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
        /// Read there, or further there: pulled.
        var pulled: [PulledProgress] = []
        /// Further here: pushed, but never as far as marking the chapter read.
        var partialPushes: [KavitaProgress] = []

        init(local: [ChapterRecord], remote: [Int: KavitaChapter]) {
            for local in local {
                guard let server = remote[local.id], server.pages > 0 else { continue }
                let target = Target(
                    seriesId: local.seriesId, libraryId: local.libraryId, volumeId: server.volumeId,
                    chapterId: local.id, pages: server.pages
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

    /// Reconciles every series in the library, then delivers what's left in the queue.
    /// Returns how many series were synced.
    @discardableResult
    func syncLibrary() async -> Int {
        guard isEnabled, let ids = try? await database.librarySeriesIds() else { return 0 }
        for id in ids {
            await syncSeries(id)
        }
        await flushPending()
        return ids.count
    }

    /// Delivers everything queued and reconciles the series it belonged to, so progress made on
    /// other devices meanwhile comes down too. Returns whether the queue is now empty.
    ///
    /// Differs from Android on purpose: every series with queued changes is reconciled, not only
    /// library ones, because series opened from Browse keep their chapters locally here too.
    @discardableResult
    func syncQueued() async -> Bool {
        guard isEnabled else { return true }
        guard let pending = try? await database.pendingProgress(), !pending.isEmpty else { return true }
        var seen = Set<Int>()
        for seriesId in pending.map(\.seriesId) where seen.insert(seriesId).inserted {
            await syncSeries(seriesId)
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

    /// The ids Kavita wants with a progress update. The stored chapter has them; one with no page
    /// count costs a request.
    private func target(for chapter: ChapterRecord, pageCount: Int?) async -> Target? {
        var pages = chapter.pages > 0 ? chapter.pages : pageCount ?? 0
        var volumeId = chapter.volumeId
        if pages <= 0 {
            do {
                let fetched = try await kavita.chapter(id: chapter.id)
                pages = fetched.pages
                volumeId = fetched.volumeId
            } catch {
                log.warning("Could not look up chapter \(chapter.id): \(error)")
                return nil
            }
        }
        return Target(seriesId: chapter.seriesId, libraryId: chapter.libraryId, volumeId: volumeId, chapterId: chapter.id, pages: pages)
    }
}
