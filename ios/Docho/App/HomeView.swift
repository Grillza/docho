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
    @State private var queueCount = 0
    @State private var updatesCount = 0

    private var tabs: [HomeTab] {
        HomeTab.allCases.filter { tab in
            switch tab {
            case .updates: app.preferences.showUpdatesTab
            case .history: app.preferences.showHistoryTab
            case .browse: app.preferences.showBrowseTab
            default: true
            }
        }
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    NavigationRail(tabs: tabs, selection: select, current: selection, badge: badge)
                    VStack(spacing: 0) {
                        content
                        DownloadBar(onOpen: openDownloads)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    content
                    DownloadBar(onOpen: openDownloads)
                    NavigationBar(tabs: tabs, selection: select, current: selection, badge: badge)
                }
            }
        }
        .background(m3.surface.ignoresSafeArea())
        .environment(\.openReader, OpenReaderAction { reader = $0 })
        .environment(\.navigate, NavigateAction { route in paths[selection, default: []].append(route) })
        .fullScreenCover(item: $reader) { launch in
            ReaderView(model: ReaderModel(app: app, series: launch.series, chapters: launch.chapters, start: launch.start))
                .environment(\.m3, m3)
        }
        .task {
            do {
                for try await queue in app.database.downloadQueue() { queueCount = queue.count }
            } catch {}
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
        case .updates: updatesCount > 0 ? String(updatesCount) : nil
        case .more: queueCount > 0 ? String(queueCount) : nil
        default: nil
        }
    }

    #if DEBUG
    /// `DOCHO_OPEN` picks a tab or screen at launch, for screenshots: a tab name, `kavita`,
    /// `series:<id>`, `settings:<page>`, `queue`, or `reader:<series id>`.
    private func openFromLaunchEnvironment() {
        guard let target = ProcessInfo.processInfo.environment["DOCHO_OPEN"] else { return }
        let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
        if let tab = HomeTab(rawValue: parts[0]) {
            selection = tab
        } else if let source = ["kavita": KavitaSource.id, "komga": KomgaSource.id, "bookorbit": BookOrbitSource.id][parts[0]] {
            selection = .browse
            paths[.browse] = [.source(source, listing: .popular)]
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
        }
    }
}

/// Material 3's navigation bar: 80 pt, a pill behind the selected icon, and labels.
private struct NavigationBar: View {
    @Environment(\.m3) private var m3
    let tabs: [HomeTab]
    let selection: (HomeTab) -> Void
    let current: HomeTab
    let badge: (HomeTab) -> String?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabs) { tab in
                NavigationItem(tab: tab, selected: tab == current, badge: badge(tab), pillWidth: 64) { selection(tab) }
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(minHeight: 80)
        .background(m3.surfaceContainer.ignoresSafeArea(edges: .bottom))
    }
}

/// Material 3's navigation rail, for wide windows.
private struct NavigationRail: View {
    @Environment(\.m3) private var m3
    let tabs: [HomeTab]
    let selection: (HomeTab) -> Void
    let current: HomeTab
    let badge: (HomeTab) -> String?

    var body: some View {
        VStack(spacing: 12) {
            ForEach(tabs) { tab in
                NavigationItem(tab: tab, selected: tab == current, badge: badge(tab), pillWidth: 56) { selection(tab) }
            }
        }
        .padding(.top, 8)
        .frame(width: 80)
        .frame(maxHeight: .infinity, alignment: .center)
        .background(m3.surface.ignoresSafeArea())
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
