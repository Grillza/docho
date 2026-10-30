import NukeUI
import SwiftUI

/// Mihon's manga screen: the series' cover and details over a blurred backdrop, its actions,
/// description and genres, then the chapter list, with a Start/Resume button.
struct SeriesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.openReader) private var openReader
    @Environment(\.openURL) private var openURL
    @State private var model: SeriesModel?
    @State private var scrolledPastHeader = false
    @State private var selection = Set<Int>()
    @State private var showSettings = false
    @State private var choosingCategories = false
    @State private var showTracking = false
    @State private var trackCount = 0
    @State private var confirmingRemove = false
    @State private var descriptionExpanded = false
    let seriesId: Int

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
            if model == nil { model = SeriesModel(app: app, seriesId: seriesId) }
        }
    }

    private func content(_ model: SeriesModel) -> some View {
        let chapters = model.displayedChapters
        return ZStack(alignment: .top) {
            GeometryReader { geometry in
                let topInset = geometry.safeAreaInsets.top
                if geometry.size.width >= 840 {
                    // Mihon's tablet layout: the details beside the chapter list.
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            if let series = model.series { header(series, model: model, topInset: topInset) }
                        }
                        .frame(width: geometry.size.width * 0.4)
                        .ignoresSafeArea(edges: .top)
                        chapterList(model, chapters: chapters)
                            .padding(.top, 64)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if let series = model.series {
                                header(series, model: model, topInset: topInset)
                            }
                            chapterRows(model, chapters: chapters)
                        }
                    }
                    .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 220 } action: { _, past in
                        withAnimation(.easeOut(duration: 0.15)) { scrolledPastHeader = past }
                    }
                    .refreshable { await model.refresh() }
                    .accessibilityIdentifier("series.scroll")
                    .ignoresSafeArea(edges: .top)
                }
            }

            appBar(model)
        }
        .overlay(alignment: .bottomTrailing) {
            if selection.isEmpty, let next = model.nextChapter, let series = model.series {
                ExtendedFAB(title: model.hasStarted ? String(localized: "Resume") : String(localized: "Start"), icon: "play_arrow.fill") {
                    openReader(series: series, chapters: model.chapters, start: next)
                }
                .padding(16)
                .accessibilityIdentifier("series.resume")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty { selectionBar(model) }
        }
        .task { await model.observeSeries() }
        .task { await model.observeChapters() }
        .task { await model.observeDownloads() }
        .task { await model.load() }
        .m3Sheet(isPresented: $showSettings) {
            ChapterSettingsSheet(display: model.display, hasFileNames: model.chapters.contains { $0.chapterMemo.string(ChapterMemo.fileName) != nil }) {
                await model.setDisplay($0)
            }
        }
        .sheet(isPresented: $choosingCategories) {
            CategoryPicker(seriesIds: [seriesId], addsToLibrary: model.series?.inLibrary == false) {}
        }
        .m3Sheet(isPresented: $showTracking) {
            TrackingSheet(seriesId: seriesId, seriesTitle: model.series?.name ?? "")
        }
        .task {
            do {
                for try await tracks in app.database.observeTracks(seriesId: seriesId) { trackCount = tracks.count }
            } catch {}
        }
        .m3Dialog(isPresented: $confirmingRemove, title: String(localized: "Remove from library")) {
            Text("Remove from your library?").padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { confirmingRemove = false }
            M3TextButton(title: String(localized: "Remove")) {
                confirmingRemove = false
                Task { await model.setInLibrary(false) }
            }
        }
    }

    /// The chapter list on its own, for the tablet layout.
    private func chapterList(_ model: SeriesModel, chapters: [ChapterRecord]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { chapterRows(model, chapters: chapters) }
        }
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("series.scroll")
    }

    @ViewBuilder
    private func chapterRows(_ model: SeriesModel, chapters: [ChapterRecord]) -> some View {
        chapterHeader(model, count: chapters.count)
        if let error = model.refreshError, model.chapters.isEmpty {
            EmptyScreen(message: error) {
                M3TextButton(title: String(localized: "Retry")) { Task { await model.refresh() } }
            }
            .frame(minHeight: 240)
        }
        ForEach(chapters) { chapter in
            ChapterRow(
                chapter: chapter, download: model.downloads[chapter.id], selected: selection.contains(chapter.id),
                showNumber: model.display.showChapterNumbers, series: model.series,
                onTap: { tap(chapter, model: model) },
                onLongPress: { toggle(chapter.id) },
                onDownloadAction: { downloadAction(chapter, model: model) },
                onSwipe: { swipe(chapter, action: $0, model: model) }
            )
        }
        Color.clear.frame(height: 96)
    }

    // MARK: App bar

    @ViewBuilder
    private func appBar(_ model: SeriesModel) -> some View {
        if !selection.isEmpty {
            TopAppBar(title: String(selection.count), onBack: { selection = [] }, elevated: true) {
                AppBarIcon("select_all", label: String(localized: "Select all")) { selection = Set(model.displayedChapters.map(\.id)) }
                AppBarIcon("flip_to_back", label: String(localized: "Select inverse")) {
                    selection = Set(model.displayedChapters.map(\.id)).subtracting(selection)
                }
            }
        } else {
            TopAppBar(title: scrolledPastHeader ? model.series?.name ?? "" : "", showsBack: true, elevated: scrolledPastHeader, transparent: true) {
                if model.series?.source != LocalSource.id {
                    Menu {
                        Button(String(localized: "Next chapter")) { Task { await model.downloadNext(1) } }
                        Button(String(localized: "Next 5 chapters")) { Task { await model.downloadNext(5) } }
                        Button(String(localized: "Next 10 chapters")) { Task { await model.downloadNext(10) } }
                        Button(String(localized: "Unread")) { Task { await model.downloadNext(nil) } }
                        Button(String(localized: "All")) { Task { await model.downloadAll() } }
                        Divider()
                        Button(String(localized: "Delete read downloads"), role: .destructive) { Task { await model.deleteAllDownloads(readOnly: true) } }
                        Button(String(localized: "Delete all downloads"), role: .destructive) { Task { await model.deleteAllDownloads(readOnly: false) } }
                    } label: {
                        MIcon("download").frame(width: 48, height: 48).contentShape(Rectangle())
                    }
                    .accessibilityLabel(String(localized: "Download"))
                }
                AppBarIcon("filter_list", label: String(localized: "Filter")) { showSettings = true }
                    .foregroundStyle(model.display.hasFilter ? Color(hex: 0xFFC107) : m3.onSurfaceVariant)
                OverflowMenu {
                    Button(String(localized: "Refresh")) { Task { await model.refresh() } }
                    if model.series?.inLibrary == true {
                        Button(String(localized: "Edit categories")) { choosingCategories = true }
                    }
                    if let url = model.series.flatMap({ model.source.webURL($0.manga) }) {
                        Button(String(localized: "Open in browser")) { openURL(url) }
                        ShareLink(String(localized: "Share"), item: url)
                    }
                }
            }
            .background(scrolledPastHeader ? m3.surfaceContainer.ignoresSafeArea(edges: .top) : nil)
        }
    }

    // MARK: Header (MangaInfoHeader)

    /// The backdrop runs under the status bar and app bar, as on Android.
    private func header(_ series: SeriesRecord, model: SeriesModel, topInset: CGFloat) -> some View {
        let cover = model.source.coverRequest(series.manga)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                // The cover, blurred and faded, behind the title, fading into the background.
                LazyImage(request: cover.map { ImageRequest(urlRequest: $0) }) { state in
                    if let image = state.image { image.resizable().scaledToFill() } else { m3.surface }
                }
                .blur(radius: 4)
                .opacity(0.2)
                .frame(maxWidth: .infinity)
                .frame(height: topInset + 64 + 16 + 150 + 16)
                .clipped()
                .overlay(LinearGradient(colors: [.clear, m3.surface], startPoint: .center, endPoint: .bottom))
                .accessibilityHidden(true)

                HStack(alignment: .top, spacing: 16) {
                    CoverImage(request: cover)
                        .frame(width: 100)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(series.name)
                            .font(M3Type.titleLarge)
                            .foregroundStyle(m3.onSurface)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("series.title")
                        Spacer().frame(height: 2)
                        infoLine("person", series.authors ?? String(localized: "Unknown author"))
                        if let artists = series.artists, artists != series.authors {
                            infoLine("brush.fill", artists)
                        }
                        Spacer().frame(height: 2)
                        HStack(spacing: 4) {
                            MIcon(series.mangaStatus.icon, size: 16)
                            Text(series.mangaStatus.title)
                            Text("•")
                            Text(model.source.name)
                        }
                        .font(M3Type.bodyMedium)
                        .foregroundStyle(m3.onSurface.opacity(0.78))
                        .lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, topInset + 64 + 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            actionButtons(series, model: model)
            description(series)
        }
    }

    private func infoLine(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            MIcon(icon, size: 16)
            Text(text).font(M3Type.titleSmall).lineLimit(2).textSelection(.enabled)
        }
        .foregroundStyle(m3.onSurface.opacity(0.78))
    }

    /// Mihon's action row: In library, Tracking and Open in browser (WebView).
    private func actionButtons(_ series: SeriesRecord, model: SeriesModel) -> some View {
        HStack(spacing: 0) {
            actionButton(
                title: series.inLibrary ? String(localized: "In library") : String(localized: "Add to library"),
                icon: series.inLibrary ? "favorite.fill" : "favorite", active: series.inLibrary
            ) {
                if series.inLibrary {
                    confirmingRemove = true
                } else {
                    addToLibrary(model)
                }
            }
            .accessibilityIdentifier("series.library")
            actionButton(
                title: trackCount == 0 ? String(localized: "Tracking") : String(localized: "\(trackCount) tracked"),
                icon: trackCount == 0 ? "sync" : "check", active: trackCount > 0
            ) { showTracking = true }
            .accessibilityIdentifier("series.tracking")
            if let url = model.source.webURL(series.manga) {
                actionButton(title: String(localized: "WebView"), icon: "public", active: false) { openURL(url) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func addToLibrary(_ model: SeriesModel) {
        let preferred = app.preferences.defaultCategory
        Task {
            let categories = (try? await app.database.categoryList()) ?? []
            if categories.isEmpty || preferred == CategoryRecord.defaultId {
                await model.setInLibrary(true, categories: [])
            } else if categories.contains(where: { $0.id == preferred }) {
                await model.setInLibrary(true, categories: [preferred])
            } else {
                choosingCategories = true
            }
        }
    }

    private func actionButton(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                MIcon(icon, size: 20)
                Text(title).font(M3Type.labelSmall).multilineTextAlignment(.center)
            }
            .foregroundStyle(active ? m3.primary : m3.onSurface.opacity(0.38))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(RippleStyle(shape: RoundedRectangle(cornerRadius: 8)))
    }

    @ViewBuilder
    private func description(_ series: SeriesRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = series.summary, !summary.isEmpty {
                Text(HTMLText.plain(summary))
                    .font(M3Type.bodyMedium)
                    .foregroundStyle(m3.onSurface.opacity(0.78))
                    .lineLimit(descriptionExpanded ? nil : 3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .overlay(alignment: .bottom) {
                        if !descriptionExpanded {
                            LinearGradient(colors: [m3.surface.opacity(0), m3.surface], startPoint: .top, endPoint: .bottom)
                                .frame(height: 24)
                                .allowsHitTesting(false)
                        }
                    }
                Button { withAnimation { descriptionExpanded.toggle() } } label: {
                    MIcon(descriptionExpanded ? "keyboard_arrow_up" : "keyboard_arrow_down")
                        .foregroundStyle(m3.onSurface)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(descriptionExpanded ? String(localized: "Show less") : String(localized: "Show more"))
            }
            let genres = series.genreList
            if !genres.isEmpty {
                if descriptionExpanded {
                    FlowLayout(spacing: 4) {
                        ForEach(genres, id: \.self) { genre in tagChip(genre) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(genres, id: \.self) { genre in tagChip(genre) }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private func tagChip(_ text: String) -> some View {
        Text(text)
            .font(M3Type.bodySmall)
            .foregroundStyle(m3.onSurfaceVariant)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(m3.outline, lineWidth: 1))
            .padding(.vertical, 4)
    }

    private func chapterHeader(_ model: SeriesModel, count: Int) -> some View {
        HStack {
            Text(count == 1 ? String(localized: "1 chapter") : String(localized: "\(count) chapters"))
                .font(M3Type.titleMedium)
                .foregroundStyle(m3.onSurface)
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small).tint(m3.primary) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(minHeight: 40)
    }

    // MARK: Chapter actions

    private func tap(_ chapter: ChapterRecord, model: SeriesModel) {
        if !selection.isEmpty {
            toggle(chapter.id)
        } else if let series = model.series {
            openReader(series: series, chapters: model.chapters, start: chapter)
        }
    }

    private func toggle(_ id: Int) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func downloadAction(_ chapter: ChapterRecord, model: SeriesModel) {
        Task {
            if chapter.isDownloaded {
                await model.deleteDownloads([chapter.id])
            } else if let download = model.downloads[chapter.id] {
                if download.state == .failed { await model.retryDownloads() } else { await model.cancelDownload(chapter.id) }
            } else {
                await model.download([chapter.id])
            }
        }
    }

    private func swipe(_ chapter: ChapterRecord, action: AppPreferences.SwipeAction, model: SeriesModel) {
        Task {
            switch action {
            case .toggleRead: await model.setRead([chapter.id], !chapter.read)
            case .toggleBookmark: await model.setBookmarked([chapter.id], !chapter.bookmark)
            case .download: downloadAction(chapter, model: model)
            case .disabled: break
            }
        }
    }

    /// Mihon's chapter action bar in select mode.
    private func selectionBar(_ model: SeriesModel) -> some View {
        let selected = model.chapters.filter { selection.contains($0.id) }
        return HStack(spacing: 0) {
            if selected.contains(where: { !$0.bookmark }) {
                barButton("bookmark_add", String(localized: "Bookmark")) { ids in Task { await model.setBookmarked(ids, true) } }
            } else {
                barButton("bookmark_remove", String(localized: "Remove bookmark")) { ids in Task { await model.setBookmarked(ids, false) } }
            }
            if selected.contains(where: { !$0.read }) {
                barButton("done_all", String(localized: "Mark as read")) { ids in Task { await model.setRead(ids, true) } }
            }
            if selected.contains(where: { $0.read || $0.lastPageRead > 0 }) {
                barButton("remove_done", String(localized: "Mark as unread")) { ids in Task { await model.setRead(ids, false) } }
            }
            if selected.count == 1, let chapter = selected.first {
                barButton("done_previous", String(localized: "Mark previous as read")) { _ in Task { await model.markPreviousRead(chapter) } }
            }
            if model.series?.source != LocalSource.id, selected.contains(where: { !$0.isDownloaded }) {
                barButton("download", String(localized: "Download")) { ids in Task { await model.download(ids) } }
            }
            if selected.contains(where: \.isDownloaded) {
                barButton("delete", String(localized: "Delete")) { _ in Task { await model.deleteDownloads(selected.filter(\.isDownloaded).map(\.id)) } }
            }
        }
        .padding(.vertical, 8)
        .background(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16).fill(m3.surfaceContainerHigh).ignoresSafeArea(edges: .bottom))
    }

    /// The action gets the selection as it was when tapped; the bar clears it straight away.
    private func barButton(_ icon: String, _ title: String, action: @escaping (Set<Int>) -> Void) -> some View {
        Button {
            action(selection)
            selection = []
        } label: {
            VStack(spacing: 4) {
                MIcon(icon)
                Text(title).font(M3Type.labelSmall).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(m3.onSurface)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ripple)
        .accessibilityLabel(title)
    }
}

// MARK: - Chapter row (MangaChapterListItem)

struct ChapterRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    let chapter: ChapterRecord
    let download: DownloadRecord?
    let selected: Bool
    let showNumber: Bool
    let series: SeriesRecord?
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onDownloadAction: () -> Void
    let onSwipe: (AppPreferences.SwipeAction) -> Void
    @State private var offset: CGFloat = 0

    private static let threshold: CGFloat = 56

    var body: some View {
        ZStack {
            swipeBackground
            row
                .background(selected ? m3.secondaryContainer.opacity(0.6) : m3.surface)
                .offset(x: offset)
                .simultaneousGesture(swipeGesture)
        }
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: chapter.read ? String(localized: "Mark as unread") : String(localized: "Mark as read")) {
            onSwipe(.toggleRead)
        }
        .accessibilityAction(named: chapter.bookmark ? String(localized: "Remove bookmark") : String(localized: "Bookmark")) {
            onSwipe(.toggleBookmark)
        }
        .accessibilityIdentifier("chapter.row")
    }

    private var row: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 2) {
                    if download == nil, !chapter.read, chapter.lastPageRead == 0, isNew {
                        Circle().fill(m3.primary).frame(width: 8, height: 8).padding(.trailing, 4)
                    }
                    if chapter.bookmark {
                        MIcon("bookmark.fill", size: 16).foregroundStyle(m3.primary)
                    }
                    Text(title)
                        .font(M3Type.bodyMedium)
                        .foregroundStyle(chapter.bookmark ? m3.primary : m3.onSurface)
                        .opacity(chapter.read ? 0.38 : 1)
                        .lineLimit(1)
                }
                HStack(spacing: 0) {
                    Text(subtitle)
                        .font(M3Type.bodySmall)
                        .foregroundStyle(m3.onSurface)
                        .opacity(chapter.read ? 0.38 : 0.78)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .padding(.vertical, 12)
            // Local comics are on the device already; Android shows no download button for them.
            if series?.source != LocalSource.id {
                ChapterDownloadIndicator(chapter: chapter, download: download, action: onDownloadAction)
                    .padding(.trailing, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(perform: onLongPress)
    }

    /// Chapters fetched in the last week that aren't read yet show a dot, as Mihon's updates do.
    private var isNew: Bool {
        guard let fetched = chapter.dateFetch, let added = series?.dateAdded else { return false }
        return fetched > added && fetched > Date().addingTimeInterval(-7 * 86400)
    }

    private var title: String {
        showNumber && chapter.number >= 0 ? String(localized: "Chapter \(formatNumber(chapter.number))") : chapter.name
    }

    private var subtitle: String {
        var parts: [String] = []
        if let date = chapter.dateUpload {
            parts.append(RelativeDates.label(date, relative: app.preferences.relativeTimestamps, format: app.preferences.dateFormat))
        }
        if chapter.inProgress {
            parts.append(String(localized: "Page \(chapter.lastPageRead + 1)"))
        }
        if let scanlator = chapter.scanlator, !scanlator.isEmpty { parts.append(scanlator) }
        return parts.joined(separator: " • ")
    }

    private var accessibilityText: String {
        var parts = [title, subtitle]
        if chapter.read { parts.append(String(localized: "Read")) }
        if chapter.isDownloaded { parts.append(String(localized: "Downloaded")) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: Swipe (Mihon's chapter swipe actions)

    private var startAction: AppPreferences.SwipeAction { app.preferences.swipeStartAction }
    private var endAction: AppPreferences.SwipeAction { app.preferences.swipeEndAction }

    @ViewBuilder
    private var swipeBackground: some View {
        let action = offset > 0 ? startAction : endAction
        HStack {
            if offset > 0 { swipeIcon(action) }
            Spacer()
            if offset < 0 { swipeIcon(action) }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(m3.primary.opacity(abs(offset) >= Self.threshold ? 1 : 0.6))
        .opacity(offset == 0 ? 0 : 1)
    }

    private func swipeIcon(_ action: AppPreferences.SwipeAction) -> some View {
        let icon: String = switch action {
        case .toggleRead: chapter.read ? "remove_done" : "done_all"
        case .toggleBookmark: chapter.bookmark ? "bookmark_remove" : "bookmark_add"
        case .download: "download"
        case .disabled: "block"
        }
        return MIcon(icon).foregroundStyle(m3.onPrimary)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                let action = value.translation.width > 0 ? startAction : endAction
                guard action != .disabled else { return }
                offset = max(min(value.translation.width, 120), -120)
            }
            .onEnded { _ in
                if abs(offset) >= Self.threshold {
                    onSwipe(offset > 0 ? startAction : endAction)
                }
                withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
            }
    }
}

/// Mihon's chapter download indicator: download, queued, progress, downloaded or failed.
struct ChapterDownloadIndicator: View {
    @Environment(\.m3) private var m3
    let chapter: ChapterRecord
    let download: DownloadRecord?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if chapter.isDownloaded {
                    MIcon("check_circle.fill").foregroundStyle(m3.onSurfaceVariant)
                } else if let download {
                    switch download.state {
                    case .failed:
                        MIcon("error").foregroundStyle(m3.error)
                    case .queued where download.pagesDone == 0:
                        ProgressView().controlSize(.small).tint(m3.onSurfaceVariant)
                    default:
                        Circle().stroke(m3.secondaryContainer, lineWidth: 2.5).frame(width: 20, height: 20)
                        Circle()
                            .trim(from: 0, to: download.progress)
                            .stroke(m3.onSurfaceVariant, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 20, height: 20)
                            .animation(.linear, value: download.progress)
                    }
                } else {
                    MIcon("download_circle").foregroundStyle(m3.onSurfaceVariant)
                }
            }
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(RippleStyle(shape: Circle()))
        .accessibilityLabel(label)
        .accessibilityIdentifier("chapter.download")
    }

    private var label: String {
        if chapter.isDownloaded { return String(localized: "Delete download") }
        guard let download else { return String(localized: "Download") }
        return download.state == .failed ? String(localized: "Retry download") : String(localized: "Cancel download")
    }
}

/// Mihon's chapter settings sheet: Filter, Sort and Display.
struct ChapterSettingsSheet: View {
    @Environment(\.m3) private var m3
    @State var display: ChapterDisplay
    let hasFileNames: Bool
    let save: (ChapterDisplay) async -> Void
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            M3Tabs(tabs: [0, 1, 2], selection: $tab, title: {
                [String(localized: "Filter"), String(localized: "Sort"), String(localized: "Display")][$0]
            })
            ScrollView {
                VStack(spacing: 0) {
                    switch tab {
                    case 0:
                        TriStateRow(title: String(localized: "Downloaded"), state: $display.downloaded)
                        TriStateRow(title: String(localized: "Unread"), state: $display.unread)
                        TriStateRow(title: String(localized: "Bookmarked"), state: $display.bookmarked)
                    case 1:
                        ForEach(ChapterDisplay.Sort.allCases, id: \.self) { sort in
                            if sort != .fileName || hasFileNames {
                                SortRow(title: sort.title, selected: display.sort == sort, ascending: !display.descending) {
                                    if display.sort == sort { display.descending.toggle() } else { display.sort = sort }
                                }
                            }
                        }
                    default:
                        RadioRow(title: String(localized: "Source title"), selected: !display.showChapterNumbers) { display.showChapterNumbers = false }
                        RadioRow(title: String(localized: "Chapter number"), selected: display.showChapterNumbers) { display.showChapterNumbers = true }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.top, 16)
        .background(m3.surfaceContainerLow)
        .onChange(of: display) { _, new in Task { await save(new) } }
    }
}

/// Lays children out in rows, wrapping as needed (genre chips when expanded).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
