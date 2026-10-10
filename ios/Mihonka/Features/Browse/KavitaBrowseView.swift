import SwiftUI

/// The Kavita source: every series on the server except EPUBs. Long-press adds a series to the
/// library or removes it, as in Mihon.
struct KavitaBrowseView: View {
    @Environment(AppModel.self) private var app
    @State private var model: KavitaBrowseModel
    @State private var libraries: [LibraryRecord] = []
    @State private var libraryIDs: Set<Int> = []

    init(client: KavitaClient) {
        _model = State(initialValue: KavitaBrowseModel(client: client))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: SeriesGrid.columns, spacing: 16) {
                ForEach(model.series) { series in
                    let inLibrary = libraryIDs.contains(series.id)
                    SeriesGridItem(title: series.title, coverURL: try? app.kavita.seriesCoverURL(seriesId: series.id), inLibrary: inLibrary)
                        .accessibilityIdentifier("browse.series")
                        .contextMenu {
                            Button {
                                Task { try? await app.database.setInLibrary(series, !inLibrary) }
                            } label: {
                                if inLibrary {
                                    Label("Remove from Library", systemImage: "heart.slash")
                                } else {
                                    Label("Add to Library", systemImage: "heart")
                                }
                            }
                        }
                        .task { await model.loadMoreIfNeeded(after: series) }
                }
            }
            .padding()

            if !model.series.isEmpty {
                footer
            }
        }
        .overlay { emptyState }
        .refreshable {
            await model.reload()
            await refreshLibraries()
        }
        .searchable(text: $model.request.query, prompt: "Search Kavita")
        .toolbar { filterMenu }
        .navigationTitle("Kavita")
        .task(id: model.request) {
            guard model.loadedRequest != model.request else { return }
            // Typing in search changes the request on every keystroke.
            if model.hasLoaded { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await model.reload()
        }
        .task { await refreshLibraries() }
        .task {
            do {
                for try await libraries in app.database.libraries() { self.libraries = libraries }
            } catch {}
        }
        .task {
            do {
                for try await ids in app.database.libraryIDs() { libraryIDs = ids }
            } catch {}
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isLoading {
            ProgressView().padding()
        } else if let error = model.error {
            VStack(spacing: 8) {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("Retry") { Task { await model.loadNextPage() } }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.series.isEmpty {
            if let error = model.error {
                ContentUnavailableView {
                    Label("Couldn't Load Kavita", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await model.reload() } }
                }
            } else if model.isLoading || !model.hasLoaded {
                ProgressView()
            } else if !model.request.query.isBlank {
                ContentUnavailableView.search(text: model.request.query)
            } else {
                ContentUnavailableView("No Series", systemImage: "books.vertical")
            }
        }
    }

    private var filterMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Library", selection: $model.request.libraryId) {
                    Text("All libraries").tag(Int?.none)
                    ForEach(libraries) { library in
                        Text(library.name).tag(Int?.some(library.id))
                    }
                }
                Picker("Sort", selection: $model.request.sort) {
                    ForEach(KavitaBrowseSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                Toggle("Ascending", isOn: $model.request.ascending)
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }

    private func refreshLibraries() async {
        guard let libraries = try? await app.kavita.libraries() else { return }
        try? await app.database.saveLibraries(libraries)
    }
}
