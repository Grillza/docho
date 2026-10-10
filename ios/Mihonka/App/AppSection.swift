import SwiftUI

/// The top-level sections: tabs on iPhone, sidebar rows on iPad.
enum AppSection: String, CaseIterable, Identifiable {
    case library
    case browse
    case downloads
    case settings

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .library: "Library"
        case .browse: "Browse"
        case .downloads: "Downloads"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "books.vertical"
        case .browse: "safari"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }
}
