import XCTest
@testable import Docho

@MainActor
final class SettingsFileTests: XCTestCase {
    private var app: AppModel!

    override func setUp() async throws {
        app = try TestApp.make("settingsfile", kavita: KavitaCredentials(serverURL: "https://kavita.test", apiKey: "key-1")).app
        StubURLProtocol.reset { _ in .json("", status: 404) }
    }

    /// Made by Java's PBKDF2WithHmacSHA256 and AES/GCM, as the Android app encrypts its files
    /// (password "correct horse", 1000 iterations).
    private let androidFile = #"""
    {"format":"docho-sync-settings","version":2,"encryption":{"cipher":"AES-256-GCM","kdf":"PBKDF2-HMAC-SHA256","iterations":1000,"salt":"AAECAwQFBgcICQoLDA0ODw==","iv":"ZGVmZ2hpamtsbW5v"},"data":"xHKYUK+5X2qO04mLSGuV4MTd5V6tTXYutZ0uH/78iWD/DTtEFDAiK4KUz71GB97ymLuK4yyqSwXCh4YNG+A/6awMfwdO7InasS5gDpIOUFo7Z5YhpHBCby1zTBH1SBtjpt6+LSVLeEj7iuiTm5H8EUQXo2k2l4lccv4ABcc49hG70Ls7bc6rSNWClS0Ho02AEl8NoxL3BtAnYF/QS+u15DcRB/0iPybY02DLx4dVUbxK3e5wl16LVyPkrXc="}
    """#

    func testImportsAnEncryptedFileFromTheAndroidApp() async throws {
        let data = Data(androidFile.utf8)
        XCTAssertTrue(SettingsFile.isEncrypted(data))
        let file = SettingsFile(app: app)

        do {
            try await file.importFile(data, password: nil)
            XCTFail("needs a password")
        } catch SettingsFile.FileError.passwordRequired {}
        do {
            try await file.importFile(data, password: "wrong horse")
            XCTFail("wrong password accepted")
        } catch SettingsFile.FileError.wrongPassword {}

        let count = try await file.importFile(data, password: "correct horse")
        XCTAssertEqual(count, 5)
        XCTAssertEqual(app.settings.serverURL, "https://kavita.example.com")
        XCTAssertEqual(app.settings.apiKey, "secret-key")
        XCTAssertFalse(app.settings.syncProgress)
        XCTAssertEqual(app.syncSettings.mode, .koreader)
    }

    func testRoundTripsEncryptedWithSignIn() async throws {
        app.komgaSettings.serverURL = "http://komga.lan:25600"
        app.komgaSettings.apiKey = "komga-key"
        let data = try SettingsFile(app: app).export(includeSignIn: true, password: "long enough")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("komga-key"), "secrets never appear in the file's text")
        XCTAssertFalse(text.contains("komga.lan"), "the whole settings object is encrypted")

        app.komgaSettings.reset()
        app.settings.apiKey = ""
        try await SettingsFile(app: app).importFile(data, password: "long enough")
        XCTAssertEqual(app.komgaSettings.serverURL, "http://komga.lan:25600")
        XCTAssertEqual(app.komgaSettings.apiKey, "komga-key")
        XCTAssertEqual(app.settings.apiKey, "key-1")
    }

    func testAPlainFileLeavesSignInDetailsOut() async throws {
        let data = try SettingsFile(app: app).export(includeSignIn: false, password: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let settings = try XCTUnwrap(json["settings"] as? [String: Any])
        XCTAssertEqual(settings["kavita_server_url"] as? String, "https://kavita.test")
        XCTAssertNil(settings["__PRIVATE_kavita_api_key"])
        XCTAssertEqual(settings["progress_sync_mode"] as? String, "SOURCE")
    }

    func testRejectsOtherFiles() async {
        do {
            try await SettingsFile(app: app).importFile(Data(#"{"format":"something-else"}"#.utf8))
            XCTFail("accepted another file")
        } catch {
            XCTAssertEqual(error as? SettingsFile.FileError, .invalid)
        }
    }
}

@MainActor
final class AppearanceTests: XCTestCase {
    func testContrastAndLuminanceMatchWCAG() {
        XCTAssertEqual(ColorMath.contrastRatio(0xFF00_0000, 0xFFFF_FFFF), 21, accuracy: 0.01)
        XCTAssertEqual(ColorMath.contrastRatio(0xFF77_7777, 0xFF77_7777), 1, accuracy: 0.001)
        XCTAssertTrue(ColorMath.isDark(0xFF12_1018))
        XCTAssertFalse(ColorMath.isDark(0xFFFE_FBFF))
    }

    func testOklabMixingKeepsTheEnds() {
        XCTAssertEqual(ColorMath.lerp(0xFF00_58CA, 0xFFFF_FFFF, 0), 0xFF00_58CA)
        XCTAssertEqual(ColorMath.lerp(0xFF00_58CA, 0xFFFF_FFFF, 1), 0xFFFF_FFFF)
        // Halfway in Oklab (L = 0.5) is sRGB 0x63, as Compose's lerp gives.
        XCTAssertEqual(ColorMath.lerp(0xFF00_0000, 0xFFFF_FFFF, 0.5), 0xFF63_6363)
    }

    func testACustomThemeIsLightOrDarkByItsBackground() {
        var theme = CustomTheme.from(.default, dark: true, name: "Mine")
        XCTAssertTrue(theme.isDark)
        let scheme = theme.scheme(pureBlack: true)
        XCTAssertTrue(scheme.isDark)
        XCTAssertEqual(scheme.background, .black, "pure black applies to a dark custom theme")
        theme.background = 0xFFFF_FFFF
        XCTAssertFalse(theme.isDark)
        XCTAssertEqual(theme.scheme(pureBlack: true).background.argb, 0xFFFF_FFFF)
    }

    func testWarnsAboutColoursHardToSee() {
        var theme = CustomTheme.from(.default, dark: false, name: "Mine")
        XCTAssertEqual(theme.hardToRead, [])
        theme.text = theme.background
        theme.primary = 0xFFFC_FCFC
        XCTAssertEqual(theme.hardToRead, [.text, .primary])
        XCTAssertEqual(ColorMath.parseHex("#abc"), 0xFFAA_BBCC)
        XCTAssertNil(ColorMath.parseHex("xyz"))
    }

    func testTabsFollowTheOrderAndLibraryAndMoreAlwaysShow() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "io.github.grillza.docho.tests.tabs.\(UUID())"))
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(HomeTab.visible(preferences), [.library, .updates, .history, .browse, .more])
        preferences.tabOrder = ["more", "browse", "library"]
        preferences.showUpdatesTab = false
        XCTAssertEqual(HomeTab.visible(preferences), [.more, .browse, .library, .history])
        XCTAssertFalse(HomeTab.library.canHide)
        XCTAssertFalse(HomeTab.more.canHide)
        XCTAssertEqual(AppPreferences(defaults: defaults).tabOrder, ["more", "browse", "library"], "saved")
    }
}
