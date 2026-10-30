import Foundation

/// One chapter as the app lists it, in Kavita reading order.
struct KavitaChapterEntry: Sendable, Equatable {
    var chapterId: Int
    var volumeId: Int
    var name: String
    /// Kept identical to Android's `chapter_number` (see `KavitaChapterList`).
    var number: Double
    var pages: Int
    var pagesRead: Int
    var dateUpload: Date?
}

/// Port of `KavitaSource.chapterList`: names, numbers and order of a series' chapters.
enum KavitaChapterList {
    /// Kavita's reading order: volumes (and their chapters), then loose chapters, then specials.
    /// Android shows the same list reversed (newest first); iOS shows it in this order.
    static func build(_ volumes: [KavitaVolume], timeZone: TimeZone = .current) -> [KavitaChapterEntry] {
        var volumeEntries: [KavitaChapterEntry] = []
        var looseChapters: [KavitaChapterEntry] = []
        var specials: [KavitaChapterEntry] = []

        for volume in volumes.sorted(by: { $0.volumeNumber < $1.volumeNumber }) {
            let looseLeaf = volume.isLooseLeaf
            for chapter in volume.chapters.sorted(by: { $0.chapterNumber < $1.chapterNumber }) {
                var entry = KavitaChapterEntry(
                    chapterId: chapter.id,
                    volumeId: chapter.volumeId,
                    name: "",
                    number: chapter.chapterNumber,
                    pages: chapter.pages,
                    pagesRead: chapter.pagesRead,
                    dateUpload: parseDate(chapter.releaseDate, timeZone: timeZone) ?? parseDate(chapter.created, timeZone: timeZone)
                )
                if chapter.isSpecial || volume.volumeNumber == KavitaConstants.specialVolumeNumber {
                    entry.name = chapter.displayTitle ?? "Special"
                    entry.number = specialChapterNumber(specials.count)
                    specials.append(entry)
                } else if chapter.isWholeVolume {
                    entry.name = "Volume " + volume.displayNumber
                    if let title = chapter.titleName, !title.isBlank, title != volume.name {
                        entry.name += " - " + title
                    }
                    entry.number = volumeChapterNumber(volume.volumeNumber)
                    volumeEntries.append(entry)
                } else {
                    var name = looseLeaf ? "" : "Vol. \(volume.displayNumber) "
                    let range = chapter.range.flatMap { $0.isBlank ? nil : $0 }
                    name += "Ch. " + (range ?? formatNumber(chapter.chapterNumber))
                    if let title = chapter.titleName, !title.isBlank, title != chapter.range {
                        name += " - " + title
                    }
                    entry.name = name
                    if looseLeaf { looseChapters.append(entry) } else { volumeEntries.append(entry) }
                }
            }
        }
        return volumeEntries + looseChapters + specials
    }

    /// Like Kavita, a whole-volume file is never compared with a chapter of the same number, so
    /// each volume gets its own number below every chapter, in volume order.
    static func volumeChapterNumber(_ volumeNumber: Double) -> Double {
        volumeNumber - 100_000
    }

    /// Specials get distinct numbers too, below the volumes, in Kavita's order.
    static func specialChapterNumber(_ index: Int) -> Double {
        Double(index) - 200_000
    }

    /// Kavita sends local times without an offset; a year of 1 means "not set". A value with an
    /// offset (or `Z`) is read as such, anything else as a time in `timeZone`.
    static func parseDate(_ value: String?, timeZone: TimeZone = .current) -> Date? {
        guard let value, !value.isBlank, !value.hasPrefix("0001"),
              let match = value.wholeMatch(of: #/(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?/#)
        else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        if let offset = match.output.2 {
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            let normalized = offset == "Z" ? "+00:00" : offset.contains(":") ? String(offset) : offset.prefix(3) + ":" + offset.suffix(2)
            return formatter.date(from: match.output.1 + normalized)
        }
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = timeZone
        return formatter.date(from: String(match.output.1))
    }
}

private extension KavitaVolume {
    var isLooseLeaf: Bool {
        volumeNumber == KavitaConstants.looseLeafVolumeNumber || (minNumber == nil && volumeNumber == 0)
    }

    var displayNumber: String {
        !name.isBlank && name != "0" ? name : formatNumber(volumeNumber)
    }
}

private extension KavitaChapter {
    var isWholeVolume: Bool {
        chapterNumber == KavitaConstants.defaultChapterNumber || (minNumber == nil && number == "0")
    }

    var displayTitle: String? {
        [titleName, title, range].lazy.compactMap { $0 }.first { !$0.isBlank }
    }
}

/// Series details as Android fills them in `KavitaSource.mangaDetails`.
struct KavitaSeriesDetails: Sendable, Equatable {
    var summary: String?
    var authors: String?
    var artists: String?
    var genres: String?
    var status: Int

    init(_ metadata: KavitaSeriesMetadata) {
        summary = metadata.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        authors = Self.labels(metadata.writers)
        artists = Self.labels(metadata.pencillers.isEmpty ? metadata.coverArtists : metadata.pencillers)
        genres = Self.labels(metadata.genres + metadata.tags)
        status = metadata.publicationStatus
    }

    private static func labels(_ named: [KavitaNamed]) -> String? {
        var seen = Set<String>()
        return named.compactMap(\.label).filter { seen.insert($0).inserted }.joined(separator: ", ").nilIfEmpty
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
