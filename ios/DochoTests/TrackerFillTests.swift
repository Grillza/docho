import XCTest
@testable import Docho

final class TrackerFillTests: XCTestCase {
    private let match = TrackerFill.Match(
        trackerName: "AniList", title: "T", author: "Writer", artist: "Artist",
        description: "About it", publishingStatus: "RELEASING", status: MangaStatus.ongoing.rawValue
    )
    private let empty = TrackerFill.Form(author: "", artist: "", description: "", status: MangaStatus.unknown.rawValue)

    func testEachTrackersWordingBecomesAStatus() {
        let statuses: [(String, MangaStatus)] = [
            ("RELEASING", .ongoing), ("Currently Publishing", .ongoing), ("Current", .ongoing),
            ("Finished", .completed), ("Released", .completed), ("Complete", .completed),
            ("Discontinued", .cancelled), ("Paused", .onHiatus), ("on_hiatus", .onHiatus),
            ("Not Yet Released", .unknown), ("", .unknown),
        ]
        for (publishing, status) in statuses {
            XCTAssertEqual(TrackerFill.status(publishing), status.rawValue, publishing)
        }
    }

    func testEmptyFieldsAreFilled() {
        XCTAssertEqual(
            TrackerFill.fill(empty, from: match, statusEdited: false),
            .init(author: "Writer", artist: "Artist", description: "About it", status: MangaStatus.ongoing.rawValue)
        )
    }

    func testWhatsAlreadyThereStays() {
        let form = TrackerFill.Form(author: "Mine", artist: "Mine", description: "Mine", status: MangaStatus.completed.rawValue)
        XCTAssertEqual(TrackerFill.fill(form, from: match, statusEdited: false), form)
    }

    func testASourcesUnknownCountsAsAnEmptyName() {
        var form = empty
        form.author = "Unknown"
        XCTAssertEqual(TrackerFill.fill(form, from: match, statusEdited: false).author, "Writer")
    }

    func testAnEditedStatusCanBeBroughtUpToDate() {
        var form = empty
        form.status = MangaStatus.completed.rawValue
        XCTAssertEqual(TrackerFill.fill(form, from: match, statusEdited: true).status, MangaStatus.ongoing.rawValue)
    }

    func testMangaUpdatesStatusIsReadFromItsDetails() {
        XCTAssertEqual(MangaUpdates.publishingStatus(["status": "43 Volumes (Ongoing)\n\n*Took over (notes)*"]), "Ongoing")
        XCTAssertEqual(MangaUpdates.publishingStatus(["status": "12 Volumes (Complete)"]), "Complete")
        XCTAssertEqual(MangaUpdates.publishingStatus(["status": "12 Volumes (Ongoing)", "completed": true]), "Completed")
        XCTAssertEqual(MangaUpdates.publishingStatus([:]), "")
    }
}

final class TrackerFillRulesTests: XCTestCase {
    private let match = TrackerFill.Match(
        trackerName: "AniList", title: "T", author: "Writer One", artist: "Artist One",
        description: "About it", publishingStatus: "RELEASING", status: 1
    )
    private let full = FillCurrent(author: "Writer One", artist: "Artist One", description: "Mine", status: 1)
    private let empty = FillCurrent(author: "", artist: "", description: "", status: 0)

    func testNamesCompareTheSameAsOnAndroidAndTheServer() {
        XCTAssertEqual(TrackerFillRules.namesKey("MIURA Kentaro, MORI Kouji"), "kentaro miura,kouji mori")
        XCTAssertEqual(TrackerFillRules.namesKey("Kouji Mori, Kentaro Miura"), "kentaro miura,kouji mori")
    }

    func testEmptyFieldsNeedNoDecision() {
        XCTAssertEqual(TrackerFillRules.problem(of: TrackerFillRules.review(empty, matches: [match], filledStatus: nil)), .ready)
    }

    func testADifferingNameIsAConflict() {
        var current = full
        current.author = "Someone Else"
        let change = TrackerFillRules.review(current, matches: [match], filledStatus: nil)
        XCTAssertEqual(change.map(\.field), [TrackerFillRules.author])
        XCTAssertEqual(change.first?.conflict, true)
    }

    func testAStatusTheLastFillGaveIsOnlyOutOfDate() {
        var current = full
        current.status = 2
        XCTAssertEqual(TrackerFillRules.review(current, matches: [match], filledStatus: 2).first?.conflict, false)
        current.status = 6
        XCTAssertEqual(TrackerFillRules.review(current, matches: [match], filledStatus: 2).first?.conflict, true)
    }

    func testSummariesAreNeverComparedAndOneKeptEmptyStaysSo() {
        var other = match
        other.description = "Other"
        XCTAssertTrue(TrackerFillRules.review(full, matches: [other], filledStatus: nil).isEmpty)
        var current = full
        current.description = ""
        XCTAssertTrue(TrackerFillRules.review(current, matches: [match], filledStatus: nil, ignored: [TrackerFillRules.description: ["kept"]]).isEmpty)
    }

    func testWhatWasDecidedAgainstIsntAskedAgainUntilATrackerSaysSomethingNew() {
        var current = full
        current.status = 6
        XCTAssertTrue(TrackerFillRules.review(current, matches: [match], filledStatus: nil, ignored: ["status": ["1"]]).isEmpty)
        var newer = match
        newer.status = 2
        XCTAssertEqual(TrackerFillRules.review(current, matches: [newer], filledStatus: nil, ignored: ["status": ["1"]]).count, 1)
    }

    func testAnItemDropsWhatAnotherDeviceSettled() {
        var scanned = full
        scanned.author = "Someone Else"
        scanned.status = 6
        let item = FillItem(
            source: 1, url: "u", title: "T", problem: .different,
            changes: TrackerFillRules.review(scanned, matches: [match], filledStatus: nil)
        )
        var now = full
        now.status = 6
        XCTAssertEqual(TrackerFillRules.prune(item, current: now, filledStatus: nil, ignored: [:])?.changes.map(\.field), [TrackerFillRules.status])
        XCTAssertNil(TrackerFillRules.prune(item, current: full, filledStatus: nil, ignored: [:]))
    }

    func testASeriesSkippedElsewhereIsGone() {
        let item = FillItem(source: 1, url: "u", title: "T", problem: .noMatch)
        XCTAssertEqual(TrackerFillRules.prune(item, current: empty, filledStatus: nil, ignored: [:]), item)
        XCTAssertNil(TrackerFillRules.prune(item, current: empty, filledStatus: nil, ignored: ["*": ["kept"]]))
    }

    @MainActor
    func testAFillRecordReadsTheSameAsAndroidWritesIt() {
        let memory = TrackerFillMemory.Memory(status: 2, ignored: ["author": ["b", "a"]])
        XCTAssertEqual(memory.json.canonical, #"{"ignored":{"author":["a","b"]},"status":2}"#)
        XCTAssertEqual(TrackerFillMemory.Memory(json: memory.json).ignored["author"], ["a", "b"])
    }
}

/// A tracker answering from a table, signed in, for scans without the network.
private final class FakeTracker: Tracker {
    let id: Int64
    let name: String
    let results: [String: [TrackSearch]]
    let brandColor: UInt32 = 0
    let signIn: TrackerSignIn = .password
    let statuses: [(id: Int, title: String)] = []
    let readingStatus = 1
    let completedStatus = 2
    let scores: [String] = []
    let isSignedIn = true
    let username = "test"

    init(id: Int64, name: String, results: [String: [TrackSearch]]) {
        self.id = id
        self.name = name
        self.results = results
    }

    func indexToScore(_ index: Int) -> Double { 0 }
    func displayScore(_ score: Double) -> String { "" }
    func signOut() {}
    func search(_ query: String) async throws -> [TrackSearch] { results[query] ?? [] }
    func bind(_ track: TrackRecord, hasReadChapters: Bool) async throws -> TrackRecord { track }
    func update(_ track: TrackRecord, didReadChapter: Bool) async throws -> TrackRecord { track }
    func refresh(_ track: TrackRecord) async throws -> TrackRecord { track }
    func delete(_ track: TrackRecord) async throws {}
}

@MainActor
final class TrackerFillScanTests: XCTestCase {
    private var database: AppDatabase!
    private var edits: SeriesEdits!
    private var memory: TrackerFillMemory!
    private var stateURL: URL!

    override func setUp() async throws {
        database = try AppDatabase.inMemory()
        let defaults = UserDefaults(suiteName: "tracker-fill-\(UUID().uuidString)")!
        edits = SeriesEdits(defaults: defaults)
        memory = TrackerFillMemory(defaults: defaults)
        stateURL = FileManager.default.temporaryDirectory.appending(path: "tracker-fill-\(UUID().uuidString).json")
    }

    private func result(_ id: Int64, _ title: String, author: String = "Writer One", status: String = "Releasing") -> TrackSearch {
        TrackSearch(remoteId: id, title: title, coverURL: nil, summary: "About \(title)", publishingStatus: status, authors: [author], artists: [author])
    }

    private func add(_ id: Int, _ title: String, authors: String? = nil, status: MangaStatus = .unknown) async throws {
        var manga = SManga(url: "/\(id)", title: title)
        manga.author = authors
        manga.artist = authors
        manga.status = status
        var series = SeriesRecord(id: id, source: 1, manga: manga)
        series.inLibrary = true
        if authors != nil { series.summary = "Mine" }
        try await database.writer.write { [series] db in try series.insert(db) }
    }

    private func makeScan(_ results: [String: [TrackSearch]]) -> TrackerFillScan {
        let trackers = TrackerManager(
            database: database, defaults: UserDefaults(suiteName: "tracker-fill-\(UUID().uuidString)")!,
            trackers: [FakeTracker(id: 2, name: "AniList", results: results)]
        )
        return TrackerFillScan(database: database, trackers: trackers, memory: memory, seriesEdits: edits, stateURL: stateURL) {}
    }

    private func finish(_ scan: TrackerFillScan) async throws {
        for _ in 0..<400 where scan.isScanning { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(scan.isScanning)
    }

    func testAScanWritesNothingAndSortsWhatItFinds() async throws {
        try await add(1, "Ready")
        try await add(2, "Differs", authors: "Someone Else", status: .ongoing)
        try await add(3, "Twice")
        try await add(4, "Nowhere")
        let scan = makeScan([
            "Ready": [result(1, "Ready")],
            "Differs": [result(2, "Differs")],
            "Twice": [result(3, "Twice"), result(4, "TWICE", author: "Other")],
            "Nowhere": [result(5, "Near Nowhere")],
        ])
        scan.start(compareAll: true, forgetChoices: false)
        try await finish(scan)

        let problems = Dictionary(uniqueKeysWithValues: scan.items.map { ($0.title, $0.problem) })
        XCTAssertEqual(problems, ["Ready": .ready, "Differs": .different, "Twice": .severalMatches, "Nowhere": .noMatch])
        XCTAssertEqual(scan.items.last?.problem, .ready, "conflicts come first")
        XCTAssertEqual(scan.items.first { $0.title == "Twice" }?.candidates.count, 2)
        XCTAssertEqual(scan.items.first { $0.title == "Nowhere" }?.candidates.first?.title, "Near Nowhere")
        let untouched = try await database.seriesRecord(id: 1)
        XCTAssertNil(untouched?.authors)
        XCTAssertTrue(edits.edits.isEmpty)
        XCTAssertEqual(scan.progress.done, 4)
    }

    func testResolvingSavesAnEditAndKeptValuesDontComeBack() async throws {
        try await add(1, "Differs", authors: "Someone Else", status: .ongoing)
        let scan = makeScan(["Differs": [result(2, "Differs")]])
        scan.start(compareAll: true, forgetChoices: false)
        try await finish(scan)
        XCTAssertEqual(scan.items.count, 1)

        // Keeps the author, takes the artist.
        await scan.resolve(SyncValues.key(1, "/1"), choices: [TrackerFillRules.artist: "Writer One"])
        XCTAssertTrue(scan.items.isEmpty)
        let series = try await database.seriesRecord(id: 1)
        XCTAssertEqual(series?.authors, "Someone Else")
        XCTAssertEqual(series?.artists, "Writer One")
        XCTAssertEqual(edits.get(source: 1, url: "/1")?.artist, "Writer One")
        XCTAssertNil(edits.get(source: 1, url: "/1")?.author)

        scan.start(compareAll: true, forgetChoices: false)
        try await finish(scan)
        XCTAssertTrue(scan.items.isEmpty, "the kept author isn't asked about again")

        scan.start(compareAll: true, forgetChoices: true)
        try await finish(scan)
        XCTAssertEqual(scan.items.first?.changes.map(\.field), [TrackerFillRules.author], "until asked to forget")
    }

    func testAStatusTheFillGaveIsOnlyOutOfDateNextTime() async throws {
        try await add(1, "Ready")
        var scan = makeScan(["Ready": [result(1, "Ready")]])
        scan.start(compareAll: true, forgetChoices: false)
        try await finish(scan)
        await scan.applyReady()
        let series = try await database.seriesRecord(id: 1)
        XCTAssertEqual(series?.status, MangaStatus.ongoing.rawValue)

        scan = makeScan(["Ready": [result(1, "Ready", status: "Finished")]])
        scan.start(compareAll: true, forgetChoices: false)
        try await finish(scan)
        XCTAssertEqual(scan.items.first?.problem, .ready)
        XCTAssertEqual(scan.items.first?.changes.first?.options.first?.value, String(MangaStatus.completed.rawValue))
    }

    func testPickingAMatchThenSkippingLeavesItOutOfLaterScans() async throws {
        try await add(1, "Twice")
        let scan = makeScan(["Twice": [result(3, "Twice"), result(4, "TWICE", author: "Other")]])
        scan.start(compareAll: true, forgetChoices: false)
        try await finish(scan)
        let id = SyncValues.key(1, "/1")
        await scan.pick(id, index: 1)
        XCTAssertEqual(scan.items.first?.changes.first?.options.first?.value, "Other")
        await scan.skip(id)
        scan.start(compareAll: true, forgetChoices: false)
        try await finish(scan)
        XCTAssertTrue(scan.items.isEmpty)
    }

    func testAPausedScanGoesOnWhereItStoppedEvenAfterARestart() async throws {
        try await add(1, "One")
        try await add(2, "Two")
        let results = ["One": [result(1, "One")], "Two": [result(2, "Two")]]
        let scan = makeScan(results)
        scan.start(compareAll: true, forgetChoices: false)
        for _ in 0..<100 where scan.progress.done == 0 { try await Task.sleep(for: .milliseconds(100)) }
        scan.pause()
        XCTAssertEqual(scan.progress.done, 1)
        XCTAssertTrue(scan.hasUnfinishedScan)

        let restarted = makeScan(results)
        XCTAssertEqual(restarted.items.count, 1)
        restarted.resume()
        try await finish(restarted)
        XCTAssertEqual(restarted.progress.done, 2)
        XCTAssertEqual(restarted.items.count, 2)
        XCTAssertFalse(restarted.hasUnfinishedScan)
    }

    func testADecisionFromAnotherDeviceClearsTheItem() async throws {
        try await add(1, "Nowhere")
        let scan = makeScan(["Nowhere": []])
        scan.start(compareAll: true, forgetChoices: false)
        try await finish(scan)
        XCTAssertEqual(scan.items.count, 1)
        memory.put(SyncValues.key(1, "/1"), .init(ignored: [TrackerFillRules.skipped: [TrackerFillRules.kept]]))
        await scan.load()
        XCTAssertTrue(scan.items.isEmpty)
    }
}

final class CurrentlyReadingTests: XCTestCase {
    func testTheBarHasAtMostThreeUnfinishedLibrarySeriesNewestFirst() async throws {
        let database = try AppDatabase.inMemory()
        // Series 1 to 4 are being read, 5 is finished and 6 isn't in the library; a higher id was read later.
        try await database.writer.write { db in
            for id in 1...6 {
                var series = SeriesRecord(id: id, source: 1, manga: SManga(url: "/\(id)", title: "S\(id)"))
                series.inLibrary = id != 6
                try series.insert(db)
                for number in 1...2 {
                    var chapter = Self.chapter(id * 10 + number, read: id == 5 || number == 1)
                    chapter.seriesId = id
                    chapter.readingOrder = number
                    chapter.url = "/\(id)/\(number)"
                    try chapter.insert(db)
                }
                try db.execute(
                    sql: "INSERT INTO history (chapterId, lastRead, timeRead) VALUES (?, ?, 0)",
                    arguments: [id * 10 + 1, Date(timeIntervalSince1970: Double(1_000 + id))]
                )
            }
        }
        var items: [ReadingItem] = []
        for try await value in database.currentlyReading() {
            items = value
            break
        }
        XCTAssertEqual(items.map(\.series.id), [4, 3, 2])
        XCTAssertEqual(items.first?.chapter.id, 42, "goes on to the next unread chapter")
        XCTAssertEqual(items.first?.readChapters, 1)
        XCTAssertEqual(items.first?.totalChapters, 2)
    }

    private static func chapter(_ id: Int, read: Bool) -> ChapterRecord {
        ChapterRecord(
            id: id, seriesId: 1, url: "/\(id)", name: "\(id)", number: Double(id), scanlator: nil, readingOrder: id, pages: 0, read: read,
            bookmark: false, lastPageRead: 0, dateUpload: nil, dateFetch: nil, isDownloaded: false, memo: nil
        )
    }

    func testResumeGoesOnFromTheLastChapterRead() {
        XCTAssertEqual(AppDatabase.resumeChapter([Self.chapter(1, read: true), Self.chapter(2, read: false), Self.chapter(3, read: false)], lastReadId: 2)?.id, 2)
        XCTAssertEqual(AppDatabase.resumeChapter([Self.chapter(1, read: false), Self.chapter(2, read: true), Self.chapter(3, read: false)], lastReadId: 2)?.id, 3)
        XCTAssertEqual(AppDatabase.resumeChapter([Self.chapter(1, read: false), Self.chapter(2, read: true)], lastReadId: 2)?.id, 1)
        XCTAssertNil(AppDatabase.resumeChapter([Self.chapter(1, read: true), Self.chapter(2, read: true)], lastReadId: 2))
    }
}
