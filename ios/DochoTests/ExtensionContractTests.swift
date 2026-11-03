import XCTest
@testable import Docho

/// The extension host's protocol fixtures (`Vendor/docho-runtime/contract/fixtures`) read and
/// write the same in Swift: each decodes into its type and encodes back to the same JSON.
final class ExtensionContractTests: XCTestCase {
    private typealias RPC = ExtensionRPC

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Vendor/docho-runtime/contract/fixtures")

    /// Fixtures for parts not built yet (WebViews come with G6, backups later).
    private static let notYet: Set<String> = [
        "webview_command_destroy", "webview_command_evaluate", "webview_command_load_data", "webview_command_load",
        "webview_command_touch", "webview_event_error", "webview_intercept_request", "webview_override_result",
        "webview_intercept_result", "webview_event_page_finished", "webview_js_call_result", "webview_js_call",
        "webview_event_evaluate_result", "preferences_import", "related_params",
    ]

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appending(path: "\(name).json"))
    }

    /// Decodes `name` as `T`, encodes it again and compares both as JSON values.
    private func roundTrip<T: Codable>(_ name: String, as type: T.Type, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try fixture(name)
        let value = try JSONDecoder().decode(T.self, from: data)
        let encoded = try JSONEncoder().encode(value)
        let expected = try JSONDecoder().decode(SyncJSON.self, from: data)
        let actual = try JSONDecoder().decode(SyncJSON.self, from: encoded)
        XCTAssertEqual(Self.withoutDefaults(actual), Self.withoutDefaults(expected), name, file: file, line: line)
    }

    /// Nulls, and defaults the host leaves out, don't count as differences.
    private static func withoutDefaults(_ value: SyncJSON) -> SyncJSON {
        switch value {
        case .object(let fields):
            var out: [String: SyncJSON] = [:]
            for (key, value) in fields where value != .null {
                out[key] = withoutDefaults(value)
            }
            return .object(out)
        case .array(let values): return .array(values.map(withoutDefaults))
        default: return value
        }
    }

    func testEveryFixtureIsCovered() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        XCTAssertFalse(names.isEmpty, "fixtures not found at \(Self.fixtures.path)")
        let covered = Set(covered.keys).union(Self.notYet)
        XCTAssertEqual(Set(names).subtracting(covered), [], "fixtures with no Swift type")
    }

    private var covered: [String: (ExtensionContractTests) throws -> Void] { [
        "rpc_request": { try $0.roundTrip("rpc_request", as: RPC.Request.self) },
        "rpc_response_ok": { try $0.roundTrip("rpc_response_ok", as: RPC.Response.self) },
        "rpc_response_error": { try $0.roundTrip("rpc_response_error", as: RPC.Response.self) },
        "hello": { try $0.roundTrip("hello", as: RPC.Hello.self) },
        "init_params": { try $0.roundTrip("init_params", as: RPC.InitParams.self) },
        "event_host_toast": { try $0.roundTrip("event_host_toast", as: RPC.Event.self) },
        "event_ext_progress": { try $0.roundTrip("event_ext_progress", as: RPC.Event.self) },
        "net_fetch_event": { try $0.roundTrip("net_fetch_event", as: RPC.NetFetch.self) },
        "net_fetch_result": { try $0.roundTrip("net_fetch_result", as: RPC.NetFetchResult.self) },
        "net_fetch_result_error": { try $0.roundTrip("net_fetch_result_error", as: RPC.NetFetchResult.self) },
        "challenge_required": { try $0.roundTrip("challenge_required", as: RPC.ChallengeRequired.self) },
        "challenge_resolved": { try $0.roundTrip("challenge_resolved", as: RPC.ChallengeResolved.self) },
        "repo": { try $0.roundTrip("repo", as: RPC.Repo.self) },
        "repo_disabled": { try $0.roundTrip("repo_disabled", as: RPC.Repo.self) },
        "repo_set_enabled": { _ in },
        "available_extensions": { try $0.roundTrip("available_extensions", as: [RPC.AvailableExtension].self) },
        "installed_extensions": { try $0.roundTrip("installed_extensions", as: [RPC.InstalledExtension].self) },
        "sources": { try $0.roundTrip("sources", as: [RPC.Source].self) },
        "mangas_page": { try $0.roundTrip("mangas_page", as: RPC.MangasPage.self) },
        "manga_update": { try $0.roundTrip("manga_update", as: RPC.MangaUpdate.self) },
        "pages": { try $0.roundTrip("pages", as: [RPC.Page].self) },
        "image_file": { try $0.roundTrip("image_file", as: RPC.ImageFile.self) },
        "filters": { try $0.roundTrip("filters", as: [RPC.Filter].self) },
        "preferences": { try $0.roundTrip("preferences", as: [RPC.Preference].self) },
        "related_mangas": { try $0.roundTrip("related_mangas", as: RPC.Related.self) },
        "related_unsupported": { try $0.roundTrip("related_unsupported", as: RPC.Related.self) },
        "imported": { try $0.roundTrip("imported", as: RPC.Imported.self) },
    ] }

    func testFixturesRoundTrip() throws {
        for (name, check) in covered.sorted(by: { $0.key < $1.key }) {
            do { try check(self) } catch { XCTFail("\(name): \(error)") }
        }
    }

    func testEventPayloadsDecode() throws {
        let event = try JSONDecoder().decode(RPC.Event.self, from: fixture("event_ext_progress"))
        let progress = try JSONDecoder().decode(RPC.ExtensionProgress.self, from: JSONEncoder().encode(event.data))
        XCTAssertEqual(progress.phase, .convert)
        XCTAssertEqual(progress.fraction, 0.5)
    }

    func testFiltersConvertBothWays() throws {
        let filters = try JSONDecoder().decode([RPC.Filter].self, from: fixture("filters"))
        XCTAssertEqual(filters.map(\.sourceFilter).map(RPC.Filter.init), filters.map { filter in
            // The app has one separator; the host's separators have no name.
            if case .separator = filter { return .separator(name: "") }
            return filter
        })
    }
}
