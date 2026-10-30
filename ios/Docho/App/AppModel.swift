import Foundation
import Nuke
import Observation
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
    let notifier = DownloadNotifier()
    private var triggers: SyncTriggers?

    /// Mirrors Kavita's latest sign-in outcome for the UI.
    private(set) var connection: KavitaConnection = .unknown

    /// A series to open from outside its tab (a notification, the download bar).
    var pendingSeries: Int?
    /// Why a comic opened from elsewhere couldn't be added.
    var openFileError: String?

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
        library = LibraryUpdater(database: database, sources: sources, sync: sync, downloads: downloads, preferences: self.preferences)
        trackers = TrackerManager(database: database, session: session, defaults: downloadDefaults)
        self.suwayomiSettings = suwayomiSettings
        suwayomi = SuwayomiModel(client: SuwayomiClient(settings: suwayomiSettings, session: session), sources: sources, defaults: downloadDefaults)

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
        Task { await suwayomi.refreshSources() }
        await downloads.resume()
        await sync.syncLibrary()
        if preferences.updateOnLaunch { await library.update() }
    }

    #if DEBUG
    /// Debug builds take server settings from the launch environment, for UI tests and
    /// screenshots: `DOCHO_KAVITA_URL`/`_KEY`, `DOCHO_KOMGA_URL`/`_KEY`, and
    /// `DOCHO_BOOKORBIT_URL`/`_USER`/`_PASSWORD`. `DOCHO_RESET=1` starts from an empty library.
    func applyLaunchSettings(_ environment: [String: String]) {
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
        if phase == .background, preferences.autoUpdate { LibraryUpdater.scheduleBackgroundUpdate() }
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
        ImagePipeline.shared = ImagePipeline(configuration: .withDataCache)
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
