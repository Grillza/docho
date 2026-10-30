import Compression
import Foundation

/// Reads a ZIP (CBZ) file: lists its entries from the central directory and extracts stored or
/// deflated ones, which is what comic archives use. Zip64 and encryption aren't supported.
struct ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int

        var isDirectory: Bool { name.hasSuffix("/") }
    }

    enum ZipError: LocalizedError {
        case unreadable
        case unsupported

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "The archive is damaged or isn't a ZIP file")
            case .unsupported: String(localized: "The archive uses a compression Dōchō can't read")
            }
        }
    }

    private let data: Data
    let entries: [Entry]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        entries = try Self.readDirectory(data)
    }

    /// The entry's bytes, inflated if they were deflated.
    func extract(_ entry: Entry) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data.uint32(at: header) == 0x0403_4B50 else { throw ZipError.unreadable }
        let start = header + 30 + Int(data.uint16(at: header + 26)) + Int(data.uint16(at: header + 28))
        guard start + entry.compressedSize <= data.count else { throw ZipError.unreadable }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        switch entry.method {
        case 0: return raw
        case 8: return try Self.inflate(raw, size: entry.size)
        default: throw ZipError.unsupported
        }
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name } ?? entries.first { ($0.name as NSString).lastPathComponent == name }
    }

    private static func readDirectory(_ data: Data) throws -> [Entry] {
        // The end of central directory record is in the last 64 KiB (its comment is at most 65535 bytes).
        guard data.count >= 22 else { throw ZipError.unreadable }
        var end = data.count - 22
        let floor = max(0, data.count - 22 - 0xFFFF)
        while end >= floor, data.uint32(at: end) != 0x0605_4B50 { end -= 1 }
        guard end >= floor else { throw ZipError.unreadable }
        let count = Int(data.uint16(at: end + 10))
        var offset = Int(data.uint32(at: end + 16))
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.uint32(at: offset) == 0x0201_4B50 else { throw ZipError.unreadable }
            let flags = data.uint16(at: offset + 8)
            let nameLength = Int(data.uint16(at: offset + 28))
            let extraLength = Int(data.uint16(at: offset + 30))
            let commentLength = Int(data.uint16(at: offset + 32))
            guard offset + 46 + nameLength <= data.count else { throw ZipError.unreadable }
            let nameBytes = data.subdata(in: (data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLength))
            // Bit 11 marks UTF-8 names; older tools wrote CP437, which is ASCII for ordinary names.
            let name = String(data: nameBytes, encoding: flags & 0x800 != 0 ? .utf8 : .isoLatin1)
                ?? String(decoding: nameBytes, as: UTF8.self)
            if flags & 0x1 == 0 {
                entries.append(Entry(
                    name: name, method: data.uint16(at: offset + 10),
                    compressedSize: Int(data.uint32(at: offset + 20)), size: Int(data.uint32(at: offset + 24)),
                    localHeaderOffset: Int(data.uint32(at: offset + 42))
                ))
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Raw DEFLATE, which is what Compression's ZLIB algorithm reads.
    private static func inflate(_ input: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { source in
                compression_decode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw ZipError.unreadable }
        return output
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }
}
