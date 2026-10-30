import SwiftUI

/// Mihon's History: the last chapter read of each series, by day, with search and deletion.
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.openReader) private var openReader
    @State private var items: [HistoryItem] = []
    @State private var loaded = false
    @State private var searching = false
    @State private var query = ""
    @State private var deleting: HistoryItem?
    @State private var deleteWholeSeries = false
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            if searching {
                HStack(spacing: 0) {
                    AppBarIcon("arrow_back", label: String(localized: "Back")) {
                        searching = false
                        query = ""
                    }
                    .foregroundStyle(m3.onSurface)
                    .padding(.leading, 4)
                    AppBarSearchField(placeholder: String(localized: "Search…"), text: $query).padding(.leading, 4)
                }
                .frame(height: 64)
                .background(m3.surface)
            } else {
                TopAppBar(title: String(localized: "History")) {
                    AppBarIcon("search", label: String(localized: "Search")) { searching = true }
                    AppBarIcon("delete_sweep", label: String(localized: "Clear history")) { confirmingClear = true }
                }
            }
            if !loaded {
                LoadingScreen()
            } else if items.isEmpty {
                EmptyScreen(message: query.isEmpty ? String(localized: "Nothing read recently") : String(localized: "No results found"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.day) { group in
                            DayHeader(date: group.day)
                            ForEach(group.items) { item in row(item) }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .background(m3.surface)
        .task(id: query) {
            do {
                for try await items in app.database.history(query: query) {
                    self.items = items
                    loaded = true
                }
            } catch {}
        }
        .m3Dialog(isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), title: String(localized: "Remove")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("This will remove the read date of this chapter. Are you sure?").padding(.horizontal, 24)
                CheckboxRow(title: String(localized: "Reset all chapters for this entry"), isOn: $deleteWholeSeries)
            }
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { deleting = nil }
            M3TextButton(title: String(localized: "Remove")) {
                if let item = deleting {
                    let whole = deleteWholeSeries
                    Task { try? await app.database.deleteHistory(chapterId: item.chapter.id, wholeSeries: whole) }
                }
                deleting = nil
            }
        }
        .m3Dialog(isPresented: $confirmingClear, title: String(localized: "Remove everything")) {
            Text("Are you sure? All history will be lost.").padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { confirmingClear = false }
            M3TextButton(title: String(localized: "OK")) {
                confirmingClear = false
                Task { try? await app.database.deleteAllHistory() }
            }
        }
    }

    private var groups: [(day: Date, items: [HistoryItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.lastRead) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    /// Mihon's HistoryItem: the cover, the title, the chapter and time, and delete and resume.
    private func row(_ item: HistoryItem) -> some View {
        let source = app.source(for: item.series)
        return HStack(spacing: 0) {
            NavigationLink(value: Route.series(item.series.id)) {
                CoverImage(request: source.coverRequest(item.series.manga)).frame(height: 80)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.series.name)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.series.name)
                    .font(M3Type.titleSmall)
                    .foregroundStyle(m3.onSurface)
                    .lineLimit(2)
                Text("\(item.chapter.name) - \(item.lastRead.formatted(date: .omitted, time: .shortened))")
                    .font(M3Type.bodySmall)
                    .foregroundStyle(m3.onSurface.opacity(0.78))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            AppBarIcon("delete", label: String(localized: "Delete")) {
                deleteWholeSeries = false
                deleting = item
            }
            .foregroundStyle(m3.onSurface)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { resume(item) }
        .accessibilityElement(children: .contain)
    }

    /// Opens the chapter after the one last read, or that one if it isn't finished.
    private func resume(_ item: HistoryItem) {
        Task {
            let chapters = (try? await app.database.chapterList(seriesId: item.series.id)) ?? []
            var start = item.chapter
            if item.chapter.read, let index = chapters.firstIndex(where: { $0.id == item.chapter.id }), index + 1 < chapters.count {
                start = chapters[index + 1]
            }
            openReader(series: item.series, chapters: chapters, start: start)
        }
    }
}
