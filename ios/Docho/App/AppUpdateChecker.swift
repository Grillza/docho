import Foundation

/// The newest Dōchō release on GitHub, as the iOS app sees it.
struct AppRelease: Equatable, Identifiable, Sendable {
    /// The iOS version, such as "0.28.0", taken from the IPA's name.
    let version: String
    /// The "## iOS and iPadOS" part of the release notes.
    let notes: String
    let page: URL
    /// The IPA itself, which AltStore or SideStore can install as the update.
    var ipa: URL?

    var id: String { version }

    /// A sideloader on the device that can install the update.
    enum Sideloader: String, CaseIterable {
        case altStore = "altstore"
        case sideStore = "sidestore"

        var name: String {
            switch self {
            case .altStore: "AltStore"
            case .sideStore: "SideStore"
            }
        }
    }

    /// `altstore://install?url=…` (SideStore takes the same link on its own scheme): opens the
    /// sideloader, which downloads and installs the IPA over the current app.
    func installURL(in sideloader: Sideloader) -> URL? {
        guard let ipa else { return nil }
        var components = URLComponents()
        components.scheme = sideloader.rawValue
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: ipa.absoluteString)]
        return components.url
    }
}

/// Checks GitHub for a newer release, as Android's AppUpdateChecker does.
///
/// One release carries both apps, and the iOS version can be a patch ahead of or behind Android's,
/// so the version comes from the IPA (`docho-0.28.0.ipa`), not the tag.
struct AppUpdateChecker: Sendable {
    static let latestURL = URL(string: "https://api.github.com/repos/Grillza/docho/releases/latest")!

    var session: URLSession = .shared

    enum Result: Equatable, Sendable {
        case newUpdate(AppRelease)
        case noNewUpdate
    }

    /// - Parameters:
    ///   - current: The installed version, such as "0.27.2".
    ///   - skipped: A version the user chose to skip; it isn't offered again.
    ///   - skipPatchUpdates: Leave out releases that only change the patch number (0.27.1 to 0.27.2).
    func check(current: String, skipped: String? = nil, skipPatchUpdates: Bool = false) async throws -> Result {
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let release = try Self.parse(data) else { return .noNewUpdate }
        return Self.evaluate(release, current: current, skipped: skipped, skipPatchUpdates: skipPatchUpdates)
    }

    static func evaluate(_ release: AppRelease, current: String, skipped: String?, skipPatchUpdates: Bool) -> Result {
        guard let latest = parseVersion(release.version), let installed = parseVersion(current),
              compare(latest, installed) > 0 else { return .noNewUpdate }
        if let skipped, parseVersion(skipped) == latest { return .noNewUpdate }
        if skipPatchUpdates, latest.prefix(2) == installed.prefix(2) { return .noNewUpdate }
        return .newUpdate(release)
    }

    // MARK: Parsing

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL?
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
    }

    /// The iOS release in GitHub's JSON, or nil if it has no IPA.
    static func parse(_ data: Data) throws -> AppRelease? {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = release.assets.first(where: { ipaVersion(of: $0.name) != nil }),
              let version = ipaVersion(of: asset.name) else { return nil }
        return AppRelease(
            version: version, notes: iosSection(of: release.body ?? ""), page: release.html_url, ipa: asset.browser_download_url
        )
    }

    /// "docho-0.28.0.ipa" gives "0.28.0".
    static func ipaVersion(of name: String) -> String? {
        guard let match = name.firstMatch(of: #/-(\d+\.\d+\.\d+)\.ipa$/#) else { return nil }
        return String(match.1)
    }

    /// The text under "## iOS…" up to the next "## " heading, or the whole body if there's none.
    static func iosSection(of body: String) -> String {
        let lines = body.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## iOS") }) else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { $0.hasPrefix("## ") }) ?? rest.endIndex
        return rest[..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first dotted number, padded to three parts: "v0.27.1" gives [0, 27, 1].
    static func parseVersion(_ name: String) -> [Int]? {
        guard let match = name.firstMatch(of: #/\d+(?:\.\d+)*/#) else { return nil }
        let parts = match.output.split(separator: ".").compactMap { Int($0) }
        return parts + Array(repeating: 0, count: max(0, 3 - parts.count))
    }

    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let diff = (i < a.count ? a[i] : 0) - (i < b.count ? b[i] : 0)
            if diff != 0 { return diff }
        }
        return 0
    }
}
