import Foundation
import os
import Synchronization

/// Finds the files behind one source's chapters (Android's `KoreaderDocumentProvider`). KOReader
/// matches documents by file, so a source takes part only if Docho can reach each chapter's file.
protocol KoreaderDocumentProvider: Sendable {
    var sourceId: Int64 { get }
    /// Documents for these chapters, keyed by chapter URL; chapters that can't be matched are left out.
    func documents(_ series: SeriesRecord, _ chapters: [ChapterRecord], pageCount: Int?) async -> [String: KoreaderDocument]
}

/// Kavita stores KOReader's hash for files it has scanned since gaining the feature, and the
/// chapter list puts it in the memo. Older files are hashed from ranged requests, and cached.
struct KavitaKoreaderDocuments: KoreaderDocumentProvider {
    let source: KavitaSource
    let cache: KoreaderDocumentCache
    var sourceId: Int64 { KavitaSource.id }

    func documents(_ series: SeriesRecord, _ chapters: [ChapterRecord], pageCount: Int?) async -> [String: KoreaderDocument] {
        var result: [String: KoreaderDocument] = [:]
        var missing: [ChapterRecord] = []
        for chapter in chapters {
            let memo = chapter.chapterMemo
            let pages = memo.int(KavitaSource.memoPages).flatMap { $0 > 0 ? $0 : nil } ?? (chapter.pages > 0 ? chapter.pages : pageCount)
            if let hash = memo.string(KavitaSource.memoKoreaderHash), let pages, pages > 0 {
                result[chapter.url] = KoreaderDocument(hash: hash, pages: pages)
            } else {
                missing.append(chapter)
            }
        }
        guard !missing.isEmpty else { return result }
        var remote: [Int: KavitaChapter] = [:]
        do {
            if missing.count == 1, let id = KavitaSource.chapterId(missing[0].url) {
                remote[id] = try await source.client.chapter(id: id)
            } else if let seriesId = KavitaSource.seriesId(series.url) {
                for chapter in try await source.client.volumes(seriesId: seriesId).flatMap(\.chapters) { remote[chapter.id] = chapter }
            }
        } catch {
            return result
        }
        for chapter in missing {
            guard let id = KavitaSource.chapterId(chapter.url), let remoteChapter = remote[id] else { continue }
            let pages = remoteChapter.pages > 0 ? remoteChapter.pages : (pageCount ?? 0)
            guard pages > 0 else { continue }
            var hash = remoteChapter.koreaderHash
            if hash == nil { hash = await computedHash(remoteChapter) }
            if let hash { result[chapter.url] = KoreaderDocument(hash: hash, pages: pages) }
        }
        return result
    }

    /// KOReader opens each file of a chapter as its own document, and a chapter of loose images
    /// isn't a file at all, so neither can be matched.
    private func computedHash(_ chapter: KavitaChapter) async -> String? {
        guard chapter.files.count == 1, chapter.files[0].format != KavitaConstants.formatImage else { return nil }
        let key = "kavita:\(chapter.id)"
        if let cached = cache.get(key) { return cached.hash }
        guard let hash = try? await KoreaderHash.compute(read: { offset, length in
            try await source.client.readFileRange(chapterId: chapter.id, offset: offset, length: length)
        }) else { return nil }
        cache.put(key, KoreaderDocument(hash: hash, pages: chapter.pages))
        return hash
    }
}

/// BookOrbit stores KOReader's hash for each file, as that's how it matches KOReader's progress.
struct BookOrbitKoreaderDocuments: KoreaderDocumentProvider {
    let source: BookOrbitSource
    let cache: KoreaderDocumentCache
    var sourceId: Int64 { BookOrbitSource.id }

    func documents(_ series: SeriesRecord, _ chapters: [ChapterRecord], pageCount: Int?) async -> [String: KoreaderDocument] {
        var result: [String: KoreaderDocument] = [:]
        for chapter in chapters {
            guard let bookId = BookOrbitSource.bookId(chapter.url), let fileId = BookOrbitSource.fileId(chapter.url) else { continue }
            let key = "bookorbit:\(fileId)"
            if let cached = cache.get(key) {
                result[chapter.url] = cached
                continue
            }
            guard let hash = try? await source.client.book(bookId).files.first(where: { $0.id == fileId })?.fileHash?.lowercased() else { continue }
            let known = chapter.pages > 0 ? chapter.pages : (pageCount ?? 0)
            guard let pages = known > 0 ? known : try? await source.client.pageCount(fileId: fileId) else { continue }
            let document = KoreaderDocument(hash: hash, pages: pages)
            cache.put(key, document)
            result[chapter.url] = document
        }
        return result
    }
}

/// Komga can store KOReader's hash but doesn't share it, and only sends whole files, so a book is
/// matched by downloading its file once and hashing it on the way, only once the user agreed.
final class KomgaKoreaderDocuments: KoreaderDocumentProvider {
    let source: KomgaSource
    let settings: KomgaSettings
    let cache: KoreaderDocumentCache
    /// Books whose file couldn't be hashed; not retried until relaunch.
    let unhashable = Mutex<Set<String>>([])
    var sourceId: Int64 { KomgaSource.id }

    init(source: KomgaSource, settings: KomgaSettings, cache: KoreaderDocumentCache) {
        self.source = source
        self.settings = settings
        self.cache = cache
    }

    func documents(_ series: SeriesRecord, _ chapters: [ChapterRecord], pageCount: Int?) async -> [String: KoreaderDocument] {
        guard settings.koreaderDownloads else { return [:] }
        var result: [String: KoreaderDocument] = [:]
        for chapter in chapters {
            guard let bookId = KomgaSource.bookIdOrNil(chapter.url), !unhashable.withLock({ $0.contains(bookId) }) else { continue }
            let key = "komga:\(bookId)"
            if let cached = cache.get(key) {
                result[chapter.url] = cached
                continue
            }
            do {
                let pages = chapter.pages > 0 ? chapter.pages : try await source.client.book(bookId).media.pagesCount
                let document = KoreaderDocument(hash: try await source.client.koreaderHash(bookId), pages: pages)
                cache.put(key, document)
                result[chapter.url] = document
            } catch {
                unhashable.withLock { _ = $0.insert(bookId) }
            }
        }
        return result
    }
}

/// Port of `KoreaderSync.kt`: two-way, page-level progress sync with a KOReader sync server.
/// While Settings → Sync is set to KOReader it is the only sync: every series whose source can
/// name the files behind its chapters syncs here, and the sources' own syncs stand down.
///
/// Positions use KOReader's form for paged documents: the 1-based page number, with the chapter
/// read once its last page is reached. The protocol only has per-document requests, so a series
/// is reconciled one chapter at a time.
actor KoreaderSync: SyncEngine {
    static let engine = "koreader"
    static let deviceName = "Docho"

    nonisolated let retryRequests: AsyncStream<Void>
    private let retryContinuation: AsyncStream<Void>.Continuation
    private let client: KoreaderClient
    private let database: AppDatabase
    private let settings: KoreaderSettings
    private let syncSettings: SyncSettings
    private let providers: [Int64: any KoreaderDocumentProvider]
    private let pageDebounce: Duration
    private var debounces: [Int: Task<Void, Never>] = [:]
    private var waiting: [Int: (series: SeriesRecord, chapter: ChapterRecord, page: Int, pageCount: Int, read: Bool)] = [:]
    /// Documents the server said it has no book for; not sent again until relaunch.
    private var unknownDocuments = Set<String>()
    private let log = Logger(subsystem: "io.github.grillza.docho", category: "koreader-sync")

    init(
        client: KoreaderClient, database: AppDatabase, settings: KoreaderSettings, syncSettings: SyncSettings,
        providers: [any KoreaderDocumentProvider], pageDebounce: Duration = KavitaSync.pageDebounce
    ) {
        self.client = client
        self.database = database
        self.settings = settings
        self.syncSettings = syncSettings
        self.providers = Dictionary(providers.map { ($0.sourceId, $0) }) { first, _ in first }
        self.pageDebounce = pageDebounce
        (retryRequests, retryContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    nonisolated var engine: String { Self.engine }
    nonisolated var isEnabled: Bool { settings.isConfigured }

    nonisolated func syncs(_ series: SeriesRecord) -> Bool {
        isEnabled && syncSettings.usesKoreader && [KavitaSource.id, BookOrbitSource.id, KomgaSource.id].contains(series.source)
    }

    /// A position waiting to reach the server: `page` of `pages`; 0 is unread and `pages` read.
    struct Pending: Codable, Sendable, Equatable {
        var document: String
        var seriesId: Int
        var page: Int
        var pages: Int

        func progress(deviceId: String) -> KoreaderProgress {
            KoreaderProgress(
                // KOReader has no page 0; an unread chapter is at the start of page 1.
                document: document, progress: String(max(page, 1)), percentage: pages > 0 ? Double(page) / Double(pages) : 0,
                device: KoreaderSync.deviceName, deviceId: deviceId
            )
        }
    }

    /// The server's position as a page number from 0 (not started) to `pages` (read). The page is
    /// used when the server sent one; otherwise it's estimated from the percentage.
    static func position(_ progress: KoreaderProgress?, pages: Int) -> Int {
        guard let progress else { return 0 }
        let percentage = progress.percentage ?? 0
        if percentage >= 1 { return pages }
        let page = progress.progress.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? Int((percentage * Double(pages)).rounded())
        return min(max(page, 0), pages)
    }

    static func shouldSend(_ entry: Pending, markedByUser: Bool, serverPosition: Int) -> Bool {
        markedByUser || entry.page > serverPosition
    }

    private func document(_ series: SeriesRecord, _ chapter: ChapterRecord, pageCount: Int?) async -> KoreaderDocument? {
        await providers[series.source]?.documents(series, [chapter], pageCount: pageCount)[chapter.url]
    }

    // MARK: Push

    func pageChanged(_ series: SeriesRecord, chapter: ChapterRecord, page: Int, pageCount: Int, read: Bool) {
        guard syncs(series) else { return }
        waiting[chapter.id] = (series, chapter, page, pageCount, read)
        debounces[chapter.id]?.cancel()
        debounces[chapter.id] = Task {
            try? await Task.sleep(for: pageDebounce)
            guard !Task.isCancelled else { return }
            debounces[chapter.id] = nil
            await sendWaiting(chapter.id)
        }
    }

    func sendWaitingPages() async {
        for chapterId in waiting.keys {
            debounces.removeValue(forKey: chapterId)?.cancel()
            await sendWaiting(chapterId)
        }
    }

    private func sendWaiting(_ chapterId: Int) async {
        guard let change = waiting.removeValue(forKey: chapterId),
              let document = await document(change.series, change.chapter, pageCount: change.pageCount > 0 ? change.pageCount : nil)
        else { return }
        let page = change.read ? document.pages : change.page + 1
        guard let entry = try? await enqueue([pending(document, seriesId: change.series.id, page: page)], markedByUser: false).first else { return }
        if await deliver(entry, serverPosition: nil) == .failed { requestRetry() }
    }

    func readStatusChanged(_ series: SeriesRecord, chapters: [ChapterRecord], read: Bool) async {
        guard syncs(series), let provider = providers[series.source] else { return }
        for chapter in chapters {
            debounces.removeValue(forKey: chapter.id)?.cancel()
            waiting[chapter.id] = nil
        }
        let documents = await provider.documents(series, chapters, pageCount: nil).values
        guard let entries = try? await enqueue(documents.map { pending($0, seriesId: series.id, page: read ? $0.pages : 0) }, markedByUser: true)
        else { return }
        for entry in entries where await deliver(entry, serverPosition: nil) == .failed {
            break
        }
    }

    // MARK: Pull

    /// Delivers the series' queued changes, then reconciles its chapters, or only `chapterIds`
    /// when given (opening the reader only needs the chapter about to be read).
    func syncSeries(_ series: SeriesRecord, chapterIds: Set<Int>?) async {
        guard syncs(series), let provider = providers[series.source] else { return }
        do {
            let key = String(series.id)
            var sent = Set<String>()
            for entry in try await database.syncQueue(engine: Self.engine, seriesKey: key) {
                let delivery = await deliver(entry, serverPosition: nil)
                if delivery == .sent { sent.insert(entry.key) }
                if delivery == .failed { break }
            }
            let skip = sent.union(try await database.syncQueue(engine: Self.engine, seriesKey: key).map(\.key))
            let locals = try await database.chapterList(seriesId: series.id).filter { chapterIds?.contains($0.id) ?? true }
            let documents = await provider.documents(series, locals, pageCount: nil)

            var pulled: [PulledProgress] = []
            var pushes: [(Pending, Int)] = []
            for local in locals {
                guard let target = documents[local.url], !skip.contains(target.hash), !unknownDocuments.contains(target.hash) else { continue }
                let server = Self.position(try await client.progress(target.hash), pages: target.pages)
                let serverRead = server >= target.pages
                let serverLastPageRead = max(server - 1, 0)
                if local.read && !serverRead {
                    pushes.append((pending(target, seriesId: series.id, page: target.pages), server))
                } else if !local.read && serverRead {
                    pulled.append(PulledProgress(chapterId: local.id, read: true))
                } else if !local.read && serverLastPageRead > local.lastPageRead {
                    pulled.append(PulledProgress(chapterId: local.id, lastPageRead: serverLastPageRead))
                } else if !local.read && local.lastPageRead > serverLastPageRead {
                    pushes.append((pending(target, seriesId: series.id, page: local.lastPageRead + 1), server))
                }
            }
            try await database.applyPulled(pulled)
            if !pushes.isEmpty {
                let entries = try await enqueue(pushes.map(\.0), markedByUser: false)
                for (entry, push) in zip(entries, pushes) where await deliver(entry, serverPosition: push.1) == .failed {
                    break
                }
            }
            if !pulled.isEmpty || !pushes.isEmpty {
                log.info("KOReader: synced '\(series.name)': \(pulled.count) pulled, \(pushes.count) pushed")
            }
        } catch {
            log.warning("KOReader: progress sync failed for '\(series.name)': \(error)")
        }
    }

    @discardableResult
    func syncLibrary() async -> Int {
        guard isEnabled, syncSettings.usesKoreader, let library = try? await database.librarySeriesRecords() else { return 0 }
        let series = library.filter(syncs)
        for item in series { await syncSeries(item, chapterIds: nil) }
        await flush()
        return series.count
    }

    @discardableResult
    func syncQueued() async -> Bool {
        guard isEnabled else { return true }
        guard let queued = try? await database.syncQueue(engine: Self.engine), !queued.isEmpty else { return true }
        for key in Set(queued.map(\.seriesKey)) {
            if let id = Int(key), let series = try? await database.seriesRecord(id: id), series.inLibrary {
                await syncSeries(series, chapterIds: nil)
            }
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

    private func pending(_ document: KoreaderDocument, seriesId: Int, page: Int) -> Pending {
        Pending(document: document.hash, seriesId: seriesId, page: min(max(page, 0), document.pages), pages: document.pages)
    }

    private func enqueue(_ entries: [Pending], markedByUser: Bool) async throws -> [SyncQueueRecord] {
        try await database.enqueueSync(
            engine: Self.engine, entries.map { (key: $0.document, seriesKey: String($0.seriesId), entry: $0) }, markedByUser: markedByUser
        )
    }

    private func deliver(_ record: SyncQueueRecord, serverPosition: Int?) async -> Delivery {
        guard let entry = record.decode(Pending.self), !unknownDocuments.contains(record.key) else {
            try? await database.removeSync([record])
            return .dropped
        }
        do {
            let onServer = if record.markedByUser { 0 } else if let serverPosition { serverPosition } else {
                Self.position(try await client.progress(entry.document), pages: entry.pages)
            }
            let send = Self.shouldSend(entry, markedByUser: record.markedByUser, serverPosition: onServer)
            if send { try await client.updateProgress(entry.progress(deviceId: settings.deviceId)) }
            try await database.removeSync([record])
            return send ? .sent : .dropped
        } catch KoreaderError.unknownDocument {
            log.info("KOReader: the server has no book for document \(entry.document)")
            unknownDocuments.insert(entry.document)
            try? await database.removeSync([record])
            return .dropped
        } catch {
            log.warning("KOReader: could not send progress for \(entry.document), queued: \(error)")
            requestRetry()
            return .failed
        }
    }

    private func requestRetry() { retryContinuation.yield() }
}
