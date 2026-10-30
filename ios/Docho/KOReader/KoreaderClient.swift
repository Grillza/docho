import CryptoKit
import Foundation
import Synchronization

/// Port of `KoreaderPreferences.kt`.
final class KoreaderSettings: Sendable {
    let store: ServerSettings

    init(store: ServerSettings = ServerSettings(prefix: "koreader")) {
        self.store = store
    }

    /// Address of the sync server as KOReader is given it, e.g.
    /// `http://bookorbit.lan:3010/api/v1/koreader` for BookOrbit.
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

    /// Identifies this install to the server, like KOReader's own device id.
    var deviceId: String {
        let stored = store.string("device_id")
        if !stored.isEmpty { return stored }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        store.setString("device_id", id)
        return id
    }

    var isConfigured: Bool { !serverURL.isBlank && !username.isBlank && !password.isBlank }

    /// Erases the server, sign-in and unsent progress. The device id and the document cache stay,
    /// as they belong to this install, not the server.
    func reset() {
        store.reset(plain: ["server_url", "username"], secret: ["password"])
    }

    /// Documents worked out for chapters, see `KoreaderDocumentCache`.
    var documentCache: String {
        get { store.string("document_cache") }
        set { store.setString("document_cache", newValue) }
    }
}

enum KoreaderError: LocalizedError, Equatable {
    case notConfigured
    case authRejected
    /// The server has no book for the document, such as a series missing from BookOrbit.
    case unknownDocument

    var errorDescription: String? {
        switch self {
        case .notConfigured: "KOReader sync is not set up. Add your server in Settings → Sync."
        case .authRejected: "The sync server rejected the username or password."
        case .unknownDocument: "The sync server doesn't have this file."
        }
    }
}

/// A kosync position. For paged documents such as CBZ, `progress` is the 1-based page number and
/// `percentage` how far into the document that page is, from 0 to 1.
struct KoreaderProgress: Codable, Sendable, Equatable {
    var document: String?
    var progress: String?
    var percentage: Double?
    var device: String?
    var deviceId: String?

    private enum CodingKeys: String, CodingKey {
        case document, progress, percentage, device
        case deviceId = "device_id"
    }

    /// Bodies must carry every field; kosync servers reject a progress update missing one.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(document, forKey: .document)
        try container.encode(progress, forKey: .progress)
        try container.encode(percentage, forKey: .percentage)
        try container.encode(device, forKey: .device)
        try container.encode(deviceId, forKey: .deviceId)
    }
}

/// Port of `KoreaderApi.kt`: a KOReader sync server (the kosync protocol), such as BookOrbit's
/// or KOReader's own. Every request carries the username and the MD5 of the password.
actor KoreaderClient {
    nonisolated let status = ConnectionStatus()
    private let session: URLSession
    private let settings: KoreaderSettings

    init(settings: KoreaderSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    @discardableResult
    func checkConnection() async -> ServerConnection {
        guard settings.isConfigured else {
            status.publish(.unknown)
            return .unknown
        }
        let snapshot = [settings.serverURL, settings.username, settings.password]
        status.publish(.checking)
        let result: ServerConnection
        do {
            _ = try await call(try request("users/auth"))
            result = .connected(settings.username)
        } catch {
            result = .failed(error.localizedDescription)
        }
        if snapshot == [settings.serverURL, settings.username, settings.password] { status.publish(result) }
        return result
    }

    /// The position the server has for a document, or nil if it has none.
    func progress(_ document: String) async throws -> KoreaderProgress? {
        let data = try await call(try request("syncs/progress/\(document)"))
        let progress = try? JSONDecoder().decode(KoreaderProgress.self, from: data)
        return progress.flatMap { $0.progress != nil || $0.percentage != nil ? $0 : nil }
    }

    /// Throws `KoreaderError.unknownDocument` when the server doesn't know the document.
    func updateProgress(_ progress: KoreaderProgress) async throws {
        var request = try request("syncs/progress")
        request.httpMethod = "PUT"
        request.httpBody = try JSONEncoder().encode(progress)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await call(request)
    }

    private func request(_ path: String) throws -> URLRequest {
        guard settings.isConfigured, let base = Self.normalizeBaseURL(settings.serverURL), let url = URL(string: "\(base)/\(path)") else {
            throw KoreaderError.notConfigured
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.koreader.v1+json", forHTTPHeaderField: "Accept")
        request.setValue(settings.username, forHTTPHeaderField: "x-auth-user")
        request.setValue(Self.md5(settings.password), forHTTPHeaderField: "x-auth-key")
        request.setValue(ServerAddress.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func call(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return data
        case 401, 403:
            status.publish(.failed(KoreaderError.authRejected.localizedDescription))
            throw KoreaderError.authRejected
        case 404 where request.httpMethod == "PUT": throw KoreaderError.unknownDocument
        default: throw HTTPError.status(code)
        }
    }

    /// Accepts a bare host or a URL with or without a trailing slash.
    static func normalizeBaseURL(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty else { return nil }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") { value = "http://" + value }
        guard let url = URL(string: value), url.host() != nil else { return nil }
        return value
    }

    static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// KOReader's document hash (`util.partialMD5`): the MD5 of 1 KiB samples taken at offset 0 and
/// at 1 KiB << 2i for i = 0…10, stopping at the end of the file. Servers such as BookOrbit and
/// Kavita store the same hash for each file, which is how a position finds its book.
enum KoreaderHash {
    static let blockSize = 1024

    /// Where the samples of a file of `size` bytes start.
    static func offsets(size: Int64) -> [Int64] {
        ([0] + (0...10).map { Int64(blockSize) << (2 * $0) }).filter { $0 < size }
    }

    /// Hashes a file through `read`, which returns up to `length` bytes from `offset` and the
    /// file's size. The first read is at offset 0.
    static func compute(read: @Sendable (Int64, Int) async throws -> (Data, Int64)) async throws -> String {
        var md5 = Insecure.MD5()
        let (first, size) = try await read(0, blockSize)
        md5.update(data: first)
        for offset in offsets(size: size).dropFirst() {
            md5.update(data: try await read(offset, blockSize).0)
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes a file that can only be read from the start, such as a download. Reading stops
    /// after the last sample, so only that much is transferred.
    static func compute<S: AsyncSequence & Sendable>(stream: S, size: Int64?) async throws -> String where S.Element == UInt8 {
        // Samples don't overlap and come in order, so one index follows them. A sample past the
        // end of a file of unknown size stays empty and adds nothing, as with KOReader.
        let wanted = offsets(size: size ?? .max)
        var samples = Array(repeating: Data(), count: wanted.count)
        var current = 0
        var position: Int64 = 0
        for try await byte in stream {
            while current < wanted.count, position >= wanted[current] + Int64(blockSize) { current += 1 }
            guard current < wanted.count else { break }
            if position >= wanted[current] { samples[current].append(byte) }
            position += 1
        }
        var md5 = Insecure.MD5()
        for sample in samples { md5.update(data: sample) }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes in-memory data (tests and local files).
    static func compute(data: Data) -> String {
        var md5 = Insecure.MD5()
        for offset in offsets(size: Int64(data.count)) {
            let start = Int(offset)
            md5.update(data: data[start..<min(start + blockSize, data.count)])
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A chapter's file as KOReader identifies it: its partial MD5 and page count.
struct KoreaderDocument: Codable, Sendable, Equatable {
    var hash: String
    var pages: Int
}

/// Documents that took requests to work out, kept across launches. Keys belong to the provider.
final class KoreaderDocumentCache: Sendable {
    private let settings: KoreaderSettings
    private let lock = Mutex(())

    init(settings: KoreaderSettings) {
        self.settings = settings
    }

    func get(_ key: String) -> KoreaderDocument? {
        lock.withLock { _ in read()[key] }
    }

    func put(_ key: String, _ document: KoreaderDocument) {
        lock.withLock { _ in
            var current = read()
            guard current[key] != document else { return }
            current[key] = document
            if let data = try? JSONEncoder().encode(current) { settings.documentCache = String(decoding: data, as: UTF8.self) }
        }
    }

    private func read() -> [String: KoreaderDocument] {
        let raw = settings.documentCache
        guard !raw.isEmpty else { return [:] }
        return (try? JSONDecoder().decode([String: KoreaderDocument].self, from: Data(raw.utf8))) ?? [:]
    }
}
