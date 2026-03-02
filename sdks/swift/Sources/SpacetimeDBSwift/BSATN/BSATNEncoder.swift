import Foundation

/// Encodes `Codable` values into the BSATN binary format.
///
/// BSATN format:
/// - Products (structs): fields serialized sequentially by declaration order, no framing
/// - Sum types (enums): u8 tag byte + variant payload
/// - Primitives: raw little-endian bytes
/// - Bool: u8 (0=false, 1=true)
/// - Float: u32 bit pattern LE, Double: u64 bit pattern LE
/// - String: u32 length prefix + UTF-8 bytes
/// - Data/bytes: u32 length prefix + raw bytes
/// - Array: u32 count prefix + elements
/// - Optional: tag 0 = Some(value), tag 1 = None
public final class BSATNEncoder: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        // Special-case Data at top level
        if let data = value as? Data {
            var writer = BSATNWriter()
            writer.putBytes(data)
            return writer.data
        }
        let enc = _BSATNEncoderImpl()
        try value.encode(to: enc)
        return enc.writer.data
    }
}

// MARK: - Internal encoder implementation

final class _BSATNEncoderImpl: Encoder {
    var writer: BSATNWriter
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    /// When true, the next keyed container is for an enum variant (write u8 tag).
    var isEnumContext: Bool = false

    init(writer: BSATNWriter = BSATNWriter()) {
        self.writer = writer
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if isEnumContext {
            isEnumContext = false
            return KeyedEncodingContainer(BSATNEnumKeyedContainer<Key>(encoder: self))
        }
        return KeyedEncodingContainer(BSATNKeyedEncodingContainer<Key>(encoder: self))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        BSATNUnkeyedEncodingContainer(encoder: self)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        BSATNSingleValueEncodingContainer(encoder: self)
    }
}

// MARK: - Helper to write BSATN optional tag + value

/// Writes tag 0 (Some) + value, or tag 1 (None).
private func encodeBSATNOptional<T: Encodable>(_ value: T?, to encoder: _BSATNEncoderImpl) throws {
    if let value = value {
        encoder.writer.putU8(0)
        try encodeBSATNValue(value, to: encoder)
    } else {
        encoder.writer.putU8(1)
    }
}

// MARK: - Keyed encoding container (for structs/products)

/// Encodes struct fields sequentially. Keys are ignored in the wire format —
/// fields are written in the order `encode(to:)` calls them, which for
/// compiler-synthesized `Codable` matches declaration / CodingKeys order.
struct BSATNKeyedEncodingContainer<K: CodingKey>: KeyedEncodingContainerProtocol {
    typealias Key = K
    let encoder: _BSATNEncoderImpl
    var codingPath: [any CodingKey] { encoder.codingPath }

    mutating func encodeNil(forKey key: K) throws {
        encoder.writer.putU8(1)
    }

    mutating func encode(_ value: Bool, forKey key: K) throws {
        encoder.writer.putBool(value)
    }

    mutating func encode(_ value: String, forKey key: K) throws {
        encoder.writer.putString(value)
    }

    mutating func encode(_ value: Double, forKey key: K) throws {
        encoder.writer.putF64(value)
    }

    mutating func encode(_ value: Float, forKey key: K) throws {
        encoder.writer.putF32(value)
    }

    mutating func encode(_ value: Int, forKey key: K) throws {
        encoder.writer.putI64LE(Int64(value))
    }

    mutating func encode(_ value: Int8, forKey key: K) throws {
        encoder.writer.putI8(value)
    }

    mutating func encode(_ value: Int16, forKey key: K) throws {
        encoder.writer.putI16LE(value)
    }

    mutating func encode(_ value: Int32, forKey key: K) throws {
        encoder.writer.putI32LE(value)
    }

    mutating func encode(_ value: Int64, forKey key: K) throws {
        encoder.writer.putI64LE(value)
    }

    mutating func encode(_ value: UInt, forKey key: K) throws {
        encoder.writer.putU64LE(UInt64(value))
    }

    mutating func encode(_ value: UInt8, forKey key: K) throws {
        encoder.writer.putU8(value)
    }

    mutating func encode(_ value: UInt16, forKey key: K) throws {
        encoder.writer.putU16LE(value)
    }

    mutating func encode(_ value: UInt32, forKey key: K) throws {
        encoder.writer.putU32LE(value)
    }

    mutating func encode(_ value: UInt64, forKey key: K) throws {
        encoder.writer.putU64LE(value)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: K) throws {
        try encodeBSATNValue(value, to: encoder)
    }

    // MARK: - Optional encoding overrides (BSATN: tag 0 = Some, tag 1 = None)
    // Swift's default `encodeIfPresent` for each primitive type simply omits nil values.
    // BSATN requires explicit None tags, so we override every primitive overload.

    mutating func encodeIfPresent(_ value: Bool?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent(_ value: String?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent(_ value: Double?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent(_ value: Float?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent(_ value: Int?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent(_ value: Int8?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent(_ value: Int16?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent(_ value: Int32?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent(_ value: Int64?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent(_ value: UInt?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent(_ value: UInt8?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent(_ value: UInt16?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent(_ value: UInt32?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent(_ value: UInt64?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: K) throws {
        try encodeBSATNOptional(value, to: encoder)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: K
    ) -> KeyedEncodingContainer<NestedKey> {
        encoder.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: K) -> any UnkeyedEncodingContainer {
        encoder.unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        encoder
    }

    mutating func superEncoder(forKey key: K) -> any Encoder {
        encoder
    }
}

// MARK: - Enum keyed container (for sum types)

struct BSATNEnumKeyedContainer<K: CodingKey>: KeyedEncodingContainerProtocol {
    typealias Key = K
    let encoder: _BSATNEncoderImpl
    var codingPath: [any CodingKey] { encoder.codingPath }
    var tagWritten = false

    mutating func writeTag(for key: K) {
        guard !tagWritten else { return }
        tagWritten = true
        if let intVal = key.intValue {
            encoder.writer.putU8(UInt8(intVal))
        }
    }

    mutating func encodeNil(forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putU8(1)
    }

    mutating func encode(_ value: Bool, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putBool(value)
    }

    mutating func encode(_ value: String, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putString(value)
    }

    mutating func encode(_ value: Double, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putF64(value)
    }

    mutating func encode(_ value: Float, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putF32(value)
    }

    mutating func encode(_ value: Int, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putI64LE(Int64(value))
    }

    mutating func encode(_ value: Int8, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putI8(value)
    }

    mutating func encode(_ value: Int16, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putI16LE(value)
    }

    mutating func encode(_ value: Int32, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putI32LE(value)
    }

    mutating func encode(_ value: Int64, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putI64LE(value)
    }

    mutating func encode(_ value: UInt, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putU64LE(UInt64(value))
    }

    mutating func encode(_ value: UInt8, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putU8(value)
    }

    mutating func encode(_ value: UInt16, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putU16LE(value)
    }

    mutating func encode(_ value: UInt32, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putU32LE(value)
    }

    mutating func encode(_ value: UInt64, forKey key: K) throws {
        writeTag(for: key)
        encoder.writer.putU64LE(value)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: K) throws {
        writeTag(for: key)
        try encodeBSATNValue(value, to: encoder)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: K
    ) -> KeyedEncodingContainer<NestedKey> {
        writeTag(for: key)
        return encoder.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: K) -> any UnkeyedEncodingContainer {
        writeTag(for: key)
        return encoder.unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder { encoder }
    mutating func superEncoder(forKey key: K) -> any Encoder { encoder }
}

// MARK: - Unkeyed encoding container (for arrays)

struct BSATNUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let encoder: _BSATNEncoderImpl
    var codingPath: [any CodingKey] { encoder.codingPath }
    var count: Int = 0

    mutating func encodeNil() throws {
        encoder.writer.putU8(1)
        count += 1
    }

    mutating func encode(_ value: Bool) throws {
        encoder.writer.putBool(value)
        count += 1
    }

    mutating func encode(_ value: String) throws {
        encoder.writer.putString(value)
        count += 1
    }

    mutating func encode(_ value: Double) throws {
        encoder.writer.putF64(value)
        count += 1
    }

    mutating func encode(_ value: Float) throws {
        encoder.writer.putF32(value)
        count += 1
    }

    mutating func encode(_ value: Int) throws {
        encoder.writer.putI64LE(Int64(value))
        count += 1
    }

    mutating func encode(_ value: Int8) throws {
        encoder.writer.putI8(value)
        count += 1
    }

    mutating func encode(_ value: Int16) throws {
        encoder.writer.putI16LE(value)
        count += 1
    }

    mutating func encode(_ value: Int32) throws {
        encoder.writer.putI32LE(value)
        count += 1
    }

    mutating func encode(_ value: Int64) throws {
        encoder.writer.putI64LE(value)
        count += 1
    }

    mutating func encode(_ value: UInt) throws {
        encoder.writer.putU64LE(UInt64(value))
        count += 1
    }

    mutating func encode(_ value: UInt8) throws {
        encoder.writer.putU8(value)
        count += 1
    }

    mutating func encode(_ value: UInt16) throws {
        encoder.writer.putU16LE(value)
        count += 1
    }

    mutating func encode(_ value: UInt32) throws {
        encoder.writer.putU32LE(value)
        count += 1
    }

    mutating func encode(_ value: UInt64) throws {
        encoder.writer.putU64LE(value)
        count += 1
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try encodeBSATNValue(value, to: encoder)
        count += 1
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        encoder.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        encoder.unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder { encoder }
}

// MARK: - Single value encoding container (for primitives)

struct BSATNSingleValueEncodingContainer: SingleValueEncodingContainer {
    let encoder: _BSATNEncoderImpl
    var codingPath: [any CodingKey] { encoder.codingPath }

    mutating func encodeNil() throws {
        encoder.writer.putU8(1)
    }

    mutating func encode(_ value: Bool) throws {
        encoder.writer.putBool(value)
    }

    mutating func encode(_ value: String) throws {
        encoder.writer.putString(value)
    }

    mutating func encode(_ value: Double) throws {
        encoder.writer.putF64(value)
    }

    mutating func encode(_ value: Float) throws {
        encoder.writer.putF32(value)
    }

    mutating func encode(_ value: Int) throws {
        encoder.writer.putI64LE(Int64(value))
    }

    mutating func encode(_ value: Int8) throws {
        encoder.writer.putI8(value)
    }

    mutating func encode(_ value: Int16) throws {
        encoder.writer.putI16LE(value)
    }

    mutating func encode(_ value: Int32) throws {
        encoder.writer.putI32LE(value)
    }

    mutating func encode(_ value: Int64) throws {
        encoder.writer.putI64LE(value)
    }

    mutating func encode(_ value: UInt) throws {
        encoder.writer.putU64LE(UInt64(value))
    }

    mutating func encode(_ value: UInt8) throws {
        encoder.writer.putU8(value)
    }

    mutating func encode(_ value: UInt16) throws {
        encoder.writer.putU16LE(value)
    }

    mutating func encode(_ value: UInt32) throws {
        encoder.writer.putU32LE(value)
    }

    mutating func encode(_ value: UInt64) throws {
        encoder.writer.putU64LE(value)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try encodeBSATNValue(value, to: encoder)
    }
}

// MARK: - Helper to encode any Encodable value

/// Routes encoding of `Encodable` values, handling special types that need
/// custom BSATN encoding (Data, Array, Optional) before falling back
/// to the default `value.encode(to:)`.
func encodeBSATNValue<T: Encodable>(_ value: T, to encoder: _BSATNEncoderImpl) throws {
    // Data → BSATN bytes (u32 len + raw bytes)
    if let data = value as? Data {
        encoder.writer.putBytes(data)
        return
    }

    // Array<Encodable> — we need the count prefix
    if let array = value as? [any Encodable] {
        encoder.writer.putU32LE(UInt32(array.count))
        for element in array {
            try encodeBSATNValue(element, to: encoder)
        }
        return
    }

    // Check: is this an Optional?
    if isOptionalNil(value) {
        encoder.writer.putU8(1) // tag 1 = None
        return
    }

    if let (wrapped, _) = unwrapOptional(value) {
        encoder.writer.putU8(0) // tag 0 = Some
        try encodeBSATNValue(wrapped, to: encoder)
        return
    }

    // Default: let the value encode itself
    try value.encode(to: encoder)
}

// MARK: - Optional helpers

private func isOptionalNil(_ value: Any) -> Bool {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        return mirror.children.isEmpty
    }
    return false
}

private func unwrapOptional(_ value: Any) -> (any Encodable, Bool)? {
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .optional else { return nil }
    guard let child = mirror.children.first else { return nil }
    guard let encodable = child.value as? any Encodable else { return nil }
    return (encodable, true)
}
