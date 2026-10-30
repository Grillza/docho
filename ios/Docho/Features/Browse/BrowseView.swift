import NukeUI
import SwiftUI

/// What a source's listing shows.
enum BrowseListing: Hashable {
    case popular
    case latest
    /// Docho's Unread listing: series not finished on the server.
    case unread
    case search(String)
}

/// Mihon's Browse → Sources: the sources set up, by language (built-in servers are "Other").
struct BrowseView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.navigate) private var navigate
    @State private var searching = false
    @State private var query = ""
    @State private var tab = BrowseTab.sources
    @State private var choosingLanguages = false

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
                    AppBarSearchField(placeholder: String(localized: "Global search"), text: $query) {
                        let text = query
                        searching = false
                        query = ""
                        navigate(.globalSearch(text))
                    }
                    .padding(.leading, 4)
                }
                .frame(height: 64)
                .background(m3.surface)
            } else {
                TopAppBar(title: String(localized: "Browse")) {
                    if tab == .extensions {
                        AppBarIcon("refresh", label: String(localized: "Check for updates")) {
                            Task { await app.suwayomi.loadExtensions(refresh: true) }
                        }
                    } else {
                        AppBarIcon("travel_explore", label: String(localized: "Global search")) { searching = true }
                    }
                    if app.suwayomi.isConfigured {
                        AppBarIcon("filter_list", label: String(localized: "Languages")) { choosingLanguages = true }
                    }
                }
            }
            if app.suwayomi.isConfigured {
                M3Tabs(tabs: BrowseTab.allCases, selection: $tab, title: \.title, badge: { tab in
                    let updates = app.suwayomi.extensions.filter { $0.isInstalled && $0.hasUpdate }.count
                    return tab == .extensions && updates > 0 ? String(updates) : nil
                })
            }
            if tab == .extensions, app.suwayomi.isConfigured {
                ExtensionsView(query: "")
            } else {
                sourceList
            }
        }
        .background(m3.surface)
        .m3Sheet(isPresented: $choosingLanguages) { LanguagesSheet() }
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.environment["DOCHO_OPEN"] == "extensions" { tab = .extensions } }
        #endif
    }

    enum BrowseTab: CaseIterable {
        case sources, extensions

        var title: String {
            switch self {
            case .sources: String(localized: "Sources")
            case .extensions: String(localized: "Extensions")
            }
        }
    }

    @ViewBuilder
    private var sourceList: some View {
        let groups = sourceGroups
        if groups.isEmpty {
            EmptyScreen(message: String(localized: "No sources set up. Add Kavita, Komga, BookOrbit or a Suwayomi server for extensions in Settings → Sync.")) {
                NavigationLink(value: Route.settingsPage(.sync)) {
                    Text("Set up a server").font(M3Type.labelLarge).foregroundStyle(m3.primary)
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title)
                            .font(M3Type.bodyMedium)
                            .foregroundStyle(m3.onSurfaceVariant)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.sources, id: \.id) { source in
                            SourceRow(source: source)
                        }
                    }
                }
            }
        }
    }

    /// The built-in sources under "Other", then the server's by language, as Mihon groups them.
    private var sourceGroups: [(title: String, sources: [any MangaSource])] {
        _ = app.suwayomi.sourceInfos
        let showNSFW = app.suwayomiSettings.showNSFW
        let languages = Set(app.preferences.sourceLanguages)
        let sources = app.sources.available.filter { source in
            guard let remote = source as? SuwayomiSource else { return true }
            return (showNSFW || !remote.info.isNSFW) && languages.contains(remote.lang)
        }
        let builtIn = sources.filter { !($0 is SuwayomiSource) }
        let remote = Dictionary(grouping: sources.filter { $0 is SuwayomiSource }, by: \.lang)
        var groups: [(title: String, sources: [any MangaSource])] = []
        if !builtIn.isEmpty { groups.append((String(localized: "Other"), builtIn)) }
        for lang in remote.keys.sorted(by: { ExtensionsView.languageName($0) < ExtensionsView.languageName($1) }) {
            let list = remote[lang, default: []].sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            groups.append((ExtensionsView.languageName(lang), list))
        }
        return groups
    }
}

/// Mihon's source item: the source's icon and name, with "Latest" at the end.
private struct SourceRow: View {
    @Environment(\.m3) private var m3
    let source: any MangaSource

    var body: some View {
        NavigationLink(value: Route.source(source.id, listing: .popular)) {
            HStack(spacing: 0) {
                SourceIcon(source: source).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text(source.name).font(M3Type.bodyMedium).foregroundStyle(m3.onSurface)
                    Text(ExtensionsView.languageName(source.lang)).font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                if source.supportsLatest {
                    NavigationLink(value: Route.source(source.id, listing: .latest)) {
                        Text("Latest").font(M3Type.labelLarge).foregroundStyle(m3.primary).padding(.horizontal, 12).frame(minHeight: 40)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ripple)
        .accessibilityIdentifier("browse.source.\(source.name)")
    }
}

/// A source's logo, or its initial.
struct SourceIcon: View {
    @Environment(\.m3) private var m3
    let source: any MangaSource

    var body: some View {
        if let remote = source as? SuwayomiSource, let request = remote.client.request(remote.info.iconPath) {
            LazyImage(request: ImageRequest(urlRequest: request)) { state in
                if let image = state.image { image.resizable().scaledToFit() } else { m3.surfaceContainerHighest }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
        } else if let asset = source.iconAsset, UIImage(named: asset) != nil {
            Image(asset).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
        } else {
            Text(source.name.prefix(1))
                .font(M3Type.titleLarge)
                .foregroundStyle(m3.onSecondaryContainer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(m3.secondaryContainer))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - A source's listing

@MainActor
@Observable
final class BrowseSourceModel {
    let source: any MangaSource
    private let app: AppModel
    var listing: BrowseListing
    private(set) var items: [SeriesRecord] = []
    private(set) var hasNextPage = true
    private(set) var isLoading = false
    private(set) var error: String?
    var filters: [SourceFilter] = []
    private(set) var defaultFilters: [SourceFilter] = []
    private var page = 1
    private var generation = 0

    init(app: AppModel, source: any MangaSource, listing: BrowseListing) {
        self.app = app
        self.source = source
        self.listing = listing
    }

    func loadFilters() async {
        guard defaultFilters.isEmpty else { return }
        defaultFilters = await source.filterList()
        if filters.isEmpty { filters = defaultFilters }
    }

    func restart(_ listing: BrowseListing) async {
        self.listing = listing
        generation += 1
        items = []
        page = 1
        hasNextPage = true
        error = nil
        await loadMore()
    }

    func loadMore() async {
        guard hasNextPage, !isLoading else { return }
        let generation = generation
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        do {
            let result: MangasPage = switch listing {
            case .popular: try await source.popular(page: page)
            case .latest: try await source.latest(page: page)
            case .unread: try await source.unread(page: page)
            case .search(let query): try await source.search(page: page, query: query, filters: filters)
            }
            guard generation == self.generation else { return }
            let stored = try await app.database.localSeries(source: source.id, mangas: result.mangas)
            let known = Set(items.map(\.id))
            items += stored.filter { !known.contains($0.id) }
            hasNextPage = result.hasNextPage && !result.mangas.isEmpty
            page += 1
            error = nil
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
            hasNextPage = false
        }
    }
}

/// Mihon's BrowseSourceScreen: Popular, Latest (and Docho's Unread), search and filters.
struct BrowseSourceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.openURL) private var openURL
    let sourceId: Int64
    let listing: BrowseListing
    @State private var model: BrowseSourceModel?
    @State private var searching = false
    @State private var query = ""
    @State private var showFilters = false
    @State private var libraryKeys = Set<String>()
    @State private var pendingAdd: SeriesRecord?
    @State private var importing = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                LoadingScreen()
            }
        }
        .background(m3.surface)
        .task {
            guard model == nil else { return }
            let model = BrowseSourceModel(app: app, source: app.sources.source(sourceId), listing: listing)
            self.model = model
            if case .search(let text) = listing { query = text }
            await model.loadMore()
        }
        .task {
            do {
                for try await keys in app.database.libraryKeys(source: sourceId) { libraryKeys = keys }
            } catch {}
        }
    }

    private func content(_ model: BrowseSourceModel) -> some View {
        VStack(spacing: 0) {
            appBar(model)
            chips(model)
            M3Divider()
            let visible = app.preferences.hideInLibraryItems ? model.items.filter { !libraryKeys.contains($0.url) } : model.items
            if visible.isEmpty, model.isLoading {
                LoadingScreen()
            } else if visible.isEmpty, model.error == nil, sourceId == LocalSource.id, model.listing == .popular {
                EmptyScreen(message: String(localized: "No local comics yet. Add CBZ, CBR, CB7, EPUB or PDF files, or put them in Files › On My iPhone › Dōchō › local.")) {
                    M3TextButton(title: String(localized: "Add from Files")) { importing = true }
                }
            } else if visible.isEmpty {
                EmptyScreen(message: model.error ?? String(localized: "No results found")) {
                    M3TextButton(title: String(localized: "Retry")) { Task { await model.restart(model.listing) } }
                }
            } else {
                ScrollView {
                    MangaGrid(items: visible, mode: app.preferences.browseDisplayMode) { series in
                        let inLibrary = libraryKeys.contains(series.url)
                        MangaItem(
                            title: series.name, cover: model.source.coverRequest(series.manga), mode: app.preferences.browseDisplayMode,
                            dimmed: inLibrary, startBadges: inLibrary ? [.inLibrary] : []
                        )
                        .overlay {
                            NavigationLink(value: Route.series(series.id)) { Color.clear }
                                .simultaneousGesture(LongPressGesture().onEnded { _ in toggleLibrary(series, inLibrary: inLibrary) })
                        }
                        .onAppear {
                            if series.id == visible.last?.id { Task { await model.loadMore() } }
                        }
                        .accessibilityIdentifier("browse.item")
                    }
                    if model.isLoading {
                        ProgressView().tint(m3.primary).padding(24)
                    } else if let error = model.error {
                        Text(error).font(M3Type.bodySmall).foregroundStyle(m3.error).padding(16)
                    }
                }
                .refreshable { await model.restart(model.listing) }
            }
        }
        .m3Sheet(isPresented: $showFilters) {
            SourceFilterSheet(filters: Binding(get: { model.filters }, set: { model.filters = $0 }), defaults: model.defaultFilters) {
                showFilters = false
                Task { await model.restart(.search(query)) }
            }
        }
        .sheet(item: $pendingAdd) { series in
            CategoryPicker(seriesIds: [series.id], addsToLibrary: true) {}
        }
        .localImport(isPresented: $importing) { _ in
            Task { await model.restart(model.listing) }
        }
    }

    @ViewBuilder
    private func appBar(_ model: BrowseSourceModel) -> some View {
        if searching {
            HStack(spacing: 0) {
                AppBarIcon("arrow_back", label: String(localized: "Back")) { searching = false }
                    .foregroundStyle(m3.onSurface)
                    .padding(.leading, 4)
                AppBarSearchField(placeholder: String(localized: "Search…"), text: $query) {
                    Task { await model.restart(.search(query)) }
                }
                .padding(.leading, 4)
                if !query.isEmpty {
                    AppBarIcon("close", label: String(localized: "Clear")) { query = "" }.foregroundStyle(m3.onSurfaceVariant)
                }
            }
            .frame(height: 64)
            .padding(.trailing, 4)
            .background(m3.surface)
        } else {
            TopAppBar(title: model.source.name, showsBack: true) {
                if sourceId == LocalSource.id {
                    AppBarIcon("add", label: String(localized: "Add from Files")) { importing = true }
                }
                AppBarIcon("search", label: String(localized: "Search")) { searching = true }
                Menu {
                    ForEach(AppPreferences.DisplayMode.allCases, id: \.self) { mode in
                        Button {
                            app.preferences.browseDisplayMode = mode
                        } label: {
                            if app.preferences.browseDisplayMode == mode { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                        }
                    }
                } label: {
                    MIcon(app.preferences.browseDisplayMode == .list ? "view_list.fill" : "view_module.fill")
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Display mode"))
            }
        }
    }

    /// The listing chips under the app bar.
    private func chips(_ model: BrowseSourceModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                M3Chip(text: String(localized: "Popular"), selected: model.listing == .popular) { Task { await model.restart(.popular) } }
                if model.source.supportsLatest {
                    M3Chip(text: String(localized: "Latest"), selected: model.listing == .latest) { Task { await model.restart(.latest) } }
                }
                if model.source.supportsUnread {
                    M3Chip(text: String(localized: "Unread"), selected: model.listing == .unread) { Task { await model.restart(.unread) } }
                }
                M3Chip(text: String(localized: "Filter"), selected: isSearch(model.listing)) {
                    Task {
                        await model.loadFilters()
                        showFilters = true
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    private func isSearch(_ listing: BrowseListing) -> Bool {
        if case .search = listing { true } else { false }
    }

    /// A long press adds to the library (asking for categories when there are some) or removes.
    private func toggleLibrary(_ series: SeriesRecord, inLibrary: Bool) {
        Task {
            if inLibrary {
                try? await app.database.setInLibrary(seriesId: series.id, false)
                return
            }
            let categories = (try? await app.database.categoryList()) ?? []
            let preferred = app.preferences.defaultCategory
            if categories.isEmpty || preferred == CategoryRecord.defaultId {
                try? await app.database.setInLibrary(seriesId: series.id, true, categories: [])
            } else if categories.contains(where: { $0.id == preferred }) {
                try? await app.database.setInLibrary(seriesId: series.id, true, categories: [preferred])
            } else {
                pendingAdd = series
            }
        }
    }
}

/// Renders a source's filters generically (Mihon's SourceFilterSheet).
struct SourceFilterSheet: View {
    @Environment(\.m3) private var m3
    @Binding var filters: [SourceFilter]
    let defaults: [SourceFilter]
    let apply: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                M3TextButton(title: String(localized: "Reset")) { filters = defaults }
                Spacer()
                FilledButton(title: String(localized: "Filter"), action: apply)
            }
            .padding(16)
            M3Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filters.indices, id: \.self) { index in
                        FilterRow(filter: $filters[index])
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(m3.surfaceContainerLow)
    }
}

private struct FilterRow: View {
    @Environment(\.m3) private var m3
    @Binding var filter: SourceFilter
    @State private var expanded = false

    var body: some View {
        switch filter {
        case .header(let name):
            Text(name).font(M3Type.bodyMedium).foregroundStyle(m3.secondary)
                .padding(.horizontal, 24).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        case .separator:
            M3Divider().padding(.vertical, 8)
        case .select(let name, let values, let state):
            HStack {
                Text(name).font(M3Type.bodyMedium).foregroundStyle(m3.onSurface)
                Spacer()
                Picker(name, selection: Binding(get: { state }, set: { filter = .select(name: name, values: values, state: $0) })) {
                    ForEach(values.indices, id: \.self) { Text(values[$0]).tag($0) }
                }
                .tint(m3.primary)
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 48)
        case .text(let name, let state):
            M3TextField(label: name, text: Binding(get: { state }, set: { filter = .text(name: name, state: $0) }))
                .padding(.horizontal, 24).padding(.vertical, 8)
        case .checkBox(let name, let state):
            CheckboxRow(title: name, isOn: Binding(get: { state }, set: { filter = .checkBox(name: name, state: $0) }))
        case .triState(let name, let state):
            TriStateRow(title: name, state: Binding(
                get: { ChapterDisplay.TriState(rawValue: state) ?? .off },
                set: { filter = .triState(name: name, state: $0.rawValue) }
            ))
        case .sort(let name, let values, let selection):
            disclosure(name) {
                ForEach(values.indices, id: \.self) { index in
                    SortRow(title: values[index], selected: selection?.index == index, ascending: selection?.ascending ?? true) {
                        let ascending = selection?.index == index ? !(selection?.ascending ?? true) : true
                        filter = .sort(name: name, values: values, selection: .init(index: index, ascending: ascending))
                    }
                }
            }
        case .group(let name, let children):
            disclosure(name) {
                ForEach(children.indices, id: \.self) { index in
                    FilterRow(filter: Binding(get: { children[index] }, set: { child in
                        var updated = children
                        updated[index] = child
                        filter = .group(name: name, filters: updated)
                    }))
                }
            }
        }
    }

    private func disclosure<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack {
                    Text(name).font(M3Type.bodyMedium).foregroundStyle(m3.onSurface)
                    Spacer()
                    MIcon(expanded ? "keyboard_arrow_up" : "keyboard_arrow_down").foregroundStyle(m3.onSurfaceVariant)
                }
                .padding(.horizontal, 24)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.ripple)
            if expanded { content() }
        }
    }
}

// MARK: - Global search

/// Mihon's global search: the query in every source, one row of results per source.
struct GlobalSearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    let initialQuery: String
    @State private var query = ""
    @State private var results: [Int64: Result<[SeriesRecord], any Error>] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                AppBarIcon("arrow_back", label: String(localized: "Back")) {}
                    .hidden()
                    .overlay { BackButton() }
                    .padding(.leading, 4)
                AppBarSearchField(placeholder: String(localized: "Global search"), text: $query) { Task { await search() } }
                    .padding(.leading, 4)
            }
            .frame(height: 64)
            .background(m3.surface)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(app.sources.available, id: \.id) { source in
                        VStack(alignment: .leading, spacing: 0) {
                            NavigationLink(value: Route.source(source.id, listing: .search(query))) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(source.name).font(M3Type.titleSmall).foregroundStyle(m3.onSurface)
                                        Text("Other").font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant)
                                    }
                                    Spacer()
                                    MIcon("arrow_forward").foregroundStyle(m3.onSurfaceVariant)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.ripple)
                            switch results[source.id] {
                            case nil:
                                ProgressView().tint(m3.primary).padding(16)
                            case .failure(let error):
                                Text(error.localizedDescription).font(M3Type.bodySmall).foregroundStyle(m3.error).padding(16)
                            case .success(let items) where items.isEmpty:
                                Text("No results found").font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant).padding(16)
                            case .success(let items):
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 4) {
                                        ForEach(items) { series in
                                            NavigationLink(value: Route.series(series.id)) {
                                                MangaItem(title: series.name, cover: source.coverRequest(series.manga)).frame(width: 104)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(m3.surface)
        .task {
            guard results.isEmpty else { return }
            query = initialQuery
            await search()
        }
    }

    private func search() async {
        results = [:]
        let query = query
        await withTaskGroup(of: (Int64, Result<[SeriesRecord], any Error>).self) { group in
            for source in app.sources.available {
                group.addTask { [app] in
                    do {
                        let page = try await source.search(page: 1, query: query, filters: await source.filterList())
                        let stored = try await app.database.localSeries(source: source.id, mangas: page.mangas)
                        return (source.id, .success(stored))
                    } catch {
                        return (source.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group { results[id] = result }
        }
    }
}

/// The app bar's back arrow, for screens that build their own bar.
struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.m3) private var m3

    var body: some View {
        AppBarIcon("arrow_back", label: String(localized: "Back")) { dismiss() }
            .foregroundStyle(m3.onSurface)
    }
}
