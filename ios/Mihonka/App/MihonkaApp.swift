import SwiftUI

@main
struct MihonkaApp: App {
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
