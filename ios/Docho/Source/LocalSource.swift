import CoreGraphics
import Foundation
import UIKit
import UniformTypeIdentifiers

/// Mihon's Local source: comics kept on the device, in `Documents/local` (shown in the Files app
/// as On My iPhone › Dōchō › local). Each folder there is a series; inside, each CBZ, CBR, CB7, EPUB, PDF or
/// folder of images is a chapter. A `cover.jpg` and `ComicInfo.xml` in the series folder are used
/// as on Android. Files put straight into `local` (or into Dōchō's top folder) get a folder of
/// their own when the source is next listed.
struct LocalSource: MangaSource {
    static let id: Int64 = 0

    let root: URL
    let documents: URL
    /// Where archive pages are unpacked and PDF pages drawn while reading.
    let cache: URL

    var id: Int64 { Self.id }
    var name: String { String(localized: "Local source") }
    var supportsLatest: Bool { true }
    var isConfigured: Bool { true }

    static func standard() -> LocalSource {
        let fileManager = FileManager.default
        let documents = (try? fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        let caches = (try? fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        return LocalSource(
            root: documents.appending(path: "local", directoryHint: .isDirectory),
            documents: documents,
            cache: caches.appending(path: "LocalPages", directoryHint: .isDirectory)
        )
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic", "heif", "bmp", "jxl"]
    /// CBZ/ZIP, CBR/RAR, CB7/7Z and EPUB (`ComicArchive`), and PDF.
    static let chapterExtensions = ComicArchive.extensions.union(["pdf"])
    private static let latestThreshold: TimeInterval = 7 * 24 * 60 * 60

    // MARK: Listing

    func popular(page: Int) async throws -> MangasPage {
        try await search(page: page, query: "", filters: [])
    }

    func latest(page: Int) async throws -> MangasPage {
        let cutoff = Date.now.addingTimeInterval(-Self.latestThreshold)
        let recent = try seriesFolders()
            .filter { modified($0) >= cutoff }
            .sorted { modified($0) > modified($1) }
        return MangasPage(mangas: recent.map(manga), hasNextPage: false)
    }

    func search(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        let folders = try seriesFolders()
            .filter { query.isBlank || $0.lastPathComponent.localizedCaseInsensitiveContains(query) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return MangasPage(mangas: folders.map(manga), hasNextPage: false)
    }

    private func manga(_ folder: URL) -> SManga {
        let name = folder.lastPathComponent
        // A cover from the first chapter, so the listing isn't blank before a series is opened.
        if coverFile(series: name) == nil, let first = try? chapterFiles(folder).first {
            try? makeCover(from: first, in: folder)
        }
        return SManga(url: name, title: name, thumbnailURL: coverFile(series: name) == nil ? nil : "cover")
    }

    /// The series folders, after giving loose chapter files a folder of their own.
    func seriesFolders() throws -> [URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in [root, documents] {
            for file in contents(directory) where !isDirectory(file) && Self.isChapterFile(file) {
                try? move(file, toSeries: file.deletingPathExtension().lastPathComponent)
            }
        }
        return contents(root).filter(isDirectory)
    }

    // MARK: Series

    func update(_ manga: SManga, details: Bool, chapters: Bool) async throws -> (manga: SManga, chapters: [SChapter]?) {
        let folder = try seriesFolder(manga.url)
        var manga = manga
        var list: [SChapter]?
        if chapters {
            list = try chapterList(manga: manga, folder: folder)
        }
        if details {
            manga.title = manga.url
            if let info = comicInfo(series: folder) {
                info.apply(to: &manga)
            } else if let legacy = try? JSONDecoder().decode(
                LegacyDetails.self, from: Data(contentsOf: folder.appending(path: "details.json"))
            ) {
                legacy.apply(to: &manga)
            }
            if coverFile(series: manga.url) == nil {
                let chapterFiles = list?.compactMap { try? chapterURL($0.url) } ?? (try? chapterFiles(folder)) ?? []
                if let first = chapterFiles.first { try? makeCover(from: first, in: folder) }
            }
            manga.thumbnailURL = coverFile(series: manga.url) == nil ? nil : "cover"
            manga.initialized = true
        }
        return (manga, list)
    }

    private func chapterList(manga: SManga, folder: URL) throws -> [SChapter] {
        try chapterFiles(folder).map { file in
            let isFolder = isDirectory(file)
            var chapter = SChapter(
                url: "\(manga.url)/\(file.lastPathComponent)",
                name: isFolder ? file.lastPathComponent : file.deletingPathExtension().lastPathComponent,
                dateUpload: modified(file)
            )
            if let info = comicInfo(chapter: file) {
                if let title = info["Title"], !title.isBlank { chapter.name = title }
                if let number = info["Number"].flatMap(Double.init) { chapter.number = number }
                if let translator = info["Translator"], !translator.isBlank { chapter.scanlator = translator }
                if let year = info["Year"].flatMap(Int.init), year > 0 {
                    let month = info["Month"].flatMap(Int.init).map { min(max($0, 1), 12) } ?? 1
                    let day = info["Day"].flatMap(Int.init).map { min(max($0, 1), 31) } ?? 1
                    chapter.dateUpload = Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
                }
            }
            if chapter.number < 0 {
                chapter.number = ChapterNumber.parse(seriesTitle: manga.title, chapterName: chapter.name)
            }
            return chapter
        }
    }

    /// A series folder's chapters in reading order.
    private func chapterFiles(_ folder: URL) throws -> [URL] {
        contents(folder)
            .filter { isDirectory($0) || Self.isChapterFile($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Pages

    func pages(_ chapter: SChapter) async throws -> [SourcePage] {
        let file = try chapterURL(chapter.url)
        let urls: [URL]
        if isDirectory(file) {
            urls = imageFiles(in: file)
        } else {
            let destination = try unpackDirectory(for: file)
            let ready = destination.appending(path: ".complete")
            if !FileManager.default.fileExists(atPath: ready.path) {
                if file.pathExtension.lowercased() == "pdf" {
                    try await Task.detached(priority: .userInitiated) { try Self.renderPDF(file, into: destination) }.value
                } else {
                    try await Task.detached(priority: .userInitiated) { try Self.unpack(file, into: destination) }.value
                }
                FileManager.default.createFile(atPath: ready.path, contents: nil)
            }
            urls = imageFiles(in: destination)
        }
        guard !urls.isEmpty else { throw SourceError.noPages }
        return urls.enumerated().map { SourcePage(index: $0.offset, imageURL: $0.element) }
    }

    func coverRequest(_ manga: SManga) -> URLRequest? {
        coverFile(series: manga.url).map { URLRequest(url: $0) }
    }

    /// Where a chapter's pages are unpacked: named by the file and when it last changed, so a
    /// replaced file is unpacked afresh.
    private func unpackDirectory(for file: URL) throws -> URL {
        let key = "\(file.path)|\(modified(file).timeIntervalSince1970)"
        // FNV-1a: stable across launches, unlike hashValue.
        let stable = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let directory = cache.appending(path: String(stable, radix: 36), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func unpack(_ file: URL, into directory: URL) throws {
        try ComicArchive(url: file).unpackPages(into: directory)
    }

    /// Draws each PDF page as a JPEG about 1600 pixels across, about what a tablet shows.
    private static func renderPDF(_ file: URL, into directory: URL) throws {
        guard let document = CGPDFDocument(file as CFURL), document.numberOfPages > 0 else { throw SourceError.noPages }
        for number in 1...document.numberOfPages {
            try autoreleasepool {
                guard let page = document.page(at: number) else { return }
                let box = page.getBoxRect(.cropBox)
                let scale = min(4, max(1, 1600 / max(box.width, 1)))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let size = CGSize(width: (box.width * scale).rounded(), height: (box.height * scale).rounded())
                let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                    UIColor.white.setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                    let cg = context.cgContext
                    cg.translateBy(x: 0, y: size.height)
                    cg.scaleBy(x: scale, y: -scale)
                    cg.translateBy(x: -box.minX, y: -box.minY)
                    cg.drawPDFPage(page)
                }
                guard let data = image.jpegData(compressionQuality: 0.9) else { return }
                try data.write(to: directory.appending(path: String(format: "%04d.jpg", number - 1)))
            }
        }
    }

    // MARK: Covers and metadata

    func coverFile(series: String) -> URL? {
        let folder = root.appending(path: series, directoryHint: .isDirectory)
        return ["cover.jpg", "cover.jpeg", "cover.png", "cover.webp"]
            .map { folder.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Android's `updateCover`: the first image of a chapter becomes the series' cover.
    private func makeCover(from chapter: URL, in folder: URL) throws {
        let data: Data
        if isDirectory(chapter) {
            guard let first = imageFiles(in: chapter).first else { return }
            data = try Data(contentsOf: first)
        } else if chapter.pathExtension.lowercased() == "pdf" {
            guard let document = CGPDFDocument(chapter as CFURL), let page = document.page(at: 1) else { return }
            let box = page.getBoxRect(.cropBox)
            let scale = 600 / max(box.width, 1)
            let size = CGSize(width: box.width * scale, height: box.height * scale)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.scaleBy(x: scale, y: -scale)
                context.cgContext.translateBy(x: -box.minX, y: -box.minY)
                context.cgContext.drawPDFPage(page)
            }
            guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
            data = jpeg
        } else {
            guard let first = try ComicArchive(url: chapter).firstPage() else { return }
            data = first
        }
        // Android always names it cover.jpg, whatever the image's format.
        try data.write(to: folder.appending(path: "cover.jpg"))
    }

    private func comicInfo(series folder: URL) -> ComicInfo? {
        let file = folder.appending(path: ComicInfo.fileName)
        if let data = try? Data(contentsOf: file) { return ComicInfo(data: data) }
        // As Android: copy one out of the first chapter that has it, so later reads are quick.
        let noXML = folder.appending(path: ".noxml")
        guard !FileManager.default.fileExists(atPath: noXML.path) else { return nil }
        for chapter in (try? chapterFiles(folder)) ?? [] {
            if let data = comicInfoData(chapter: chapter) {
                try? data.write(to: file)
                return ComicInfo(data: data)
            }
        }
        FileManager.default.createFile(atPath: noXML.path, contents: nil)
        return nil
    }

    private func comicInfo(chapter: URL) -> ComicInfo? {
        comicInfoData(chapter: chapter).flatMap(ComicInfo.init(data:))
    }

    private func comicInfoData(chapter: URL) -> Data? {
        if isDirectory(chapter) {
            return try? Data(contentsOf: chapter.appending(path: ComicInfo.fileName))
        }
        guard ComicArchive.isArchive(chapter), chapter.pathExtension.lowercased() != "epub" else { return nil }
        return try? ComicArchive(url: chapter).data(named: ComicInfo.fileName)
    }

    // MARK: Files

    private func seriesFolder(_ name: String) throws -> URL {
        let folder = root.appending(path: name, directoryHint: .isDirectory)
        guard !name.contains("/"), isDirectory(folder) else { throw LocalError.missing }
        return folder
    }

    private func chapterURL(_ url: String) throws -> URL {
        let parts = url.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts.contains("..") else { throw LocalError.missing }
        let file = root.appending(path: parts[0], directoryHint: .isDirectory).appending(path: parts[1])
        guard FileManager.default.fileExists(atPath: file.path) else { throw LocalError.missing }
        return file
    }

    private func contents(_ directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    private func imageFiles(in directory: URL) -> [URL] {
        contents(directory)
            .filter { !isDirectory($0) && Self.isImage($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    static func isImage(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func isChapterFile(_ url: URL) -> Bool {
        chapterExtensions.contains(url.pathExtension.lowercased())
    }

    enum LocalError: LocalizedError {
        case missing
        case nothingToAdd

        var errorDescription: String? {
            switch self {
            case .missing: String(localized: "The file isn't in the local folder any more")
            case .nothingToAdd: String(localized: "No comics found to add")
            }
        }
    }

    // MARK: Adding

    /// The names of the series folders, for picking where to add files.
    func seriesNames() -> [String] {
        ((try? seriesFolders()) ?? [])
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Copies comics picked in the Files app into the local folder: a file or a folder of images
    /// becomes a chapter of `series`; a folder of chapters becomes a series of its own. Returns
    /// the series folders added to.
    @discardableResult
    func add(_ urls: [URL], series: String?) throws -> [String] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var added: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let target: String
            if isDirectory(url) {
                let items = contents(url)
                if items.contains(where: { isDirectory($0) || Self.isChapterFile($0) }) {
                    target = Self.folderName(url.lastPathComponent)
                    try copy(url, to: root.appending(path: target, directoryHint: .isDirectory))
                } else if items.contains(where: { Self.isImage($0.lastPathComponent) }) {
                    target = series.map(Self.folderName) ?? Self.folderName(url.lastPathComponent)
                    try copy(url, toSeries: target)
                } else {
                    continue
                }
            } else {
                let ext = url.pathExtension.lowercased()
                guard Self.chapterExtensions.contains(ext) else { continue }
                target = series.map(Self.folderName) ?? Self.folderName(url.deletingPathExtension().lastPathComponent)
                try copy(url, toSeries: target)
            }
            if !added.contains(target) { added.append(target) }
        }
        guard !added.isEmpty else { throw LocalError.nothingToAdd }
        return added
    }

    /// A file's or folder's name made safe as a series folder.
    static func folderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "Untitled" : cleaned
    }

    private func copy(_ item: URL, toSeries series: String) throws {
        let folder = root.appending(path: series, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try copy(item, to: folder.appending(path: item.lastPathComponent))
    }

    private func copy(_ item: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: item, to: destination)
    }

    private func move(_ file: URL, toSeries series: String) throws {
        let folder = root.appending(path: Self.folderName(series), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: file.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.moveItem(at: file, to: destination)
    }
}

/// The parts of ComicInfo.xml Mihon reads (Android's `copyFromComicInfo`).
struct ComicInfo {
    static let fileName = "ComicInfo.xml"

    private let values: [String: String]

    init?(data: Data) {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse(), !collector.values.isEmpty else { return nil }
        values = collector.values
    }

    subscript(_ key: String) -> String? {
        values[key]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    func apply(to manga: inout SManga) {
        if let series = self["Series"] { manga.title = series }
        if let summary = self["Summary"] { manga.description = summary }
        if let writer = self["Writer"] { manga.author = writer }
        let artists = [self["Penciller"], self["Inker"], self["Colorist"], self["Letterer"], self["CoverArtist"]].compactMap { $0 }
        var names: [String] = []
        for name in artists.flatMap({ $0.split(separator: ",") }).map({ $0.trimmingCharacters(in: .whitespaces) }) where !names.contains(name) {
            names.append(name)
        }
        if !names.isEmpty { manga.artist = names.joined(separator: ", ") }
        let genres = [self["Genre"], self["Tags"]].compactMap { $0 }
        if !genres.isEmpty { manga.genre = genres.joined(separator: ", ") }
        switch self["PublishingStatusTachiyomi"] {
        case "Ongoing": manga.status = .ongoing
        case "Completed": manga.status = .completed
        case "Licensed": manga.status = .licensed
        case "Publishing finished": manga.status = .publishingFinished
        case "Cancelled": manga.status = .cancelled
        case "On hiatus": manga.status = .onHiatus
        default: break
        }
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        private var text = ""
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            depth += 1
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            // Fields are the children of <ComicInfo>.
            if depth == 2, values[name] == nil { values[name] = text }
            depth -= 1
            text = ""
        }
    }
}

/// Android's old `details.json` in a series folder.
private struct LegacyDetails: Decodable {
    var title: String?
    var author: String?
    var artist: String?
    var description: String?
    var genre: [String]?
    var status: Int?

    func apply(to manga: inout SManga) {
        if let title { manga.title = title }
        if let author { manga.author = author }
        if let artist { manga.artist = artist }
        if let description { manga.description = description }
        if let genre { manga.genre = genre.joined(separator: ", ") }
        if let status { manga.status = MangaStatus(rawValue: status) ?? .unknown }
    }
}

/// A short form of Android's `ChapterRecognition.parseChapterNumber`: the number after "ch.",
/// else the first number left once the series title, versions and volumes are taken out.
enum ChapterNumber {
    static func parse(seriesTitle: String, chapterName: String) -> Double {
        var name = chapterName.lowercased().replacingOccurrences(of: seriesTitle.lowercased(), with: "")
        name = name.replacing(#/\b(?:ver|version)[^a-z]?[0-9]+/#, with: "")
        name = name.replacing(#/\s(?=extra|special|omake)/#, with: "")
        if let match = name.firstMatch(of: #/(?:\b(?:ch|chap|chapter|ep|episode)\.? *|#)([0-9]+)(\.[0-9]+)?(\.?[a-z]+)?/#) {
            return value(String(match.1), match.2.map(String.init), match.3.map(String.init))
        }
        name = name.replacing(#/\b(?:(?:vol(?:ume)?|season)[^a-z0-9]? *|[vs]\.?)([0-9]+(?:\.[0-9]+)?)\b/#, with: "")
        guard let match = name.firstMatch(of: #/([0-9]+)(\.[0-9]+)?(\.?[a-z]+)?/#) else { return -1 }
        return value(String(match.1), match.2.map(String.init), match.3.map(String.init))
    }

    /// "10" + ".5" is 10.5; a letter as in "10a" adds tenths (a = .1), as Android does.
    private static func value(_ whole: String, _ decimal: String?, _ letter: String?) -> Double {
        let base = Double(whole + (decimal ?? "")) ?? -1
        guard decimal == nil, let letter = letter?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), letter.count == 1,
              let ascii = letter.unicodeScalars.first?.value, ascii >= 97, ascii < 106
        else { return base }
        return base + Double(ascii - 96) / 10
    }
}

private extension String {
    var nilIfBlank: String? { isBlank ? nil : self }
}
