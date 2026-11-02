import Foundation

/// Names and numbers the user gave chapters in Dōchō, and whether they said a chapter is a volume
/// (Android's `ChapterRenames`). Sources send their own names again on every refresh, so these are
/// kept apart, keyed by source id and chapter url, and put back over them (`apply`).
@MainActor
final class ChapterRenames {
    /// `original` is the source's name before the user's first rename, and `at` when it was last
    /// renamed (seconds since 1970), both missing on renames from before 0.30.1.
    struct Rename: Codable, Equatable, Sendable {
        var name: String
        var number: Double
        var original: String?
        var at: Double?
    }

    private let defaults: UserDefaults
    private(set) var renames: [String: Rename]
    /// `ChapterMemo.kindVolume` or `ChapterMemo.kindChapter` by key.
    private(set) var kinds: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        renames = defaults.data(forKey: "chapter_renames").flatMap { try? JSONDecoder().decode([String: Rename].self, from: $0) } ?? [:]
        kinds = defaults.data(forKey: "chapter_kinds").flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// What the user renamed the chapter at `url` to, if they did.
    func get(source: Int64, url: String) -> Rename? { renames[Self.key(source, url)] }

    /// Remembers `rename` for the chapter at `newURL`, which was at `oldURL` before its file was
    /// renamed.
    func put(source: Int64, oldURL: String, newURL: String, _ rename: Rename) {
        renames[Self.key(source, oldURL)] = nil
        renames[Self.key(source, newURL)] = rename
        if oldURL != newURL, let kind = kinds.removeValue(forKey: Self.key(source, oldURL)) {
            kinds[Self.key(source, newURL)] = kind
        }
        save()
    }

    /// Forgets the user's name and number for the chapter at `url`; Dōchō Sync, when another
    /// device dropped it.
    func remove(source: Int64, url: String) {
        renames[Self.key(source, url)] = nil
        save()
    }

    func removeKind(source: Int64, url: String) {
        kinds[Self.key(source, url)] = nil
        save()
    }

    /// Remembers whether the chapter at `url` is a volume or a chapter.
    func putKind(source: Int64, url: String, _ kind: String) {
        kinds[Self.key(source, url)] = kind
        save()
    }

    /// Puts the user's names, numbers and kinds over the ones `chapters` came with.
    func apply(source: Int64, _ chapters: [SChapter]) -> [SChapter] {
        guard !renames.isEmpty || !kinds.isEmpty else { return chapters }
        return chapters.map { chapter in
            var chapter = chapter
            let key = Self.key(source, chapter.url)
            if let rename = renames[key] {
                chapter.name = rename.name
                chapter.number = rename.number
            }
            if let kind = kinds[key] { chapter.memo.values[ChapterMemo.kind] = .string(kind) }
            return chapter
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(renames) { defaults.set(data, forKey: "chapter_renames") }
        if let data = try? JSONEncoder().encode(kinds) { defaults.set(data, forKey: "chapter_kinds") }
    }

    private static func key(_ source: Int64, _ url: String) -> String { "\(source)|\(url)" }
}

extension ChapterMemo {
    /// Set to `kindVolume` or `kindChapter` when the user says which a chapter is.
    static let kind = "kind"
    static let kindVolume = "volume"
    static let kindChapter = "chapter"

    /// "Vol. 3", "Volume 3 - Title" or "v03", but not "Vol. 3 Ch. 12", a chapter in a volume.
    static func looksLikeVolume(_ name: String) -> Bool {
        name.firstMatch(of: #/^\s*(?i:vol(?:ume)?\.?|v\.?)\s*[0-9]/#) != nil
            && name.firstMatch(of: #/(?i)\b(?:ch|chap|chapter)\.?\s*[0-9]/#) == nil
    }
}

extension ChapterRecord {
    /// Whether this is a whole volume: as the user set it, else read from its name.
    var isVolume: Bool {
        switch chapterMemo.string(ChapterMemo.kind) {
        case ChapterMemo.kindVolume: true
        case ChapterMemo.kindChapter: false
        default: ChapterMemo.looksLikeVolume(name)
        }
    }
}
