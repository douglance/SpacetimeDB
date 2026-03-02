import Foundation

/// Decodes `Codable` values from BSATN binary format.
///
/// Mirrors the BSATNEncoder format exactly:
/// - Products (structs): fields read sequentially
/// - Sum types (enums): u8 tag byte + variant payload
/// - Primitives: raw little-endian bytes
/// - Optional: tag 0 = Some(value), tag 1 = None
/// - Array: u32 count prefix + elements
/// - String: u32 length prefix + UTF-8 bytes
public final class BSATNDecoder: Sendable {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        var reader = BSATNReader(data: data)
        return try decode(type, from: &reader)
    }

    public func decode<T: Decodable>(_ type: T.Type, from reader: inout BSATNReader) throws -> T {
        // Special-case Data at top level
        if type == Data.self {
            let data = try reader.readBytes()
            return data as! T
        }
        let dec = _BSATNDecoderImpl(reader: reader)
        let result = try T(from: dec)
        reader = dec.reader
        return result
    }
}

// MARK: - Internal decoder implementation

final class _BSATNDecoderImpl: Decoder {
    var reader: BSATNReader
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    /// When set, the next keyed container decoding should use this tag
    /// to determine which enum case to decode.
    var enumTag: UInt8?

    init(reader: BSATNReader) {
        self.reader = reader
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        if let tag = enumTag {
            enumTag = nil
            return KeyedDecodingContainer(BSATNEnumKeyedDecodingContainer<Key>(decoder: self, tag: tag))
        }
        return KeyedDecodingContainer(BSATNKeyedDecodingContainer<Key>(decoder: self))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let count = try reader.readU32LE()
        return BSATNUnkeyedDecodingContainer(decoder: self, count: Int(count))
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        BSATNSingleValueDecodingContainer(decoder: self)
    }
}

// MARK: - Keyed decoding container (for structs/products)

struct BSATNKeyedDecodingContainer<K: CodingKey>: KeyedDecodingContainerProtocol {
    typealias Key = K
    let decoder: _BSATNDecoderImpl
    var codingPath: [any CodingKey] { decoder.codingPath }

    // BSATN products are sequential — all keys are always present.
    var allKeys: [K] { [] }

    func contains(_ key: K) -> Bool { true }

    func decodeNil(forKey key: K) throws -> Bool {
        // BSATN optionals: tag 0 = Some, tag 1 = None
        // Consume the tag byte. If Some (0), the caller reads the value next.
        let tag = try decoder.reader.readU8()
        return tag == 1
    }

    func decode(_ type: Bool.Type, forKey key: K) throws -> Bool {
        try decoder.reader.readBool()
    }

    func decode(_ type: String.Type, forKey key: K) throws -> String {
        try decoder.reader.readString()
    }

    func decode(_ type: Double.Type, forKey key: K) throws -> Double {
        try decoder.reader.readF64()
    }

    func decode(_ type: Float.Type, forKey key: K) throws -> Float {
        try decoder.reader.readF32()
    }

    func decode(_ type: Int.Type, forKey key: K) throws -> Int {
        Int(try decoder.reader.readI64LE())
    }

    func decode(_ type: Int8.Type, forKey key: K) throws -> Int8 {
        try decoder.reader.readI8()
    }

    func decode(_ type: Int16.Type, forKey key: K) throws -> Int16 {
        try decoder.reader.readI16LE()
    }

    func decode(_ type: Int32.Type, forKey key: K) throws -> Int32 {
        try decoder.reader.readI32LE()
    }

    func decode(_ type: Int64.Type, forKey key: K) throws -> Int64 {
        try decoder.reader.readI64LE()
    }

    func decode(_ type: UInt.Type, forKey key: K) throws -> UInt {
        UInt(try decoder.reader.readU64LE())
    }

    func decode(_ type: UInt8.Type, forKey key: K) throws -> UInt8 {
        try decoder.reader.readU8()
    }

    func decode(_ type: UInt16.Type, forKey key: K) throws -> UInt16 {
        try decoder.reader.readU16LE()
    }

    func decode(_ type: UInt32.Type, forKey key: K) throws -> UInt32 {
        try decoder.reader.readU32LE()
    }

    func decode(_ type: UInt64.Type, forKey key: K) throws -> UInt64 {
        try decoder.reader.readU64LE()
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: K) throws -> T {
        try decodeBSATNValue(type, from: decoder)
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: K) throws -> T? {
        let tag = try decoder.reader.readU8()
        if tag == 1 {
            return nil // None
        }
        // tag == 0: Some
        return try decodeBSATNValue(type, from: decoder)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: K
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try decoder.container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: K) throws -> any UnkeyedDecodingContainer {
        try decoder.unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder { decoder }
    func superDecoder(forKey key: K) throws -> any Decoder { decoder }
}

// MARK: - Enum keyed decoding container

/// For decoding enums: reads a u8 tag, then provides the corresponding case key.
struct BSATNEnumKeyedDecodingContainer<K: CodingKey>: KeyedDecodingContainerProtocol {
    typealias Key = K
    let decoder: _BSATNDecoderImpl
    let tag: UInt8
    var codingPath: [any CodingKey] { decoder.codingPath }

    var allKeys: [K] {
        if let key = K(intValue: Int(tag)) {
            return [key]
        }
        return []
    }

    func contains(_ key: K) -> Bool {
        key.intValue == Int(tag)
    }

    func decodeNil(forKey key: K) throws -> Bool { false }

    func decode(_ type: Bool.Type, forKey key: K) throws -> Bool {
        try decoder.reader.readBool()
    }

    func decode(_ type: String.Type, forKey key: K) throws -> String {
        try decoder.reader.readString()
    }

    func decode(_ type: Double.Type, forKey key: K) throws -> Double {
        try decoder.reader.readF64()
    }

    func decode(_ type: Float.Type, forKey key: K) throws -> Float {
        try decoder.reader.readF32()
    }

    func decode(_ type: Int.Type, forKey key: K) throws -> Int {
        Int(try decoder.reader.readI64LE())
    }

    func decode(_ type: Int8.Type, forKey key: K) throws -> Int8 {
        try decoder.reader.readI8()
    }

    func decode(_ type: Int16.Type, forKey key: K) throws -> Int16 {
        try decoder.reader.readI16LE()
    }

    func decode(_ type: Int32.Type, forKey key: K) throws -> Int32 {
        try decoder.reader.readI32LE()
    }

    func decode(_ type: Int64.Type, forKey key: K) throws -> Int64 {
        try decoder.reader.readI64LE()
    }

    func decode(_ type: UInt.Type, forKey key: K) throws -> UInt {
        UInt(try decoder.reader.readU64LE())
    }

    func decode(_ type: UInt8.Type, forKey key: K) throws -> UInt8 {
        try decoder.reader.readU8()
    }

    func decode(_ type: UInt16.Type, forKey key: K) throws -> UInt16 {
        try decoder.reader.readU16LE()
    }

    func decode(_ type: UInt32.Type, forKey key: K) throws -> UInt32 {
        try decoder.reader.readU32LE()
    }

    func decode(_ type: UInt64.Type, forKey key: K) throws -> UInt64 {
        try decoder.reader.readU64LE()
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: K) throws -> T {
        try decodeBSATNValue(type, from: decoder)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: K
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try decoder.container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: K) throws -> any UnkeyedDecodingContainer {
        try decoder.unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder { decoder }
    func superDecoder(forKey key: K) throws -> any Decoder { decoder }
}

// MARK: - Unkeyed decoding container (for arrays)

struct BSATNUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let decoder: _BSATNDecoderImpl
    let count: Int?
    var currentIndex: Int = 0
    var codingPath: [any CodingKey] { decoder.codingPath }
    var isAtEnd: Bool { currentIndex >= (count ?? 0) }

    init(decoder: _BSATNDecoderImpl, count: Int) {
        self.decoder = decoder
        self.count = count
    }

    mutating func decodeNil() throws -> Bool {
        let tag = try decoder.reader.readU8()
        if tag == 1 { currentIndex += 1; return true }
        decoder.reader.offset -= 1
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        defer { currentIndex += 1 }
        return try decoder.reader.readBool()
    }

    mutating func decode(_ type: String.Type) throws -> String {
        defer { currentIndex += 1 }
        return try decoder.reader.readString()
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        defer { currentIndex += 1 }
        return try decoder.reader.readF64()
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        defer { currentIndex += 1 }
        return try decoder.reader.readF32()
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        defer { currentIndex += 1 }
        return Int(try decoder.reader.readI64LE())
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        defer { currentIndex += 1 }
        return try decoder.reader.readI8()
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        defer { currentIndex += 1 }
        return try decoder.reader.readI16LE()
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        defer { currentIndex += 1 }
        return try decoder.reader.readI32LE()
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        defer { currentIndex += 1 }
        return try decoder.reader.readI64LE()
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        defer { currentIndex += 1 }
        return UInt(try decoder.reader.readU64LE())
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        defer { currentIndex += 1 }
        return try decoder.reader.readU8()
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        defer { currentIndex += 1 }
        return try decoder.reader.readU16LE()
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        defer { currentIndex += 1 }
        return try decoder.reader.readU32LE()
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        defer { currentIndex += 1 }
        return try decoder.reader.readU64LE()
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        defer { currentIndex += 1 }
        return try decodeBSATNValue(type, from: decoder)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try decoder.container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try decoder.unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder { decoder }
}

// MARK: - Single value decoding container

struct BSATNSingleValueDecodingContainer: SingleValueDecodingContainer {
    let decoder: _BSATNDecoderImpl
    var codingPath: [any CodingKey] { decoder.codingPath }

    func decodeNil() -> Bool {
        // Peek at tag
        guard decoder.reader.remaining >= 1 else { return true }
        let tag = decoder.reader.data[decoder.reader.data.startIndex + decoder.reader.offset]
        if tag == 1 {
            decoder.reader.offset += 1
            return true
        }
        return false
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try decoder.reader.readBool()
    }

    func decode(_ type: String.Type) throws -> String {
        try decoder.reader.readString()
    }

    func decode(_ type: Double.Type) throws -> Double {
        try decoder.reader.readF64()
    }

    func decode(_ type: Float.Type) throws -> Float {
        try decoder.reader.readF32()
    }

    func decode(_ type: Int.Type) throws -> Int {
        Int(try decoder.reader.readI64LE())
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        try decoder.reader.readI8()
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        try decoder.reader.readI16LE()
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        try decoder.reader.readI32LE()
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        try decoder.reader.readI64LE()
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        UInt(try decoder.reader.readU64LE())
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try decoder.reader.readU8()
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try decoder.reader.readU16LE()
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try decoder.reader.readU32LE()
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try decoder.reader.readU64LE()
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try decodeBSATNValue(type, from: decoder)
    }
}

// MARK: - Helper to decode any Decodable value

func decodeBSATNValue<T: Decodable>(_ type: T.Type, from decoder: _BSATNDecoderImpl) throws -> T {
    // Data → BSATN bytes (u32 len + raw bytes)
    if type == Data.self {
        let data = try decoder.reader.readBytes()
        return data as! T
    }

    // Default: let the type decode itself
    return try T(from: decoder)
}
