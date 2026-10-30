import Foundation
import UniformTypeIdentifiers

/// Where downloaded pages live: `Application Support/Downloads/<seriesId>/<chapterId>/<000>.<ext>`,
/// excluded from iCloud backup. A chapter is written to `<chapterId>.partial` and renamed once
/// every page is there, so a half-finished download never looks complete.
struct DownloadStore: Sendable {
    let root: URL

    static func standard() -> DownloadStore {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return DownloadStore(root: support.appending(path: "Downloads", directoryHint: .isDirectory))
    }

    func seriesDirectory(_ seriesId: Int) -> URL {
        root.appending(path: String(seriesId), directoryHint: .isDirectory)
    }

    func chapterDirectory(seriesId: Int, chapterId: Int) -> URL {
        seriesDirectory(seriesId).appending(path: String(chapterId), directoryHint: .isDirectory)
    }

    func partialDirectory(seriesId: Int, chapterId: Int) -> URL {
        seriesDirectory(seriesId).appending(path: "\(chapterId).partial", directoryHint: .isDirectory)
    }

    /// Creates the root (excluded from backup) and the chapter's partial folder.
    func preparePartial(seriesId: Int, chapterId: Int) throws -> URL {
        let manager = FileManager.default
        if !manager.fileExists(atPath: root.path(percentEncoded: false)) {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var root = root
            try root.setResourceValues(values)
        }
        let partial = partialDirectory(seriesId: seriesId, chapterId: chapterId)
        try manager.createDirectory(at: partial, withIntermediateDirectories: true)
        return partial
    }

    /// Pages already in `directory`, by page index.
    func pages(in directory: URL) -> [Int: URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var pages: [Int: URL] = [:]
        for file in files {
            if let page = Int(file.deletingPathExtension().lastPathComponent) { pages[page] = file }
        }
        return pages
    }

    /// The downloaded chapter's pages in order; empty when it isn't (completely) downloaded.
    func pageFiles(seriesId: Int, chapterId: Int) -> [URL] {
        let pages = pages(in: chapterDirectory(seriesId: seriesId, chapterId: chapterId))
        return pages.keys.sorted().compactMap { pages[$0] }
    }

    /// Moves a fetched page into the partial folder as `<000>.<ext>`.
    func storePage(_ file: URL, page: Int, mimeType: String?, in partial: URL) throws {
        let name = String(format: "%03d", page) + "." + Self.fileExtension(mimeType: mimeType)
        let target = partial.appending(path: name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
    }

    /// The partial folder becomes the chapter's folder.
    func complete(seriesId: Int, chapterId: Int) throws {
        let target = chapterDirectory(seriesId: seriesId, chapterId: chapterId)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partialDirectory(seriesId: seriesId, chapterId: chapterId), to: target)
    }

    /// Removes a chapter's pages, finished or not.
    func delete(seriesId: Int, chapterId: Int) {
        try? FileManager.default.removeItem(at: chapterDirectory(seriesId: seriesId, chapterId: chapterId))
        try? FileManager.default.removeItem(at: partialDirectory(seriesId: seriesId, chapterId: chapterId))
        let series = seriesDirectory(seriesId)
        if (try? FileManager.default.contentsOfDirectory(atPath: series.path(percentEncoded: false)))?.isEmpty == true {
            try? FileManager.default.removeItem(at: series)
        }
    }

    /// Bytes used by a series' downloads.
    func size(seriesId: Int) -> Int64 {
        let enumerator = FileManager.default.enumerator(at: seriesDirectory(seriesId), includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Kavita serves webp, avif, png, jpeg or gif; the extension follows the response's type.
    static func fileExtension(mimeType: String?) -> String {
        guard let mimeType = mimeType?.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
              let type = UTType(mimeType: mimeType), type.conforms(to: .image),
              let ext = type.preferredFilenameExtension
        else { return "jpg" }
        return ext == "jpeg" ? "jpg" : ext
    }
}
