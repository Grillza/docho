import SwiftUI

/// Lists the sources. Kavita is the only one.
struct BrowseView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                NavigationLink {
                    KavitaBrowseView(client: app.kavita)
                } label: {
                    Label("Kavita", systemImage: "server.rack")
                }
                .disabled(!app.settings.credentials.isConfigured)
            } header: {
                Text("Sources")
            } footer: {
                if !app.settings.credentials.isConfigured {
                    Text("Add your Kavita server in Settings first.")
                }
            }
        }
        .navigationTitle("Browse")
    }
}

#Preview {
    NavigationStack { BrowseView() }
        .environment(AppModel())
}
