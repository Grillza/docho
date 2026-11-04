import Foundation

/// Fills a series' empty details from a tracker, for Edit details to show before they're saved.
/// Series linked to a tracker use that entry; others search for it and the user picks the result.
/// Android's `TrackerFill`.
struct TrackerFill: Sendable {
    /// What a tracker knows about a series.
    struct Match: Codable, Sendable, Equatable {
        var trackerName: String
        var title: String
        var author: String
        var artist: String
        var description: String
        var publishingStatus: String
        var status: Int
        var trackerId: Int64 = 0
        var remoteId: Int64 = 0
        /// False if it's a search result that lacks the people and status its details would add.
        var complete = true
    }

    /// The fields a tracker can fill.
    struct Form: Sendable, Equatable {
        var author: String
        var artist: String
        var description: String
        var status: Int
    }

    private static let resultsPerTracker = 5
    private static let mangaUpdatesId: Int64 = 7

    let trackers: [any Tracker]

    var canFill: Bool { !trackers.isEmpty }

    /// The entries of the trackers the series is linked to; empty if there are none.
    func linked(_ tracks: [TrackRecord]) async -> [Match] {
        var matches: [Match] = []
        for track in tracks {
            guard let tracker = trackers.first(where: { $0.id == track.trackerId }) else { continue }
            // MangaUpdates' search results have no people or status: it's looked up by id
            let query = tracker.id == Self.mangaUpdatesId ? "id:\(track.remoteId)" : track.title
            let results = (try? await tracker.search(query)) ?? []
            if let result = results.first(where: { $0.remoteId == track.remoteId }) {
                matches.append(Self.match(result, on: tracker))
            }
        }
        return matches
    }

    /// The closest results on each tracker. Throws only if every tracker failed.
    func search(_ query: String) async throws -> [Match] {
        var matches: [Match] = []
        var failure: Error?
        var succeeded = false
        await withTaskGroup(of: (Int, Result<[Match], Error>).self) { group in
            for (index, tracker) in trackers.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await Self.search(query, on: tracker)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var byTracker: [Int: [Match]] = [:]
            for await (index, result) in group {
                switch result {
                case .success(let found):
                    byTracker[index] = found
                    succeeded = true
                case .failure(let error):
                    failure = error
                }
            }
            matches = byTracker.keys.sorted().flatMap { byTracker[$0] ?? [] }
        }
        if !succeeded, let failure { throw failure }
        return matches
    }

    private static func search(_ query: String, on tracker: any Tracker) async throws -> [Match] {
        let results = Array(try await tracker.search(query).prefix(resultsPerTracker))
        guard tracker.id == mangaUpdatesId else { return results.map { match($0, on: tracker) } }
        var matches: [Match] = []
        for result in results {
            let details = (try? await tracker.search("id:\(result.remoteId)"))?.first
            matches.append(match(details ?? result, on: tracker))
        }
        return matches
    }

    /// The ones with the most details first, so a scan asks fewer.
    var trackersInScanOrder: [any Tracker] {
        // AniList, MyAnimeList, MangaUpdates, MangaBaka, Kitsu, Shikimori, Comick, Hikka, Bangumi
        let order: [Int64] = [2, 1, 7, 11, 3, 4, 12, 10, 5]
        return trackers.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    /// A search result with whatever its details add.
    func withDetails(_ result: TrackSearch, on tracker: any Tracker) async -> Match {
        guard tracker.id == Self.mangaUpdatesId else { return Self.match(result, on: tracker) }
        let details = (try? await tracker.search("id:\(result.remoteId)"))?.first
        return Self.match(details ?? result, on: tracker)
    }

    /// A search result as it is, saying if its details would add to it.
    func withoutDetails(_ result: TrackSearch, on tracker: any Tracker) -> Match {
        var match = Self.match(result, on: tracker)
        match.complete = tracker.id != Self.mangaUpdatesId
        return match
    }

    /// A `Match` from `withoutDetails` with its details.
    func completed(_ match: Match) async -> Match {
        guard let tracker = trackers.first(where: { $0.id == match.trackerId }),
              let details = (try? await tracker.search("id:\(match.remoteId)"))?.first else { return match }
        return Self.match(details, on: tracker)
    }

    private static func match(_ result: TrackSearch, on tracker: any Tracker) -> Match {
        func names(_ names: [String]) -> String {
            var seen = Set<String>()
            return names.filter { seen.insert($0).inserted }.joined(separator: ", ")
        }
        return Match(
            trackerName: tracker.name, title: result.title, author: names(result.authors), artist: names(result.artists),
            description: result.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            publishingStatus: result.publishingStatus, status: status(result.publishingStatus),
            trackerId: tracker.id, remoteId: result.remoteId
        )
    }

    /// A tracker's publishing status as a series status; each site words it its own way.
    static func status(_ publishing: String) -> Int {
        let words = publishing.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let status: MangaStatus = switch words {
        case "releasing", "publishing", "currently publishing", "ongoing", "current": .ongoing
        case "finished", "completed", "complete", "released": .completed
        case "cancelled", "canceled", "discontinued", "dropped": .cancelled
        case "hiatus", "on hiatus", "paused": .onHiatus
        default: .unknown
        }
        return status.rawValue
    }

    /// Puts `match` in the fields that are empty, leaving what's there. Sources often send
    /// "Unknown" for a missing name, which counts as empty. A status edited earlier can go stale,
    /// so `statusEdited` lets a tracker's status replace it; it's still shown to check.
    static func fill(_ form: Form, from match: Match, statusEdited: Bool) -> Form {
        func isEmpty(_ name: String) -> Bool {
            let name = name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty || name.lowercased() == "unknown"
        }
        let unknown = MangaStatus.unknown.rawValue
        var filled = form
        if isEmpty(form.author), !match.author.isEmpty { filled.author = match.author }
        if isEmpty(form.artist), !match.artist.isEmpty { filled.artist = match.artist }
        if form.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { filled.description = match.description }
        if match.status != unknown, form.status == unknown || statusEdited { filled.status = match.status }
        return filled
    }
}
