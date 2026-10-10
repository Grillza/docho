import SwiftUI

struct LibraryView: View {
    var body: some View {
        ContentUnavailableView(
            "Your Library Is Empty",
            systemImage: "books.vertical",
            description: Text("Add series from Kavita in Browse.")
        )
        .navigationTitle("Library")
    }
}

#Preview {
    NavigationStack { LibraryView() }
}
