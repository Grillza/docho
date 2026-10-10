import Foundation
import Observation

/// The dependency container: one instance for the app, handed to views through the environment.
@MainActor
@Observable
final class AppModel {
    let settings: KavitaSettings
    let kavita: KavitaClient

    /// Mirrors the client's latest sign-in outcome for the UI.
    private(set) var connection: KavitaConnection = .unknown

    init(settings: KavitaSettings = KavitaSettings(), session: URLSession = .shared) {
        self.settings = settings
        kavita = KavitaClient(session: session) { [settings] in settings.credentials }
        Task { [weak self, changes = kavita.connectionChanges] in
            for await connection in changes {
                self?.connection = connection
            }
        }
    }
}
