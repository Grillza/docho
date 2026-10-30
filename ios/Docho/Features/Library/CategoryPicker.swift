import SwiftUI

/// Mihon's "Set categories" dialog: tick the categories for the series; none means Default.
/// With `addsToLibrary`, OK also adds the series to the library.
struct CategoryPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.dismiss) private var dismiss
    let seriesIds: [Int]
    var addsToLibrary = false
    let onDone: () -> Void
    @State private var categories: [CategoryRecord] = []
    @State private var chosen = Set<Int>()
    @State private var newName = ""
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set categories")
                .font(M3Type.headlineSmall)
                .foregroundStyle(m3.onSurface)
                .padding(24)
            if categories.isEmpty {
                Text("You have no categories. Tap the plus button to create one for organizing your library.")
                    .font(M3Type.bodyMedium)
                    .foregroundStyle(m3.onSurfaceVariant)
                    .padding(.horizontal, 24)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(categories) { category in
                        CheckboxRow(title: category.name, isOn: Binding(
                            get: { chosen.contains(category.id) },
                            set: { if $0 { chosen.insert(category.id) } else { chosen.remove(category.id) } }
                        ))
                    }
                }
            }
            HStack {
                M3TextButton(title: String(localized: "Edit")) { creating = true }
                Spacer()
                M3TextButton(title: String(localized: "Cancel")) { dismiss() }
                M3TextButton(title: String(localized: "OK")) {
                    let categories = Array(chosen)
                    Task {
                        if addsToLibrary {
                            for id in seriesIds { try? await app.database.setInLibrary(seriesId: id, true, categories: categories) }
                        } else {
                            try? await app.database.setCategories(seriesIds: seriesIds, categories: categories)
                        }
                        onDone()
                        dismiss()
                    }
                }
            }
            .padding(16)
        }
        .background(m3.surfaceContainerHigh)
        .presentationDetents([.medium])
        .presentationBackground(m3.surfaceContainerHigh)
        .presentationCornerRadius(28)
        .task {
            categories = (try? await app.database.categoryList()) ?? []
            if seriesIds.count == 1, let first = seriesIds.first {
                chosen = Set((try? await app.database.categoryIds(seriesId: first)) ?? [])
            }
        }
        .m3Dialog(isPresented: $creating, title: String(localized: "Add category")) {
            M3TextField(label: String(localized: "Name"), text: $newName).padding(.horizontal, 24).padding(.top, 8)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { creating = false }
            M3TextButton(title: String(localized: "Add")) {
                let name = newName.trimmingCharacters(in: .whitespaces)
                creating = false
                newName = ""
                guard !name.isEmpty else { return }
                Task {
                    try? await app.database.createCategory(name)
                    categories = (try? await app.database.categoryList()) ?? []
                }
            }
        }
    }
}
