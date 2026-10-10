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
    let database: AppDatabase
    let sync: KavitaSync
    private var triggers: SyncTriggers?

    /// Mirrors the client's latest sign-in outcome for the UI.
    private(set) var connection: KavitaConnection = .unknown

    init(
        settings: KavitaSettings = KavitaSettings(),
        session: URLSession = .shared,
        database: AppDatabase? = nil,
        pageDebounce: Duration = KavitaSync.pageDebounce
    ) {
        self.settings = settings
        kavita = KavitaClient(session: session) { [settings] in settings.credentials }
        self.database = database ?? Self.openDatabase()
        sync = KavitaSync(kavita: kavita, database: self.database, settings: settings, pageDebounce: pageDebounce)
        Task { [weak self, changes = kavita.connectionChanges] in
            for await connection in changes {
                self?.connection = connection
            }
        }
    }

    /// Starts delivering queued progress in the background, then runs library sync.
    /// Called once by the app; tests leave it out.
    func start() async {
        guard triggers == nil else { return }
        let triggers = SyncTriggers(sync: sync)
        self.triggers = triggers
        triggers.start()
        await sync.syncLibrary()
    }

    func sceneChanged(to phase: SyncTriggers.ScenePhaseChange) {
        triggers?.sceneChanged(to: phase)
    }

    func backgroundRefresh() async {
        await (triggers ?? SyncTriggers(sync: sync)).backgroundRefresh()
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
