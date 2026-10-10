import Foundation

/// The sorts Kavita browse offers, as on Android.
enum KavitaBrowseSort: Int, CaseIterable, Identifiable, Sendable {
    case name
    case recentlyAdded
    case lastChapterAdded
    case readingProgress

    var id: Self { self }

    var field: Int {
        switch self {
        case .name: KavitaConstants.sortName
        case .recentlyAdded: KavitaConstants.sortCreated
        case .lastChapterAdded: KavitaConstants.sortLastChapterAdded
        case .readingProgress: KavitaConstants.sortReadProgress
        }
    }

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .recentlyAdded: String(localized: "Recently added")
        case .lastChapterAdded: String(localized: "Last chapter added")
        case .readingProgress: String(localized: "Reading progress")
        }
    }
}

/// What the browse grid shows; a change starts again from page 1.
struct KavitaBrowseRequest: Equatable, Sendable {
    var query = ""
    var libraryId: Int?
    var sort = KavitaBrowseSort.name
    var ascending = true

    /// Port of `KavitaSource.getSearchManga` + `browse`: search, library, sort, and never EPUBs,
    /// which Kavita renders as text and which have no page images.
    var filter: KavitaFilter {
        var statements: [KavitaFilterStatement] = []
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            statements.append(KavitaFilterStatement(
                comparison: KavitaConstants.comparisonMatches, field: KavitaConstants.fieldSeriesName, value: query
            ))
        }
        if let libraryId {
            statements.append(KavitaFilterStatement(
                comparison: KavitaConstants.comparisonContains, field: KavitaConstants.fieldLibraries, value: String(libraryId)
            ))
        }
        statements.append(KavitaFilterStatement(
            comparison: KavitaConstants.comparisonNotContains,
            field: KavitaConstants.fieldFormats,
            value: String(KavitaConstants.formatEpub)
        ))
        return KavitaFilter(statements: statements, sortOptions: KavitaSortOptions(sortField: sort.field, isAscending: ascending))
    }
}
