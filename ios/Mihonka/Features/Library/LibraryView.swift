import SwiftUI

/// The series you've added, from the database.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var series: [SeriesRecord] = []
    @State private var loaded = false
    @State private var refreshError: String?

    var body: some View {
        ScrollView {
            if let refreshError {
                Text("Couldn't refresh: \(refreshError)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            LazyVGrid(columns: SeriesGrid.columns, spacing: 16) {
                ForEach(series) { record in
                    NavigationLink {
                        SeriesView(app: app, seriesId: record.id, title: record.name)
                    } label: {
                        SeriesGridItem(title: record.name, coverURL: try? app.kavita.seriesCoverURL(seriesId: record.id))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.series")
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { try? await app.database.setInLibrary(seriesId: record.id, false) }
                            } label: {
                                Label("Remove from Library", systemImage: "heart.slash")
                            }
                        }
                }
            }
            .padding()
        }
        .overlay {
            if loaded && series.isEmpty {
                ContentUnavailableView(
                    "Your Library Is Empty",
                    systemImage: "books.vertical",
                    description: Text("Add series from Kavita in Browse: press and hold a cover.")
                )
            }
        }
        .refreshable { await refresh() }
        .navigationTitle("Library")
        .task {
            do {
                for try await series in app.database.librarySeries() {
                    self.series = series
                    loaded = true
                }
            } catch {}
        }
    }

    /// Picks up renamed or moved series from Kavita. Progress sync joins in milestone 6.
    private func refresh() async {
        let ids = series.map(\.id)
        let kavita = app.kavita
        do {
            let updated = try await withThrowingTaskGroup(of: KavitaSeries.self) { group in
                for id in ids {
                    group.addTask { try await kavita.series(id: id) }
                }
                var updated: [KavitaSeries] = []
                for try await series in group {
                    updated.append(series)
                }
                return updated
            }
            try await app.database.updateSeries(updated)
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { LibraryView() }
        .environment(AppModel())
}
