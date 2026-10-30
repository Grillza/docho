import XCTest
@testable import Doki

final class KavitaSettingsTests: XCTestCase {
    private let suite = "app.doki.tests.settings"
    private let service = "app.doki.tests"

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        KeychainItem(service: service, account: "kavita_api_key").delete()
    }

    private func makeSettings() throws -> KavitaSettings {
        KavitaSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), keychainService: service)
    }

    func testDefaults() throws {
        let settings = try makeSettings()
        XCTAssertEqual(settings.serverURL, "")
        XCTAssertEqual(settings.apiKey, "")
        XCTAssertTrue(settings.syncProgress)
        XCTAssertFalse(settings.credentials.isConfigured)
    }

    func testPersistsTheServerInDefaultsAndTheKeyInTheKeychain() throws {
        let settings = try makeSettings()
        settings.serverURL = "https://kavita.example.com"
        settings.apiKey = "secret"
        settings.syncProgress = false

        let reloaded = try makeSettings()
        XCTAssertEqual(reloaded.serverURL, "https://kavita.example.com")
        XCTAssertEqual(reloaded.apiKey, "secret")
        XCTAssertFalse(reloaded.syncProgress)
        XCTAssertEqual(KeychainItem(service: service, account: "kavita_api_key").read(), "secret")
        XCTAssertNil(UserDefaults(suiteName: suite)?.dictionaryRepresentation().values.first { $0 as? String == "secret" })

        reloaded.apiKey = ""
        XCTAssertNil(KeychainItem(service: service, account: "kavita_api_key").read())
    }
}
