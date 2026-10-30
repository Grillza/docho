import SwiftUI

/// Mihon's library: the series you've added, in category tabs, with search, filters, sort and
/// display options, a continue-reading button, and multi-select.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.openReader) private var openReader
    @Environment(\.navigate) private var navigate
    @Environment(\.openBrowse) private var openBrowse
    @State private var items: [LibraryItem] = []
    @State private var categories: [CategoryRecord] = []
    @State private var loaded = false
    @State private var categoryIndex = 0
    @State private var searching = false
    @State private var query = ""
    @State private var selection = Set<Int>()
    @State private var showSettings = false
    @State private var changingCategories = false
    @State private var confirmingRemove = false

    private var preferences: AppPreferences { app.preferences }

    /// The tabs: the default category when it has entries (or there's nothing else), then the user's.
    private var tabs: [CategoryRecord] {
        let hasUncategorised = items.contains { $0.categoryIds.isEmpty }
        let defaultTab = hasUncategorised || categories.isEmpty ? [CategoryRecord.default] : []
        return defaultTab + categories
    }

    private var currentCategory: CategoryRecord? {
        tabs.isEmpty ? nil : tabs[min(categoryIndex, tabs.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            appBar
            if preferences.categoryTabs, tabs.count > 1 {
                M3Tabs(
                    tabs: Array(tabs.indices), selection: $categoryIndex, scrollable: true,
                    title: { tabs[$0].name },
                    badge: { preferences.categoryCounts ? String(entries(in: tabs[$0]).count) : nil }
                )
            }
            content
            if !selection.isEmpty { selectionBar }
        }
        .background(m3.surface)
        .task { await observeLibrary() }
        .task { await observeCategories() }
        .onChange(of: categoryIndex) { _, index in preferences.lastCategoryIndex = index }
        .onAppear { categoryIndex = preferences.lastCategoryIndex }
        .m3Sheet(isPresented: $showSettings) { LibrarySettingsSheet(category: currentCategory) }
        .sheet(isPresented: $changingCategories) {
            CategoryPicker(seriesIds: Array(selection)) { selection = [] }
        }
        .m3Dialog(isPresented: $confirmingRemove, title: String(localized: "Remove from library")) {
            Text("Remove \(selection.count) entries from the library? Their downloads stay on the device.")
                .padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { confirmingRemove = false }
            M3TextButton(title: String(localized: "Remove")) {
                let ids = selection
                confirmingRemove = false
                selection = []
                Task { for id in ids { try? await app.database.setInLibrary(seriesId: id, false) } }
            }
        }
    }

    // MARK: App bar

    @ViewBuilder
    private var appBar: some View {
        if !selection.isEmpty {
            TopAppBar(title: String(selection.count), onBack: { selection = [] }, elevated: true) {
                AppBarIcon("select_all", label: String(localized: "Select all")) {
                    selection.formUnion(visibleItems.map(\.id))
                }
                AppBarIcon("flip_to_back", label: String(localized: "Select inverse")) {
                    selection = Set(visibleItems.map(\.id)).subtracting(selection)
                }
            }
        } else if searching {
            HStack(spacing: 0) {
                AppBarIcon("arrow_back", label: String(localized: "Back")) {
                    searching = false
                    query = ""
                }
                .foregroundStyle(m3.onSurface)
                .padding(.leading, 4)
                AppBarSearchField(placeholder: String(localized: "Search…"), text: $query)
                    .padding(.leading, 4)
                if !query.isEmpty {
                    AppBarIcon("close", label: String(localized: "Clear")) { query = "" }
                        .foregroundStyle(m3.onSurfaceVariant)
                }
            }
            .frame(height: 64)
            .padding(.trailing, 4)
            .background(m3.surface)
        } else {
            TopAppBar(title: String(localized: "Library")) {
                AppBarIcon("search", label: String(localized: "Search")) { searching = true }
                AppBarIcon("filter_list", label: String(localized: "Filter")) { showSettings = true }
                    .foregroundStyle(preferences.hasLibraryFilter ? Color(hex: 0xFFC107) : m3.onSurfaceVariant)
                OverflowMenu {
                    Button(String(localized: "Update library")) { Task { await app.library.update() } }
                    Button(String(localized: "Update category")) { Task { await app.library.update(category: currentCategory?.id) } }
                    Button(String(localized: "Open random entry")) {
                        if let random = visibleItems.randomElement() { navigate(.series(random.id)) }
                    }
                }
            }
            .accessibilityIdentifier("library.appbar")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !loaded {
            LoadingScreen()
        } else if items.isEmpty {
            EmptyScreen(message: String(localized: "Your library is empty")) {
                M3TextButton(title: String(localized: "Add files from Browse")) { openBrowse() }
                    .accessibilityIdentifier("library.addFromBrowse")
            }
        } else {
            let visible = visibleItems
            ScrollView {
                if visible.isEmpty {
                    EmptyScreen(message: query.isEmpty
                        ? String(localized: "This category is empty")
                        : String(localized: "No matches found in your library"))
                        .frame(minHeight: 400)
                }
                MangaGrid(items: visible, mode: preferences.displayMode, columns: columns) { item in
                    cell(item)
                }
                if app.library.isRunning {
                    ProgressView(value: Double(app.library.progress.done), total: Double(max(app.library.progress.total, 1)))
                        .tint(m3.primary)
                        .padding(16)
                }
            }
            .refreshable { await app.library.update(category: currentCategory?.id) }
            .background(m3.surface)
        }
    }

    private var columns: Int {
        UIScreen.main.bounds.width > UIScreen.main.bounds.height ? preferences.gridColumnsLandscape : preferences.gridColumnsPortrait
    }

    private func cell(_ item: LibraryItem) -> some View {
        let source = app.source(for: item.series)
        var start: [MangaItem.ItemBadge] = []
        if preferences.downloadBadge, item.downloadCount > 0 { start.append(.downloaded(item.downloadCount)) }
        if preferences.unreadBadge, item.unreadCount > 0 { start.append(.unread(item.unreadCount)) }
        let end: [MangaItem.ItemBadge] = preferences.sourceBadge ? [.text(source.name)] : []
        let selected = selection.contains(item.id)
        return MangaItem(
            title: item.series.name, cover: source.coverRequest(item.series.manga), mode: preferences.displayMode,
            selected: selected, startBadges: start, endBadges: end,
            onContinueReading: preferences.continueReadingButton && item.unreadCount > 0 ? { continueReading(item.series) } : nil
        )
        .overlay {
            if selection.isEmpty {
                NavigationLink(value: Route.series(item.id)) { Color.clear }
                    .simultaneousGesture(LongPressGesture().onEnded { _ in selection.insert(item.id) })
            } else {
                Color.clear.contentShape(Rectangle()).onTapGesture { toggle(item.id) }
            }
        }
        .accessibilityIdentifier("library.item")
    }

    private func toggle(_ id: Int) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func continueReading(_ series: SeriesRecord) {
        Task {
            guard let next = try? await app.database.nextChapter(seriesId: series.id),
                  let chapters = try? await app.database.chapterList(seriesId: series.id)
            else { return }
            openReader(series: series, chapters: chapters, start: next)
        }
    }

    // MARK: Selection actions (Mihon's LibraryBottomActionMenu)

    private var selectionBar: some View {
        HStack(spacing: 0) {
            actionButton("label", String(localized: "Set categories")) { changingCategories = true }
            actionButton("done_all", String(localized: "Mark as read")) { mark(read: true) }
            actionButton("remove_done", String(localized: "Mark as unread")) { mark(read: false) }
            Menu {
                Button(String(localized: "Next chapter")) { download(limit: 1) }
                Button(String(localized: "Next 5 chapters")) { download(limit: 5) }
                Button(String(localized: "Next 10 chapters")) { download(limit: 10) }
                Button(String(localized: "Unread")) { download(limit: nil) }
            } label: {
                actionLabel("download", String(localized: "Download"))
            }
            actionButton("delete", String(localized: "Delete")) { confirmingRemove = true }
        }
        .padding(.vertical, 8)
        .background(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16).fill(m3.surfaceContainerHigh).ignoresSafeArea(edges: .bottom))
    }

    private func actionButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(icon, title) }.buttonStyle(.ripple)
    }

    private func actionLabel(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            MIcon(icon)
            Text(title).font(M3Type.labelSmall).lineLimit(1)
        }
        .foregroundStyle(m3.onSurface)
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func mark(read: Bool) {
        let ids = selection
        selection = []
        Task {
            for id in ids {
                guard let series = try? await app.database.seriesRecord(id: id),
                      let chapters = try? await app.database.chapterList(seriesId: id)
                else { continue }
                let changed = chapters.filter { $0.read != read }
                guard !changed.isEmpty else { continue }
                try? await app.database.setChaptersRead(changed.map(\.id), read: read)
                await app.sync.readStatusChanged(series, chapters: changed, read: read)
            }
        }
    }

    private func download(limit: Int?) {
        let ids = selection
        selection = []
        Task {
            for id in ids {
                guard let chapters = try? await app.database.chapterList(seriesId: id) else { continue }
                let unread = chapters.filter { !$0.read && !$0.isDownloaded }
                await app.userDownload(limit.map { Array(unread.prefix($0)) } ?? unread)
            }
        }
    }

    // MARK: Data

    private func observeLibrary() async {
        do {
            for try await items in app.database.library() {
                self.items = items
                loaded = true
            }
        } catch {}
    }

    private func observeCategories() async {
        do {
            for try await categories in app.database.categories() { self.categories = categories }
        } catch {}
    }

    private func entries(in category: CategoryRecord) -> [LibraryItem] {
        items.filter { category.isDefault ? $0.categoryIds.isEmpty : $0.categoryIds.contains(category.id) }
    }

    /// The current category's entries after search, filters and sort.
    private var visibleItems: [LibraryItem] {
        let base = (preferences.categoryTabs ? currentCategory.map(entries(in:)) : nil) ?? items
        let needle = query.trimmingCharacters(in: .whitespaces)
        let filtered = base.filter { item in
            if !needle.isEmpty, item.series.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
            let downloaded = preferences.downloadedOnly ? ChapterDisplay.TriState.include : preferences.filterDownloaded
            return Self.matches(downloaded, item.downloadCount > 0)
                && Self.matches(preferences.filterUnread, item.unreadCount > 0)
                && Self.matches(preferences.filterStarted, item.hasStarted)
                && Self.matches(preferences.filterBookmarked, item.bookmarkCount > 0)
                && Self.matches(preferences.filterCompleted, item.series.mangaStatus == .completed)
        }
        let sorted = filtered.sorted { lhs, rhs in
            switch preferences.librarySort {
            case .alphabetical: lhs.series.name.localizedCaseInsensitiveCompare(rhs.series.name) == .orderedAscending
            case .lastRead: (lhs.lastRead ?? .distantPast) < (rhs.lastRead ?? .distantPast)
            case .lastUpdate: (lhs.series.lastUpdate ?? .distantPast) < (rhs.series.lastUpdate ?? .distantPast)
            case .unreadCount: lhs.unreadCount < rhs.unreadCount
            case .totalChapters: lhs.totalChapters < rhs.totalChapters
            case .latestChapter: (lhs.latestUpload ?? .distantPast) < (rhs.latestUpload ?? .distantPast)
            case .chapterFetchDate: (lhs.chapterFetchedAt ?? .distantPast) < (rhs.chapterFetchedAt ?? .distantPast)
            case .dateAdded: (lhs.series.dateAdded ?? .distantPast) < (rhs.series.dateAdded ?? .distantPast)
            }
        }
        return preferences.librarySortAscending ? sorted : sorted.reversed()
    }

    private static func matches(_ state: ChapterDisplay.TriState, _ value: Bool) -> Bool {
        switch state {
        case .off: true
        case .include: value
        case .exclude: !value
        }
    }
}

/// Mihon's library settings sheet: Filter, Sort and Display tabs.
struct LibrarySettingsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    let category: CategoryRecord?
    @State private var tab = 0

    var body: some View {
        @Bindable var preferences = app.preferences
        VStack(spacing: 0) {
            M3Tabs(tabs: [0, 1, 2], selection: $tab, title: {
                [String(localized: "Filter"), String(localized: "Sort"), String(localized: "Display")][$0]
            })
            ScrollView {
                VStack(spacing: 0) {
                    switch tab {
                    case 0:
                        TriStateRow(
                            title: String(localized: "Downloaded"),
                            state: preferences.downloadedOnly ? .constant(.include) : $preferences.filterDownloaded,
                            enabled: !preferences.downloadedOnly
                        )
                        TriStateRow(title: String(localized: "Unread"), state: $preferences.filterUnread)
                        TriStateRow(title: String(localized: "Started"), state: $preferences.filterStarted)
                        TriStateRow(title: String(localized: "Bookmarked"), state: $preferences.filterBookmarked)
                        TriStateRow(title: String(localized: "Completed"), state: $preferences.filterCompleted)
                    case 1:
                        ForEach(AppPreferences.LibrarySort.allCases, id: \.self) { sort in
                            SortRow(title: sort.title, selected: preferences.librarySort == sort, ascending: preferences.librarySortAscending) {
                                if preferences.librarySort == sort {
                                    preferences.librarySortAscending.toggle()
                                } else {
                                    preferences.librarySort = sort
                                    preferences.librarySortAscending = sort == .alphabetical
                                }
                            }
                        }
                    default:
                        PreferenceHeader(title: String(localized: "Display mode"))
                        ForEach(AppPreferences.DisplayMode.allCases, id: \.self) { mode in
                            RadioRow(title: mode.title, selected: preferences.displayMode == mode) { preferences.displayMode = mode }
                        }
                        if preferences.displayMode != .list {
                            PreferenceHeader(title: String(localized: "Grid size"))
                            Stepper(
                                value: $preferences.gridColumnsPortrait, in: 0...10,
                                label: {
                                    Text(preferences.gridColumnsPortrait == 0
                                        ? String(localized: "Items per row: Default")
                                        : String(localized: "Items per row: \(preferences.gridColumnsPortrait)"))
                                        .font(M3Type.bodyMedium).foregroundStyle(m3.onSurface)
                                }
                            )
                            .padding(.horizontal, 24)
                            .frame(minHeight: 48)
                        }
                        PreferenceHeader(title: String(localized: "Badges"))
                        CheckboxRow(title: String(localized: "Downloaded chapters"), isOn: $preferences.downloadBadge)
                        CheckboxRow(title: String(localized: "Unread chapters"), isOn: $preferences.unreadBadge)
                        CheckboxRow(title: String(localized: "Source"), isOn: $preferences.sourceBadge)
                        PreferenceHeader(title: String(localized: "Tabs"))
                        CheckboxRow(title: String(localized: "Show category tabs"), isOn: $preferences.categoryTabs)
                        CheckboxRow(title: String(localized: "Show number of items"), isOn: $preferences.categoryCounts)
                        PreferenceHeader(title: String(localized: "Other"))
                        CheckboxRow(title: String(localized: "Show continue reading button"), isOn: $preferences.continueReadingButton)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.top, 16)
        .background(m3.surfaceContainerLow)
    }
}
