import Foundation
import Observation

/// Extensions installed on this device (PLAN-2 Part G), run by the extension host on the JVM in
/// the app. Off until turned on in Settings → Browse (the App Store route: nothing about
/// extensions shows until then). Sources are remembered between launches, so series from them
/// open before the JVM has started; it starts the first time one is used.
@MainActor
@Observable
final class DeviceExtensions {
    typealias RPC = ExtensionRPC

    enum Status: Equatable {
        case off
        /// No JVM in this build, or the runtime isn't bundled.
        case unavailable
        case starting
        case ready
        case failed(String)
    }

    private let sources: SourceManager
    private let defaults: UserDefaults
    private static let enabledKey = "device_extensions_enabled"
    private static let cacheKey = "device_extensions_sources"
    /// A desktop dev host to use instead of the JVM in the app (`DOCHO_EXTENSION_HOST_URL`, or this default).
    private static let devHostKey = "device_extensions_dev_host"

    private(set) var status: Status = .off
    private(set) var host: ExtensionHost?
    private(set) var repos: [RPC.Repo] = []
    private(set) var available: [RPC.AvailableExtension] = []
    private(set) var installed: [RPC.InstalledExtension] = []
    private(set) var sourceInfos: [RPC.Source] = []
    private(set) var error: String?
    private(set) var isLoading = false
    /// Install or update progress by package (0…1, nil while it can't tell).
    private(set) var progress: [String: Double?] = [:]
    private(set) var lastToast: String?

    init(sources: SourceManager, defaults: UserDefaults = .standard) {
        self.sources = sources
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if isEnabled {
            if let data = defaults.data(forKey: Self.cacheKey), let cached = try? JSONDecoder().decode([RPC.Source].self, from: data) {
                apply(cached)
            }
            prepareHost()
        }
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                prepareHost()
                Task { await refresh() }
            } else {
                apply([])
                status = .off
            }
        }
    }

    /// Whether this build can run extensions at all.
    var isSupported: Bool { Self.transport() != nil }

    // MARK: Host

    private static func transport() -> (any ExtensionTransport, prepare: @Sendable () throws -> Void)? {
        let configured = ProcessInfo.processInfo.environment["DOCHO_EXTENSION_HOST_URL"] ?? UserDefaults.standard.string(forKey: devHostKey)
        if let configured, let url = URL(string: configured) {
            return (HTTPExtensionTransport(baseURL: url), {})
        }
        guard let runtime = EmbeddedExtensionTransport.Runtime.bundled() else { return nil }
        let transport = EmbeddedExtensionTransport.shared
        return (transport, { try transport.start(runtime) })
    }

    private func prepareHost() {
        guard host == nil else { return }
        guard let (transport, prepare) = Self.transport() else {
            status = .unavailable
            return
        }
        let host = ExtensionHost(transport: transport, prepare: prepare)
        self.host = host
        ExtensionImageProtocol.host = host
        Task {
            await host.onToast { text in Task { @MainActor in self.lastToast = text } }
            for await event in await host.progress() { self.handle(event) }
        }
        apply(sourceInfos)
    }

    /// Starts the host if it isn't running; the first time takes a few seconds.
    func start() async -> ExtensionHost? {
        guard isEnabled else { return nil }
        prepareHost()
        guard let host else { return nil }
        if status == .ready { return host }
        status = .starting
        do {
            try await host.start()
            status = .ready
            return host
        } catch {
            status = .failed(error.localizedDescription)
            return nil
        }
    }

    private func apply(_ infos: [RPC.Source]) {
        sourceInfos = infos
        guard isEnabled, let host else {
            sources.setDynamic([], from: .device)
            return
        }
        sources.setDynamic(infos.map { ExtensionSource(host: host, info: $0) }, from: .device)
    }

    // MARK: Lists

    /// Repos, installed and available extensions, and the sources; `refreshRepos` fetches the
    /// repos' indexes again first.
    func refresh(refreshRepos: Bool = false) async {
        guard let host = await start() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if refreshRepos { _ = try await host.refreshRepos() }
            repos = try await host.repos()
            installed = try await host.installedExtensions()
            available = try await host.availableExtensions(includeNsfw: true)
            try await refreshSources(host)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refreshSources(_ host: ExtensionHost) async throws {
        let infos = try await host.sources()
        apply(infos)
        defaults.set(try? JSONEncoder().encode(infos), forKey: Self.cacheKey)
    }

    func addRepo(_ url: String) async throws {
        guard let host = await start() else { return }
        _ = try await host.addRepo(url.trimmingCharacters(in: .whitespacesAndNewlines))
        await refresh()
    }

    func removeRepo(_ repo: RPC.Repo) async {
        guard let host = await start() else { return }
        do {
            try await host.removeRepo(repo.indexUrl)
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    // MARK: Install, update, uninstall, trust

    func install(_ ext: RPC.AvailableExtension) async {
        guard let host = await start() else { return }
        progress[ext.pkgName] = .some(nil)
        do {
            _ = try await host.install(ext.pkgName, repo: ext.repoIndexUrl)
        } catch {
            progress[ext.pkgName] = nil
            self.error = error.localizedDescription
        }
    }

    func update(_ ext: RPC.InstalledExtension) async {
        guard let host = await start() else { return }
        progress[ext.pkgName] = .some(nil)
        do {
            _ = try await host.update(ext.pkgName)
        } catch {
            progress[ext.pkgName] = nil
            self.error = error.localizedDescription
        }
    }

    func uninstall(_ ext: RPC.InstalledExtension) async {
        guard let host = await start() else { return }
        do {
            try await host.uninstall(ext.pkgName)
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    func trust(_ ext: RPC.InstalledExtension) async {
        guard let host = await start() else { return }
        do {
            _ = try await host.trust(ext)
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    private func handle(_ event: RPC.ExtensionProgress) {
        guard let pkg = event.pkgName else { return }
        switch event.phase {
        case .done:
            progress[pkg] = nil
            Task { await refresh() }
        case .failed:
            progress[pkg] = nil
            error = event.error?.message ?? String(localized: "The extension couldn't be installed")
            Task { await refresh() }
        default:
            progress[pkg] = .some(event.fraction)
        }
    }

    func clearToast() { lastToast = nil }
}
