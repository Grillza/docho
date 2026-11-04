import Foundation

/// A value a field could take, and the tracker it's from. Statuses are numbers, as text.
struct FillOption: Codable, Sendable, Equatable, Hashable {
    var value: String
    var trackerName: String
}

/// A field a tracker has something to say about. `field` is its name in "details" records.
struct FillChange: Codable, Sendable, Equatable {
    var field: String
    var current: String
    var options: [FillOption]
    /// It takes a decision: `current` would be replaced, or the `options` differ.
    var conflict: Bool
}

enum FillProblem: String, Codable, Sendable { case ready, different, severalMatches, noMatch }

/// A series on the review list a scan leaves.
struct FillItem: Codable, Sendable, Equatable, Identifiable {
    var source: Int64
    var url: String
    var title: String
    var problem: FillProblem
    var changes: [FillChange] = []
    /// The series it could be, when there's no clear match.
    var candidates: [TrackerFill.Match] = []
    /// The user said which series it is; scans would only fail to find it again.
    var picked = false

    var id: String { SyncValues.key(source, url) }
}

/// The fields a tracker can fill, as a series has them.
struct FillCurrent: Sendable, Equatable {
    var author: String
    var artist: String
    var description: String
    var status: Int

    var hasEmptyFields: Bool {
        TrackerFillRules.isEmptyName(author) || TrackerFillRules.isEmptyName(artist)
            || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status == MangaStatus.unknown.rawValue
    }
}

/// What a scan makes of what trackers say. These are the same rules as Dōchō Server's `TrackerFill`
/// and Android's `TrackerFillRules`: decisions are shared through Dōchō Sync, so names must compare alike.
enum TrackerFillRules {
    static let author = "author"
    static let artist = "artist"
    static let description = "description"
    static let status = "status"
    /// In the remembered choices, a series left out of scans altogether.
    static let skipped = "*"
    static let kept = "kept"

    static func isEmptyName(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.lowercased() == "unknown"
    }

    /// A title without case, spaces or punctuation, so only real differences stop a match.
    static func comparable(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Names to compare whatever their order: "MIURA Kentaro" is "Kentaro Miura".
    static func namesKey(_ names: String) -> String {
        var seen = Set<String>()
        return names.split(separator: ",")
            .map { name in
                name.split(whereSeparator: \.isWhitespace).map { comparable(String($0)) }.filter { !$0.isEmpty }.sorted().joined(separator: " ")
            }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted()
            .joined(separator: ",")
    }

    /// The value that stands for an option in the remembered choices.
    static func optionKey(_ field: String, _ value: String) -> String {
        field == author || field == artist ? namesKey(value) : value
    }

    /// Whether a tracker's `status` says the same as the series'. Trackers can't tell these apart.
    private static func sameStatus(_ current: Int, _ status: Int) -> Bool {
        current == status || current == MangaStatus.licensed.rawValue
            || (current == MangaStatus.publishingFinished.rawValue && status == MangaStatus.completed.rawValue)
    }

    /// What `matches` have to say about a series. An empty field just takes its value, unless
    /// trackers disagree. A field with a value is a conflict if a tracker differs, except for a
    /// status the last fill gave (`filledStatus`), which is only out of date. Summaries are never
    /// compared: no two are worded alike. Values in `ignored` were decided on earlier.
    static func review(
        _ current: FillCurrent, matches: [TrackerFill.Match], filledStatus: Int?, ignored: [String: [String]] = [:]
    ) -> [FillChange] {
        var changes: [FillChange] = []
        func names(_ field: String, _ value: String, _ of: (TrackerFill.Match) -> String) {
            var seen = Set<String>()
            let options = matches
                .filter { !of($0).isEmpty }
                .map { FillOption(value: of($0), trackerName: $0.trackerName) }
                .filter { seen.insert(namesKey($0.value)).inserted }
                .filter { !(ignored[field] ?? []).contains(namesKey($0.value)) }
            if isEmptyName(value) {
                if !options.isEmpty { changes.append(FillChange(field: field, current: value, options: options, conflict: options.count > 1)) }
            } else {
                let different = options.filter { namesKey($0.value) != namesKey(value) }
                if !different.isEmpty { changes.append(FillChange(field: field, current: value, options: different, conflict: true)) }
            }
        }
        names(author, current.author) { $0.author }
        names(artist, current.artist) { $0.artist }

        if current.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (ignored[description] ?? []).isEmpty,
           let match = matches.first(where: { !$0.description.isEmpty }) {
            changes.append(FillChange(
                field: description, current: "", options: [FillOption(value: match.description, trackerName: match.trackerName)], conflict: false
            ))
        }

        var seenStatus = Set<Int>()
        let statuses = matches
            .filter { $0.status != MangaStatus.unknown.rawValue && !(ignored[status] ?? []).contains(String($0.status)) }
            .filter { seenStatus.insert($0.status).inserted }
            .filter { !sameStatus(current.status, $0.status) }
            .map { FillOption(value: String($0.status), trackerName: $0.trackerName) }
        if !statuses.isEmpty {
            let weOwnIt = current.status == MangaStatus.unknown.rawValue || current.status == filledStatus
            changes.append(FillChange(field: status, current: String(current.status), options: statuses, conflict: !weOwnIt || statuses.count > 1))
        }
        return changes
    }

    /// The problem for `changes`, or nil if there's nothing to say.
    static func problem(of changes: [FillChange]) -> FillProblem? {
        if changes.isEmpty { return nil }
        return changes.contains(where: \.conflict) ? .different : .ready
    }

    /// An item as it stands now that the series may have changed since the scan, here or on another
    /// device: values it already has or that were decided against drop out. Nil if nothing's left.
    static func prune(_ item: FillItem, current: FillCurrent, filledStatus: Int?, ignored: [String: [String]]) -> FillItem? {
        if ignored[skipped] != nil { return nil }
        if item.changes.isEmpty { return current.hasEmptyFields ? item : nil }
        let changes: [FillChange] = item.changes.compactMap { change in
            var change = change
            let decided = ignored[change.field] ?? []
            switch change.field {
            case author, artist:
                let live = change.field == author ? current.author : current.artist
                let options = change.options.filter {
                    !decided.contains(namesKey($0.value)) && (isEmptyName(live) || namesKey($0.value) != namesKey(live))
                }
                guard !options.isEmpty else { return nil }
                change.current = live
                change.options = options
                change.conflict = !isEmptyName(live) || options.count > 1
            case description:
                guard current.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, decided.isEmpty else { return nil }
            default:
                let options = change.options.filter { option in
                    !decided.contains(option.value) && !sameStatus(current.status, Int(option.value) ?? 0)
                }
                guard !options.isEmpty else { return nil }
                let weOwnIt = current.status == MangaStatus.unknown.rawValue || current.status == filledStatus
                change.current = String(current.status)
                change.options = options
                change.conflict = !weOwnIt || options.count > 1
            }
            return change
        }
        guard let problem = problem(of: changes) else { return nil }
        var pruned = item
        pruned.problem = problem
        pruned.changes = changes
        return pruned
    }
}
