internal import CLibArchive
import Foundation

/// A chapter in one file: CBZ/ZIP, CBR/RAR (RAR 4 and 5), CB7/7Z, or an EPUB of images, as
/// Android's Local source reads them. ZIPs are read directly; RAR and 7-Zip through the
/// libarchive that comes with iOS. An EPUB's pages are its images in spine order.
struct ComicArchive {
    static let zipExtensions: Set<String> = ["cbz", "zip"]
    static let libarchiveExtensions: Set<String> = ["cbr", "rar", "cb7", "7z"]
    static let extensions = zipExtensions.union(libarchiveExtensions).union(["epub"])

    let url: URL
    private let ext: String

    init(url: URL) {
        self.url = url
        ext = url.pathExtension.lowercased()
    }

    static func isArchive(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// The page images' names, in reading order.
    func imageNames() throws -> [String] {
        switch ext {
        case "epub": return try EpubPages(ZipArchive(url: url)).imageNames()
        default: return Self.readingOrder(try entryNames().filter(Self.isPage))
        }
    }

    /// One entry's bytes, by its full name or (for ComicInfo.xml) its file name.
    func data(named name: String) throws -> Data? {
        if Self.libarchiveExtensions.contains(ext) {
            return try LibArchive.read(url) { entry in entry == name || (entry as NSString).lastPathComponent == name }.first?.value
        }
        let zip = try ZipArchive(url: url)
        return try zip.entry(named: name).map(zip.extract)
    }

    /// Writes the pages to `directory` as `0000.jpg`, `0001.png`… in reading order.
    func unpackPages(into directory: URL) throws {
        let names = try imageNames()
        let order = Dictionary(names.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        func file(_ name: String) -> URL {
            let ext = (name as NSString).pathExtension.lowercased()
            return directory.appending(path: String(format: "%04d.%@", order[name] ?? 0, ext))
        }
        if Self.libarchiveExtensions.contains(ext) {
            // One pass: a solid 7-Zip or RAR archive can only be read from the start.
            try LibArchive.forEach(url, where: { order[$0] != nil }) { name, data in
                try data.write(to: file(name))
            }
        } else {
            let zip = try ZipArchive(url: url)
            for entry in zip.entries where order[entry.name] != nil {
                try zip.extract(entry).write(to: file(entry.name))
            }
        }
    }

    /// The first page's bytes, for a cover.
    func firstPage() throws -> Data? {
        guard let first = try imageNames().first else { return nil }
        return try data(named: first)
    }

    private func entryNames() throws -> [String] {
        if Self.libarchiveExtensions.contains(ext) { return try LibArchive.names(url) }
        return try ZipArchive(url: url).entries.filter { !$0.isDirectory }.map(\.name)
    }

    /// An image that's a page: not hidden, and not macOS's resource-fork copies.
    static func isPage(_ name: String) -> Bool {
        LocalSource.isImage(name) && !(name as NSString).lastPathComponent.hasPrefix(".") && !name.hasPrefix("__MACOSX")
    }

    static func readingOrder(_ names: [String]) -> [String] {
        names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

// MARK: - EPUB

/// The images of an EPUB's pages in spine order (Android's `EpubReader.getImagesFromPages`):
/// container.xml names the package, whose spine lists the pages; each page's `<img src>` and SVG
/// `<image href>` are its images.
private struct EpubPages {
    let zip: ZipArchive

    init(_ zip: ZipArchive) {
        self.zip = zip
    }

    func imageNames() throws -> [String] {
        let names = Set(zip.entries.map(\.name))
        guard let container = text("META-INF/container.xml"),
              let packagePath = XMLAttributes.all(in: container, element: "rootfile").first?["full-path"],
              let package = text(packagePath)
        else { return ComicArchive.readingOrder(names.filter(ComicArchive.isPage)) }

        let base = (packagePath as NSString).deletingLastPathComponent
        var manifest: [String: String] = [:]
        for item in XMLAttributes.all(in: package, element: "item") {
            if let id = item["id"], let href = item["href"] { manifest[id] = Self.resolve(href, from: base) }
        }
        var images: [String] = []
        for itemref in XMLAttributes.all(in: package, element: "itemref") {
            guard let id = itemref["idref"], let page = manifest[id] else { continue }
            if ComicArchive.isPage(page) {
                images.append(page)
                continue
            }
            guard let html = text(page) else { continue }
            let folder = (page as NSString).deletingLastPathComponent
            for element in ["img", "image"] {
                for attributes in XMLAttributes.all(in: html, element: element) {
                    guard let source = attributes["src"] ?? attributes["xlink:href"] ?? attributes["href"] else { continue }
                    let image = Self.resolve(source, from: folder)
                    if names.contains(image), !images.contains(image) { images.append(image) }
                }
            }
        }
        return images.isEmpty ? ComicArchive.readingOrder(names.filter(ComicArchive.isPage)) : images
    }

    private func text(_ name: String) -> String? {
        guard let entry = zip.entry(named: name), let data = try? zip.extract(entry) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `href` relative to `folder`, with `..` and percent-escapes resolved, as a ZIP entry name.
    static func resolve(_ href: String, from folder: String) -> String {
        let path = (href.removingPercentEncoding ?? href).split(separator: "#").first.map(String.init) ?? href
        var parts = folder.isEmpty ? [] : folder.split(separator: "/").map(String.init)
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts.joined(separator: "/")
    }
}

/// The attributes of each `<element …>` tag in some XML or XHTML; enough for EPUB's few files
/// without a full parser, which XHTML pages often trip up with HTML entities.
enum XMLAttributes {
    static func all(in text: String, element: String) -> [[String: String]] {
        let tag = try? Regex("<(?:[A-Za-z]+:)?\(element)\\b([^>]*)>").ignoresCase()
        let attribute = #/([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/#
        guard let tag else { return [] }
        return text.matches(of: tag).map { match in
            let body = match.output[1].substring.map(String.init) ?? ""
            var values: [String: String] = [:]
            for pair in body.matches(of: attribute) {
                values[String(pair.1)] = String(pair.2 ?? pair.3 ?? "")
            }
            return values
        }
    }
}

// MARK: - libarchive

private enum LibArchive {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Opens the archive for one pass over its entries.
    private static func open(_ url: URL) throws -> OpaquePointer {
        guard let archive = archive_read_new() else { throw Failure(message: "libarchive") }
        archive_read_support_filter_all(archive)
        archive_read_support_format_rar(archive)
        archive_read_support_format_rar5(archive)
        archive_read_support_format_7zip(archive)
        // A CBR is sometimes really a ZIP, or a tar, renamed.
        archive_read_support_format_zip(archive)
        archive_read_support_format_tar(archive)
        guard archive_read_open_filename(archive, url.path, 64 * 1024) == ARCHIVE_OK else {
            let message = String(cString: archive_error_string(archive))
            archive_read_free(archive)
            throw Failure(message: String(localized: "Couldn't open the archive: \(message)"))
        }
        return archive
    }

    /// Each file entry's name, read in order; `body` decides whether to read its data.
    private static func walk(_ url: URL, _ body: (OpaquePointer, String) throws -> Bool) throws {
        let archive = try open(url)
        defer { archive_read_free(archive) }
        var entry: OpaquePointer?
        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF { return }
            guard status >= ARCHIVE_WARN, let entry else {
                throw Failure(message: String(cString: archive_error_string(archive)))
            }
            let raw = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)
            guard let raw, archive_entry_filetype(entry) & AE_IFMT == AE_IFREG else {
                archive_read_data_skip(archive)
                continue
            }
            if try !body(archive, String(cString: raw)) {
                archive_read_data_skip(archive)
            }
        }
    }

    private static func readData(_ archive: OpaquePointer) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { archive_read_data(archive, $0.baseAddress, $0.count) }
            if count == 0 { return data }
            guard count > 0 else { throw Failure(message: String(cString: archive_error_string(archive))) }
            data.append(buffer, count: count)
        }
    }

    static func names(_ url: URL) throws -> [String] {
        var names: [String] = []
        try walk(url) { _, name in
            names.append(name)
            return false
        }
        return names
    }

    static func read(_ url: URL, where wanted: (String) -> Bool) throws -> [String: Data] {
        var found: [String: Data] = [:]
        try walk(url) { archive, name in
            guard wanted(name) else { return false }
            found[name] = try readData(archive)
            return true
        }
        return found
    }

    static func forEach(_ url: URL, where wanted: (String) -> Bool, _ body: (String, Data) throws -> Void) throws {
        try walk(url) { archive, name in
            guard wanted(name) else { return false }
            try body(name, try readData(archive))
            return true
        }
    }
}
