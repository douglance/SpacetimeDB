import Foundation

/// Errors that can occur during BSATN deserialization.
public enum BSATNDecodeError: Error, Equatable, Sendable {
    case insufficientData(expected: Int, available: Int)
    case invalidBool(UInt8)
    case invalidUtf8
    case invalidTag(UInt8)
    case custom(String)
}

/// Low-level reader for BSATN binary data.
/// All multi-byte integers are read in little-endian byte order.
public struct BSATNReader: Sendable {
    public let data: Data
    public var offset: Int

    public init(data: Data) {
        self.data = data
        self.offset = 0
    }

    public var remaining: Int {
        data.count - offset
    }

    public var isAtEnd: Bool {
        offset >= data.count
    }

    // MARK: - Raw read

    @inline(__always)
    public mutating func readRawBytes(_ count: Int) throws -> Data {
        guard remaining >= count else {
            throw BSATNDecodeError.insufficientData(expected: count, available: remaining)
        }
        let start = data.startIndex + offset
        let result = data[start ..< start + count]
        offset += count
        return result
    }

    @inline(__always)
    mutating func readRawBytesArray(_ count: Int) throws -> [UInt8] {
        guard remaining >= count else {
            throw BSATNDecodeError.insufficientData(expected: count, available: remaining)
        }
        let start = data.startIndex + offset
        let result = [UInt8](data[start ..< start + count])
        offset += count
        return result
    }

    // MARK: - Unsigned integers

    @inline(__always)
    public mutating func readU8() throws -> UInt8 {
        guard remaining >= 1 else {
            throw BSATNDecodeError.insufficientData(expected: 1, available: remaining)
        }
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }

    @inline(__always)
    public mutating func readU16LE() throws -> UInt16 {
        let bytes = try readRawBytesArray(2)
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    @inline(__always)
    public mutating func readU32LE() throws -> UInt32 {
        let bytes = try readRawBytesArray(4)
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    @inline(__always)
    public mutating func readU64LE() throws -> UInt64 {
        let bytes = try readRawBytesArray(8)
        return UInt64(bytes[0])
            | (UInt64(bytes[1]) << 8)
            | (UInt64(bytes[2]) << 16)
            | (UInt64(bytes[3]) << 24)
            | (UInt64(bytes[4]) << 32)
            | (UInt64(bytes[5]) << 40)
            | (UInt64(bytes[6]) << 48)
            | (UInt64(bytes[7]) << 56)
    }

    // MARK: - Signed integers

    @inline(__always)
    public mutating func readI8() throws -> Int8 {
        Int8(bitPattern: try readU8())
    }

    @inline(__always)
    public mutating func readI16LE() throws -> Int16 {
        Int16(bitPattern: try readU16LE())
    }

    @inline(__always)
    public mutating func readI32LE() throws -> Int32 {
        Int32(bitPattern: try readU32LE())
    }

    @inline(__always)
    public mutating func readI64LE() throws -> Int64 {
        Int64(bitPattern: try readU64LE())
    }

    // MARK: - Floating point

    @inline(__always)
    public mutating func readF32() throws -> Float {
        Float(bitPattern: try readU32LE())
    }

    @inline(__always)
    public mutating func readF64() throws -> Double {
        Double(bitPattern: try readU64LE())
    }

    // MARK: - Bool

    @inline(__always)
    public mutating func readBool() throws -> Bool {
        let byte = try readU8()
        switch byte {
        case 0: return false
        case 1: return true
        default: throw BSATNDecodeError.invalidBool(byte)
        }
    }

    // MARK: - Length-prefixed data

    public mutating func readString() throws -> String {
        let len = try readU32LE()
        let bytes = try readRawBytes(Int(len))
        guard let str = String(data: bytes, encoding: .utf8) else {
            throw BSATNDecodeError.invalidUtf8
        }
        return str
    }

    public mutating func readBytes() throws -> Data {
        let len = try readU32LE()
        return try readRawBytes(Int(len))
    }
}
