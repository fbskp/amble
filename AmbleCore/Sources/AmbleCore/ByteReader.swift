import Foundation

/// Little-endian cursor over a byte buffer. Every read returns nil when the buffer is too short.
struct ByteReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - index }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { index += 2 }
        return UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    mutating func i16() -> Int16? { u16().map { Int16(bitPattern: $0) } }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { index += 4 }
        return UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }

    mutating func u24() -> UInt32? {
        guard remaining >= 3 else { return nil }
        defer { index += 3 }
        return UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16
    }
}
