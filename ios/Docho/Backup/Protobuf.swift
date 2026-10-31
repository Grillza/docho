import Foundation

/// Just enough Protocol Buffers for Mihon's backups, which kotlinx.serialization writes:
/// integers as plain varints (negative ones as ten bytes), floats as fixed32, strings, bytes and
/// messages length-delimited, repeated fields one entry per value. Fields left at their default
/// aren't written, as kotlinx leaves them out.
struct ProtoWriter {
    private(set) var data = Data()

    private mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    private mutating func tag(_ field: Int, _ wireType: UInt64) {
        varint(UInt64(field) << 3 | wireType)
    }

    mutating func int(_ field: Int, _ value: Int64, always: Bool = false) {
        guard value != 0 || always else { return }
        tag(field, 0)
        varint(UInt64(bitPattern: value))
    }

    mutating func int(_ field: Int, _ value: Int, always: Bool = false) {
        int(field, Int64(value), always: always)
    }

    mutating func bool(_ field: Int, _ value: Bool, default fallback: Bool = false) {
        guard value != fallback else { return }
        tag(field, 0)
        varint(value ? 1 : 0)
    }

    mutating func float(_ field: Int, _ value: Float, always: Bool = false) {
        guard value != 0 || always else { return }
        tag(field, 5)
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        tag(field, 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String?, always: Bool = false) {
        guard let value, !value.isEmpty || always else { return }
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }
}

enum ProtoError: Error {
    case truncated
    case badWireType
}

/// Reads a message's fields in order; repeated fields come back once per value.
struct ProtoReader {
    struct Field {
        let number: Int
        let wireType: Int
        /// A varint, or a fixed32/fixed64's bits.
        let integer: UInt64
        /// A length-delimited field's bytes.
        let bytes: Data

        var int64: Int64 { Int64(bitPattern: integer) }
        var int: Int { Int(truncatingIfNeeded: int64) }
        var bool: Bool { integer != 0 }
        var float: Float { wireType == 1 ? Float(Double(bitPattern: integer)) : Float(bitPattern: UInt32(truncatingIfNeeded: integer)) }
        var string: String { String(decoding: bytes, as: UTF8.self) }
        var message: ProtoReader { ProtoReader(bytes) }

        /// The values of a repeated integer field, packed or not.
        var packedInts: [Int64] {
            guard wireType == 2 else { return [int64] }
            var reader = ProtoReader(bytes)
            var values: [Int64] = []
            while let value = try? reader.readVarint() { values.append(Int64(bitPattern: value)) }
            return values
        }
    }

    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = Data(data)
        offset = self.data.startIndex
    }

    fileprivate mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < data.endIndex, shift < 64 else { throw ProtoError.truncated }
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else { throw ProtoError.truncated }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    /// The next field, or nil at the end of the message.
    mutating func next() throws -> Field? {
        guard offset < data.endIndex else { return nil }
        let key = try readVarint()
        let number = Int(key >> 3)
        let wireType = Int(key & 7)
        switch wireType {
        case 0:
            return Field(number: number, wireType: 0, integer: try readVarint(), bytes: Data())
        case 1:
            let bits = try read(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return Field(number: number, wireType: 1, integer: bits, bytes: Data())
        case 2:
            let length = try readVarint()
            guard length <= UInt64(Int.max) else { throw ProtoError.truncated }
            return Field(number: number, wireType: 2, integer: 0, bytes: try read(Int(length)))
        case 5:
            let bits = try read(4).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return Field(number: number, wireType: 5, integer: bits, bytes: Data())
        default:
            throw ProtoError.badWireType
        }
    }

    /// Every field, for messages read whole.
    func fields() throws -> [Field] {
        var reader = self
        var fields: [Field] = []
        while let field = try reader.next() { fields.append(field) }
        return fields
    }
}
