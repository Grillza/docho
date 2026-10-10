import SwiftUI

/// Cover, details and the chapter list in Kavita reading order. Chapters can be marked read or
/// unread one at a time (swipe or press and hold) or several at once (Select).
struct SeriesView: View {
    @State private var model: SeriesModel
    @State private var selection = Set<Int>()
    @State private var editMode = EditMode.inactive
    private let fallbackTitle: String

    init(app: AppModel, seriesId: Int, title: String) {
        _model = State(initialValue: SeriesModel(app: app, seriesId: seriesId))
        fallbackTitle = title
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                SeriesHeader(model: model, fallbackTitle: fallbackTitle)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
            }

            Section {
                ForEach(model.chapters) { chapter in
                    ChapterRow(chapter: chapter)
                        .tag(chapter.id)
                        .accessibilityIdentifier("chapter.row")
                        .swipeActions(edge: .leading) { readButton(for: chapter) }
                        .contextMenu {
                            readButton(for: chapter)
                            Button {
                                Task { await model.markPreviousRead(chapter) }
                            } label: {
                                Label("Mark Previous as Read", systemImage: "arrow.up.to.line")
                            }
                        }
                }
            } header: {
                if !model.chapters.isEmpty {
                    Text("\(model.chapters.count) chapters")
                }
            }
        }
        .listStyle(.plain)
        .overlay { emptyState }
        .environment(\.editMode, $editMode)
        .refreshable { await model.refresh() }
        .navigationTitle(model.series?.name ?? fallbackTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await model.observeSeries() }
        .task { await model.observeChapters() }
        .task { await model.refresh() }
    }

    private func readButton(for chapter: ChapterRecord) -> some View {
        Button {
            Task { await model.setRead([chapter.id], !chapter.read) }
        } label: {
            if chapter.read {
                Label("Mark as Unread", systemImage: "eye.slash")
            } else {
                Label("Mark as Read", systemImage: "eye")
            }
        }
        .tint(.accentColor)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.chapters.isEmpty {
            if model.isRefreshing {
                ProgressView()
            } else if let error = model.refreshError {
                ContentUnavailableView {
                    Label("Couldn't Load Chapters", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await model.refresh() } }
                }
            } else {
                ContentUnavailableView("No Chapters", systemImage: "book.closed")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if editMode.isEditing {
                Button("Done") {
                    editMode = .inactive
                    selection = []
                }
            } else {
                Button("Select") { editMode = .active }
                    .disabled(model.chapters.isEmpty)
            }
        }
        if editMode.isEditing {
            ToolbarItemGroup(placement: .bottomBar) {
                Button(selection.count == model.chapters.count ? "Select None" : "Select All") {
                    selection = selection.count == model.chapters.count ? [] : Set(model.chapters.map(\.id))
                }
                Spacer()
                Button("Mark Read") { mark(read: true) }
                    .disabled(selection.isEmpty)
                Button("Mark Unread") { mark(read: false) }
                    .disabled(selection.isEmpty)
            }
        }
    }

    private func mark(read: Bool) {
        let ids = selection
        Task { await model.setRead(ids, read) }
        selection = []
        editMode = .inactive
    }
}

private struct SeriesHeader: View {
    let model: SeriesModel
    let fallbackTitle: String
    @Environment(AppModel.self) private var app
    @State private var summaryExpanded = false

    var body: some View {
        let series = model.series
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                SeriesCover(url: try? app.kavita.seriesCoverURL(seriesId: model.seriesId))
                    .frame(width: 110)
                VStack(alignment: .leading, spacing: 6) {
                    Text(series?.name ?? fallbackTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let authors = series?.authors {
                        Label(authors, systemImage: "person").font(.subheadline)
                    }
                    if let artists = series?.artists, artists != series?.authors {
                        Label(artists, systemImage: "paintbrush").font(.subheadline)
                    }
                    if let status = PublicationStatus.title(series?.status) {
                        Label(status, systemImage: "clock").font(.subheadline)
                    }
                    libraryButton(series)
                        .padding(.top, 4)
                }
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }

            if let summary = series?.summary {
                Text(summary)
                    .font(.callout)
                    .lineLimit(summaryExpanded ? nil : 3)
                    .onTapGesture { withAnimation { summaryExpanded.toggle() } }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(summaryExpanded ? "Collapses the summary" : "Shows the whole summary")
            }

            if let genres = series?.genres {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(genres.components(separatedBy: ", "), id: \.self) { genre in
                            Text(genre)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.quaternary, in: .capsule)
                        }
                    }
                }
            }

            if let error = model.refreshError, !model.chapters.isEmpty {
                Label("Couldn't refresh: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func libraryButton(_ series: SeriesRecord?) -> some View {
        let inLibrary = series?.inLibrary ?? false
        return Button {
            Task { await model.setInLibrary(!inLibrary) }
        } label: {
            Label(inLibrary ? "In Library" : "Add to Library", systemImage: inLibrary ? "heart.fill" : "heart")
        }
        .buttonStyle(.bordered)
        .disabled(series == nil)
        .accessibilityIdentifier("series.library")
    }
}

private struct ChapterRow: View {
    let chapter: ChapterRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(chapter.name)
                .foregroundStyle(chapter.read ? .secondary : .primary)
            HStack(spacing: 8) {
                if let date = chapter.dateUpload {
                    Text(date, format: .dateTime.day().month(.abbreviated).year())
                }
                if chapter.inProgress {
                    Text("Page \(chapter.lastPageRead + 1) of \(chapter.pages)")
                        .foregroundStyle(.tint)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(state)
    }

    private var state: Text {
        if chapter.read { return Text("Read") }
        if chapter.inProgress { return Text("Page \(chapter.lastPageRead + 1) of \(chapter.pages)") }
        return Text("Unread")
    }
}
