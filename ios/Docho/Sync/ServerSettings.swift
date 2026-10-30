import Foundation
import Synchronization

/// One server's settings: plain values in UserDefaults, secrets (API keys, passwords, tokens) in
/// the Keychain, cached in memory since every request needs them.
final class ServerSettings: Sendable {
    nonisolated(unsafe) private let defaults: UserDefaults
    private let keychainService: String
    private let prefix: String
    private let secrets = Mutex<[String: String]>([:])

    /// `prefix` is Android's preference prefix, such as "komga" for `komga_server_url`.
    init(prefix: String, defaults: UserDefaults = .standard, keychainService: String = "io.github.grillza.docho") {
        self.prefix = prefix
        self.defaults = defaults
        self.keychainService = keychainService
    }

    func string(_ key: String) -> String {
        defaults.string(forKey: "\(prefix)_\(key)") ?? ""
    }

    func setString(_ key: String, _ value: String) {
        defaults.set(value, forKey: "\(prefix)_\(key)")
    }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: "\(prefix)_\(key)") as? Bool ?? fallback
    }

    func setBool(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: "\(prefix)_\(key)")
    }

    func secret(_ key: String) -> String {
        secrets.withLock { cache in
            if let cached = cache[key] { return cached }
            let stored = item(key).read() ?? ""
            cache[key] = stored
            return stored
        }
    }

    func setSecret(_ key: String, _ value: String) {
        secrets.withLock { cache in
            guard cache[key] != value else { return }
            if value.isEmpty { item(key).delete() } else { item(key).write(value) }
            cache[key] = value
        }
    }

    /// Erases these keys (Delete in a server's settings section).
    func reset(plain: [String], secret: [String]) {
        for key in plain { defaults.removeObject(forKey: "\(prefix)_\(key)") }
        for key in secret { setSecret(key, "") }
    }

    private func item(_ key: String) -> KeychainItem {
        KeychainItem(service: keychainService, account: "\(prefix)_\(key)")
    }
}

/// Outcome of the latest connection check of a server, shown as its status in Settings.
enum ServerConnection: Sendable, Equatable {
    /// No server configured, or not checked yet.
    case unknown
    case checking
    case connected(String)
    case failed(String)
}

/// A connection status that screens can follow. Each `changes` gets its own stream, starting
/// with the latest value.
final class ConnectionStatus: Sendable {
    private struct State {
        var latest = ServerConnection.unknown
        var subscribers: [UUID: AsyncStream<ServerConnection>.Continuation] = [:]
    }

    private let state = Mutex(State())

    init() {}

    var value: ServerConnection { state.withLock { $0.latest } }

    var changes: AsyncStream<ServerConnection> {
        let (stream, continuation) = AsyncStream<ServerConnection>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { state in
            continuation.yield(state.latest)
            state.subscribers[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    func publish(_ connection: ServerConnection) {
        let subscribers = state.withLock { state in
            state.latest = connection
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.yield(connection) }
    }
}

enum HTTPError: LocalizedError, Equatable {
    case status(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .status(let code): "HTTP \(code)"
        case .message(let text): text
        }
    }
}

extension URLSession {
    /// Data for a request, failing on anything but 2xx.
    func checkedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError.status(http.statusCode) }
        return (data, http)
    }
}
