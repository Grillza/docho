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

    /// Mirrors the client's latest sign-in outcome for the UI.
    private(set) var connection: KavitaConnection = .unknown

    init(settings: KavitaSettings = KavitaSettings(), session: URLSession = .shared, database: AppDatabase? = nil) {
        self.settings = settings
        kavita = KavitaClient(session: session) { [settings] in settings.credentials }
        self.database = database ?? Self.openDatabase()
        Task { [weak self, changes = kavita.connectionChanges] in
            for await connection in changes {
                self?.connection = connection
            }
        }
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
