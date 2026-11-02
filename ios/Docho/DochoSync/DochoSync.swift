import Foundation
import GRDB
import Observation
import os

// Dōchō Sync (Android's `docho.dochosync`): keeps the library and categories, chapter renames and
// types, read state and history the same on every device signed in to a Dōchō Sync server
// (`sync-server/` in the repository). Records and their keys match the Android app's, so phones
// and iPads on either platform share one account.

// MARK: - Settings

final class DochoSyncSettings: Sendable {
    let store: ServerSettings

    init(store: ServerSettings = ServerSettings(prefix: "docho_sync")) {
        self.store = store
    }

    var serverURL: String {
        get { store.string("server_url") }
        set { store.setString("server_url", newValue) }
    }

    var username: String {
        get { store.string("username") }
        set { store.setString("username", newValue) }
    }

    var password: String {
        get { store.secret("password") }
        set { store.setSecret("password", newValue) }
    }

    /// The server's sign-in for this device.
    var token: String {
        get { store.secret("token") }
        set { store.setSecret("token", newValue) }
    }

    var automatic: Bool {
        get { store.bool("automatic", default: true) }
        set { store.setBool("automatic", newValue) }
    }

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

    var isConfigured: Bool { !serverURL.isBlank && !username.isBlank && !password.isBlank }

    func reset() {
        store.reset(plain: ["server_url", "username", "since", "last_at", "last_error"], secret: ["password", "token"])
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

    /// A chapter's state on two devices put together, for a first sync: read anywhere is read.
    static func mergeChapter(local: SyncJSON, remote: SyncJSON) -> SyncJSON {
        chapter(
            mangaURL: remote["manga"]?.string ?? local["manga"]?.string ?? "",
            read: (local["read"]?.bool ?? false) || (remote["read"]?.bool ?? false),
            bookmark: (local["bookmark"]?.bool ?? false) || (remote["bookmark"]?.bool ?? false),
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

/// Talks to the Dōchō Sync server.
@MainActor
final class DochoSyncClient {
    private let settings: DochoSyncSettings
    private let session: URLSession
    private(set) var connection: DochoSyncConnection = .unknown {
        didSet { continuation.yield(connection) }
    }
    let changes: AsyncStream<DochoSyncConnection>
    private let continuation: AsyncStream<DochoSyncConnection>.Continuation

    init(settings: DochoSyncSettings, session: URLSession) {
        self.settings = settings
        self.session = session
        (changes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Signs in with the saved settings, or creates the account first if `register`.
    @discardableResult
    func signIn(register: Bool = false) async -> DochoSyncConnection {
        guard settings.isConfigured else { connection = .unknown; return connection }
        connection = .checking
        do {
            let body: [String: Any] = ["username": settings.username, "password": settings.password, "device": settings.deviceId]
            let response = try await post(register ? "register" : "login", body, authorized: false)
            settings.token = response["token"] as? String ?? ""
            connection = .connected(response["username"] as? String ?? settings.username)
        } catch {
            connection = .failed(error.localizedDescription)
        }
        return connection
    }

    /// Checks the saved sign-in still works, signing in again with the password if it doesn't.
    @discardableResult
    func checkConnection() async -> DochoSyncConnection {
        guard settings.isConfigured else { connection = .unknown; return connection }
        guard !settings.token.isEmpty else { return await signIn() }
        connection = .checking
        do {
            let me = try await send(request("me"))
            connection = .connected(me["username"] as? String ?? settings.username)
        } catch let error as DochoSyncError where error.signedOut {
            return await signIn()
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
        let response: [String: Any]
        do {
            response = try await post("sync", body, authorized: true)
        } catch let error as DochoSyncError where error.signedOut {
            guard case .connected = await signIn() else { throw error }
            response = try await post("sync", body, authorized: true)
        }
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

    private func post(_ path: String, _ body: [String: Any], authorized: Bool) async throws -> [String: Any] {
        var request = try request(path, authorized: authorized)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func request(_ path: String, authorized: Bool = true) throws -> URLRequest {
        guard let base = ServerAddress.normalize(settings.serverURL, apiPath: "/api/v1"), let url = URL(string: "\(base)/\(path)") else {
            throw DochoSyncError(message: String(localized: "No server address"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(ServerAddress.userAgent, forHTTPHeaderField: "User-Agent")
        if authorized { request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(status), let body { return body }
        let message = body?["error"] as? String ?? "HTTP \(status)"
        throw DochoSyncError(message: message, signedOut: status == 401)
    }
}

// MARK: - Engine

/// Runs a sync: works out what changed here by comparing every record with how it was when last
/// synced, sends that, and applies what other devices changed. The server keeps the newest write of
/// each record. The first sync of a device merges instead, so neither device's reading is lost.
@MainActor
@Observable
final class DochoSync {
    enum Status: Equatable {
        case idle, syncing
        case done(sent: Int, received: Int)
        case failed(String)
    }

    private(set) var status: Status = .idle
    @ObservationIgnored let settings: DochoSyncSettings
    @ObservationIgnored let client: DochoSyncClient
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let renames: ChapterRenames
    @ObservationIgnored private let refresh: @MainActor (SeriesRecord) async -> Void
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private var running: Task<Status, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.github.grillza.docho", category: "docho-sync")
    private static let batch = 5_000

    private struct State: Codable {
        var synced: [String: String] = [:]
        var pending: [String: SyncRecord] = [:]
    }

    init(
        settings: DochoSyncSettings, client: DochoSyncClient, database: AppDatabase, renames: ChapterRenames,
        stateURL: URL = URL.applicationSupportDirectory.appending(path: "docho-sync-state.json"),
        refresh: @escaping @MainActor (SeriesRecord) async -> Void
    ) {
        self.settings = settings
        self.client = client
        self.database = database
        self.renames = renames
        self.stateURL = stateURL
        self.refresh = refresh
    }

    var isEnabled: Bool { settings.isConfigured }

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
            if settings.token.isEmpty, case .failed(let reason) = await client.signIn() { throw DochoSyncError(message: reason) }
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
        repeat {
            let batch = Array(outgoing.prefix(Self.batch))
            outgoing = outgoing.dropFirst(batch.count)
            page = try await client.sync(since: since, changes: batch)
            remote += page.changes
            since = page.seq
        } while page.more || !outgoing.isEmpty
        for change in changes {
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
            state.synced[record.id] = after[record.id]?.value.canonical
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
        return records
    }

    // MARK: Applying

    private func applyAll(_ records: [SyncRecord], firstSync: Bool, added: inout [SeriesRecord]) async -> Set<String> {
        let order = [SyncValues.category, SyncValues.manga, SyncValues.rename, SyncValues.kind, SyncValues.chapter, SyncValues.history]
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
            let merged = firstSync
                ? SyncValues.mergeChapter(
                    local: SyncValues.chapter(mangaURL: "", read: chapter.read, bookmark: chapter.bookmark, page: Int64(chapter.lastPageRead)),
                    remote: value
                )
                : value
            let read = merged["read"]?.bool ?? false
            let bookmark = merged["bookmark"]?.bool ?? false
            let page = Int(merged["page"]?.int ?? 0)
            try await database.writer.write { db in
                try db.execute(
                    sql: "UPDATE chapter SET read = ?, bookmark = ?, lastPageRead = ? WHERE id = ?",
                    arguments: [read, bookmark, page, chapter.id]
                )
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
