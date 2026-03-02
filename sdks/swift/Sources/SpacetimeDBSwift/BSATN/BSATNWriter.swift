import Foundation

/// Low-level writer for BSATN binary data.
/// All multi-byte integers are written in little-endian byte order.
public struct BSATNWriter: Sendable {
    public var data: Data

    public init() {
        self.data = Data()
    }

    public init(capacity: Int) {
        self.data = Data()
        self.data.reserveCapacity(capacity)
    }

    // MARK: - Unsigned integers

    @inline(__always)
    public mutating func putU8(_ value: UInt8) {
        data.append(value)
    }

    @inline(__always)
    public mutating func putU16LE(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    @inline(__always)
    public mutating func putU32LE(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    @inline(__always)
    public mutating func putU64LE(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    @inline(__always)
    public mutating func putU128LE(_ value: (UInt64, UInt64)) {
        putU64LE(value.0) // low
        putU64LE(value.1) // high
    }

    // MARK: - Signed integers

    @inline(__always)
    public mutating func putI8(_ value: Int8) {
        data.append(UInt8(bitPattern: value))
    }

    @inline(__always)
    public mutating func putI16LE(_ value: Int16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    @inline(__always)
    public mutating func putI32LE(_ value: Int32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    @inline(__always)
    public mutating func putI64LE(_ value: Int64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    // MARK: - Floating point (as bit patterns)

    @inline(__always)
    public mutating func putF32(_ value: Float) {
        putU32LE(value.bitPattern)
    }

    @inline(__always)
    public mutating func putF64(_ value: Double) {
        putU64LE(value.bitPattern)
    }

    // MARK: - Bool

    @inline(__always)
    public mutating func putBool(_ value: Bool) {
        putU8(value ? 1 : 0)
    }

    // MARK: - Length-prefixed data

    public mutating func putString(_ value: String) {
        let utf8 = Array(value.utf8)
        putU32LE(UInt32(utf8.count))
        data.append(contentsOf: utf8)
    }

    public mutating func putBytes(_ value: Data) {
        putU32LE(UInt32(value.count))
        data.append(value)
    }

    public mutating func putBytes(_ value: [UInt8]) {
        putU32LE(UInt32(value.count))
        data.append(contentsOf: value)
    }

    // MARK: - Raw slice

    @inline(__always)
    public mutating func putSlice(_ value: Data) {
        data.append(value)
    }

    @inline(__always)
    public mutating func putSlice(_ value: [UInt8]) {
        data.append(contentsOf: value)
    }
}
