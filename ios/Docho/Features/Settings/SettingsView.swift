import Nuke
import SwiftUI

enum SettingsPage: String, Hashable, CaseIterable {
    case appearance, library, reader, downloads, sync, browse, advanced

    var title: String {
        switch self {
        case .appearance: String(localized: "Appearance")
        case .library: String(localized: "Library")
        case .reader: String(localized: "Reader")
        case .downloads: String(localized: "Downloads")
        case .sync: String(localized: "Sync / Self-hosted sources")
        case .browse: String(localized: "Browse")
        case .advanced: String(localized: "Advanced")
        }
    }

    var summary: String {
        switch self {
        case .appearance: String(localized: "Theme, date & time format")
        case .library: String(localized: "Categories, global update, chapter swipe")
        case .reader: String(localized: "Reading mode, display, navigation")
        case .downloads: String(localized: "Automatic download, download ahead")
        case .sync: String(localized: "Kavita, BookOrbit, Komga, KOReader sync and where reading progress goes")
        case .browse: String(localized: "Sources, global search")
        case .advanced: String(localized: "Clear caches, reset settings")
        }
    }

    var icon: String {
        switch self {
        case .appearance: "palette"
        case .library: "collections_bookmark"
        case .reader: "chrome_reader_mode"
        case .downloads: "download"
        case .sync: "dns"
        case .browse: "explore"
        case .advanced: "code"
        }
    }
}

/// Mihon's settings list, in Docho's order.
struct SettingsView: View {
    @Environment(\.m3) private var m3

    var body: some View {
        VStack(spacing: 0) {
            TopAppBar(title: String(localized: "Settings"), showsBack: true)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach([SettingsPage.appearance, .library, .reader, .downloads, .sync, .browse], id: \.self) { page in
                        item(page)
                    }
                    NavigationLink(value: Route.dataStorage) {
                        PreferenceRow(
                            title: String(localized: "Data and storage"), subtitle: String(localized: "Storage space, downloads"),
                            icon: "storage"
                        )
                    }
                    .buttonStyle(.ripple)
                    item(.advanced)
                    NavigationLink(value: Route.about) {
                        PreferenceRow(title: String(localized: "About"), subtitle: "Dōchō \(AboutView.version)", icon: "info")
                    }
                    .buttonStyle(.ripple)
                }
            }
        }
        .background(m3.surface)
    }

    private func item(_ page: SettingsPage) -> some View {
        NavigationLink(value: Route.settingsPage(page)) {
            PreferenceRow(title: page.title, subtitle: page.summary, icon: page.icon)
        }
        .buttonStyle(.ripple)
        .accessibilityIdentifier("settings.\(page.rawValue)")
    }
}

struct SettingsPageView: View {
    @Environment(\.m3) private var m3
    let page: SettingsPage

    var body: some View {
        VStack(spacing: 0) {
            TopAppBar(title: page.title, showsBack: true)
            ScrollView {
                VStack(spacing: 0) {
                    switch page {
                    case .appearance: AppearanceSettings()
                    case .library: LibrarySettings()
                    case .reader: ReaderSettingsPage()
                    case .downloads: DownloadSettings()
                    case .sync: SyncSettingsPage()
                    case .browse: BrowseSettings()
                    case .advanced: AdvancedSettings()
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(m3.surface)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3

    var body: some View {
        @Bindable var preferences = app.preferences
        PreferenceHeader(title: String(localized: "Theme"))
        Picker(String(localized: "Theme mode"), selection: $preferences.themeMode) {
            Text("System").tag(AppPreferences.ThemeMode.system)
            Text("Light").tag(AppPreferences.ThemeMode.light)
            Text("Dark").tag(AppPreferences.ThemeMode.dark)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AppTheme.allCases) { theme in
                    ThemePreview(theme: theme, selected: !preferences.useCustomTheme && preferences.appTheme == theme, dark: m3.isDark) {
                        preferences.appTheme = theme
                        preferences.useCustomTheme = false
                    }
                }
                // "Custom" is the last theme, as on Android: the user's own themes.
                NavigationLink(value: Route.customThemes) {
                    VStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 17).fill(m3.surfaceContainerHigh)
                            if let custom = preferences.customThemes.first {
                                HStack(spacing: 0) {
                                    ForEach(CustomTheme.Role.allCases) { Color(argb: custom[keyPath: $0.keyPath]) }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 17))
                            }
                            MIcon(preferences.useCustomTheme ? "check_circle.fill" : "palette", size: 32)
                                .foregroundStyle(m3.primary)
                                .padding(8)
                                .background(Circle().fill(m3.surface))
                        }
                        .frame(width: 114, height: 170)
                        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(
                            preferences.useCustomTheme ? m3.primary : m3.outlineVariant, lineWidth: preferences.useCustomTheme ? 4 : 1
                        ))
                        Text("Custom").font(M3Type.bodySmall).foregroundStyle(m3.onSurface)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Custom themes"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        SwitchPreference(title: String(localized: "Pure black dark mode"), isOn: $preferences.pureBlack)
        NavigationBarSettings()
        PreferenceHeader(title: String(localized: "Display"))
        ListPreference(
            title: String(localized: "Date format"), selection: $preferences.dateFormat,
            options: [("", String(localized: "Default"))] + ["MM/dd/yy", "dd/MM/yy", "yyyy-MM-dd", "dd MMM yyyy", "MMM dd, yyyy"].map { format in
                (format, "\(format) (\(Self.example(format)))")
            }
        )
        SwitchPreference(
            title: String(localized: "Relative timestamps"),
            subtitle: String(localized: "\"Today\" instead of the date"),
            isOn: $preferences.relativeTimestamps
        )
    }

    private static func example(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: Date())
    }
}

/// Mihon's theme picker tile: a miniature app in the theme's colours.
private struct ThemePreview: View {
    let theme: AppTheme
    let selected: Bool
    let dark: Bool
    let action: () -> Void

    var body: some View {
        let scheme = dark ? theme.dark : theme.light
        Button(action: action) {
            VStack(spacing: 8) {
                VStack(spacing: 6) {
                    HStack {
                        RoundedRectangle(cornerRadius: 4).fill(scheme.onSurface.opacity(0.6)).frame(width: 40, height: 10)
                        Spacer()
                        if selected { MIcon("check_circle.fill", size: 16).foregroundStyle(scheme.primary) }
                    }
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(scheme.primary).frame(height: 40)
                        RoundedRectangle(cornerRadius: 4).fill(scheme.secondary.opacity(0.5)).frame(height: 40)
                    }
                    RoundedRectangle(cornerRadius: 4).fill(scheme.onSurface.opacity(0.2)).frame(height: 8)
                    RoundedRectangle(cornerRadius: 4).fill(scheme.onSurface.opacity(0.2)).frame(height: 8)
                    Spacer()
                    HStack {
                        RoundedRectangle(cornerRadius: 4).fill(scheme.tertiary).frame(width: 16, height: 12)
                        Spacer()
                        Capsule().fill(scheme.secondaryContainer).frame(width: 28, height: 12)
                    }
                    .padding(6)
                    .background(scheme.surfaceContainer)
                }
                .padding(8)
                .frame(width: 114, height: 170)
                .background(scheme.background)
                .clipShape(RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(selected ? scheme.primary : scheme.outlineVariant, lineWidth: selected ? 4 : 1))
                Text(theme.title).font(M3Type.bodySmall).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Library

private struct LibrarySettings: View {
    @Environment(AppModel.self) private var app
    @State private var categories: [CategoryRecord] = []

    var body: some View {
        @Bindable var preferences = app.preferences
        PreferenceHeader(title: String(localized: "Categories"))
        NavigationLink(value: Route.categories) {
            PreferenceRow(title: String(localized: "Edit categories"), subtitle: categories.isEmpty ? nil : String(localized: "\(categories.count) categories"))
        }
        .buttonStyle(.ripple)
        ListPreference(
            title: String(localized: "Default category"), selection: $preferences.defaultCategory,
            options: [(-1, String(localized: "Always ask")), (CategoryRecord.defaultId, String(localized: "Default"))] + categories.map { ($0.id, $0.name) }
        )
        PreferenceHeader(title: String(localized: "Global update"))
        SwitchPreference(title: String(localized: "Update library on app launch"), isOn: $preferences.updateOnLaunch)
        SwitchPreference(
            title: String(localized: "Automatic updates"),
            subtitle: String(localized: "Checks for new chapters in the background. iOS decides when that happens, usually overnight while charging."),
            isOn: $preferences.autoUpdate
        )
        PreferenceRow(title: String(localized: "Skip updating entries"))
        CheckboxRow(title: String(localized: "With \"Completed\" status"), isOn: $preferences.smartUpdateSkipCompleted)
        CheckboxRow(title: String(localized: "With unread chapter(s)"), isOn: $preferences.smartUpdateSkipUnread)
        CheckboxRow(title: String(localized: "That haven't been started"), isOn: $preferences.smartUpdateSkipNotStarted)
        PreferenceHeader(title: String(localized: "Chapter swipe"))
        ListPreference(title: String(localized: "Swipe to right action"), selection: $preferences.swipeStartAction, options: AppPreferences.SwipeAction.allCases.map { ($0, $0.title) })
        ListPreference(title: String(localized: "Swipe to left action"), selection: $preferences.swipeEndAction, options: AppPreferences.SwipeAction.allCases.map { ($0, $0.title) })
        Color.clear.frame(height: 0)
            .task { categories = (try? await app.database.categoryList()) ?? [] }
    }
}

// MARK: - Reader

private struct ReaderSettingsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var reader = app.readerSettings
        ListPreference(title: String(localized: "Default reading mode"), selection: $reader.defaultMode, options: ReaderMode.allCases.map { ($0, $0.title) })
        SwitchPreference(title: String(localized: "Animate page transitions"), isOn: $reader.animatePageTransitions)
        PreferenceHeader(title: String(localized: "Display"))
        ListPreference(title: String(localized: "Background color"), selection: $reader.background, options: ReaderBackground.allCases.map { ($0, $0.title) })
        SwitchPreference(title: String(localized: "Fullscreen"), isOn: $reader.fullscreen)
        SwitchPreference(title: String(localized: "Keep screen on"), isOn: $reader.keepScreenOn)
        SwitchPreference(title: String(localized: "Show page number"), isOn: $reader.showPageNumber)
        PreferenceHeader(title: String(localized: "Reading"))
        SwitchPreference(title: String(localized: "Skip chapters marked read"), isOn: $reader.skipRead)
        SwitchPreference(title: String(localized: "Always show chapter transition"), isOn: $reader.alwaysShowTransition)
        PreferenceHeader(title: String(localized: "Paged"))
        ListPreference(title: String(localized: "Tap zones"), selection: $reader.pagedTapZones, options: TapZones.allCases.map { ($0, $0.title) })
        ListPreference(title: String(localized: "Invert tap zones"), selection: $reader.pagedInvert, options: InvertTaps.allCases.map { ($0, $0.title) })
        SwitchPreference(title: String(localized: "Double tap to zoom"), isOn: $reader.doubleTapZoom)
        SwitchPreference(
            title: String(localized: "Dual page view"),
            subtitle: String(localized: "Two pages side by side when the screen is wider than it is tall"),
            isOn: $reader.spreads
        )
        SwitchPreference(title: String(localized: "First page alone"), subtitle: String(localized: "In dual page view, the cover stands on its own"), isOn: $reader.coverAlone)
        PreferenceHeader(title: String(localized: "Long strip"))
        ListPreference(title: String(localized: "Tap zones"), selection: $reader.stripTapZones, options: TapZones.allCases.map { ($0, $0.title) })
        ListPreference(title: String(localized: "Invert tap zones"), selection: $reader.stripInvert, options: InvertTaps.allCases.map { ($0, $0.title) })
    }
}

// MARK: - Downloads

private struct DownloadSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var preferences = app.preferences
        SwitchPreference(title: String(localized: "Only download over Wi-Fi"), isOn: $preferences.downloadOnlyOnWifi)
        ListPreference(
            title: String(localized: "Concurrent page downloads"), selection: $preferences.concurrentPages,
            options: (1...10).map { ($0, String($0)) }
        )
        PreferenceHeader(title: String(localized: "Delete chapters"))
        SwitchPreference(title: String(localized: "After manually marked as read"), isOn: $preferences.deleteAfterMarkedRead)
        SwitchPreference(title: String(localized: "After reading automatically"), isOn: $preferences.deleteAfterReading)
        PreferenceHeader(title: String(localized: "Auto-download"))
        SwitchPreference(title: String(localized: "Download new chapters"), isOn: $preferences.downloadNewChapters)
        ListPreference(
            title: String(localized: "Download ahead"), selection: $preferences.downloadAhead,
            options: [(0, String(localized: "Disabled")), (2, "2"), (3, "3"), (5, "5"), (10, "10")]
        )
        InfoPreference(text: String(localized: "Download ahead only works for entries in the library, when the chapter being read is downloaded too."))
    }
}

// MARK: - Browse

private struct BrowseSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var preferences = app.preferences
        PreferenceHeader(title: String(localized: "Sources"))
        SwitchPreference(title: String(localized: "Hide entries already in library"), isOn: $preferences.hideInLibraryItems)
        InfoPreference(text: String(localized: "Kavita, Komga and BookOrbit are built in. Set them up under Settings → Sync / Self-hosted sources."))
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var app
    @State private var cleared: String?

    var body: some View {
        PreferenceHeader(title: String(localized: "Data"))
        PreferenceRow(
            title: String(localized: "Clear chapter cache"),
            subtitle: cleared ?? String(localized: "Covers and pages kept for faster loading"),
            action: {
                ImagePipeline.shared.cache.removeAll()
                cleared = String(localized: "Cache cleared")
            }
        )
        PreferenceRow(
            title: String(localized: "Reset viewer settings"),
            subtitle: String(localized: "Every series goes back to the default reading mode"),
            action: {
                Task {
                    try? await app.database.writer.write { db in try db.execute(sql: "UPDATE series SET readerMode = NULL") }
                    cleared = String(localized: "Viewer settings reset")
                }
            }
        )
    }
}

// MARK: - Navigation bar

/// Android's navigation bar settings (0.25): a live preview, which tabs show, where the tabs
/// sit in the bar; plus where the bar itself sits and the tabs' order.
private struct NavigationBarSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3

    var body: some View {
        @Bindable var preferences = app.preferences
        PreferenceHeader(title: String(localized: "Navigation bar"))
        preview
        Text("Choose which tabs show in the navigation bar. Library and More always show, so you can always get around the app.")
            .font(M3Type.bodySmall)
            .foregroundStyle(m3.onSurfaceVariant)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        SwitchPreference(title: String(localized: "Updates"), icon: "nav.updates", isOn: $preferences.showUpdatesTab)
        SwitchPreference(title: String(localized: "History"), icon: "nav.history", isOn: $preferences.showHistoryTab)
        SwitchPreference(title: String(localized: "Browse"), icon: "nav.browse", isOn: $preferences.showBrowseTab)
        ListPreference(
            title: String(localized: "Bar position"), selection: $preferences.navPosition,
            options: AppPreferences.NavPosition.allCases.map { ($0, $0.title) }
        )
        ListPreference(
            title: String(localized: "Tab position"), selection: $preferences.navAlignment,
            options: AppPreferences.NavAlignment.allCases.map { ($0, $0.title) }
        )
        PreferenceRow(title: String(localized: "Tab order"), subtitle: String(localized: "Move tabs up or down"))
        ForEach(Array(order.enumerated()), id: \.element) { index, tab in
            HStack(spacing: 16) {
                MIcon(tab.icon).foregroundStyle(m3.primary)
                Text(tab.title).font(.system(size: 16)).foregroundStyle(m3.onSurface)
                Spacer()
                AppBarIcon("keyboard_arrow_up", label: String(localized: "Move \(tab.title) up")) { move(index, by: -1) }
                    .disabled(index == 0)
                    .opacity(index == 0 ? 0.38 : 1)
                AppBarIcon("keyboard_arrow_down", label: String(localized: "Move \(tab.title) down")) { move(index, by: 1) }
                    .disabled(index == order.count - 1)
                    .opacity(index == order.count - 1 ? 0.38 : 1)
            }
            .foregroundStyle(m3.onSurfaceVariant)
            .padding(.leading, 16)
            .padding(.trailing, 8)
        }
    }

    private var order: [HomeTab] {
        let ordered = app.preferences.tabOrder.compactMap(HomeTab.init(rawValue:))
        return ordered + HomeTab.allCases.filter { !ordered.contains($0) }
    }

    private func move(_ index: Int, by offset: Int) {
        var tabs = order
        let target = index + offset
        guard tabs.indices.contains(target) else { return }
        tabs.swapAt(index, target)
        withAnimation { app.preferences.tabOrder = tabs.map(\.rawValue) }
    }

    /// A small copy of the bar as the settings would show it (Android's preview).
    @ViewBuilder
    private var preview: some View {
        let preferences = app.preferences
        let tabs = HomeTab.visible(preferences)
        let position = preferences.navPosition == .automatic
            ? (UIDevice.current.userInterfaceIdiom == .pad ? AppPreferences.NavPosition.left : .bottom)
            : preferences.navPosition
        let bar = NavBar(tabs: tabs, position: position, alignment: preferences.navAlignment, current: tabs.first ?? .library,
                         badge: { _ in nil }, selection: { _ in })
            .allowsHitTesting(false)
        let screen = RoundedRectangle(cornerRadius: 8).fill(m3.surfaceContainerLow)
        Group {
            switch position {
            case .left, .automatic: HStack(spacing: 0) { bar; screen }
            case .right: HStack(spacing: 0) { screen; bar }
            case .top: VStack(spacing: 0) { bar; screen }
            case .bottom: VStack(spacing: 0) { screen; bar }
            }
        }
        .frame(height: position == .left || position == .right ? 480 : 200)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(m3.outlineVariant))
        .padding(16)
        .animation(.easeOut(duration: 0.2), value: preferences.navPosition)
        .animation(.easeOut(duration: 0.2), value: preferences.navAlignment)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Preview: \(tabs.map(\.title).joined(separator: ", "))"))
    }
}
