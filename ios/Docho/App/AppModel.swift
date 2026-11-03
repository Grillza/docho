import Foundation
import Nuke
import Observation
import UIKit
import os

/// The dependency container: one instance for the app, handed to views through the environment.
@MainActor
@Observable
final class AppModel {
    let settings: KavitaSettings
    let kavita: KavitaClient
    let komgaSettings: KomgaSettings
    let komga: KomgaClient
    let bookOrbitSettings: BookOrbitSettings
    let bookOrbit: BookOrbitClient
    let koreaderSettings: KoreaderSettings
    let koreader: KoreaderClient
    let syncSettings: SyncSettings
    let database: AppDatabase
    let readerSettings: ReaderSettings
    let preferences: AppPreferences
    let sources: SourceManager
    let localSource: LocalSource
    /// Names, numbers and kinds the user gave chapters.
    let renames: ChapterRenames
    /// Series details the user edited, kept over the source's.
    let seriesEdits: SeriesEdits
    let kavitaSource: KavitaSource
    let komgaSource: KomgaSource
    let bookOrbitSource: BookOrbitSource
    let kavitaSync: KavitaSync
    let komgaSync: KomgaSync
    let bookOrbitSync: BookOrbitSync
    let koreaderSync: KoreaderSync
    let sync: ProgressSync
    let downloads: DownloadManager
    let library: LibraryUpdater
    let trackers: TrackerManager
    let suwayomiSettings: SuwayomiSettings
    let suwayomi: SuwayomiModel
    /// Extensions on this device (off until turned on).
    let deviceExtensions: DeviceExtensions
    let notifier = DownloadNotifier()
    let dochoSyncSettings: DochoSyncSettings
    let dochoSyncClient: DochoSyncClient
    /// Dōchō Sync: the library, renames, read state and history across devices.
    let dochoSync: DochoSync
    private var triggers: SyncTriggers?

    /// Mirrors Kavita's latest sign-in outcome for the UI.
    private(set) var connection: KavitaConnection = .unknown

    /// A series to open from outside its tab (a notification, the download bar).
    var pendingSeries: Int?
    /// Why a comic opened from elsewhere couldn't be added.
    var openFileError: String?
    /// A newer release to offer (HomeView shows it).
    var availableUpdate: AppRelease?
    var updateChecker = AppUpdateChecker()
    @ObservationIgnored private var lastUpdateCheck: Date?

    init(
        settings: KavitaSettings = KavitaSettings(),
        komgaSettings: KomgaSettings = KomgaSettings(),
        bookOrbitSettings: BookOrbitSettings = BookOrbitSettings(),
        koreaderSettings: KoreaderSettings = KoreaderSettings(),
        syncSettings: SyncSettings = SyncSettings(),
        session: URLSession = .shared,
        database: AppDatabase? = nil,
        readerSettings: ReaderSettings? = nil,
        preferences: AppPreferences? = nil,
        pageDebounce: Duration = KavitaSync.pageDebounce,
        downloadStore: DownloadStore = .standard(),
        pageFetcher: any PageFetcher = BackgroundFetch(),
        downloadDefaults: UserDefaults = .standard,
        localSource: LocalSource = .standard(),
        suwayomiSettings: SuwayomiSettings = SuwayomiSettings()
    ) {
        self.settings = settings
        self.komgaSettings = komgaSettings
        self.bookOrbitSettings = bookOrbitSettings
        self.koreaderSettings = koreaderSettings
        self.syncSettings = syncSettings
        self.readerSettings = readerSettings ?? ReaderSettings()
        self.preferences = preferences ?? AppPreferences()
        let database = database ?? Self.openDatabase()
        self.database = database

        kavita = KavitaClient(session: session) { [settings] in settings.credentials }
        komga = KomgaClient(settings: komgaSettings, session: session)
        bookOrbit = BookOrbitClient(settings: bookOrbitSettings, session: session)
        koreader = KoreaderClient(settings: koreaderSettings, session: session)

        self.localSource = localSource
        kavitaSource = KavitaSource(client: kavita, settings: settings, database: database)
        komgaSource = KomgaSource(client: komga, settings: komgaSettings)
        bookOrbitSource = BookOrbitSource(client: bookOrbit, settings: bookOrbitSettings)
        sources = SourceManager(sources: [localSource, kavitaSource, komgaSource, bookOrbitSource])

        kavitaSync = KavitaSync(source: kavitaSource, database: database, settings: settings, syncSettings: syncSettings, pageDebounce: pageDebounce)
        komgaSync = KomgaSync(source: komgaSource, database: database, settings: komgaSettings, syncSettings: syncSettings, pageDebounce: pageDebounce)
        bookOrbitSync = BookOrbitSync(
            source: bookOrbitSource, database: database, settings: bookOrbitSettings, syncSettings: syncSettings, pageDebounce: pageDebounce
        )
        let documentCache = KoreaderDocumentCache(settings: koreaderSettings)
        koreaderSync = KoreaderSync(
            client: koreader, database: database, settings: koreaderSettings, syncSettings: syncSettings,
            providers: [
                KavitaKoreaderDocuments(source: kavitaSource, cache: documentCache),
                BookOrbitKoreaderDocuments(source: bookOrbitSource, cache: documentCache),
                KomgaKoreaderDocuments(source: komgaSource, settings: komgaSettings, cache: documentCache),
            ],
            pageDebounce: pageDebounce
        )
        sync = ProgressSync(engines: [kavitaSync, komgaSync, bookOrbitSync, koreaderSync])
        downloads = DownloadManager(database: database, sources: sources, store: downloadStore, fetcher: pageFetcher, defaults: SendableDefaults(downloadDefaults))
        renames = ChapterRenames(defaults: downloadDefaults)
        seriesEdits = SeriesEdits(defaults: downloadDefaults)
        library = LibraryUpdater(
            database: database, sources: sources, sync: sync, downloads: downloads, preferences: self.preferences, renames: renames,
            seriesEdits: seriesEdits
        )
        trackers = TrackerManager(database: database, session: session, defaults: downloadDefaults)
        let dochoSyncSettings = DochoSyncSettings()
        self.dochoSyncSettings = dochoSyncSettings
        dochoSyncClient = DochoSyncClient(settings: dochoSyncSettings, session: session)
        dochoSync = DochoSync(
            settings: dochoSyncSettings, client: dochoSyncClient, database: database, renames: renames, seriesEdits: seriesEdits
        ) { [library] series in
            _ = try? await library.refresh(series)
        }
        self.suwayomiSettings = suwayomiSettings
        suwayomi = SuwayomiModel(client: SuwayomiClient(settings: suwayomiSettings, session: session), sources: sources, defaults: downloadDefaults)
        deviceExtensions = DeviceExtensions(sources: sources, defaults: downloadDefaults)

        Task { [weak self, changes = kavita.connectionChanges] in
            for await connection in changes {
                self?.connection = connection
            }
        }
    }

    /// Starts delivering queued progress, resumes downloads, then runs library sync.
    /// Called once by the app; tests leave it out.
    func start() async {
        guard triggers == nil else { return }
        let triggers = SyncTriggers(sync: sync)
        self.triggers = triggers
        triggers.start()
        notifier.attach(self)
        Task { _ = try? await checkForAppUpdate() }
        Task { await suwayomi.refreshSources() }
        await downloads.resume()
        if dochoSyncSettings.automatic { await dochoSync.sync() }
        await sync.syncLibrary()
        if preferences.updateOnLaunch { await library.update() }
    }

    #if DEBUG
    /// Debug builds take server settings from the launch environment, for UI tests and
    /// screenshots: `DOCHO_KAVITA_URL`/`_KEY`, `DOCHO_KOMGA_URL`/`_KEY`, and
    /// `DOCHO_BOOKORBIT_URL`/`_USER`/`_PASSWORD`. `DOCHO_RESET=1` starts from an empty library.
    func applyLaunchSettings(_ environment: [String: String]) {
        // Launches for tests and screenshots skip the welcome guide unless they ask for it.
        if environment.keys.contains(where: { $0.hasPrefix("DOCHO_") }) {
            preferences.shownWelcome = environment["DOCHO_WELCOME"] == nil
        }
        if environment["DOCHO_RESET"] == "1" {
            try? database.writer.write { db in
                try db.execute(sql: "DELETE FROM series; DELETE FROM category; DELETE FROM download; DELETE FROM pendingProgress; DELETE FROM syncQueue")
            }
        }
        if let url = environment["DOCHO_KAVITA_URL"], let key = environment["DOCHO_KAVITA_KEY"] {
            settings.serverURL = url
            settings.apiKey = key
        }
        if let url = environment["DOCHO_SUWAYOMI_URL"] {
            suwayomiSettings.serverURL = url
        }
        if let url = environment["DOCHO_KOMGA_URL"], let key = environment["DOCHO_KOMGA_KEY"] {
            komgaSettings.serverURL = url
            komgaSettings.apiKey = key
        }
        if let url = environment["DOCHO_BOOKORBIT_URL"], let user = environment["DOCHO_BOOKORBIT_USER"],
           let password = environment["DOCHO_BOOKORBIT_PASSWORD"] {
            bookOrbitSettings.serverURL = url
            bookOrbitSettings.username = user
            bookOrbitSettings.password = password
        }
    }
    #endif

    func sceneChanged(to phase: SyncTriggers.ScenePhaseChange) {
        triggers?.sceneChanged(to: phase)
        if phase == .background { notifier.appWentToBackground() }
        syncDochoOnSceneChange(phase)
        // The app can stay open for days, so returning to it checks again, at most every 6 hours (as on Android).
        if phase == .active, triggers != nil, let last = lastUpdateCheck, Date.now.timeIntervalSince(last) > 6 * 3600 {
            Task { _ = try? await checkForAppUpdate() }
        }
        if phase == .background, preferences.autoUpdate { LibraryUpdater.scheduleBackgroundUpdate() }
    }

    static var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Checks GitHub for a newer release. The automatic check offers it in a dialog and respects
    /// the skipped version and "Skip bug-fix updates"; a manual one (About) ignores both and
    /// returns the result instead. Debug builds don't check on their own.
    @discardableResult
    func checkForAppUpdate(manual: Bool = false) async throws -> AppUpdateChecker.Result {
        #if DEBUG
        if !manual { return .noNewUpdate }
        #endif
        lastUpdateCheck = .now
        let result: AppUpdateChecker.Result
        do {
            result = try await updateChecker.check(
                current: Self.installedVersion,
                skipped: manual ? nil : preferences.skippedAppUpdate,
                skipPatchUpdates: !manual && preferences.skipPatchAppUpdates
            )
        } catch {
            if manual { throw error }
            return .noNewUpdate
        }
        if !manual, case .newUpdate(let release) = result { availableUpdate = release }
        return result
    }

    /// The automatic library update iOS runs in the background (Settings → Library).
    /// Adds a comic opened from the Files app (or shared from another app) to the Local source,
    /// as a series named after the file, and opens it.
    func openLocalFile(_ url: URL) async {
        guard url.isFileURL else { return }
        let source = localSource
        do {
            let rootPath = source.root.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            let series: String
            if path.hasPrefix(rootPath) {
                // Already in the local folder: open the series it's in.
                series = String(path.dropFirst(rootPath.count).split(separator: "/").first ?? "")
            } else {
                series = try await Task.detached { try source.add([url], series: nil) }.value.first ?? ""
                // Files shared from other apps arrive in Documents/Inbox; the copy in local is enough.
                if path.hasPrefix(source.documents.appending(path: "Inbox").standardizedFileURL.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            guard !series.isEmpty else { return }
            let record = try await database.localSeries(source: LocalSource.id, manga: SManga(url: series, title: series))
            pendingSeries = record.id
        } catch {
            openFileError = error.localizedDescription
        }
    }

    func backgroundLibraryUpdate() async {
        guard preferences.autoUpdate else { return }
        await library.update()
        LibraryUpdater.scheduleBackgroundUpdate()
    }

    func backgroundRefresh() async {
        await (triggers ?? SyncTriggers(sync: sync)).backgroundRefresh()
    }

    func source(for series: SeriesRecord) -> any MangaSource {
        sources.source(series.source)
    }

    /// Covers and pages are cached on disk as well as in memory.
    static func configureImagePipeline() {
        var configuration = ImagePipeline.Configuration.withDataCache
        // Extension pages and covers (docho-ext://) come from the extension host.
        let session = DataLoader.defaultConfiguration
        session.protocolClasses = [ExtensionImageProtocol.self] + (session.protocolClasses ?? [])
        configuration.dataLoader = DataLoader(configuration: session)
        ImagePipeline.shared = ImagePipeline(configuration: configuration)
    }

    private static func openDatabase() -> AppDatabase {
        do {
            return try .onDisk()
        } catch {
            // Keep the app usable; nothing is saved until the next launch succeeds.
            Logger().error("Could not open the database: \(error)")
            // swiftlint:disable:next force_try
            return try! .inMemory()
        }
    }
}

extension AppModel {
    /// Dōchō Sync runs when the app comes back (to take other devices' changes) and as it goes to
    /// the background (to send this one's), with a little extra time to finish there.
    fileprivate func syncDochoOnSceneChange(_ phase: SyncTriggers.ScenePhaseChange) {
        guard triggers != nil, dochoSyncSettings.isConfigured, dochoSyncSettings.automatic else { return }
        switch phase {
        case .active:
            Task { await dochoSync.sync() }
        case .background:
            let task = BackgroundTask()
            task.id = UIApplication.shared.beginBackgroundTask(withName: "docho-sync") {
                MainActor.assumeIsolated { task.end() }
            }
            Task {
                await dochoSync.sync()
                task.end()
            }
        }
    }
}

/// A `beginBackgroundTask` id, ended once whichever comes first: the work or its expiry.
@MainActor
private final class BackgroundTask {
    var id = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
