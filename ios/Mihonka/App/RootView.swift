import SwiftUI

/// A tab bar on iPhone. On iPad, `.sidebarAdaptable` gives a tab bar that expands into a sidebar.
struct RootView: View {
    @State private var selection: AppSection = .library

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppSection.allCases) { section in
                Tab(section.title, systemImage: section.systemImage, value: section) {
                    NavigationStack {
                        section.screen
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

private extension AppSection {
    @MainActor @ViewBuilder
    var screen: some View {
        switch self {
        case .library: LibraryView()
        case .browse: BrowseView()
        case .downloads: DownloadsView()
        case .settings: SettingsView()
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
