import Foundation
import GRDB

/// The tracking sites (Android's `TrackerManager`), with the ids Android gives them.
@MainActor
@Observable
final class TrackerManager {
    let trackers: [any Tracker]
    private let database: AppDatabase
    private let defaults: UserDefaults
    /// Bumped on sign-in and sign-out, so views reading `isSignedIn` refresh.
    private(set) var revision = 0

    init(database: AppDatabase, session: URLSession = .shared, defaults: UserDefaults = .standard, trackers: [any Tracker]? = nil) {
        self.database = database
        self.defaults = defaults
        // Android's order. Its Komga, Kavita and Suwayomi trackers are sources here, synced by them.
        self.trackers = trackers ?? [
            MangaBaka(session: session, defaults: defaults), MyAnimeList(session: session, defaults: defaults),
            AniList(session: session, defaults: defaults), Kitsu(session: session, defaults: defaults),
            Shikimori(session: session, defaults: defaults), Bangumi(session: session, defaults: defaults),
            MangaUpdates(session: session, defaults: defaults), Hikka(session: session, defaults: defaults),
            Comick(session: session, defaults: defaults),
        ]
    }

    func tracker(_ id: Int64) -> (any Tracker)? {
        trackers.first { $0.id == id }
    }

    var signedIn: [any Tracker] {
        _ = revision
        return trackers.filter(\.isSignedIn)
    }

    /// Android's "Update progress after reading" (`pref_auto_update_manga_sync_key`).
    var updateAfterReading: Bool {
        get {
            access(keyPath: \.updateAfterReading)
            return defaults.object(forKey: "pref_auto_update_manga_sync_key") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.updateAfterReading) { defaults.set(newValue, forKey: "pref_auto_update_manga_sync_key") }
        }
    }

    func signIn(_ tracker: any Tracker, callback: URL) async throws {
        try await tracker.signIn(callback: callback)
        revision += 1
    }

    func signIn(_ tracker: any Tracker, username: String, password: String) async throws {
        try await tracker.signIn(username: username, password: password)
        revision += 1
    }

    func signOut(_ tracker: any Tracker) {
        tracker.signOut()
        revision += 1
    }

    // MARK: Linking

    /// Links a series to a search result: binds it on the site and keeps the track.
    func link(seriesId: Int, to result: TrackSearch, tracker: any Tracker) async throws {
        let chapters = (try? await database.chapterList(seriesId: seriesId)) ?? []
        var track = result.track(seriesId: seriesId, trackerId: tracker.id)
        // Android starts from the highest chapter read here.
        track.lastChapterRead = chapters.filter(\.read).map(\.number).filter { $0 >= 0 }.max() ?? 0
        let hasRead = chapters.contains(where: \.read)
        var bound = try await tracker.bind(track, hasReadChapters: hasRead)
        // The site may have read further; send ours if we're ahead.
        if bound.lastChapterRead < track.lastChapterRead {
            bound.lastChapterRead = track.lastChapterRead
            bound = try await tracker.update(bound, didReadChapter: true)
        }
        bound.seriesId = seriesId
        bound.trackerId = tracker.id
        if bound.title.isEmpty { bound.title = result.title }
        if bound.remoteUrl.isEmpty { bound.remoteUrl = result.trackingURL }
        if bound.totalChapters == 0 { bound.totalChapters = result.totalChapters }
        try await database.saveTrack(bound)
    }

    /// Sends a change made on the tracking sheet, then keeps it.
    func update(_ track: TrackRecord) async throws {
        guard let tracker = tracker(track.trackerId) else { return }
        var updated = try await tracker.update(track, didReadChapter: false)
        updated.id = track.id
        try await database.saveTrack(updated)
    }

    func refresh(_ track: TrackRecord) async throws {
        guard let tracker = tracker(track.trackerId) else { return }
        var refreshed = try await tracker.refresh(track)
        refreshed.id = track.id
        refreshed.seriesId = track.seriesId
        refreshed.trackerId = track.trackerId
        try await database.saveTrack(refreshed)
    }

    /// Unlinks the series, and takes it off the site's list too if asked.
    func unlink(_ track: TrackRecord, fromSite: Bool) async throws {
        if fromSite, let tracker = tracker(track.trackerId) { try await tracker.delete(track) }
        try await database.deleteTrack(track)
    }

    // MARK: Reading

    /// Android's `TrackChapter`: after a chapter is read, each linked site behind it moves up to
    /// it. Failures are left for the next chapter, as the sites keep the highest anyway.
    func chapterRead(seriesId: Int, number: Double) async {
        guard updateAfterReading, number >= 0 else { return }
        let tracks = (try? await database.tracks(seriesId: seriesId)) ?? []
        for track in tracks where number > track.lastChapterRead {
            guard let tracker = tracker(track.trackerId), tracker.isSignedIn else { continue }
            var track = track
            track.lastChapterRead = number
            do {
                var updated = try await tracker.update(track, didReadChapter: true)
                updated.id = track.id
                try await database.saveTrack(updated)
            } catch {
                // Keep it locally, so the sheet shows where reading got to.
                try? await database.saveTrack(track)
            }
        }
    }
}

extension AppDatabase {
    func tracks(seriesId: Int) async throws -> [TrackRecord] {
        try await writer.read { db in
            try TrackRecord.filter(Column("seriesId") == seriesId).fetchAll(db)
        }
    }

    func observeTracks(seriesId: Int) -> AsyncValueObservation<[TrackRecord]> {
        ValueObservation
            .tracking { db in try TrackRecord.filter(Column("seriesId") == seriesId).fetchAll(db) }
            .values(in: writer)
    }

    /// Saves a track; one per series and tracker.
    func saveTrack(_ track: TrackRecord) async throws {
        try await writer.write { db in
            var track = track
            if track.id == nil {
                track.id = try Int64.fetchOne(
                    db, sql: "SELECT id FROM track WHERE seriesId = ? AND trackerId = ?", arguments: [track.seriesId, track.trackerId]
                )
            }
            try track.save(db)
        }
    }

    func deleteTrack(_ track: TrackRecord) async throws {
        _ = try await writer.write { db in
            try db.execute(sql: "DELETE FROM track WHERE seriesId = ? AND trackerId = ?", arguments: [track.seriesId, track.trackerId])
        }
    }
}
