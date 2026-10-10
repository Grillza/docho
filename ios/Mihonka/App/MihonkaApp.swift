import SwiftUI

@main
struct MihonkaApp: App {
    @State private var model = AppModel()

    init() {
        AppModel.configureImagePipeline()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
