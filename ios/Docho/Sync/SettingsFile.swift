import CommonCrypto
import CryptoKit
import Foundation

/// Port of Android's `SyncSettingsFile` (0.25): the Sync / Self-hosted sources settings, and how
/// often to back up, as a JSON file to set up another device the same way. With a password the
/// settings are encrypted (AES-256-GCM, key from PBKDF2-HMAC-SHA256 at 600,000 rounds), and one
/// is needed to include sign-in details. Files move between the Android and iOS apps: the format
/// and the keys (Android's preference keys) are the same.
///
/// What belongs to this install alone (unsent progress, the KOReader device id) stays behind.
@MainActor
struct SettingsFile {
    static let fileName = "docho-sync-settings.json"
    static let minimumPassword = 8

    private static let format = "docho-sync-settings"
    private static let versionPlain = 1
    private static let versionEncrypted = 2
    private static let iterations = 600_000
    private static let maxIterations = 5_000_000
    // Ties the encrypted data to this kind of file.
    private static var associatedData: Data { Data("\(format)/\(versionEncrypted)".utf8) }

    let app: AppModel

    enum FileError: LocalizedError, Equatable {
        case invalid
        case passwordRequired
        case wrongPassword

        var errorDescription: String? {
            switch self {
            case .invalid: String(localized: "That isn't a Dōchō settings file")
            case .passwordRequired: String(localized: "The settings file is encrypted")
            case .wrongPassword: String(localized: "Wrong password")
            }
        }
    }

    /// One setting: Android's preference key, whether it's a secret, and how to read and write it.
    private struct Entry {
        let key: String
        let secret: Bool
        let read: () -> Any
        /// Sets the value, returning whether it was one this setting takes.
        let write: (Any) -> Bool
    }

    private var entries: [Entry] {
        let kavita = app.settings
        let komga = app.komgaSettings
        let bookOrbit = app.bookOrbitSettings
        let koreader = app.koreaderSettings
        let sync = app.syncSettings
        let suwayomi = app.suwayomiSettings
        func text(_ key: String, secret: Bool = false, _ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> Entry {
            Entry(key: key, secret: secret, read: get) { value in
                guard let value = value as? String else { return false }
                set(value)
                return true
            }
        }
        func flag(_ key: String, _ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> Entry {
            Entry(key: key, secret: false, read: get) { value in
                guard let value = value as? Bool else { return false }
                set(value)
                return true
            }
        }
        return [
            text("kavita_server_url", { kavita.serverURL }, { kavita.serverURL = $0 }),
            text("__PRIVATE_kavita_api_key", secret: true, { kavita.apiKey }, { kavita.apiKey = $0 }),
            flag("kavita_sync_progress", { kavita.syncProgress }, { kavita.syncProgress = $0 }),
            text("bookorbit_server_url", { bookOrbit.serverURL }, { bookOrbit.serverURL = $0 }),
            text("bookorbit_username", { bookOrbit.username }, { bookOrbit.username = $0 }),
            text("__PRIVATE_bookorbit_password", secret: true, { bookOrbit.password }, { bookOrbit.password = $0 }),
            flag("bookorbit_sync_progress", { bookOrbit.syncProgress }, { bookOrbit.syncProgress = $0 }),
            text("komga_server_url", { komga.serverURL }, { komga.serverURL = $0 }),
            text("__PRIVATE_komga_api_key", secret: true, { komga.apiKey }, { komga.apiKey = $0 }),
            flag("komga_sync_progress", { komga.syncProgress }, { komga.syncProgress = $0 }),
            flag("komga_koreader_downloads", { komga.koreaderDownloads }, { komga.koreaderDownloads = $0 }),
            // iOS only (Android runs extensions itself); Android skips keys it doesn't know.
            text("suwayomi_server_url", { suwayomi.serverURL }, { suwayomi.serverURL = $0 }),
            text("suwayomi_username", { suwayomi.username }, { suwayomi.username = $0 }),
            text("__PRIVATE_suwayomi_password", secret: true, { suwayomi.password }, { suwayomi.password = $0 }),
            text("koreader_server_url", { koreader.serverURL }, { koreader.serverURL = $0 }),
            text("koreader_username", { koreader.username }, { koreader.username = $0 }),
            text("__PRIVATE_koreader_password", secret: true, { koreader.password }, { koreader.password = $0 }),
            Entry(key: "progress_sync_mode", secret: false, read: { sync.mode == .koreader ? "KOREADER" : "SOURCE" }) { value in
                switch value as? String {
                case "SOURCE": sync.mode = .source
                case "KOREADER": sync.mode = .koreader
                default: return false
                }
                return true
            },
            // iOS has no automatic backups yet; the value is kept so a file passes through intact.
            Entry(key: "backup_interval", secret: false, read: { UserDefaults.standard.object(forKey: "backup_interval") as? Int ?? 12 }) { value in
                guard let value = value as? Int else { return false }
                UserDefaults.standard.set(value, forKey: "backup_interval")
                return true
            },
        ]
    }

    /// The settings as a file's text, encrypted with `password` if there is one. Sign-in details
    /// are only written to an encrypted file.
    func export(includeSignIn: Bool, password: String?) throws -> Data {
        precondition(!includeSignIn || !(password ?? "").isEmpty, "Sign-in details need a password")
        var settings: [String: Any] = [:]
        for entry in entries where includeSignIn || !entry.secret {
            settings[entry.key] = entry.read()
        }
        let file: [String: Any]
        if let password, !password.isEmpty {
            let plain = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
            let salt = Self.randomBytes(16)
            let nonce = AES.GCM.Nonce()
            let key = try Self.deriveKey(password: password, salt: salt, iterations: Self.iterations)
            let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: Self.associatedData)
            file = [
                "format": Self.format,
                "version": Self.versionEncrypted,
                "encryption": [
                    "cipher": "AES-256-GCM", "kdf": "PBKDF2-HMAC-SHA256", "iterations": Self.iterations,
                    "salt": salt.base64EncodedString(), "iv": Data(nonce).base64EncodedString(),
                ],
                // As Java's GCM: the ciphertext followed by the tag.
                "data": (sealed.ciphertext + sealed.tag).base64EncodedString(),
            ]
        } else {
            file = ["format": Self.format, "version": Self.versionPlain, "settings": settings]
        }
        return try JSONSerialization.data(withJSONObject: file, options: [.sortedKeys, .prettyPrinted])
    }

    /// Whether `data` is an encrypted settings file, which needs a password to import.
    static func isEncrypted(_ data: Data) -> Bool {
        (try? parse(data))?["encryption"] != nil
    }

    /// Applies the settings in `data`, returning how many were set.
    @discardableResult
    func importFile(_ data: Data, password: String? = nil) async throws -> Int {
        let file = try Self.parse(data)
        let settings: [String: Any]
        if let encryption = file["encryption"] as? [String: Any] {
            guard let password, !password.isEmpty else { throw FileError.passwordRequired }
            guard let salt = (encryption["salt"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let iv = (encryption["iv"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let iterations = encryption["iterations"] as? Int,
                  let sealed = (file["data"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  sealed.count > 16,
                  // A made-up file mustn't be able to keep the phone busy for minutes.
                  (1...Self.maxIterations).contains(iterations)
            else { throw FileError.invalid }
            let key = try await Task.detached { try Self.deriveKey(password: password, salt: salt, iterations: iterations) }.value
            let plain: Data
            do {
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
                plain = try AES.GCM.open(box, using: key, authenticating: Self.associatedData)
            } catch {
                throw FileError.wrongPassword
            }
            guard let decoded = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw FileError.invalid }
            settings = decoded
        } else {
            guard let plain = file["settings"] as? [String: Any] else { throw FileError.invalid }
            settings = plain
        }
        var applied = 0
        for entry in entries {
            if let value = settings[entry.key], entry.write(Self.normalize(value)) { applied += 1 }
        }
        // BookOrbit's session belongs to the old account; sign in afresh with the new details.
        await app.bookOrbit.signOut()
        return applied
    }

    /// JSONSerialization gives NSNumber for both booleans and numbers.
    private static func normalize(_ value: Any) -> Any {
        guard let number = value as? NSNumber else { return value }
        return CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : number.intValue
    }

    private static func parse(_ data: Data) throws -> [String: Any] {
        guard let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              file["format"] as? String == format
        else { throw FileError.invalid }
        return file
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// PBKDF2-HMAC-SHA256, as Java's `PBKDF2WithHmacSHA256` (password as UTF-8).
    nonisolated static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, passwordBytes.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &key, key.count
            )
        }
        guard status == kCCSuccess else { throw FileError.invalid }
        return SymmetricKey(data: key)
    }
}
