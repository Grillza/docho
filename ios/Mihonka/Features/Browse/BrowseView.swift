import SwiftUI

/// Lists the sources. Kavita is the only one; its series grid arrives in milestone 3.
struct BrowseView: View {
    var body: some View {
        List {
            Section("Sources") {
                Label("Kavita", systemImage: "server.rack")
            }
        }
        .navigationTitle("Browse")
    }
}

#Preview {
    NavigationStack { BrowseView() }
}
