import SwiftUI

@main
struct DokiApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppModel.configureImagePipeline()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.sceneChanged(to: .active)
            case .background: model.sceneChanged(to: .background)
            default: break
            }
        }
        .backgroundTask(.appRefresh(SyncTriggers.refreshTaskIdentifier)) { [model] in
            await model.backgroundRefresh()
        }
    }
}

/// Hands iOS's wake-up for finished background downloads to the download session.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundPageFetcher.identifier else { return completionHandler() }
        nonisolated(unsafe) let completion = completionHandler
        BackgroundPageFetcher.shared.setEventsCompletion { completion() }
    }
}
