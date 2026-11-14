import Foundation
import GRDB
import Observation
import os

// Dōchō Sync (Android's `docho.dochosync`): keeps the library and categories, edited series
// details, chapter renames and types, read state and history the same on every device and Dōchō
// Server's web reader. It's built into Dōchō Server (`server/`, at /api/docho/sync/v1) and set up
// with it: the same address, and the server's own login if it has one. Records and their keys
// match the Android app's.

// MARK: - Settings

final class DochoSyncSettings: Sendable {
    let store: ServerSettings
    /// Dōchō Server's address and login (Settings → Dōchō Server / Suwayomi).
    let server: SuwayomiSettings

    init(store: ServerSettings = ServerSettings(prefix: "docho_sync"), server: SuwayomiSettings = SuwayomiSettings()) {
        self.store = store
        self.server = server
    }

    var serverURL: String { server.serverURL }
    /// The server's basic-auth login; empty when it has none.
    var username: String { server.username }
    var password: String { server.password }

    /// Whether to sync with the Dōchō Server set up under Dōchō Server / Suwayomi.
    var enabled: Bool {
        get { store.bool("enabled", default: true) }
        set { store.setBool("enabled", newValue) }
    }

    var automatic: Bool {
        get { store.bool("automatic", default: true) }
        set { store.setBool("automatic", newValue) }
    }

    /// Minutes between syncs while the app is open; one of `intervals`.
    var intervalMinutes: Int {
        get { Int(store.string("interval_minutes")) ?? 5 }
        set { store.setString("interval_minutes", String(newValue)) }
    }

    static let intervals = [1, 2, 5, 10, 15, 30, 60]

    /// The server's change number this device has caught up to; 0 until the first sync.
    var since: Int64 {
        get { Int64(store.string("since")) ?? 0 }
        set { store.setString("since", String(newValue)) }
    }

    var lastSyncAt: Double {
        get { Double(store.string("last_at")) ?? 0 }
        set { store.setString("last_at", String(newValue)) }
    }

    var lastError: String {
        get { store.string("last_error") }
        set { store.setString("last_error", newValue) }
    }

    var deviceId: String {
        let stored = store.string("device_id")
        if !stored.isEmpty { return stored }
        let id = UUID().uuidString.lowercased()
        store.setString("device_id", id)
        return id
    }

    var isConfigured: Bool { enabled && server.isConfigured }

    /// Which server the sync state belongs to: before `serverEpoch` it was the standalone sync
    /// server's, whose change numbers mean nothing to Dōchō Server. A device that synced with that
    /// one starts over with a first sync (which merges) the first time it syncs with Dōchō Server.
    var epoch: Int {
        get { Int(store.string("epoch")) ?? 0 }
        set { store.setString("epoch", String(newValue)) }
    }

    /// The sync state is Dōchō Server's (0.32.3).
    static let serverEpoch = 2

    /// Before 0.32.1 Dōchō Sync had its own server address and account. The address moves to
    /// Dōchō Server's settings if those are empty; the account isn't needed any more.
    func migrate() {
        let old = store.string("server_url")
        guard !old.isBlank else { return }
        if server.serverURL.isBlank { server.serverURL = old }
        store.reset(plain: ["server_url", "username"], secret: ["password", "token"])
    }

    func reset() {
        store.reset(plain: ["since", "last_at", "last_error"], secret: [])
    }
}

// MARK: - JSON values

/// A JSON value, kept exact so records compare the same way every time (`canonical`).
enum SyncJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([SyncJSON])
    case object([String: SyncJSON])

    init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.int64Value)
            }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { SyncJSON(any: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { SyncJSON(any: $0) })
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.any)
        case .object(let values): values.mapValues(\.any)
        }
    }

    /// Object keys sorted and nulls dropped, as text, for comparing records.
    var canonical: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value): value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .string(let value): Self.quote(value)
        case .array(let values): "[" + values.map(\.canonical).joined(separator: ",") + "]"
        case .object(let values):
            "{" + values.filter { $0.value != .null }.sorted { $0.key < $1.key }
                .map { Self.quote($0.key) + ":" + $0.value.canonical }.joined(separator: ",") + "}"
        }
    }

    subscript(key: String) -> SyncJSON? {
        if case .object(let values) = self { return values[key] }
        return nil
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool { if case .bool(let value) = self { value } else { false } }
    var int: Int64? {
        switch self {
        case .int(let value): value
        case .double(let value): Int64(value)
        default: nil
        }
    }
    var strings: [String] { if case .array(let values) = self { values.compactMap(\.string) } else { [] } }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension SyncJSON: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([SyncJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: SyncJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
}

/// One record as the server keeps it; `value` is nil once deleted.
struct SyncRecord: Codable, Equatable, Sendable {
    var kind: String
    var key: String
    var value: SyncJSON?
    var updatedAt: Int64
    var device: String?

    var isDeleted: Bool { value == nil || value == .null }
    var id: String { SyncValues.id(kind, key) }
}

/// The records both apps write (Android's `SyncValues`).
enum SyncValues {
    static let manga = "manga"
    static let category = "category"
    static let chapter = "chapter"
    static let history = "history"
    static let rename = "rename"
    static let kind = "kind"
    /// A series' edited details (`SeriesEdits`): only the edited fields, blank ones as "".
    static let details = "details"
    /// What the tracker fill remembers about a series (`TrackerFillMemory`).
    static let fill = "fill"

    static func key(_ source: Int64, _ url: String) -> String { "\(source)|\(url)" }
    static func id(_ kind: String, _ key: String) -> String { "\(kind)\t\(key)" }

    static func parseKey(_ key: String) -> (Int64, String)? {
        guard let bar = key.firstIndex(of: "|"), let source = Int64(key[..<bar]) else { return nil }
        return (source, String(key[key.index(after: bar)...]))
    }

    static func manga(title: String, categories: [String], addedAt: Int64) -> SyncJSON {
        .object([
            "addedAt": .int(addedAt), "categories": .array(Array(Set(categories)).sorted().map(SyncJSON.string)),
            "title": .string(title),
        ])
    }

    static func chapter(mangaURL: String, read: Bool, bookmark: Bool, page: Int64) -> SyncJSON {
        .object(["bookmark": .bool(bookmark), "manga": .string(mangaURL), "page": .int(read ? 0 : page), "read": .bool(read)])
    }

    static func history(mangaURL: String, readAt: Int64) -> SyncJSON {
        .object(["manga": .string(mangaURL), "readAt": .int(readAt)])
    }

    static func rename(name: String, number: Double, original: String?, at: Int64, mangaURL: String?) -> SyncJSON {
        .object([
            "at": .int(at), "manga": mangaURL.map(SyncJSON.string) ?? .null, "name": .string(name),
            "number": .string(Self.number(number)), "original": original.map(SyncJSON.string) ?? .null,
        ])
    }

    static func kind(_ kind: String, mangaURL: String?) -> SyncJSON {
        .object(["kind": .string(kind), "manga": mangaURL.map(SyncJSON.string) ?? .null])
    }

    /// "10" or "119.1", as the Android app writes them.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    /// A chapter's state here and on the server put together, keeping the furthest point: read
    /// anywhere is read, and the further page is kept. The bookmark is `remote`'s when
    /// `remoteBookmark`, else bookmarked on either is bookmarked (a first sync).
    static func mergeChapter(local: SyncJSON, remote: SyncJSON, remoteBookmark: Bool = false) -> SyncJSON {
        chapter(
            mangaURL: remote["manga"]?.string ?? local["manga"]?.string ?? "",
            read: (local["read"]?.bool ?? false) || (remote["read"]?.bool ?? false),
            bookmark: remoteBookmark
                ? (remote["bookmark"]?.bool ?? false)
                : (local["bookmark"]?.bool ?? false) || (remote["bookmark"]?.bool ?? false),
            page: max(local["page"]?.int ?? 0, remote["page"]?.int ?? 0)
        )
    }

    /// What changed here since the last sync (Android's `syncChanges`).
    static func changes(
        current: [String: (kind: String, value: SyncJSON)], synced: [String: String], pending: Set<String>, now: Int64
    ) -> [SyncRecord] {
        var changes: [SyncRecord] = []
        for (id, entry) in current where !pending.contains(id) && synced[id] != entry.value.canonical {
            changes.append(SyncRecord(kind: entry.kind, key: String(id.drop { $0 != "\t" }.dropFirst()), value: entry.value, updatedAt: now))
        }
        for id in synced.keys where current[id] == nil && !pending.contains(id) {
            let kind = String(id.prefix { $0 != "\t" })
            changes.append(SyncRecord(kind: kind, key: String(id.drop { $0 != "\t" }.dropFirst()), value: nil, updatedAt: now))
        }
        return changes
    }
}

// MARK: - Client

enum DochoSyncConnection: Equatable, Sendable {
    case unknown, checking
    case connected(String)
    case failed(String)
}

struct DochoSyncError: LocalizedError {
    var message: String
    var signedOut = false
    var errorDescription: String? { message }
}

struct SyncPage: Sendable {
    var seq: Int64
    var more: Bool
    var changes: [SyncRecord]
}

/// Talks to the Dōchō Sync built into Dōchō Server, through the server's own authentication.
@MainActor
final class DochoSyncClient {
    private let settings: DochoSyncSettings
    private let session: URLSession
    private(set) var connection: DochoSyncConnection = .unknown {
        didSet { continuation.yield(connection) }
    }
    let changes: AsyncStream<DochoSyncConnection>
    private let continuation: AsyncStream<DochoSyncConnection>.Continuation
    /// Whether the server at an address has Dōchō Sync (a Dōchō Server, not a plain Suwayomi).
    private var probed: [String: Bool] = [:]

    init(settings: DochoSyncSettings, session: URLSession) {
        self.settings = settings
        self.session = session
        (changes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Whether the configured server is a Dōchō Server; asked once per address (and again after a failure).
    func isDochoServer() async -> Bool {
        guard let base = base else { return false }
        if let known = probed[base] { return known }
        guard let url = URL(string: "\(base)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(ServerAddress.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request) else { return false }
        let ok = (response as? HTTPURLResponse)?.statusCode == 200
            && ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["name"] != nil
        probed[base] = ok
        return ok
    }

    /// Checks the server has Dōchō Sync and lets this device in.
    @discardableResult
    func checkConnection() async -> DochoSyncConnection {
        guard settings.isConfigured else { connection = .unknown; return connection }
        connection = .checking
        probed[base ?? ""] = nil
        guard await isDochoServer() else {
            connection = .failed(String(localized: "This server has no Dōchō Sync. Update it to Dōchō Server to sync."))
            return connection
        }
        do {
            let me = try await send(try request("me"))
            connection = .connected(me["username"] as? String ?? "")
        } catch {
            connection = .failed(error.localizedDescription)
        }
        return connection
    }

    func sync(since: Int64, changes: [SyncRecord]) async throws -> SyncPage {
        let body: [String: Any] = [
            "since": since, "device": settings.deviceId,
            "changes": changes.map { ["kind": $0.kind, "key": $0.key, "value": $0.value?.any ?? NSNull(), "updatedAt": $0.updatedAt] },
        ]
        guard await isDochoServer() else {
            throw DochoSyncError(message: String(localized: "This server has no Dōchō Sync. Update it to Dōchō Server to sync."))
        }
        let response = try await post("sync", body)
        let records = (response["changes"] as? [[String: Any]] ?? []).compactMap { change -> SyncRecord? in
            guard let kind = change["kind"] as? String, let key = change["key"] as? String else { return nil }
            let value = SyncJSON(any: change["value"])
            return SyncRecord(
                kind: kind, key: key, value: value == .null ? nil : value,
                updatedAt: (change["updatedAt"] as? NSNumber)?.int64Value ?? 0, device: change["device"] as? String
            )
        }
        return SyncPage(seq: (response["seq"] as? NSNumber)?.int64Value ?? since, more: response["more"] as? Bool ?? false, changes: records)
    }

    private var base: String? { ServerAddress.normalize(settings.serverURL, apiPath: "/api/docho/sync/v1") }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = try request(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func request(_ path: String) throws -> URLRequest {
        guard let base, let url = URL(string: "\(base)/\(path)") else {
            throw DochoSyncError(message: String(localized: "No server address"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(ServerAddress.userAgent, forHTTPHeaderField: "User-Agent")
        // The server's own login, as for its sources (basic authentication).
        if !settings.username.isEmpty {
            let credentials = Data("\(settings.username):\(settings.password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(status), let body { return body }
        if status == 401 {
            throw DochoSyncError(message: String(localized: "The server's username or password is wrong (Dōchō Server / Suwayomi)"), signedOut: true)
        }
        throw DochoSyncError(message: body?["error"] as? String ?? "HTTP \(status)")
    }
}

// MARK: - Engine

/// Runs a sync: works out what changed here by comparing every record with how it was when last
/// synced, sends that, and applies what other devices changed. The server keeps the newest write of
/// each record, except reading progress, where the furthest point is kept: progress sent is put
/// together with the server's, and progress coming down with this device's, so an app that's behind
/// (after an update, say) takes the server's rather than undoing it. The first sync of a device
/// merges too, so neither device's reading is lost.
@MainActor
@Observable
final class DochoSync {
    enum Status: Equatable {
        case idle, syncing
        case done(sent: Int, received: Int)
        case failed(String)
    }

    /// Reading another device did on a chapter, as it's applied here.
    struct RemoteProgress: Sendable {
        var chapterId: Int
        var page: Int
        var read: Bool
    }

    private(set) var status: Status = .idle
    /// So an open reader doesn't later write its older page over what arrived.
    @ObservationIgnored var onRemoteProgress: (@MainActor (RemoteProgress) -> Void)?
    @ObservationIgnored let settings: DochoSyncSettings
    @ObservationIgnored let client: DochoSyncClient
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let renames: ChapterRenames
    @ObservationIgnored private let seriesEdits: SeriesEdits
    @ObservationIgnored private let trackerFillMemory: TrackerFillMemory
    @ObservationIgnored private let refresh: @MainActor (SeriesRecord) async -> Void
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private var running: Task<Status, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.github.grillza.docho", category: "docho-sync")
    private static let batch = 5_000
    /// Reading progress, where the furthest point is kept.
    private static let progress: Set<String> = [SyncValues.chapter, SyncValues.history]

    private struct State: Codable {
        var synced: [String: String] = [:]
        var pending: [String: SyncRecord] = [:]
    }

    init(
        settings: DochoSyncSettings, client: DochoSyncClient, database: AppDatabase, renames: ChapterRenames,
        seriesEdits: SeriesEdits? = nil,
        trackerFillMemory: TrackerFillMemory? = nil,
        stateURL: URL = URL.applicationSupportDirectory.appending(path: "docho-sync-state.json"),
        refresh: @escaping @MainActor (SeriesRecord) async -> Void
    ) {
        self.settings = settings
        self.client = client
        self.database = database
        self.renames = renames
        self.seriesEdits = seriesEdits ?? SeriesEdits(defaults: UserDefaults(suiteName: "docho-series-edits-\(UUID().uuidString)")!)
        self.trackerFillMemory = trackerFillMemory ?? TrackerFillMemory(defaults: UserDefaults(suiteName: "docho-tracker-fill-\(UUID().uuidString)")!)
        self.stateURL = stateURL
        self.refresh = refresh
    }

    var isEnabled: Bool { settings.isConfigured }
    var syncsAutomatically: Bool { settings.isConfigured && settings.automatic }
    /// If the last sync failed, the server may be out of reach and isn't worth waiting for.
    var lastSyncWorked: Bool { settings.lastError.isEmpty }

    /// Syncs every so often until cancelled, which is while the app is open. A sync that just happened
    /// for another reason (such as reading) counts, so reading doesn't add any syncs. Checks each
    /// minute, so a changed setting applies soon.
    func syncWhileOpen() async {
        var lastAsked = Date().timeIntervalSince1970
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, syncsAutomatically else { continue }
            let now = Date().timeIntervalSince1970
            if now - max(lastAsked, settings.lastSyncAt) >= Double(settings.intervalMinutes * 60) {
                lastAsked = now
                await sync()
            }
        }
    }

    @ObservationIgnored private var soon: Task<Void, Never>?

    /// Syncs a few seconds after something changed here, such as the page being read, so other
    /// devices and Dōchō Server see it while you read. Changes made before then go in the same
    /// sync. Only while syncing is automatic.
    func syncSoon(after seconds: Double = 15) {
        guard settings.isConfigured, settings.automatic, soon == nil else { return }
        soon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.soon = nil
            await self?.sync()
        }
    }

    /// Syncs now in the background, while syncing is automatic: when a series or the reader opens
    /// or closes.
    func syncInBackground() {
        guard settings.isConfigured, settings.automatic else { return }
        Task { await sync() }
    }

    /// Syncs now; a sync already running is waited for instead of starting another.
    @discardableResult
    func sync() async -> Status {
        guard settings.isConfigured else { return .idle }
        if let running { return await running.value }
        let task = Task { await self.runGuarded() }
        running = task
        let result = await task.value
        running = nil
        return result
    }

    /// Forgets what was synced, so the next sync is a first sync; for a new server or account.
    func resetState() {
        try? FileManager.default.removeItem(at: stateURL)
        settings.since = 0
    }

    private func runGuarded() async -> Status {
        status = .syncing
        let result: Status
        do {
            // State from the standalone sync server: start over here with a first sync.
            if settings.epoch < DochoSyncSettings.serverEpoch {
                resetState()
                settings.epoch = DochoSyncSettings.serverEpoch
            }
            result = try await run()
            settings.lastSyncAt = Date().timeIntervalSince1970
            settings.lastError = ""
        } catch {
            log.warning("Dōchō Sync failed: \(error)")
            settings.lastError = error.localizedDescription
            result = .failed(error.localizedDescription)
        }
        status = result
        return result
    }

    private func run() async throws -> Status {
        var state = loadState()
        let me = settings.deviceId
        let firstSync = settings.since == 0 && state.synced.isEmpty
        var since = settings.since
        var added: [SeriesRecord] = []
        var received = 0

        for id in await applyAll(Array(state.pending.values), firstSync: false, added: &added) { state.pending[id] = nil }

        if firstSync {
            var remote: [SyncRecord] = []
            var page: SyncPage
            repeat {
                page = try await client.sync(since: since, changes: [])
                remote += page.changes
                since = page.seq
            } while page.more
            let live = remote.filter { !$0.isDeleted }
            received += live.count
            let applied = await applyAll(live, firstSync: true, added: &added)
            for record in live where !applied.contains(record.id) { state.pending[record.id] = record }
            await refreshAdded(added)
            added = []
            var none: [SeriesRecord] = []
            for id in await applyAll(Array(state.pending.values), firstSync: true, added: &none) { state.pending[id] = nil }
            let current = try await snapshot()
            for record in live {
                if let here = current[record.id], here.value.canonical == record.value?.canonical {
                    state.synced[record.id] = here.value.canonical
                }
            }
        }

        let current = try await snapshot()
        let changes = SyncValues.changes(
            current: current, synced: state.synced, pending: Set(state.pending.keys), now: Int64(Date().timeIntervalSince1970 * 1000)
        )
        var remote: [SyncRecord] = []
        var outgoing = changes[...]
        var page: SyncPage
        // Kinds an older server doesn't take yet ("details" before 0.32), kept for a later sync.
        var unsent = Set<String>()
        repeat {
            let batch = Array(outgoing.prefix(Self.batch))
            outgoing = outgoing.dropFirst(batch.count)
            var sending = batch
            while true {
                do {
                    page = try await client.sync(since: since, changes: sending)
                    break
                } catch let error as DochoSyncError {
                    guard let kind = Set(sending.map(\.kind)).first(where: { error.message.hasPrefix("Unknown kind: \($0)") }) else { throw error }
                    unsent.formUnion(sending.filter { $0.kind == kind }.map(\.id))
                    sending = sending.filter { $0.kind != kind }
                }
            }
            remote += page.changes
            since = page.seq
        } while page.more || !outgoing.isEmpty
        for change in changes where !unsent.contains(change.id) {
            if change.isDeleted { state.synced[change.id] = nil } else { state.synced[change.id] = change.value?.canonical }
        }

        // What other devices changed; ours come back too where they won, and are skipped
        var latest: [String: SyncRecord] = [:]
        for record in remote where record.device != me { latest[record.id] = record }
        let theirs = Array(latest.values)
        received += theirs.count
        let applied = await applyAll(theirs, firstSync: false, added: &added)
        await refreshAdded(added)
        for record in theirs {
            if !applied.contains(record.id) && !record.isDeleted { state.pending[record.id] = record } else { state.pending[record.id] = nil }
        }
        var none: [SeriesRecord] = []
        for id in await applyAll(Array(state.pending.values), firstSync: false, added: &none) { state.pending[id] = nil }
        let after = try await snapshot()
        for record in theirs where state.pending[record.id] == nil {
            if after[record.id] != nil, Self.progress.contains(record.kind), let value = record.value, !record.isDeleted {
                // What the server has: where this device kept further progress, it differs and goes up next sync.
                state.synced[record.id] = value.canonical
            } else {
                state.synced[record.id] = after[record.id]?.value.canonical
            }
        }

        saveState(state)
        settings.since = since
        return .done(sent: changes.count, received: received)
    }

    // MARK: Snapshot

    private func snapshot() async throws -> [String: (kind: String, value: SyncJSON)] {
        let data = try await database.writer.read { db in try SyncSnapshotData.fetch(db) }
        var records: [String: (kind: String, value: SyncJSON)] = [:]
        func put(_ kind: String, _ key: String, _ value: SyncJSON) { records[SyncValues.id(kind, key)] = (kind, value) }

        for name in data.categories { put(SyncValues.category, name, .object([:])) }
        var mangaURLByChapter: [String: String] = [:]
        for series in data.series {
            put(SyncValues.manga, SyncValues.key(series.source, series.url), SyncValues.manga(
                title: series.name, categories: data.seriesCategories[series.id] ?? [],
                addedAt: Int64((series.dateAdded?.timeIntervalSince1970 ?? 0) * 1000)
            ))
        }
        let seriesById = Dictionary(uniqueKeysWithValues: data.series.map { ($0.id, $0) })
        for chapter in data.chapters {
            guard let series = seriesById[chapter.seriesId] else { continue }
            let key = SyncValues.key(series.source, chapter.url)
            mangaURLByChapter[key] = series.url
            put(SyncValues.chapter, key, SyncValues.chapter(
                mangaURL: series.url, read: chapter.read, bookmark: chapter.bookmark, page: Int64(chapter.lastPageRead)
            ))
            if let lastRead = data.history[chapter.id] {
                put(SyncValues.history, key, SyncValues.history(mangaURL: series.url, readAt: Int64(lastRead.timeIntervalSince1970 * 1000)))
            }
        }
        for (key, rename) in renames.renames {
            put(SyncValues.rename, key, SyncValues.rename(
                name: rename.name, number: rename.number, original: rename.original, at: Int64(rename.at ?? 0),
                mangaURL: mangaURLByChapter[key]
            ))
        }
        for (key, kind) in renames.kinds {
            put(SyncValues.kind, key, SyncValues.kind(kind, mangaURL: mangaURLByChapter[key]))
        }
        for (key, details) in seriesEdits.edits where !details.isEmpty {
            put(SyncValues.details, key, details.json)
        }
        for (key, memory) in trackerFillMemory.all {
            put(SyncValues.fill, key, memory.json)
        }
        return records
    }

    // MARK: Applying

    private func applyAll(_ records: [SyncRecord], firstSync: Bool, added: inout [SeriesRecord]) async -> Set<String> {
        let order = [SyncValues.category, SyncValues.manga, SyncValues.details, SyncValues.rename, SyncValues.kind, SyncValues.chapter, SyncValues.history]
        var applied = Set<String>()
        for record in records.sorted(by: { (order.firstIndex(of: $0.kind) ?? 9) < (order.firstIndex(of: $1.kind) ?? 9) }) {
            do {
                if try await apply(record, firstSync: firstSync, added: &added) { applied.insert(record.id) }
            } catch {
                log.warning("Dōchō Sync couldn't apply \(record.kind) \(record.key): \(error)")
            }
        }
        return applied
    }

    private func apply(_ record: SyncRecord, firstSync: Bool, added: inout [SeriesRecord]) async throws -> Bool {
        let value = record.isDeleted ? nil : record.value
        switch record.kind {
        case SyncValues.category:
            let categories = try await database.categoryList()
            if value == nil {
                if !firstSync, let category = categories.first(where: { $0.name == record.key }) {
                    try await database.deleteCategory(category.id)
                }
            } else if !categories.contains(where: { $0.name == record.key }) {
                try await database.createCategory(record.key)
            }
            return true
        case SyncValues.manga:
            return try await applySeries(record.key, value, firstSync: firstSync, added: &added)
        case SyncValues.chapter:
            guard let value else { return true }
            guard let chapter = try await findChapter(record.key, mangaURL: value["manga"]?.string) else { return false }
            // Never goes back: where this device is further, it keeps its own and sends it next sync.
            let merged = SyncValues.mergeChapter(
                local: SyncValues.chapter(mangaURL: "", read: chapter.read, bookmark: chapter.bookmark, page: Int64(chapter.lastPageRead)),
                remote: value,
                remoteBookmark: !firstSync
            )
            let read = merged["read"]?.bool ?? false
            let bookmark = merged["bookmark"]?.bool ?? false
            let page = Int(merged["page"]?.int ?? 0)
            try await database.writer.write { db in
                try db.execute(
                    sql: "UPDATE chapter SET read = ?, bookmark = ?, lastPageRead = ? WHERE id = ?",
                    arguments: [read, bookmark, page, chapter.id]
                )
            }
            if read != chapter.read || page != chapter.lastPageRead {
                onRemoteProgress?(RemoteProgress(chapterId: chapter.id, page: page, read: read))
            }
            return true
        case SyncValues.history:
            guard let value else { return true }
            guard let chapter = try await findChapter(record.key, mangaURL: value["manga"]?.string) else { return false }
            guard let readAt = value["readAt"]?.int else { return true }
            let date = Date(timeIntervalSince1970: Double(readAt) / 1000)
            try await database.writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO history (chapterId, lastRead, timeRead) VALUES (?, ?, 0)
                        ON CONFLICT(chapterId) DO UPDATE SET lastRead = MAX(lastRead, excluded.lastRead)
                        """,
                    arguments: [chapter.id, date]
                )
            }
            return true
        case SyncValues.rename:
            guard let (source, url) = SyncValues.parseKey(record.key) else { return true }
            guard let value, let name = value["name"]?.string else {
                renames.remove(source: source, url: url)
                return true
            }
            let number = Double(value["number"]?.string ?? "") ?? -1
            renames.put(
                source: source, oldURL: url, newURL: url,
                .init(name: name, number: number, original: value["original"]?.string, at: value["at"]?.int.map(Double.init))
            )
            if let chapter = try await findChapter(record.key, mangaURL: value["manga"]?.string) {
                try await database.renameChapter(id: chapter.id, url: chapter.url, name: name, number: number, memo: chapter.chapterMemo)
            }
            return true
        case SyncValues.kind:
            guard let (source, url) = SyncValues.parseKey(record.key) else { return true }
            guard let kind = value?["kind"]?.string else {
                renames.removeKind(source: source, url: url)
                return true
            }
            renames.putKind(source: source, url: url, kind)
            if let chapter = try await findChapter(record.key, mangaURL: value?["manga"]?.string) {
                var memo = chapter.chapterMemo
                memo[ChapterMemo.kind] = .string(kind)
                try await database.renameChapter(id: chapter.id, url: chapter.url, name: chapter.name, number: chapter.number, memo: memo)
            }
            return true
        case SyncValues.fill:
            trackerFillMemory.put(record.key, value.map(TrackerFillMemory.Memory.init(json:)))
            return true
        case SyncValues.details:
            guard let (source, url) = SyncValues.parseKey(record.key) else { return true }
            // Kept even for series not here yet: they take the edits when they're added.
            let details = value.map(SeriesEdits.Details.init(json:))
            seriesEdits.put(source: source, url: url, details)
            // Unlocked fields come back from the source on its next refresh.
            guard let details else { return true }
            try await database.writer.write { db in
                guard var series = try SeriesRecord
                    .filter(SeriesRecord.Columns.source == source && SeriesRecord.Columns.url == url).fetchOne(db) else { return }
                SeriesEdits.write(details, to: &series)
                try series.update(db)
            }
            return true
        default:
            return true
        }
    }

    private func applySeries(_ key: String, _ value: SyncJSON?, firstSync: Bool, added: inout [SeriesRecord]) async throws -> Bool {
        guard let (source, url) = SyncValues.parseKey(key) else { return true }
        let existing = try await database.writer.read { db in
            try SeriesRecord.filter(SeriesRecord.Columns.source == source && SeriesRecord.Columns.url == url).fetchOne(db)
        }
        guard let value else {
            if !firstSync, let existing, existing.inLibrary { try await database.setInLibrary(seriesId: existing.id, false) }
            return true
        }
        var names = value["categories"]?.strings ?? []
        if firstSync, let existing {
            let here = try await database.categoryIds(seriesId: existing.id)
            let all = try await database.categoryList()
            names += all.filter { here.contains($0.id) }.map(\.name)
        }
        var categories = try await database.categoryList()
        for name in Set(names) where !categories.contains(where: { $0.name == name }) { try await database.createCategory(name) }
        categories = try await database.categoryList()
        let ids = Set(names).compactMap { name in categories.first { $0.name == name }?.id }
        let addedAt = value["addedAt"]?.int.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1000) : nil } ?? Date()
        let title = value["title"]?.string ?? ""
        let series = try await database.writer.write { db -> (SeriesRecord, Bool) in
            var record = try existing ?? AppDatabase.localSeries(db, source: source, manga: SManga(url: url, title: title))
            let wasIn = record.inLibrary
            let hasChapters = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chapter WHERE seriesId = ?", arguments: [record.id]) ?? 0 > 0
            if !record.inLibrary {
                record.inLibrary = true
                record.dateAdded = addedAt
                try record.update(db)
            }
            return (record, !wasIn && !hasChapters)
        }
        try await database.setCategories(seriesIds: [series.0.id], categories: ids)
        if series.1 { added.append(series.0) }
        return true
    }

    private func refreshAdded(_ added: [SeriesRecord]) async {
        var seen = Set<Int>()
        for series in added where seen.insert(series.id).inserted {
            await refresh(series)
        }
    }

    private func findChapter(_ key: String, mangaURL: String?) async throws -> ChapterRecord? {
        guard let (source, url) = SyncValues.parseKey(key), let mangaURL else { return nil }
        return try await database.writer.read { db in
            try ChapterRecord.fetchOne(db, sql: """
                SELECT chapter.* FROM chapter JOIN series ON series.id = chapter.seriesId
                WHERE series.source = ? AND series.url = ? AND chapter.url = ?
                """, arguments: [source, mangaURL, url])
        }
    }

    private func loadState() -> State {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    private func saveState(_ state: State) {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }
}

/// Everything a snapshot needs, read in one go.
private struct SyncSnapshotData: Sendable {
    var categories: [String]
    var series: [SeriesRecord]
    var seriesCategories: [Int: [String]]
    var chapters: [ChapterRecord]
    var history: [Int: Date]

    static func fetch(_ db: Database) throws -> SyncSnapshotData {
        let categories = try CategoryRecord.fetchAll(db)
        let names = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        let series = try SeriesRecord.filter(SeriesRecord.Columns.inLibrary).fetchAll(db)
        var seriesCategories: [Int: [String]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT seriesId, categoryId FROM seriesCategory") {
            let seriesId: Int = row["seriesId"]
            let categoryId: Int = row["categoryId"]
            if let name = names[categoryId] { seriesCategories[seriesId, default: []].append(name) }
        }
        let chapters = try ChapterRecord.fetchAll(
            db, sql: "SELECT chapter.* FROM chapter JOIN series ON series.id = chapter.seriesId WHERE series.inLibrary = 1"
        )
        var history: [Int: Date] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT history.chapterId, history.lastRead FROM history
            JOIN chapter ON chapter.id = history.chapterId JOIN series ON series.id = chapter.seriesId
            WHERE series.inLibrary = 1
            """) {
            history[row["chapterId"]] = row["lastRead"]
        }
        return SyncSnapshotData(
            categories: categories.map(\.name), series: series, seriesCategories: seriesCategories, chapters: chapters, history: history
        )
    }
}
