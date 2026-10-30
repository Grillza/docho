import Foundation
import Observation

/// App-wide preferences that mirror Android's settings, kept in UserDefaults. Server settings and
/// the reader's live elsewhere (`*Settings`, `ReaderSettings`).
@MainActor
@Observable
final class AppPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    // MARK: Appearance

    enum ThemeMode: String, CaseIterable, Sendable {
        case system, light, dark
    }

    var themeMode: ThemeMode { didSet { save(themeMode.rawValue, "pref_theme_mode_key") } }
    var appTheme: AppTheme { didSet { save(appTheme.rawValue, "pref_app_theme") } }
    /// Pure black backgrounds in dark mode.
    var pureBlack: Bool { didSet { save(pureBlack, "pref_theme_dark_amoled_key") } }
    /// Whether one of the user's own themes is used instead of `appTheme` (Android's CUSTOM).
    var useCustomTheme: Bool { didSet { save(useCustomTheme, "pref_app_theme_custom") } }
    /// Up to `CustomTheme.max` themes the user made.
    var customThemes: [CustomTheme] {
        didSet { if let data = try? JSONEncoder().encode(customThemes) { save(data, "custom_themes") } }
    }
    var customThemeIndex: Int { didSet { save(customThemeIndex, "custom_theme_index") } }

    /// The custom theme in use, if "Custom" is chosen and there is one.
    var activeCustomTheme: CustomTheme? {
        guard useCustomTheme, !customThemes.isEmpty else { return nil }
        return customThemes.indices.contains(customThemeIndex) ? customThemes[customThemeIndex] : customThemes[0]
    }
    var relativeTimestamps: Bool { didSet { save(relativeTimestamps, "relative_time_v2") } }
    /// "" follows the system; otherwise a `DateFormatter` pattern.
    var dateFormat: String { didSet { save(dateFormat, "app_date_format") } }

    // MARK: Navigation (Docho 0.25)

    var showUpdatesTab: Bool { didSet { save(showUpdatesTab, "nav_show_updates") } }
    var showHistoryTab: Bool { didSet { save(showHistoryTab, "nav_show_history") } }
    var showBrowseTab: Bool { didSet { save(showBrowseTab, "nav_show_browse") } }

    /// Where the navigation bar sits. Automatic is a bar at the bottom on iPhone and a rail on
    /// the left on iPad, as on Android.
    enum NavPosition: String, CaseIterable, Sendable {
        case automatic, bottom, top, left, right

        var title: String {
            switch self {
            case .automatic: String(localized: "Automatic")
            case .bottom: String(localized: "Bottom")
            case .top: String(localized: "Top")
            case .left: String(localized: "Left")
            case .right: String(localized: "Right")
            }
        }
    }

    /// Where the tabs sit within the bar when some are hidden (Android's "Tab position").
    enum NavAlignment: String, CaseIterable, Sendable {
        case start, center, end

        /// Left, centred or right in a bar; top, centred or bottom in a rail at the side.
        func title(vertical: Bool) -> String {
            switch self {
            case .start: vertical ? String(localized: "Top") : String(localized: "Left")
            case .center: String(localized: "Centred")
            case .end: vertical ? String(localized: "Bottom") : String(localized: "Right")
            }
        }
    }

    var navPosition: NavPosition { didSet { save(navPosition.rawValue, "nav_bar_position") } }
    var navAlignment: NavAlignment { didSet { save(navAlignment.rawValue, "nav_bar_alignment") } }
    /// The tabs in the order the bar shows them.
    var tabOrder: [String] { didSet { save(tabOrder, "nav_bar_order") } }

    /// The languages whose sources and extensions Browse lists (Mihon's `source_languages`):
    /// the device's language and multi-language ones to start with.
    var sourceLanguages: [String] { didSet { save(sourceLanguages, "source_languages") } }

    // MARK: Library

    enum DisplayMode: String, CaseIterable, Sendable {
        case compactGrid, comfortableGrid, coverOnlyGrid, list

        var title: String {
            switch self {
            case .compactGrid: String(localized: "Compact grid")
            case .comfortableGrid: String(localized: "Comfortable grid")
            case .coverOnlyGrid: String(localized: "Cover-only grid")
            case .list: String(localized: "List")
            }
        }
    }

    enum LibrarySort: String, CaseIterable, Sendable {
        case alphabetical, lastRead, lastUpdate, unreadCount, totalChapters, latestChapter, chapterFetchDate, dateAdded

        var title: String {
            switch self {
            case .alphabetical: String(localized: "Alphabetically")
            case .lastRead: String(localized: "Last read")
            case .lastUpdate: String(localized: "Last update check")
            case .unreadCount: String(localized: "Unread count")
            case .totalChapters: String(localized: "Total chapters")
            case .latestChapter: String(localized: "Latest chapter")
            case .chapterFetchDate: String(localized: "Chapter fetch date")
            case .dateAdded: String(localized: "Date added")
            }
        }
    }

    var displayMode: DisplayMode { didSet { save(displayMode.rawValue, "pref_display_mode_library") } }
    /// 0 picks a column count from the width, as Mihon's "Default".
    var gridColumnsPortrait: Int { didSet { save(gridColumnsPortrait, "pref_library_columns_portrait_key") } }
    var gridColumnsLandscape: Int { didSet { save(gridColumnsLandscape, "pref_library_columns_landscape_key") } }
    var downloadBadge: Bool { didSet { save(downloadBadge, "display_download_badge") } }
    var unreadBadge: Bool { didSet { save(unreadBadge, "display_unread_badge") } }
    var sourceBadge: Bool { didSet { save(sourceBadge, "display_source_badge") } }
    var continueReadingButton: Bool { didSet { save(continueReadingButton, "display_continue_reading_button") } }
    var categoryTabs: Bool { didSet { save(categoryTabs, "display_category_tabs") } }
    var categoryCounts: Bool { didSet { save(categoryCounts, "display_number_of_items") } }
    var librarySort: LibrarySort { didSet { save(librarySort.rawValue, "library_sorting_mode") } }
    var librarySortAscending: Bool { didSet { save(librarySortAscending, "library_sorting_ascending") } }
    var filterDownloaded: ChapterDisplay.TriState { didSet { save(filterDownloaded.rawValue, "pref_filter_library_downloaded_v2") } }
    var filterUnread: ChapterDisplay.TriState { didSet { save(filterUnread.rawValue, "pref_filter_library_unread_v2") } }
    var filterStarted: ChapterDisplay.TriState { didSet { save(filterStarted.rawValue, "pref_filter_library_started_v2") } }
    var filterBookmarked: ChapterDisplay.TriState { didSet { save(filterBookmarked.rawValue, "pref_filter_library_bookmarked_v2") } }
    var filterCompleted: ChapterDisplay.TriState { didSet { save(filterCompleted.rawValue, "pref_filter_library_completed_v2") } }
    var lastCategoryIndex: Int { didSet { save(lastCategoryIndex, "last_used_category") } }
    /// Checks the library for new chapters when the app starts.
    var updateOnLaunch: Bool { didSet { save(updateOnLaunch, "pref_update_library_on_launch") } }
    /// Background updates through `BGAppRefreshTask`, which iOS runs when it decides.
    var autoUpdate: Bool { didSet { save(autoUpdate, "pref_library_update_interval_key") } }
    /// Skips series that are completed, fully read or never started, as Mihon's smart update.
    var smartUpdateSkipCompleted: Bool { didSet { save(smartUpdateSkipCompleted, "library_update_restriction_completed") } }
    var smartUpdateSkipUnread: Bool { didSet { save(smartUpdateSkipUnread, "library_update_restriction_unread") } }
    var smartUpdateSkipNotStarted: Bool { didSet { save(smartUpdateSkipNotStarted, "library_update_restriction_not_started") } }
    /// Category new library entries go to; -1 asks each time.
    var defaultCategory: Int { didSet { save(defaultCategory, "default_category") } }

    enum SwipeAction: String, CaseIterable, Sendable {
        case toggleRead, toggleBookmark, download, disabled

        var title: String {
            switch self {
            case .toggleRead: String(localized: "Mark as read/unread")
            case .toggleBookmark: String(localized: "Bookmark/unbookmark chapter")
            case .download: String(localized: "Download")
            case .disabled: String(localized: "Disabled")
            }
        }
    }

    var swipeStartAction: SwipeAction { didSet { save(swipeStartAction.rawValue, "pref_chapter_swipe_start_action") } }
    var swipeEndAction: SwipeAction { didSet { save(swipeEndAction.rawValue, "pref_chapter_swipe_end_action") } }

    // MARK: Downloads

    var downloadOnlyOnWifi: Bool { didSet { save(downloadOnlyOnWifi, "pref_download_only_over_wifi_key") } }
    var concurrentPages: Int { didSet { save(concurrentPages, "download_parallel_page_limit") } }
    var deleteAfterReading: Bool { didSet { save(deleteAfterReading, "pref_remove_after_read") } }
    var deleteAfterMarkedRead: Bool { didSet { save(deleteAfterMarkedRead, "pref_remove_after_marked_as_read_key") } }
    var downloadNewChapters: Bool { didSet { save(downloadNewChapters, "download_new") } }
    /// Chapters to download ahead while reading; 0 is off.
    var downloadAhead: Int { didSet { save(downloadAhead, "auto_download_while_reading") } }
    /// The queue stops after the page in flight and starts nothing new.
    var downloadsPaused: Bool { didSet { save(downloadsPaused, "download_queue_paused") } }

    // MARK: Browse

    var hideInLibraryItems: Bool { didSet { save(hideInLibraryItems, "browse_hide_in_library_items") } }
    var browseDisplayMode: DisplayMode { didSet { save(browseDisplayMode.rawValue, "pref_display_mode_catalogue") } }

    // MARK: More

    var downloadedOnly: Bool { didSet { save(downloadedOnly, "pref_downloaded_only") } }
    /// Reading isn't saved to history.
    var incognitoMode: Bool { didSet { save(incognitoMode, "incognito_mode") } }
    /// Whether the welcome guide has been shown (Mihon's `onboarding_complete`).
    var shownWelcome: Bool { didSet { save(shownWelcome, "onboarding_complete") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func string(_ key: String) -> String? { defaults.string(forKey: key) }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
        func tri(_ key: String) -> ChapterDisplay.TriState { ChapterDisplay.TriState(rawValue: int(key, 0)) ?? .off }

        themeMode = string("pref_theme_mode_key").flatMap(ThemeMode.init) ?? .system
        appTheme = string("pref_app_theme").flatMap(AppTheme.init) ?? .default
        pureBlack = bool("pref_theme_dark_amoled_key", false)
        useCustomTheme = bool("pref_app_theme_custom", false)
        customThemes = defaults.data(forKey: "custom_themes").flatMap { try? JSONDecoder().decode([CustomTheme].self, from: $0) } ?? []
        customThemeIndex = int("custom_theme_index", 0)
        relativeTimestamps = bool("relative_time_v2", true)
        dateFormat = string("app_date_format") ?? ""
        showUpdatesTab = bool("nav_show_updates", true)
        showHistoryTab = bool("nav_show_history", true)
        showBrowseTab = bool("nav_show_browse", true)
        navPosition = string("nav_bar_position").flatMap(NavPosition.init) ?? .automatic
        navAlignment = string("nav_bar_alignment").flatMap(NavAlignment.init) ?? .center
        tabOrder = defaults.stringArray(forKey: "nav_bar_order") ?? ["library", "updates", "history", "browse", "more"]
        sourceLanguages = defaults.stringArray(forKey: "source_languages") ?? ["all", Locale.current.language.languageCode?.identifier ?? "en"]

        displayMode = string("pref_display_mode_library").flatMap(DisplayMode.init) ?? .compactGrid
        gridColumnsPortrait = int("pref_library_columns_portrait_key", 0)
        gridColumnsLandscape = int("pref_library_columns_landscape_key", 0)
        downloadBadge = bool("display_download_badge", false)
        unreadBadge = bool("display_unread_badge", true)
        sourceBadge = bool("display_source_badge", false)
        continueReadingButton = bool("display_continue_reading_button", false)
        categoryTabs = bool("display_category_tabs", true)
        categoryCounts = bool("display_number_of_items", false)
        librarySort = string("library_sorting_mode").flatMap(LibrarySort.init) ?? .alphabetical
        librarySortAscending = bool("library_sorting_ascending", true)
        filterDownloaded = tri("pref_filter_library_downloaded_v2")
        filterUnread = tri("pref_filter_library_unread_v2")
        filterStarted = tri("pref_filter_library_started_v2")
        filterBookmarked = tri("pref_filter_library_bookmarked_v2")
        filterCompleted = tri("pref_filter_library_completed_v2")
        lastCategoryIndex = int("last_used_category", 0)
        updateOnLaunch = bool("pref_update_library_on_launch", false)
        autoUpdate = bool("pref_library_update_interval_key", false)
        smartUpdateSkipCompleted = bool("library_update_restriction_completed", true)
        smartUpdateSkipUnread = bool("library_update_restriction_unread", false)
        smartUpdateSkipNotStarted = bool("library_update_restriction_not_started", false)
        defaultCategory = int("default_category", -1)
        swipeStartAction = string("pref_chapter_swipe_start_action").flatMap(SwipeAction.init) ?? .toggleBookmark
        swipeEndAction = string("pref_chapter_swipe_end_action").flatMap(SwipeAction.init) ?? .toggleRead

        downloadOnlyOnWifi = bool("pref_download_only_over_wifi_key", true)
        concurrentPages = int("download_parallel_page_limit", 3)
        deleteAfterReading = bool("pref_remove_after_read", false)
        deleteAfterMarkedRead = bool("pref_remove_after_marked_as_read_key", false)
        downloadNewChapters = bool("download_new", false)
        downloadAhead = int("auto_download_while_reading", 0)
        downloadsPaused = bool("download_queue_paused", false)

        hideInLibraryItems = bool("browse_hide_in_library_items", false)
        browseDisplayMode = string("pref_display_mode_catalogue").flatMap(DisplayMode.init) ?? .compactGrid

        downloadedOnly = bool("pref_downloaded_only", false)
        incognitoMode = bool("incognito_mode", false)
        shownWelcome = bool("onboarding_complete", false)
    }

    /// Whether any library filter is on (the filter icon shows as active).
    var hasLibraryFilter: Bool {
        [filterDownloaded, filterUnread, filterStarted, filterBookmarked, filterCompleted].contains { $0 != .off } || downloadedOnly
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

/// Read by actors that can't reach the main actor synchronously: a snapshot of the download
/// preferences, kept current by `AppPreferences`.
struct DownloadPreferences: Sendable {
    var onlyOnWifi: Bool
    var concurrentPages: Int
    var paused: Bool

    static func current(_ defaults: UserDefaults = .standard) -> DownloadPreferences {
        DownloadPreferences(
            onlyOnWifi: defaults.object(forKey: "pref_download_only_over_wifi_key") as? Bool ?? true,
            concurrentPages: max(1, defaults.object(forKey: "download_parallel_page_limit") as? Int ?? 3),
            paused: defaults.object(forKey: "download_queue_paused") as? Bool ?? false
        )
    }
}
