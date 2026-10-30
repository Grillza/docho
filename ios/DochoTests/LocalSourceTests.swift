import Compression
import UIKit
import XCTest
@testable import Docho

final class LocalSourceTests: XCTestCase {
    private var base: URL!
    private var source: LocalSource!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "local-\(UUID())", directoryHint: .isDirectory)
        source = LocalSource(
            root: base.appending(path: "Documents/local"), documents: base.appending(path: "Documents"),
            cache: base.appending(path: "Caches")
        )
        try FileManager.default.createDirectory(at: source.root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testReadsStoredAndDeflatedEntries() throws {
        let text = Data(String(repeating: "Dōchō ", count: 200).utf8)
        let data = Self.zip([("a.txt", text, false), ("dir/", Data(), false), ("b.txt", text, true)])
        let archive = try ZipArchive(data: data)
        XCTAssertEqual(archive.entries.map(\.name), ["a.txt", "dir/", "b.txt"])
        XCTAssertEqual(try archive.extract(archive.entries[0]), text)
        XCTAssertEqual(archive.entries[2].method, 8)
        XCTAssertLessThan(archive.entries[2].compressedSize, text.count)
        XCTAssertEqual(try archive.extract(archive.entries[2]), text)
        XCTAssertThrowsError(try ZipArchive(data: Data("not a zip at all, sorry".utf8)))
    }

    func testRecognisesChapterNumbers() {
        XCTAssertEqual(ChapterNumber.parse(seriesTitle: "Blame", chapterName: "Chapter 12"), 12)
        XCTAssertEqual(ChapterNumber.parse(seriesTitle: "Blame", chapterName: "Vol.2 Ch. 10.5"), 10.5)
        XCTAssertEqual(ChapterNumber.parse(seriesTitle: "Blame 2", chapterName: "Blame 2 - 003"), 3)
        XCTAssertEqual(ChapterNumber.parse(seriesTitle: "X", chapterName: "Volume 4"), -1)
        XCTAssertEqual(ChapterNumber.parse(seriesTitle: "X", chapterName: "ch 10a"), 10.1)
    }

    func testListsSeriesAndGivesLooseFilesAFolder() async throws {
        try FileManager.default.createDirectory(at: source.root.appending(path: "Alpha"), withIntermediateDirectories: true)
        try Self.zip([("1.png", Self.png(), false)]).write(to: source.root.appending(path: "Loose One.cbz"))
        try Self.zip([("1.png", Self.png(), false)]).write(to: source.documents.appending(path: "Dropped.cbz"))
        try Data().write(to: source.root.appending(path: "notes.txt"))

        let page = try await source.popular(page: 1)
        XCTAssertEqual(page.mangas.map(\.title), ["Alpha", "Dropped", "Loose One"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.root.appending(path: "Loose One/Loose One.cbz").path))
        let found = try await source.search(page: 1, query: "lo", filters: [])
        XCTAssertEqual(found.mangas.map(\.title), ["Loose One"])
        let latest = try await source.latest(page: 1)
        XCTAssertEqual(latest.mangas.count, 3, "all were just made")
    }

    func testReadsChaptersComicInfoAndCovers() async throws {
        let folder = source.root.appending(path: "Series")
        try FileManager.default.createDirectory(at: folder.appending(path: "Series 003 extra"), withIntermediateDirectories: true)
        let info = """
        <?xml version="1.0"?>
        <ComicInfo><Series>Proper Title</Series><Title>The Start</Title><Number>1</Number><Writer>Someone</Writer>
        <Penciller>Artist A</Penciller><Inker>Artist A</Inker><Genre>Action</Genre><Summary>About it.</Summary>
        <PublishingStatusTachiyomi>Completed</PublishingStatusTachiyomi><Year>2020</Year><Month>4</Month></ComicInfo>
        """
        try Self.zip([
            ("ComicInfo.xml", Data(info.utf8), true), ("__MACOSX/._10.png", Data("x".utf8), false),
            ("10.png", Self.png(.red), true), ("2.png", Self.png(.blue), false),
        ]).write(to: folder.appending(path: "Series 001.cbz"))
        try Self.pdf(pages: 2).write(to: folder.appending(path: "Series 002.pdf"))
        try Self.png().write(to: folder.appending(path: "Series 003 extra/01.png"))

        let manga = SManga(url: "Series", title: "Series")
        let (details, chapters) = try await source.update(manga, details: true, chapters: true)
        let list = try XCTUnwrap(chapters)
        XCTAssertEqual(list.map(\.name), ["The Start", "Series 002", "Series 003 extra"])
        XCTAssertEqual(list.map(\.number), [1, 2, 3])
        XCTAssertEqual(list[0].url, "Series/Series 001.cbz")
        XCTAssertNotNil(list[0].dateUpload.map { Calendar.current.component(.year, from: $0) == 2020 })

        XCTAssertEqual(details.title, "Proper Title")
        XCTAssertEqual(details.author, "Someone")
        XCTAssertEqual(details.artist, "Artist A")
        XCTAssertEqual(details.status, .completed)
        XCTAssertEqual(details.description, "About it.")
        XCTAssertTrue(details.initialized)
        XCTAssertNotNil(source.coverRequest(details), "the first chapter's first page became the cover")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "ComicInfo.xml").path), "copied out as Android does")

        let archivePages = try await source.pages(list[0])
        XCTAssertEqual(archivePages.count, 2, "__MACOSX entries are skipped")
        let first = try Data(contentsOf: archivePages[0].imageURL)
        XCTAssertEqual(first, Self.png(.blue), "2.png comes before 10.png")
        let again = try await source.pages(list[0])
        XCTAssertEqual(again.map(\.imageURL), archivePages.map(\.imageURL), "unpacked once")

        let pdfPages = try await source.pages(list[1])
        XCTAssertEqual(pdfPages.count, 2)
        let image = try XCTUnwrap(UIImage(contentsOfFile: pdfPages[0].imageURL.path))
        XCTAssertEqual(image.size.width, 1600, accuracy: 1)

        let folderPages = try await source.pages(list[2])
        XCTAssertEqual(folderPages.count, 1)
    }

    func testAddsPickedFiles() throws {
        let outside = base.appending(path: "Picked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside.appending(path: "Whole Series/Vol 1"), withIntermediateDirectories: true)
        try Self.png().write(to: outside.appending(path: "Whole Series/Vol 1/1.png"))
        try Self.zip([("1.png", Self.png(), false)]).write(to: outside.appending(path: "One Shot.cbz"))
        try Self.pdf(pages: 1).write(to: outside.appending(path: "Extra.pdf"))
        try Data().write(to: outside.appending(path: "Thing.cbr"))

        XCTAssertEqual(try source.add([outside.appending(path: "One Shot.cbz")], series: nil), ["One Shot"])
        XCTAssertEqual(try source.add([outside.appending(path: "Extra.pdf")], series: "One Shot"), ["One Shot"])
        XCTAssertEqual(try source.add([outside.appending(path: "Whole Series")], series: "One Shot"), ["Whole Series"], "a folder of chapters is its own series")
        XCTAssertEqual(source.seriesNames(), ["One Shot", "Whole Series"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.root.appending(path: "One Shot/Extra.pdf").path))
        XCTAssertEqual(try source.add([outside.appending(path: "Thing.cbr")], series: nil), ["Thing"])
        try Data().write(to: outside.appending(path: "notes.txt"))
        XCTAssertThrowsError(try source.add([outside.appending(path: "notes.txt")], series: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appending(path: "One Shot.cbz").path), "copied, not moved")
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil), "\(name) in the test bundle")
    }

    func testReadsRARAndRAR5WithTheSystemLibarchive() throws {
        // libarchive's own test archives: RAR 4 with a folder and a link, RAR 5 compressed.
        let rar4 = ComicArchive(url: try fixture("rar4.cbr"))
        XCTAssertEqual(try rar4.data(named: "test.txt"), Data("test text document\r\n".utf8))
        XCTAssertEqual(try rar4.data(named: "testdir/test.txt")?.count, 20)
        XCTAssertEqual(try rar4.imageNames(), [], "no pages, and the link and folders are skipped")
        let rar5 = try XCTUnwrap(ComicArchive(url: try fixture("rar5.cbr")).data(named: "test.bin"))
        XCTAssertEqual(rar5.count, 1200)
    }

    func testReadsA7ZipComicAsAChapter() async throws {
        let folder = source.root.appending(path: "Seven")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try fixture("Seven.cb7"), to: folder.appending(path: "Seven 01.cb7"))
        let (manga, chapters) = try await source.update(SManga(url: "Seven", title: "Seven"), details: true, chapters: true)
        let chapter = try XCTUnwrap(chapters?.first)
        XCTAssertEqual(chapter.name, "Packed", "ComicInfo.xml read from inside the 7-Zip")
        XCTAssertEqual(chapter.number, 3)
        XCTAssertEqual(manga.title, "Seven")
        XCTAssertNotNil(source.coverRequest(manga))
        let pages = try await source.pages(chapter)
        XCTAssertEqual(pages.map { $0.imageURL.lastPathComponent }, ["0000.jpg", "0001.jpg"])
        // 2.jpg comes first in reading order though it's second in the archive.
        let first = try XCTUnwrap(UIImage(contentsOfFile: pages[0].imageURL.path))
        XCTAssertGreaterThan(first.size.width, 0)
    }

    func testReadsAnEpubsImagesInSpineOrder() throws {
        let container = """
        <?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        let package = """
        <package><manifest>
        <item id="p1" href="text/one.xhtml" media-type="application/xhtml+xml"/>
        <item id="p2" href="text/two.xhtml" media-type="application/xhtml+xml"/>
        <item id="cover" href="images/z-cover.png" media-type="image/png"/>
        </manifest><spine><itemref idref="cover"/><itemref idref="p1"/><itemref idref="p2"/></spine></package>
        """
        let one = #"<html><body>&nbsp;<img src="../images/b%20page.png" alt="b"/></body></html>"#
        let two = #"<html><body><svg><image width="1" height="1" xlink:href="../images/a.png"/></svg></body></html>"#
        let data = Self.zip([
            ("mimetype", Data("application/epub+zip".utf8), false), ("META-INF/container.xml", Data(container.utf8), false),
            ("OEBPS/content.opf", Data(package.utf8), true), ("OEBPS/text/one.xhtml", Data(one.utf8), true),
            ("OEBPS/text/two.xhtml", Data(two.utf8), true), ("OEBPS/images/a.png", Self.png(.red), false),
            ("OEBPS/images/b page.png", Self.png(.blue), false), ("OEBPS/images/z-cover.png", Self.png(), false),
        ])
        let file = base.appending(path: "book.epub")
        try data.write(to: file)
        let archive = ComicArchive(url: file)
        XCTAssertEqual(try archive.imageNames(), ["OEBPS/images/z-cover.png", "OEBPS/images/b page.png", "OEBPS/images/a.png"])
        XCTAssertEqual(try archive.firstPage(), Self.png())
    }

    // MARK: Fixtures

    static func png(_ color: UIColor = .gray) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 6), format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
        }
    }

    static func pdf(pages: Int) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            for _ in 0..<pages { context.beginPage() }
        }
    }

    /// A ZIP with the given entries, deflated where asked (CRCs are left zero; the reader ignores them).
    static func zip(_ entries: [(name: String, data: Data, deflate: Bool)]) -> Data {
        var body = Data()
        var directory = Data()
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        for entry in entries {
            let stored = entry.deflate ? deflate(entry.data) : entry.data
            let method = entry.deflate ? 8 : 0
            let name = Data(entry.name.utf8)
            let offset = body.count
            body += le32(0x0403_4B50) + le16(20) + le16(0x800) + le16(method) + le32(0) + le32(0)
            body += le32(stored.count) + le32(entry.data.count) + le16(name.count) + le16(0) + name + stored
            directory += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0x800) + le16(method) + le32(0) + le32(0)
            directory += le32(stored.count) + le32(entry.data.count) + le16(name.count) + le16(0) + le16(0)
            directory += le16(0) + le16(0) + le32(0) + le32(offset) + name
        }
        let end = le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
            + le32(directory.count) + le32(body.count) + le16(0)
        return body + directory + end
    }

    private static func deflate(_ data: Data) -> Data {
        var output = Data(count: data.count + 1024)
        let size = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        return output.prefix(size)
    }
}
