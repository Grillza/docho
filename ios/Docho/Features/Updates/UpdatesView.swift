import SwiftUI

/// Mihon's Updates: new chapters of library series, by the day they were found.
struct UpdatesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.openReader) private var openReader
    @State private var items: [UpdateItem] = []
    @State private var downloads: [Int: DownloadRecord] = [:]
    @State private var loaded = false
    @State private var lastUpdate: Date?
    @State private var selection = Set<Int>()

    var body: some View {
        VStack(spacing: 0) {
            if selection.isEmpty {
                TopAppBar(title: String(localized: "Updates")) {
                    AppBarIcon("refresh", label: String(localized: "Update library")) { Task { await app.library.update() } }
                }
            } else {
                TopAppBar(title: String(selection.count), onBack: { selection = [] }, elevated: true) {
                    AppBarIcon("select_all", label: String(localized: "Select all")) { selection = Set(items.map(\.id)) }
                }
            }
            if !loaded {
                LoadingScreen()
            } else if items.isEmpty {
                EmptyScreen(message: String(localized: "No recent updates"))
                    .refreshable { await app.library.update() }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        if let lastUpdate {
                            Text("Library last updated: \(lastUpdate.formatted(.relative(presentation: .named)))")
                                .font(M3Type.bodySmall)
                                .foregroundStyle(m3.onSurfaceVariant)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        if app.library.isRunning {
                            ProgressView(value: Double(app.library.progress.done), total: Double(max(app.library.progress.total, 1)))
                                .tint(m3.primary)
                                .padding(.horizontal, 16)
                        }
                        ForEach(groups, id: \.day) { group in
                            DayHeader(date: group.day)
                            ForEach(group.items) { item in row(item) }
                        }
                    }
                    .padding(.bottom, 16)
                }
                .refreshable { await app.library.update() }
            }
            if !selection.isEmpty { selectionBar }
        }
        .background(m3.surface)
        .task {
            do {
                for try await items in app.database.updates() {
                    self.items = items
                    loaded = true
                    lastUpdate = try? await app.database.lastLibraryUpdate()
                }
            } catch {}
        }
        .task {
            do {
                for try await queue in app.database.downloadQueue() {
                    downloads = Dictionary(queue.map { ($0.download.chapterId, $0.download) }) { first, _ in first }
                }
            } catch {}
        }
    }

    private var groups: [(day: Date, items: [UpdateItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.dateFetch) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    private func row(_ item: UpdateItem) -> some View {
        let selected = selection.contains(item.id)
        let source = app.source(for: item.series)
        return HStack(spacing: 0) {
            NavigationLink(value: Route.series(item.series.id)) {
                CoverImage(request: source.coverRequest(item.series.manga), ratio: 1).frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.series.name)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.series.name)
                    .font(M3Type.bodyMedium)
                    .foregroundStyle(m3.onSurface)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if item.chapter.bookmark { MIcon("bookmark.fill", size: 14).foregroundStyle(m3.primary) }
                    Text(item.chapter.name)
                        .font(M3Type.bodySmall)
                        .foregroundStyle(m3.onSurface.opacity(0.78))
                        .lineLimit(1)
                    if item.chapter.inProgress {
                        Text("• Page \(item.chapter.lastPageRead + 1)")
                            .font(M3Type.bodySmall)
                            .foregroundStyle(m3.onSurface.opacity(0.38))
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(item.chapter.read ? 0.38 : 1)
            ChapterDownloadIndicator(chapter: item.chapter, download: downloads[item.chapter.id]) {
                Task {
                    if item.chapter.isDownloaded {
                        await app.downloads.delete(seriesId: item.series.id, chapterIds: [item.chapter.id])
                    } else if downloads[item.chapter.id] != nil {
                        await app.downloads.cancel([(item.series.id, item.chapter.id)])
                    } else {
                        await app.userDownload([item.chapter])
                    }
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 64)
        .background(selected ? m3.secondaryContainer.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if selection.isEmpty {
                Task {
                    let chapters = (try? await app.database.chapterList(seriesId: item.series.id)) ?? []
                    openReader(series: item.series, chapters: chapters, start: item.chapter)
                }
            } else {
                toggle(item.id)
            }
        }
        .onLongPressGesture { toggle(item.id) }
    }

    private func toggle(_ id: Int) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private var selectionBar: some View {
        let selected = items.filter { selection.contains($0.id) }
        return HStack(spacing: 0) {
            barButton("done_all", String(localized: "Mark as read")) { mark(selected, read: true) }
            barButton("remove_done", String(localized: "Mark as unread")) { mark(selected, read: false) }
            barButton("download", String(localized: "Download")) {
                Task { await app.userDownload(selected.map(\.chapter)) }
            }
        }
        .padding(.vertical, 8)
        .background(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16).fill(m3.surfaceContainerHigh))
    }

    private func barButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            selection = []
        } label: {
            VStack(spacing: 4) {
                MIcon(icon)
                Text(title).font(M3Type.labelSmall)
            }
            .foregroundStyle(m3.onSurface)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ripple)
    }

    private func mark(_ items: [UpdateItem], read: Bool) {
        Task {
            for (seriesId, group) in Dictionary(grouping: items, by: \.series.id) {
                let chapters = group.map(\.chapter)
                try? await app.database.setChaptersRead(chapters.map(\.id), read: read)
                if let series = group.first?.series {
                    await app.sync.readStatusChanged(series, chapters: chapters, read: read)
                }
                _ = seriesId
            }
        }
    }
}

/// A day header in Updates and History ("Today", "Yesterday", or the date).
struct DayHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    let date: Date

    var body: some View {
        Text(RelativeDates.label(date, relative: app.preferences.relativeTimestamps, format: app.preferences.dateFormat))
            .font(M3Type.bodyMedium)
            .foregroundStyle(m3.onSurfaceVariant)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
