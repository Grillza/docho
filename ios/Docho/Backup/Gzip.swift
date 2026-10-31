import Foundation

/// Gzip, as Mihon's `.tachibk` files are written: one member around a raw DEFLATE stream, which
/// the Compression framework's zlib algorithm reads and writes.
enum Gzip {
    enum GzipError: Error {
        case notGzip
        case corrupt
    }

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 18 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
        out.append(deflated)
        append(crc32(data), to: &out)
        append(UInt32(truncatingIfNeeded: data.count), to: &out)
        return out
    }

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard isGzip(data), bytes[2] == 8 else { throw GzipError.notGzip }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { throw GzipError.corrupt }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { throw GzipError.corrupt }
        let deflated = Data(bytes[offset..<(bytes.count - 8)])
        guard let inflated = try? (deflated as NSData).decompressed(using: .zlib) as Data else { throw GzipError.corrupt }
        let trailer = Array(bytes.suffix(8))
        let crc = trailer[0..<4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard crc == crc32(inflated) else { throw GzipError.corrupt }
        return inflated
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}
