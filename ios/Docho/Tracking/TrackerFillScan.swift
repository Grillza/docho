import Foundation
import GRDB
import OSLog

/// Scans the library against the trackers signed in on this device, and keeps what it finds as a
/// list to review, in a file as a scan can take hours. iOS doesn't let it run in the background, so
/// it pauses when the app leaves the screen and goes on when it's back. Nothing changes on a series
/// until it's resolved here, which saves ordinary edits that reach everything through Dōchō Sync.
/// Android's `TrackerFillScan`.
@MainActor
@Observable
final class TrackerFillScan {
    struct Progress: Codable, Equatable {
        var total = 0
        var done = 0
        var unchanged = 0
        var failed = 0
        var finished = false
    }

    private struct State: Codable {
        var progress = Progress()
        var items: [FillItem] = []
        /// The series still to scan; the scan is under way while there are any.
        var queue: [Int] = []
        var compareAll = true
    }

    private(set) var progress = Progress()
    private(set) var items: [FillItem] = []
    private(set) var isScanning = false

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let trackers: TrackerManager
    @ObservationIgnored private let memory: TrackerFillMemory
    @ObservationIgnored private let seriesEdits: SeriesEdits
    @ObservationIgnored private let onChange: @MainActor () -> Void
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private var state = State()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.github.grillza.docho", category: "tracker-fill")

    /// Trackers are asked one at a time with a pause between, not to run into their rate limits.
    private static let pause: Duration = .seconds(2)
    private static let suggestionsPerTracker = 3
    private static let resultsPerTracker = 5
    /// Dōchō Server's Series Groups: not a series on any tracker.
    private static let seriesGroupsSource: Int64 = 0x0D0C_0000_0000_0000

    init(
        database: AppDatabase, trackers: TrackerManager, memory: TrackerFillMemory, seriesEdits: SeriesEdits,
        stateURL: URL = URL.applicationSupportDirectory.appending(path: "tracker-fill.json"),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.database = database
        self.trackers = trackers
        self.memory = memory
        self.seriesEdits = seriesEdits
        self.stateURL = stateURL
        self.onChange = onChange
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
            progress = saved.progress
            items = Self.sorted(saved.items)
        }
    }

    var canScan: Bool { !trackers.signedIn.isEmpty }
    var hasUnfinishedScan: Bool { !state.queue.isEmpty }

    private var fill: TrackerFill { TrackerFill(trackers: trackers.signedIn) }

    private static func sorted(_ items: [FillItem]) -> [FillItem] {
        items.sorted {
            if ($0.problem == .ready) != ($1.problem == .ready) { return $1.problem == .ready }
            return $0.title.lowercased() < $1.title.lowercased()
        }
    }

    private func save() {
        state.progress = progress
        state.items = items
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    private func series(_ source: Int64, _ url: String) async -> SeriesRecord? {
        try? await database.writer.read { db in
            try SeriesRecord.filter(SeriesRecord.Columns.source == source && SeriesRecord.Columns.url == url).fetchOne(db)
        }
    }

    private static func current(_ series: SeriesRecord) -> FillCurrent {
        FillCurrent(author: series.authors ?? "", artist: series.artists ?? "", description: series.summary ?? "", status: series.status)
    }

    /// Brings the list up to date with what changed since, here or on another device.
    func load() async {
        var left: [FillItem] = []
        for item in items {
            guard let series = await series(item.source, item.url) else { continue }
            let remembered = memory.get(item.id)
            if let pruned = TrackerFillRules.prune(
                item, current: Self.current(series), filledStatus: remembered?.status, ignored: remembered?.ignored ?? [:]
            ) {
                left.append(pruned)
            }
        }
        items = Self.sorted(left)
        save()
    }

    // MARK: Scanning

    /// Starts a scan, which replaces the list. `compareAll` also looks up series with no empty fields.
    func start(compareAll: Bool, forgetChoices: Bool) {
        task?.cancel()
        if forgetChoices { memory.forgetChoices() }
        items = []
        progress = Progress()
        state = State(compareAll: compareAll)
        isScanning = true
        task = Task { [weak self] in
            guard let self else { return }
            let library = (try? await self.database.writer.read { db in
                try SeriesRecord.filter(SeriesRecord.Columns.inLibrary == true).fetchAll(db)
            }) ?? []
            self.state.queue = library.filter { series in
                let remembered = self.memory.get(SyncValues.key(series.source, series.url))
                return series.source != Self.seriesGroupsSource && remembered?.ignored[TrackerFillRules.skipped] == nil
                    && (compareAll || Self.current(series).hasEmptyFields || remembered?.status == series.status)
            }.map(\.id)
            self.progress.total = self.state.queue.count
            self.save()
            await self.work()
        }
    }

    /// Goes on with a scan that was paused, if there is one.
    func resume() {
        guard task == nil, hasUnfinishedScan, canScan else { return }
        isScanning = true
        task = Task { [weak self] in await self?.work() }
    }

    /// Stops for now, when the app leaves the screen; `resume` goes on from here.
    func pause() {
        task?.cancel()
        task = nil
        isScanning = false
    }

    /// Stops the scan for good; what it found so far stays on the list.
    func stop() {
        pause()
        state.queue = []
        progress.finished = true
        save()
    }

    private func work() async {
        while let id = state.queue.first {
            if let series = try? await database.seriesRecord(id: id) { await scan(series) }
            if Task.isCancelled { return }
            state.queue.removeFirst()
            progress.done += 1
            save()
        }
        progress.finished = true
        isScanning = false
        task = nil
        save()
    }

    private struct Lookup {
        var matches: [TrackerFill.Match] = []
        var failed = 0
        var several: [TrackerFill.Match] = []
        var suggestions: [TrackerFill.Match] = []
    }

    private func scan(_ series: SeriesRecord) async {
        let current = Self.current(series)
        let lookup = await lookUp(series, current: current)
        // Cut short by the app leaving the screen: it's looked at again when it's back
        if Task.isCancelled { return }
        progress.failed += lookup.failed
        let remembered = memory.get(SyncValues.key(series.source, series.url))
        var item: FillItem?
        if lookup.matches.isEmpty, !current.hasEmptyFields {
            // Nothing is missing, so not knowing which series it is doesn't matter
        } else if !lookup.several.isEmpty {
            item = FillItem(
                source: series.source, url: series.url, title: series.name, problem: .severalMatches, candidates: lookup.several + lookup.matches
            )
        } else if !lookup.matches.isEmpty {
            let changes = TrackerFillRules.review(
                current, matches: lookup.matches, filledStatus: remembered?.status, ignored: remembered?.ignored ?? [:]
            )
            if let problem = TrackerFillRules.problem(of: changes) {
                item = FillItem(source: series.source, url: series.url, title: series.name, problem: problem, changes: changes)
            } else {
                progress.unchanged += 1
            }
        } else if lookup.failed == 0 || !lookup.suggestions.isEmpty {
            // A tracker that couldn't be reached says nothing about whether there's a match
            item = FillItem(source: series.source, url: series.url, title: series.name, problem: .noMatch, candidates: lookup.suggestions)
        }
        if let item { items = Self.sorted(items + [item]) }
    }

    /// The entries a series is linked to; else exact title matches, until nothing's missing.
    private func lookUp(_ series: SeriesRecord, current: FillCurrent) async -> Lookup {
        let fill = fill
        let tracks = (try? await database.tracks(seriesId: series.id)) ?? []
        if !tracks.isEmpty {
            let linked = await fill.linked(tracks)
            try? await Task.sleep(for: Self.pause * tracks.count)
            if !linked.isEmpty { return Lookup(matches: linked) }
        }
        var lookup = Lookup()
        let wanted = TrackerFillRules.comparable(series.name)
        for tracker in fill.trackersInScanOrder {
            if Task.isCancelled { return lookup }
            do {
                let results = try await tracker.search(series.name)
                let exact = wanted.isEmpty ? [] : results.filter { TrackerFillRules.comparable($0.title) == wanted }
                if exact.count == 1 {
                    lookup.matches.append(await fill.withDetails(exact[0], on: tracker))
                } else if exact.count > 1 {
                    for result in exact.prefix(Self.resultsPerTracker) { lookup.several.append(await fill.withDetails(result, on: tracker)) }
                    return lookup
                } else {
                    lookup.suggestions += results.prefix(Self.suggestionsPerTracker).map { fill.withoutDetails($0, on: tracker) }
                }
            } catch {
                if Task.isCancelled { return lookup }
                log.warning("Couldn't search for \(series.name) on \(tracker.name): \(error)")
                lookup.failed += 1
            }
            try? await Task.sleep(for: Self.pause)
            if isComplete(current, lookup.matches) { break }
        }
        return lookup
    }

    private func isComplete(_ current: FillCurrent, _ matches: [TrackerFill.Match]) -> Bool {
        let all = state.compareAll
        return ((!all && !TrackerFillRules.isEmptyName(current.author)) || matches.contains { !$0.author.isEmpty })
            && ((!all && !TrackerFillRules.isEmptyName(current.artist)) || matches.contains { !$0.artist.isEmpty })
            && (!current.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || matches.contains { !$0.description.isEmpty })
            && matches.contains { $0.status != MangaStatus.unknown.rawValue }
    }

    // MARK: The review list

    private func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Settles an item: each field takes its choice, or keeps what it has if there's none (`choices`
    /// by field). Options not taken are remembered, so they aren't asked about again.
    func resolve(_ id: String, choices: [String: String]) async {
        await load()
        guard let item = items.first(where: { $0.id == id }) else { return }
        var details = seriesEdits.get(source: item.source, url: item.url) ?? .init()
        var ignore: [String: [String]] = [:]
        for change in item.changes {
            let value = choices[change.field]
            if let value {
                switch change.field {
                case TrackerFillRules.author: details.author = value
                case TrackerFillRules.artist: details.artist = value
                case TrackerFillRules.description: details.description = value
                default: details.status = Int(value)
                }
            }
            if change.field == TrackerFillRules.description {
                ignore[change.field] = value == nil ? [TrackerFillRules.kept] : []
            } else {
                ignore[change.field] = change.options.map(\.value).filter { $0 != value }.map { TrackerFillRules.optionKey(change.field, $0) }
            }
        }
        if item.picked { ignore[TrackerFillRules.skipped] = [TrackerFillRules.kept] }
        if !choices.isEmpty {
            seriesEdits.put(source: item.source, url: item.url, details)
            let (source, url) = (item.source, item.url)
            try? await database.writer.write { [details] db in
                guard var series = try SeriesRecord
                    .filter(SeriesRecord.Columns.source == source && SeriesRecord.Columns.url == url).fetchOne(db) else { return }
                SeriesEdits.write(details, to: &series)
                try series.update(db)
            }
        }
        memory.remember(id, filledStatus: choices[TrackerFillRules.status].flatMap { Int($0) }, ignore: ignore)
        remove(id)
        onChange()
    }

    /// Takes an item off the list, keeping what the series has; one with no match isn't scanned again.
    func skip(_ id: String) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.changes.isEmpty {
            memory.remember(id, filledStatus: nil, ignore: [TrackerFillRules.skipped: [TrackerFillRules.kept]])
            remove(id)
            onChange()
        } else {
            await resolve(id, choices: [:])
        }
    }

    /// Applies everything with nothing to decide.
    func applyReady() async {
        await load()
        for item in items where item.problem == .ready {
            await resolve(item.id, choices: Dictionary(uniqueKeysWithValues: item.changes.compactMap { change in
                change.options.first.map { (change.field, $0.value) }
            }))
        }
    }

    /// Takes every conflict off the list, keeping what the series have.
    func dismissConflicts() async {
        for item in items where item.problem != .ready { await skip(item.id) }
    }

    /// Takes one of an item's candidates as the series.
    func pick(_ id: String, index: Int) async {
        guard let position = items.firstIndex(where: { $0.id == id }), items[position].candidates.indices.contains(index) else { return }
        let item = items[position]
        let candidate = item.candidates[index]
        let match = candidate.complete ? candidate : await fill.completed(candidate)
        guard let series = await series(item.source, item.url) else { return }
        let changes = TrackerFillRules.review(Self.current(series), matches: [match], filledStatus: memory.get(id)?.status)
        guard let problem = TrackerFillRules.problem(of: changes) else {
            memory.remember(id, filledStatus: nil, ignore: [TrackerFillRules.skipped: [TrackerFillRules.kept]])
            remove(id)
            onChange()
            return
        }
        var picked = item
        picked.problem = problem
        picked.changes = changes
        picked.candidates = []
        picked.picked = true
        items = Self.sorted(items.map { $0.id == id ? picked : $0 })
        save()
    }

    /// Replaces an item's candidates with search results for `query`.
    func search(_ id: String, query: String) async throws {
        let found = try await fill.search(query.trimmingCharacters(in: .whitespacesAndNewlines))
        items = Self.sorted(items.map { item in
            guard item.id == id else { return item }
            var item = item
            item.problem = found.isEmpty ? .noMatch : .severalMatches
            item.changes = []
            item.candidates = found
            return item
        })
        save()
    }
}
