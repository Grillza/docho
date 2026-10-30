import Foundation
import Observation

/// How a series is read. Stored per series in `series.readerMode`; the default is in Settings.
enum ReaderMode: String, CaseIterable, Identifiable, Sendable {
    case leftToRight = "ltr"
    case rightToLeft = "rtl"
    /// Vertical, continuous, at full width.
    case webtoon

    var id: Self { self }

    var title: String {
        switch self {
        case .leftToRight: String(localized: "Left to right")
        case .rightToLeft: String(localized: "Right to left")
        case .webtoon: String(localized: "Webtoon")
        }
    }

    var systemImage: String {
        switch self {
        case .leftToRight: "arrow.right.square"
        case .rightToLeft: "arrow.left.square"
        case .webtoon: "arrow.down.square"
        }
    }

    var isRightToLeft: Bool { self == .rightToLeft }
}

/// Reader preferences that apply to every series, kept in UserDefaults.
@MainActor
@Observable
final class ReaderSettings {
    private static let defaultModeKey = "reader_default_mode"
    private static let spreadsKey = "reader_spreads"
    private static let coverAloneKey = "reader_spreads_cover_alone"

    @ObservationIgnored private let defaults: UserDefaults

    /// For series without their own mode. Right to left, as in Mihon.
    var defaultMode: ReaderMode {
        didSet { defaults.set(defaultMode.rawValue, forKey: Self.defaultModeKey) }
    }

    /// Two pages side by side in paged mode, when the screen is wider than it is tall.
    var spreads: Bool {
        didSet { defaults.set(spreads, forKey: Self.spreadsKey) }
    }

    /// In spreads, the first page (usually the cover) stands alone, so pairs line up as printed.
    var coverAlone: Bool {
        didSet { defaults.set(coverAlone, forKey: Self.coverAloneKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultMode = defaults.string(forKey: Self.defaultModeKey).flatMap(ReaderMode.init(rawValue:)) ?? .rightToLeft
        spreads = defaults.object(forKey: Self.spreadsKey) as? Bool ?? false
        coverAlone = defaults.object(forKey: Self.coverAloneKey) as? Bool ?? true
    }
}
