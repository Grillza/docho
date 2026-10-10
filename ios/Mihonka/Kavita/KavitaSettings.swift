import Foundation
import Security
import Synchronization

/// Port of `KavitaPreferences.kt`. The server address lives in UserDefaults; the API key,
/// which grants full access to the Kavita account, lives in the Keychain.
final class KavitaSettings: Sendable {
    private static let serverURLKey = "kavita_server_url"
    private static let syncProgressKey = "kavita_sync_progress"

    /// UserDefaults is documented as thread-safe but isn't marked `Sendable`.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let keychain: KeychainItem
    /// The Keychain is read once; every request needs the key.
    private let apiKeyCache = Mutex<String?>(nil)

    init(defaults: UserDefaults = .standard, keychainService: String = "app.mihonka") {
        self.defaults = defaults
        self.keychain = KeychainItem(service: keychainService, account: "kavita_api_key")
    }

    /// Base address of the Kavita server as entered, e.g. `https://kavita.example.com`.
    var serverURL: String {
        get { defaults.string(forKey: Self.serverURLKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.serverURLKey) }
    }

    var apiKey: String {
        get {
            apiKeyCache.withLock { cached in
                if let cached { return cached }
                let stored = keychain.read() ?? ""
                cached = stored
                return stored
            }
        }
        set {
            apiKeyCache.withLock { cached in
                guard cached != newValue else { return }
                if newValue.isEmpty { keychain.delete() } else { keychain.write(newValue) }
                cached = newValue
            }
        }
    }

    /// Pushes reading progress to Kavita and pulls it back, page by page.
    var syncProgress: Bool {
        get { defaults.object(forKey: Self.syncProgressKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.syncProgressKey) }
    }

    var credentials: KavitaCredentials {
        KavitaCredentials(serverURL: serverURL, apiKey: apiKey)
    }
}

/// One generic-password Keychain item. Readable after first unlock, so background refresh can
/// deliver queued progress while the device is locked.
struct KeychainItem: Sendable {
    let service: String
    let account: String

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    func read() -> String? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    func write(_ value: String) {
        let attributes: [CFString: Any] = [
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
