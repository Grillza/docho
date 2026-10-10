import SwiftUI

/// Cover, details and the chapter list in Kavita reading order. Chapters can be marked read or
/// unread, and downloaded or deleted, one at a time (swipe or press and hold) or several at once
/// (Select).
struct SeriesView: View {
    @State private var model: SeriesModel
    @State private var selection = Set<Int>()
    @State private var editMode = EditMode.inactive
    @State private var reading: ChapterRecord?
    private let app: AppModel
    private let fallbackTitle: String

    init(app: AppModel, seriesId: Int, title: String) {
        _model = State(initialValue: SeriesModel(app: app, seriesId: seriesId))
        self.app = app
        fallbackTitle = title
    }

    var body: some View {
        List(selection: editMode.isEditing ? $selection : nil) {
            Section {
                SeriesHeader(model: model, fallbackTitle: fallbackTitle) { reading = $0 }
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
            }

            Section {
                ForEach(model.chapters) { chapter in
                    chapterRow(chapter)
                        .swipeActions(edge: .leading) { readButton(for: chapter) }
                        .contextMenu {
                            readButton(for: chapter)
                            Button {
                                Task { await model.markPreviousRead(chapter) }
                            } label: {
                                Label("Mark Previous as Read", systemImage: "arrow.up.to.line")
                            }
                            downloadMenuItem(for: chapter)
                        }
                }
            } header: {
                if !model.chapters.isEmpty {
                    Text("^[\(model.chapters.count) chapter](inflect: true)")
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
        .fullScreenCover(item: $reading) { chapter in
            ReaderView(model: ReaderModel(
                app: app,
                seriesId: model.seriesId,
                seriesName: model.series?.name ?? fallbackTitle,
                readerMode: model.series?.readerMode,
                chapters: model.chapters,
                start: chapter
            ))
        }
        .task { await model.observeSeries() }
        .task { await model.observeChapters() }
        .task { await model.observeDownloads() }
        .task { await model.refresh() }
    }

    /// A tap opens the chapter, except while selecting.
    @ViewBuilder
    private func chapterRow(_ chapter: ChapterRecord) -> some View {
        if editMode.isEditing {
            ChapterRow(chapter: chapter).tag(chapter.id)
                .accessibilityIdentifier("chapter.row")
        } else {
            HStack {
                Button { reading = chapter } label: { ChapterRow(chapter: chapter) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chapter.row")
                DownloadButton(chapter: chapter, download: model.downloads[chapter.id], model: model)
            }
        }
    }

    @ViewBuilder
    private func downloadMenuItem(for chapter: ChapterRecord) -> some View {
        if chapter.isDownloaded {
            Button(role: .destructive) {
                Task { await model.deleteDownloads([chapter.id]) }
            } label: {
                Label("Delete Download", systemImage: "trash")
            }
        } else if model.downloads[chapter.id] != nil {
            Button {
                Task { await model.cancelDownload(chapter.id) }
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        } else {
            Button {
                Task { await model.download([chapter.id]) }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
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
        if !editMode.isEditing {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await model.downloadUnread() }
                    } label: {
                        Label("Download Unread", systemImage: "arrow.down.circle")
                    }
                    Button(role: .destructive) {
                        Task { await model.deleteAllDownloads(readOnly: true) }
                    } label: {
                        Label("Delete Read Downloads", systemImage: "trash")
                    }
                    Button(role: .destructive) {
                        Task { await model.deleteAllDownloads(readOnly: false) }
                    } label: {
                        Label("Delete All Downloads", systemImage: "trash")
                    }
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                .disabled(model.chapters.isEmpty)
                .accessibilityIdentifier("series.downloads")
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
                Button("Download") {
                    let ids = selection
                    Task { await model.download(ids) }
                    selection = []
                    editMode = .inactive
                }
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
    let read: (ChapterRecord) -> Void
    @Environment(AppModel.self) private var app
    @State private var summaryExpanded = false

    var body: some View {
        let series = model.series
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                SeriesCover(url: try? app.kavita.seriesCoverURL(seriesId: model.seriesId))
                    .frame(width: 110)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(series?.name ?? fallbackTitle)
                        .font(.title3.weight(.semibold))
                    Group {
                        if let authors = series?.authors {
                            Label(authors, systemImage: "person")
                        }
                        if let artists = series?.artists, artists != series?.authors {
                            Label(artists, systemImage: "paintbrush")
                        }
                        if let status = PublicationStatus.title(series?.status) {
                            Label(status, systemImage: "clock")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    HStack {
                        libraryButton(series)
                        resumeButton
                    }
                    .padding(.top, 4)
                }
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

    /// Starts or resumes the first chapter not read yet, as Mihon's resume button does.
    @ViewBuilder
    private var resumeButton: some View {
        if let next = model.chapters.first(where: { !$0.read }) {
            Button {
                read(next)
            } label: {
                Label(next.inProgress ? "Resume" : "Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(next.name)
            .accessibilityIdentifier("series.resume")
        }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(state)
    }

    private var state: Text {
        if chapter.read { return Text("Read") }
        if chapter.inProgress { return Text("Page \(chapter.lastPageRead + 1) of \(chapter.pages)") }
        return Text("Unread")
    }
}

/// A chapter's download state; tapping downloads it, cancels it, or retries a failed one.
private struct DownloadButton: View {
    let chapter: ChapterRecord
    let download: DownloadRecord?
    let model: SeriesModel

    var body: some View {
        Group {
            if chapter.isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Downloaded")
            } else if let download {
                switch download.state {
                case .queued:
                    button("Cancel download", "clock") { await model.cancelDownload(chapter.id) }
                case .downloading:
                    Button {
                        Task { await model.cancelDownload(chapter.id) }
                    } label: {
                        ProgressView(value: download.progress)
                            .progressViewStyle(.circular)
                            .frame(width: 22, height: 22)
                    }
                    .accessibilityLabel("Downloading, \(download.pagesDone) of \(download.pagesTotal) pages")
                    .accessibilityHint("Cancels the download")
                case .failed:
                    button("Download failed, retry", "exclamationmark.circle") { await model.retryDownloads() }
                        .foregroundStyle(.red)
                }
            } else {
                button("Download", "arrow.down.circle") { await model.download([chapter.id]) }
            }
        }
        .font(.title3)
        .frame(width: 44, height: 44)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("chapter.download")
    }

    private func button(_ label: LocalizedStringKey, _ image: String, action: @escaping @MainActor () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: image)
        }
        .accessibilityLabel(label)
    }
}
