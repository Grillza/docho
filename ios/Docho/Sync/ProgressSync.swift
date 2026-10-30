import Foundation
import Observation

/// What every reading-progress sync does: Kavita, Komga, BookOrbit and KOReader each follow the
/// same rules (the side that has read further wins, except hand marks; an offline queue).
protocol SyncEngine: Actor {
    /// Names the engine's entries in the sync queue and its count in Settings.
    nonisolated var engine: String { get }
    /// Yields when something couldn't be delivered and should be retried later.
    nonisolated var retryRequests: AsyncStream<Void> { get }
    /// Whether this engine syncs the series right now.
    nonisolated func syncs(_ series: SeriesRecord) -> Bool

    func pageChanged(_ series: SeriesRecord, chapter: ChapterRecord, page: Int, pageCount: Int, read: Bool)
    func readStatusChanged(_ series: SeriesRecord, chapters: [ChapterRecord], read: Bool) async
    /// Delivers the series' queued changes, then reconciles it; only `chapterIds` when given.
    func syncSeries(_ series: SeriesRecord, chapterIds: Set<Int>?) async
    /// Reconciles every library series this engine syncs. Returns how many.
    @discardableResult func syncLibrary() async -> Int
    /// Delivers everything queued. Returns whether the queue is now empty.
    @discardableResult func syncQueued() async -> Bool
    /// Sends pages still waiting out their pause, e.g. when the app goes to the background.
    func sendWaitingPages() async
}

/// Where reading progress is synced (Android's `ProgressSyncMode`).
enum ProgressSyncMode: String, CaseIterable, Sendable {
    /// Each series syncs with the server it is read from.
    case source
    /// Every series syncs with the KOReader sync server, and nothing else.
    case koreader
}

/// The app-wide sync choice, in UserDefaults.
final class SyncSettings: Sendable {
    static let modeKey = "progress_sync_mode"
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var mode: ProgressSyncMode {
        get { defaults.string(forKey: Self.modeKey).flatMap(ProgressSyncMode.init(rawValue:)) ?? .source }
        set { defaults.set(newValue.rawValue, forKey: Self.modeKey) }
    }

    var usesKoreader: Bool { mode == .koreader }
}

/// Sends a series' reading progress to wherever it is synced: its source's server, or the
/// KOReader sync server when Settings → Sync says so. At most one engine syncs any series.
final class ProgressSync: Sendable {
    let engines: [any SyncEngine]

    init(engines: [any SyncEngine]) {
        self.engines = engines
    }

    /// Yields when any engine wants a retry.
    var retryRequests: AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        for engine in engines {
            Task {
                for await _ in engine.retryRequests { continuation.yield() }
            }
        }
        return stream
    }

    func syncs(_ series: SeriesRecord) -> Bool {
        engines.contains { $0.syncs(series) }
    }

    func pageChanged(_ series: SeriesRecord, chapter: ChapterRecord, page: Int, pageCount: Int, read: Bool) async {
        for engine in engines where engine.syncs(series) {
            await engine.pageChanged(series, chapter: chapter, page: page, pageCount: pageCount, read: read)
        }
    }

    func readStatusChanged(_ series: SeriesRecord, chapters: [ChapterRecord], read: Bool) async {
        for engine in engines where engine.syncs(series) {
            await engine.readStatusChanged(series, chapters: chapters, read: read)
        }
    }

    func syncSeries(_ series: SeriesRecord, chapterIds: Set<Int>? = nil) async {
        for engine in engines where engine.syncs(series) {
            await engine.syncSeries(series, chapterIds: chapterIds)
        }
    }

    func syncLibrary() async {
        for engine in engines { await engine.syncLibrary() }
    }

    @discardableResult
    func syncQueued() async -> Bool {
        var empty = true
        for engine in engines where await !engine.syncQueued() { empty = false }
        return empty
    }

    func sendWaitingPages() async {
        for engine in engines { await engine.sendWaitingPages() }
    }
}
