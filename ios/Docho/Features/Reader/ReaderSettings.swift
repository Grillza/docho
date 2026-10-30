import Foundation
import Observation

/// How a series is read (Mihon's reading modes). Stored per series in `series.readerMode`; the
/// default is in Settings → Reader.
enum ReaderMode: String, CaseIterable, Identifiable, Sendable {
    case leftToRight = "ltr"
    case rightToLeft = "rtl"
    /// Paged, top to bottom.
    case vertical
    /// Vertical, continuous, at full width.
    case webtoon
    /// Like webtoon, with a gap between pages.
    case webtoonGaps

    var id: Self { self }

    var title: String {
        switch self {
        case .leftToRight: String(localized: "Paged (left to right)")
        case .rightToLeft: String(localized: "Paged (right to left)")
        case .vertical: String(localized: "Paged (vertical)")
        case .webtoon: String(localized: "Long strip")
        case .webtoonGaps: String(localized: "Long strip with gaps")
        }
    }

    /// Mihon's reading mode icon.
    var icon: String {
        switch self {
        case .leftToRight: "reader_left_to_right"
        case .rightToLeft: "reader_right_to_left"
        case .vertical: "reader_vertical"
        case .webtoon: "reader_long_strip"
        case .webtoonGaps: "reader_long_strip_gaps"
        }
    }

    var isRightToLeft: Bool { self == .rightToLeft }
    var isLongStrip: Bool { self == .webtoon || self == .webtoonGaps }
    var isPaged: Bool { !isLongStrip }
}

/// Where taps turn pages (Mihon's navigation layouts).
enum TapZones: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case lShaped
    case kindle
    case edge
    case disabled

    var id: Self { self }

    var title: String {
        switch self {
        case .default: String(localized: "Default")
        case .lShaped: String(localized: "L shaped")
        case .kindle: String(localized: "Kindle-ish")
        case .edge: String(localized: "Edge")
        case .disabled: String(localized: "Disabled")
        }
    }

    /// `left` and `right` turn pages by direction (Mihon's default for paged modes), so they
    /// mean next or previous depending on the reading direction.
    enum Action { case previous, next, left, right, menu }

    /// What a tap at `point` (0…1 in both axes) does: Mihon's `ViewerNavigation` regions, with
    /// everything outside them showing the menu.
    func action(at point: CGPoint, invert: InvertTaps) -> Action {
        var x = point.x
        var y = point.y
        if invert == .horizontal || invert == .both { x = 1 - x }
        if invert == .vertical || invert == .both { y = 1 - y }
        let one: CGFloat = 0.33
        let two: CGFloat = 0.66
        switch self {
        case .default:
            if x < one { return .left }
            if x >= two { return .right }
            return .menu
        case .lShaped:
            if y < one || (x < one && y < two) { return .previous }
            if y >= two || (x >= two && y >= one) { return .next }
            return .menu
        case .kindle:
            if y < one { return .menu }
            return x < one ? .previous : .next
        case .edge:
            if x < one || x >= two { return .next }
            if y >= two { return .previous }
            return .menu
        case .disabled:
            return .menu
        }
    }
}

enum InvertTaps: String, CaseIterable, Identifiable, Sendable {
    case none, horizontal, vertical, both

    var id: Self { self }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .horizontal: String(localized: "Horizontal")
        case .vertical: String(localized: "Vertical")
        case .both: String(localized: "Both")
        }
    }
}

enum ReaderBackground: String, CaseIterable, Identifiable, Sendable {
    case black, gray, white, automatic

    var id: Self { self }

    var title: String {
        switch self {
        case .black: String(localized: "Black")
        case .gray: String(localized: "Gray")
        case .white: String(localized: "White")
        case .automatic: String(localized: "Automatic")
        }
    }
}

/// Reader preferences that apply to every series, kept in UserDefaults.
@MainActor
@Observable
final class ReaderSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// For series without their own mode. Right to left, as in Mihon.
    var defaultMode: ReaderMode { didSet { defaults.set(defaultMode.rawValue, forKey: "reader_default_mode") } }
    /// Two pages side by side in paged mode, when the screen is wider than it is tall.
    var spreads: Bool { didSet { defaults.set(spreads, forKey: "reader_spreads") } }
    /// In spreads, the first page (usually the cover) stands alone, so pairs line up as printed.
    var coverAlone: Bool { didSet { defaults.set(coverAlone, forKey: "reader_spreads_cover_alone") } }
    var showPageNumber: Bool { didSet { defaults.set(showPageNumber, forKey: "pref_show_page_number_key") } }
    var keepScreenOn: Bool { didSet { defaults.set(keepScreenOn, forKey: "pref_keep_screen_on_key") } }
    var fullscreen: Bool { didSet { defaults.set(fullscreen, forKey: "fullscreen") } }
    var background: ReaderBackground { didSet { defaults.set(background.rawValue, forKey: "pref_reader_theme_key") } }
    var pagedTapZones: TapZones { didSet { defaults.set(pagedTapZones.rawValue, forKey: "reader_navigation_mode_pager") } }
    var pagedInvert: InvertTaps { didSet { defaults.set(pagedInvert.rawValue, forKey: "reader_tapping_inverted") } }
    var stripTapZones: TapZones { didSet { defaults.set(stripTapZones.rawValue, forKey: "reader_navigation_mode_webtoon") } }
    var stripInvert: InvertTaps { didSet { defaults.set(stripInvert.rawValue, forKey: "reader_tapping_inverted_webtoon") } }
    var skipRead: Bool { didSet { defaults.set(skipRead, forKey: "skip_read") } }
    /// Show the transition page between chapters even when moving on by tap.
    var alwaysShowTransition: Bool { didSet { defaults.set(alwaysShowTransition, forKey: "always_show_chapter_transition") } }
    var doubleTapZoom: Bool { didSet { defaults.set(doubleTapZoom, forKey: "pref_enable_double_tap_zoom") } }
    var animatePageTransitions: Bool { didSet { defaults.set(animatePageTransitions, forKey: "pref_enable_transitions_key") } }
    /// Long strip: the page gap in points for "Long strip with gaps".
    var stripSidePadding: Int { didSet { defaults.set(stripSidePadding, forKey: "webtoon_side_padding") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        defaultMode = defaults.string(forKey: "reader_default_mode").flatMap(ReaderMode.init(rawValue:)) ?? .rightToLeft
        spreads = bool("reader_spreads", false)
        coverAlone = bool("reader_spreads_cover_alone", true)
        showPageNumber = bool("pref_show_page_number_key", true)
        keepScreenOn = bool("pref_keep_screen_on_key", true)
        fullscreen = bool("fullscreen", true)
        background = defaults.string(forKey: "pref_reader_theme_key").flatMap(ReaderBackground.init) ?? .black
        pagedTapZones = defaults.string(forKey: "reader_navigation_mode_pager").flatMap(TapZones.init) ?? .default
        pagedInvert = defaults.string(forKey: "reader_tapping_inverted").flatMap(InvertTaps.init) ?? .none
        stripTapZones = defaults.string(forKey: "reader_navigation_mode_webtoon").flatMap(TapZones.init) ?? .lShaped
        stripInvert = defaults.string(forKey: "reader_tapping_inverted_webtoon").flatMap(InvertTaps.init) ?? .none
        skipRead = bool("skip_read", false)
        alwaysShowTransition = bool("always_show_chapter_transition", true)
        doubleTapZoom = bool("pref_enable_double_tap_zoom", true)
        animatePageTransitions = bool("pref_enable_transitions_key", true)
        stripSidePadding = defaults.object(forKey: "webtoon_side_padding") as? Int ?? 0
    }
}
