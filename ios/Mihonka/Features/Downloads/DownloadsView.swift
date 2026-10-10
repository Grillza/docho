import SwiftUI

struct DownloadsView: View {
    var body: some View {
        ContentUnavailableView(
            "No Downloads",
            systemImage: "arrow.down.circle",
            description: Text("Downloaded chapters can be read without a network.")
        )
        .navigationTitle("Downloads")
    }
}

#Preview {
    NavigationStack { DownloadsView() }
}
