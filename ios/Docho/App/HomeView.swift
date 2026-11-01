import SwiftUI
import UIKit

/// The main tabs, as in Mihon. Updates, History and Browse can be hidden (Docho 0.25).
enum HomeTab: String, CaseIterable, Identifiable, Hashable {
    case library, updates, history, browse, more

    var id: Self { self }

    var title: String {
        switch self {
        case .library: String(localized: "Library")
        case .updates: String(localized: "Updates")
        case .history: String(localized: "History")
        case .browse: String(localized: "Browse")
        case .more: String(localized: "More")
        }
    }

    /// The Android navigation icons, outlined and (selected) filled.
    var icon: String { "nav.\(rawValue)" }

    /// Library and More always show, so the app can always be got around (Android 0.25).
    var canHide: Bool { self != .library && self != .more }

    /// The tabs shown, in the order chosen in Settings → Appearance → Navigation bar.
    @MainActor
    static func visible(_ preferences: AppPreferences) -> [HomeTab] {
        let ordered = preferences.tabOrder.compactMap(HomeTab.init(rawValue:))
        let all = ordered + allCases.filter { !ordered.contains($0) }
        return all.filter { tab in
            switch tab {
            case .updates: preferences.showUpdatesTab
            case .history: preferences.showHistoryTab
            case .browse: preferences.showBrowseTab
            default: true
            }
        }
    }
}

/// Where a tab's navigation stack can go.
enum Route: Hashable {
    case series(Int)
    case source(Int64, listing: BrowseListing)
    case globalSearch(String)
    case downloadQueue
    case categories
    case statistics
    case dataStorage
    case settings
    case settingsPage(SettingsPage)
    case about
    case acknowledgements
    case customThemes
}

/// The app's root: the current tab's screen with a navigation bar below it (iPhone) or a
/// navigation rail beside it (iPad and other wide windows).
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: HomeTab = .library
    @State private var paths: [HomeTab: [Route]] = [:]
    @State private var reader: ReaderLaunch?
    @State private var updatesCount = 0
    /// Whether the window is wider than tall, for a landscape bar layout of its own.
    @State private var isLandscape = false

    private var tabs: [HomeTab] { HomeTab.visible(app.preferences) }

    /// Where the bar sits: the setting, or a bottom bar on iPhone and a left rail on iPad.
    private var position: AppPreferences.NavPosition {
        // On iPhone the bar is always at the bottom.
        guard UIDevice.current.userInterfaceIdiom == .pad else { return .bottom }
        let chosen = app.preferences.navLayout(landscape: isLandscape).position
        guard chosen == .automatic else { return chosen }
        return sizeClass == .regular ? .left : .bottom
    }

    var body: some View {
        let bar = NavBar(
            tabs: tabs, position: position, alignment: app.preferences.navLayout(landscape: isLandscape).alignment,
            current: selection, badge: badge, selection: select
        )
        Group {
            switch position {
            case .left, .automatic:
                HStack(spacing: 0) {
                    bar
                    VStack(spacing: 0) { content; DownloadBar(onOpen: openDownloads) }
                }
            case .right:
                HStack(spacing: 0) {
                    VStack(spacing: 0) { content; DownloadBar(onOpen: openDownloads) }
                    bar
                }
            case .top:
                VStack(spacing: 0) { bar; content; DownloadBar(onOpen: openDownloads) }
            case .bottom:
                VStack(spacing: 0) { content; DownloadBar(onOpen: openDownloads); bar }
            }
        }
        .background(m3.surface.ignoresSafeArea())
        .onGeometryChange(for: Bool.self, of: { $0.size.width > $0.size.height }) { isLandscape = $0 }
        .environment(\.openReader, OpenReaderAction { reader = $0 })
        .environment(\.navigate, NavigateAction { route in paths[selection, default: []].append(route) })
        .environment(\.openBrowse, OpenBrowseAction { route in
            // Browse may be hidden from the bar; then its screen opens on the current tab.
            if tabs.contains(.browse) {
                selection = .browse
                paths[.browse] = route.map { [$0] } ?? []
            } else {
                paths[selection, default: []].append(route ?? .source(LocalSource.id, listing: .popular))
            }
        })
        .fullScreenCover(isPresented: Binding(get: { !app.preferences.shownWelcome }, set: { if !$0 { app.preferences.shownWelcome = true } })) {
            WelcomeView { setUpServer in
                app.preferences.shownWelcome = true
                if setUpServer {
                    selection = .more
                    paths[.more] = [.settings, .settingsPage(.sync)]
                }
            }
            .environment(\.m3, m3)
        }
        .fullScreenCover(item: $reader) { launch in
            ReaderView(model: ReaderModel(app: app, series: launch.series, chapters: launch.chapters, start: launch.start))
                .environment(\.m3, m3)
        }
        .task {
            do {
                for try await updates in app.database.updates(limit: 200) { updatesCount = updates.filter { !$0.chapter.read }.count }
            } catch {}
        }
        #if DEBUG
        .task { openFromLaunchEnvironment() }
        #endif
        .onChange(of: app.pendingSeries) { _, seriesId in
            guard let seriesId else { return }
            app.pendingSeries = nil
            selection = .library
            paths[.library, default: []].append(.series(seriesId))
        }
        .m3Dialog(
            isPresented: Binding(get: { app.openFileError != nil }, set: { if !$0 { app.openFileError = nil } }),
            title: String(localized: "Couldn't open the file")
        ) {
            Text(app.openFileError ?? "").font(M3Type.bodyMedium).foregroundStyle(m3.onSurfaceVariant)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        } buttons: {
            M3TextButton(title: String(localized: "OK")) { app.openFileError = nil }
        }
        .m3Dialog(
            isPresented: Binding(get: { app.availableUpdate != nil && app.openFileError == nil }, set: { if !$0 { app.availableUpdate = nil } }),
            title: String(localized: "New version available!")
        ) {
            if let release = app.availableUpdate { AppUpdateContent(release: release) }
        } buttons: {
            AppUpdateButtons()
        }
    }

    private var content: some View {
        ZStack {
            ForEach(tabs) { tab in
                NavigationStack(path: binding(for: tab)) {
                    root(of: tab)
                        .navigationDestination(for: Route.self) { route in
                            destination(route).toolbar(.hidden, for: .navigationBar)
                        }
                        .toolbar(.hidden, for: .navigationBar)
                }
                .opacity(tab == selection ? 1 : 0)
                .allowsHitTesting(tab == selection)
                .accessibilityHidden(tab != selection)
            }
        }
    }

    private func binding(for tab: HomeTab) -> Binding<[Route]> {
        Binding(get: { paths[tab] ?? [] }, set: { paths[tab] = $0 })
    }

    /// Selecting the current tab again goes back to its first screen, as on Android.
    private func select(_ tab: HomeTab) {
        if tab == selection {
            paths[tab] = []
        } else {
            selection = tab
        }
    }

    private func badge(_ tab: HomeTab) -> String? {
        switch tab {
        // Only Updates: the download bar already shows the queue, so More has no count.
        case .updates: updatesCount > 0 ? String(updatesCount) : nil
        default: nil
        }
    }

    #if DEBUG
    /// `DOCHO_OPEN` picks a tab or screen at launch, for screenshots: a tab name, `kavita`,
    /// `series:<id>`, `settings:<page>`, `queue`, or `reader:<series id>`.
    private func openFromLaunchEnvironment() {
        guard let target = ProcessInfo.processInfo.environment["DOCHO_OPEN"] else { return }
        let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
        if parts[0] == "extensions" {
            selection = .browse
        } else if let tab = HomeTab(rawValue: parts[0]) {
            selection = tab
        } else if let source = ["local": LocalSource.id, "kavita": KavitaSource.id, "komga": KomgaSource.id, "bookorbit": BookOrbitSource.id][parts[0]] {
            selection = .browse
            paths[.browse] = [.source(source, listing: .popular)]
        } else if parts[0] == "source", let id = parts.last.flatMap(Int64.init) {
            selection = .browse
            paths[.browse] = [.source(id, listing: .popular)]
        } else if parts[0] == "series", let id = parts.last.flatMap(Int.init) {
            paths[.library] = [.series(id)]
        } else if parts[0] == "settings", let page = parts.last.flatMap(SettingsPage.init) {
            selection = .more
            paths[.more] = [.settings, .settingsPage(page)]
        } else if parts[0] == "queue" {
            openDownloads()
        } else if parts[0] == "reader", let id = parts.last.flatMap(Int.init) {
            Task {
                guard let series = try? await app.database.seriesRecord(id: id),
                      let chapters = try? await app.database.chapterList(seriesId: id), let first = chapters.first else { return }
                reader = ReaderLaunch(series: series, chapters: chapters, start: first)
            }
        }
    }
    #endif

    private func openDownloads() {
        selection = .more
        paths[.more] = [.downloadQueue]
    }

    @ViewBuilder
    private func root(of tab: HomeTab) -> some View {
        switch tab {
        case .library: LibraryView()
        case .updates: UpdatesView()
        case .history: HistoryView()
        case .browse: BrowseView()
        case .more: MoreView()
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .series(let id): SeriesView(seriesId: id)
        case .source(let id, let listing): BrowseSourceView(sourceId: id, listing: listing)
        case .globalSearch(let query): GlobalSearchView(initialQuery: query)
        case .downloadQueue: DownloadQueueView()
        case .categories: CategoriesView()
        case .statistics: StatisticsView()
        case .dataStorage: DataStorageView()
        case .settings: SettingsView()
        case .settingsPage(let page): SettingsPageView(page: page)
        case .about: AboutView()
        case .acknowledgements: AcknowledgementsView()
        case .customThemes: CustomThemesView()
        }
    }
}

/// Material 3's navigation bar (top or bottom: 80 pt, with labels) or navigation rail (left
/// or right: 80 pt wide). Tabs keep the size they have when all five show, and sit at the start,
/// centre or end as Android's "Tab position" says.
struct NavBar: View {
    @Environment(\.m3) private var m3
    let tabs: [HomeTab]
    let position: AppPreferences.NavPosition
    let alignment: AppPreferences.NavAlignment
    let current: HomeTab
    let badge: (HomeTab) -> String?
    let selection: (HomeTab) -> Void

    private var isRail: Bool { position == .left || position == .right }

    var body: some View {
        if isRail {
            VStack(spacing: 12) {
                if alignment != .start { Spacer(minLength: 0) }
                items(pillWidth: 56)
                if alignment != .end { Spacer(minLength: 0) }
            }
            .padding(.vertical, 8)
            .frame(width: 80)
            .frame(maxHeight: .infinity)
            .background(m3.surface.ignoresSafeArea())
            .overlay(alignment: position == .left ? .trailing : .leading) {
                Rectangle().fill(m3.outlineVariant.opacity(0.4)).frame(width: 1).ignoresSafeArea()
            }
        } else {
            GeometryReader { geometry in
                // Each tab is a fifth of the bar, as when all are shown; the group is aligned.
                let tabWidth = (geometry.size.width - 16) / CGFloat(HomeTab.allCases.count)
                HStack(spacing: 0) {
                    if alignment != .start { Spacer(minLength: 0) }
                    ForEach(tabs) { tab in
                        NavigationItem(tab: tab, selected: tab == current, badge: badge(tab), pillWidth: 64) { selection(tab) }
                            .frame(width: tabWidth)
                    }
                    if alignment != .end { Spacer(minLength: 0) }
                }
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
            }
            .padding(position == .bottom ? .top : .bottom, 12)
            .padding(position == .bottom ? .bottom : .top, 16)
            .frame(height: 80)
            .background(m3.surfaceContainer.ignoresSafeArea(edges: position == .bottom ? .bottom : .top))
        }
    }

    private func items(pillWidth: CGFloat) -> some View {
        ForEach(tabs) { tab in
            NavigationItem(tab: tab, selected: tab == current, badge: badge(tab), pillWidth: pillWidth) { selection(tab) }
        }
    }
}

private struct NavigationItem: View {
    @Environment(\.m3) private var m3
    let tab: HomeTab
    let selected: Bool
    let badge: String?
    let pillWidth: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Capsule()
                        .fill(selected ? m3.secondaryContainer : .clear)
                        .frame(width: selected ? pillWidth : 32, height: 32)
                    MIcon(selected ? tab.icon + ".fill" : tab.icon)
                        .foregroundStyle(selected ? m3.onSecondaryContainer : m3.onSurfaceVariant)
                        .overlay(alignment: .topTrailing) {
                            if let badge {
                                Text(badge)
                                    .font(M3Type.labelSmall)
                                    .foregroundStyle(m3.onError)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(Capsule().fill(m3.error))
                                    .offset(x: 12, y: -6)
                                    .fixedSize()
                            }
                        }
                }
                .animation(.easeOut(duration: 0.2), value: selected)
                Text(tab.title)
                    .font(M3Type.labelMedium)
                    .foregroundStyle(selected ? m3.onSurface : m3.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(minWidth: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(badge.map { String(localized: "\($0) new") } ?? "")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("tab.\(tab.rawValue)")
    }
}

// MARK: - Opening the reader

struct ReaderLaunch: Identifiable, Sendable {
    let series: SeriesRecord
    let chapters: [ChapterRecord]
    let start: ChapterRecord
    let id = UUID()
}

struct OpenReaderAction: Sendable {
    let open: @MainActor (ReaderLaunch) -> Void

    @MainActor
    func callAsFunction(series: SeriesRecord, chapters: [ChapterRecord], start: ChapterRecord) {
        open(ReaderLaunch(series: series, chapters: chapters, start: start))
    }
}

private struct OpenReaderKey: EnvironmentKey {
    static let defaultValue = OpenReaderAction { _ in }
}

extension EnvironmentValues {
    /// Opens the reader over the whole app.
    var openReader: OpenReaderAction {
        get { self[OpenReaderKey.self] }
        set { self[OpenReaderKey.self] = newValue }
    }
}

/// Pushes a screen onto the current tab's stack, for screens that navigate from code.
struct NavigateAction: Sendable {
    let push: @MainActor (Route) -> Void

    @MainActor
    func callAsFunction(_ route: Route) {
        push(route)
    }
}

private struct NavigateKey: EnvironmentKey {
    static let defaultValue = NavigateAction { _ in }
}

extension EnvironmentValues {
    var navigate: NavigateAction {
        get { self[NavigateKey.self] }
        set { self[NavigateKey.self] = newValue }
    }
}

/// Switches to Browse, opening `route` there if given (the Library's "Add files from Browse").
struct OpenBrowseAction: Sendable {
    let open: @MainActor (Route?) -> Void

    @MainActor
    func callAsFunction(_ route: Route? = nil) {
        open(route)
    }
}

private struct OpenBrowseKey: EnvironmentKey {
    static let defaultValue = OpenBrowseAction { _ in }
}

extension EnvironmentValues {
    var openBrowse: OpenBrowseAction {
        get { self[OpenBrowseKey.self] }
        set { self[OpenBrowseKey.self] = newValue }
    }
}

// MARK: - Back swipe with hidden navigation bars

/// Navigation bars are hidden in favour of Material app bars; this keeps the edge swipe that
/// goes back, which UIKit turns off along with the bar.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

// MARK: - App update

/// The release's version and iOS notes, and the "skip bug-fix updates" choice.
private struct AppUpdateContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    let release: AppRelease

    var body: some View {
        @Bindable var preferences = app.preferences
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "v\(release.version)")
                .font(M3Type.titleMedium)
                .foregroundStyle(m3.onSurface)
                .padding(.horizontal, 24)
            Text(Self.markdown(release.notes))
                .font(M3Type.bodyMedium)
                .foregroundStyle(m3.onSurfaceVariant)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            CheckboxRow(title: String(localized: "Skip bug-fix updates (0.0.x)"), isOn: $preferences.skipPatchAppUpdates)
        }
    }

    /// GitHub's Markdown, keeping line breaks; headings and lists show as plain lines.
    static func markdown(_ text: String) -> AttributedString {
        let cleaned = text.components(separatedBy: "\n")
            .map { $0.replacing(#/^#+\s*/#, with: "").replacing(#/^- /#, with: "• ") }
            .joined(separator: "\n")
        return (try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(cleaned)
    }
}

/// Skip this version, Not now, and Update: through AltStore or SideStore when one is on the
/// device, which installs the new IPA, or else the release page.
private struct AppUpdateButtons: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    /// The first sideloader installed that can take the update (its scheme is listed in
    /// LSApplicationQueriesSchemes, so canOpenURL can see it).
    private var sideloader: AppRelease.Sideloader? {
        AppRelease.Sideloader.allCases.first { UIApplication.shared.canOpenURL(URL(string: "\($0.rawValue)://")!) }
    }

    var body: some View {
        M3TextButton(title: String(localized: "Skip this version")) {
            if let release = app.availableUpdate { app.preferences.skippedAppUpdate = release.version }
            app.availableUpdate = nil
        }
        M3TextButton(title: String(localized: "Not now")) { app.availableUpdate = nil }
        let sideloader = sideloader
        M3TextButton(title: sideloader.map { String(localized: "Update in \($0.name)") } ?? String(localized: "Download")) {
            if let release = app.availableUpdate {
                if let sideloader, let url = release.installURL(in: sideloader) {
                    // Falls back to the release page if the sideloader turns the link down.
                    openURL(url) { accepted in if !accepted { openURL(release.page) } }
                } else {
                    openURL(release.page)
                }
            }
            app.availableUpdate = nil
        }
    }
}
