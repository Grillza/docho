import Foundation

/// Series details the user edited: title, author, artist, description, genres and status. Like
/// Kavita's locked fields, an edited field stays over what the source sends on every refresh
/// (`apply`) until it's reset. Shared with other devices and Dōchō Server as Dōchō Sync's
/// "details" records, whose value is `json`: only the edited fields, blank ones as "". Android's
/// `SeriesEdits`.
@MainActor
final class SeriesEdits {
    /// The edited fields; nil ones weren't edited.
    struct Details: Codable, Equatable, Sendable {
        var title: String?
        var author: String?
        var artist: String?
        var description: String?
        var genres: [String]?
        var status: Int?

        var isEmpty: Bool { self == Details() }

        var json: SyncJSON {
            var fields: [String: SyncJSON] = [:]
            if let title { fields["title"] = .string(title) }
            if let author { fields["author"] = .string(author) }
            if let artist { fields["artist"] = .string(artist) }
            if let description { fields["description"] = .string(description) }
            if let genres { fields["genres"] = .array(genres.map(SyncJSON.string)) }
            if let status { fields["status"] = .int(Int64(status)) }
            return .object(fields)
        }

        init(title: String? = nil, author: String? = nil, artist: String? = nil, description: String? = nil, genres: [String]? = nil, status: Int? = nil) {
            self.title = title
            self.author = author
            self.artist = artist
            self.description = description
            self.genres = genres
            self.status = status
        }

        init(json: SyncJSON) {
            title = json["title"]?.string
            author = json["author"]?.string
            artist = json["artist"]?.string
            description = json["description"]?.string
            if case .array = json["genres"] { genres = json["genres"]?.strings } else { genres = nil }
            status = json["status"]?.int.map { Int($0) }
        }
    }

    private let defaults: UserDefaults
    /// By "source|url", as Dōchō Sync keys series.
    private(set) var edits: [String: Details]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        edits = defaults.data(forKey: "series_edits").flatMap { try? JSONDecoder().decode([String: Details].self, from: $0) } ?? [:]
    }

    func get(source: Int64, url: String) -> Details? { edits[SyncValues.key(source, url)] }

    /// Remembers `details` for the series, or forgets them when empty or nil.
    func put(source: Int64, url: String, _ details: Details?) {
        let key = SyncValues.key(source, url)
        if let details, !details.isEmpty { edits[key] = details } else { edits[key] = nil }
        defaults.set(try? JSONEncoder().encode(edits), forKey: "series_edits")
    }

    /// Puts the edited fields over what a source just sent, before it's saved.
    func apply(source: Int64, _ manga: SManga) -> SManga {
        guard let edit = get(source: source, url: manga.url) else { return manga }
        var manga = manga
        if let title = edit.title, !title.isEmpty { manga.title = title }
        if let author = edit.author { manga.author = author }
        if let artist = edit.artist { manga.artist = artist }
        if let description = edit.description { manga.description = description }
        if let genres = edit.genres { manga.genre = genres.joined(separator: ", ") }
        if let status = edit.status { manga.status = MangaStatus(rawValue: status) ?? .unknown }
        return manga
    }

    /// Writes `details`' fields over a stored series' details.
    nonisolated static func write(_ details: Details, to series: inout SeriesRecord) {
        if let title = details.title, !title.isEmpty { series.name = title }
        if let author = details.author { series.authors = author.isEmpty ? nil : author }
        if let artist = details.artist { series.artists = artist.isEmpty ? nil : artist }
        if let description = details.description { series.summary = description.isEmpty ? nil : description }
        if let genres = details.genres { series.genres = genres.isEmpty ? nil : genres.joined(separator: ", ") }
        if let status = details.status { series.status = status }
    }
}
