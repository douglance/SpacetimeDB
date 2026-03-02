import Foundation
import Testing
@testable import SpacetimeDBSwift

// MARK: - Test types

struct SimpleStruct: Codable, Equatable, Sendable {
    var x: UInt32
    var y: UInt32
    var z: String
}

struct AllPrimitives: Codable, Equatable, Sendable {
    var b: Bool
    var u8: UInt8
    var u16: UInt16
    var u32: UInt32
    var u64: UInt64
    var i8: Int8
    var i16: Int16
    var i32: Int32
    var i64: Int64
    var f32: Float
    var f64: Double
    var s: String
}

struct WithOptional: Codable, Equatable, Sendable {
    var name: String
    var age: UInt32?
}

struct WithArray: Codable, Equatable, Sendable {
    var values: [UInt32]
}

struct Point: Codable, Equatable, Sendable {
    var x: Int64
    var y: Int64
}

struct WithNestedStruct: Codable, Equatable, Sendable {
    var id: UInt32
    var location: Point
}

struct WithNestedArray: Codable, Equatable, Sendable {
    var points: [Point]
}

// MARK: - Writer/Reader tests

@Test func writerReaderU8() throws {
    var writer = BSATNWriter()
    writer.putU8(0)
    writer.putU8(42)
    writer.putU8(255)

    var reader = BSATNReader(data: writer.data)
    #expect(try reader.readU8() == 0)
    #expect(try reader.readU8() == 42)
    #expect(try reader.readU8() == 255)
    #expect(reader.isAtEnd)
}

@Test func writerReaderU16() throws {
    var writer = BSATNWriter()
    writer.putU16LE(0)
    writer.putU16LE(1234)
    writer.putU16LE(65535)

    var reader = BSATNReader(data: writer.data)
    #expect(try reader.readU16LE() == 0)
    #expect(try reader.readU16LE() == 1234)
    #expect(try reader.readU16LE() == 65535)
    #expect(reader.isAtEnd)
}

@Test func writerReaderU32() throws {
    var writer = BSATNWriter()
    writer.putU32LE(0)
    writer.putU32LE(123456)
    writer.putU32LE(UInt32.max)

    var reader = BSATNReader(data: writer.data)
    #expect(try reader.readU32LE() == 0)
    #expect(try reader.readU32LE() == 123456)
    #expect(try reader.readU32LE() == UInt32.max)
    #expect(reader.isAtEnd)
}

@Test func writerReaderU64() throws {
    var writer = BSATNWriter()
    writer.putU64LE(0)
    writer.putU64LE(987654321)
    writer.putU64LE(UInt64.max)

    var reader = BSATNReader(data: writer.data)
    #expect(try reader.readU64LE() == 0)
    #expect(try reader.readU64LE() == 987654321)
    #expect(try reader.readU64LE() == UInt64.max)
    #expect(reader.isAtEnd)
}

@Test func writerReaderSignedIntegers() throws {
    var writer = BSATNWriter()
    writer.putI8(-128)
    writer.putI8(127)
    writer.putI16LE(-32768)
    writer.putI16LE(32767)
    writer.putI32LE(Int32.min)
    writer.putI32LE(Int32.max)
    writer.putI64LE(Int64.min)
    writer.putI64LE(Int64.max)

    var reader = BSATNReader(data: writer.data)
    #expect(try reader.readI8() == -128)
    #expect(try reader.readI8() == 127)
    #expect(try reader.readI16LE() == -32768)
    #expect(try reader.readI16LE() == 32767)
    #expect(try reader.readI32LE() == Int32.min)
    #expect(try reader.readI32LE() == Int32.max)
    #expect(try reader.readI64LE() == Int64.min)
    #expect(try reader.readI64LE() == Int64.max)
    #expect(reader.isAtEnd)
}

@Test func writerReaderFloat() throws {
    var writer = BSATNWriter()
    writer.putF32(3.14)
    writer.putF64(2.718281828459045)

    var reader = BSATNReader(data: writer.data)
    let f32 = try reader.readF32()
    let f64 = try reader.readF64()
    #expect(abs(f32 - 3.14) < 0.001)
    #expect(abs(f64 - 2.718281828459045) < 0.0000001)
    #expect(reader.isAtEnd)
}

@Test func writerReaderBool() throws {
    var writer = BSATNWriter()
    writer.putBool(true)
    writer.putBool(false)

    var reader = BSATNReader(data: writer.data)
    #expect(try reader.readBool() == true)
    #expect(try reader.readBool() == false)
    #expect(reader.isAtEnd)
}

@Test func writerReaderString() throws {
    var writer = BSATNWriter()
    writer.putString("hello")
    writer.putString("")
    writer.putString("world!")

    var reader = BSATNReader(data: writer.data)
    #expect(try reader.readString() == "hello")
    #expect(try reader.readString() == "")
    #expect(try reader.readString() == "world!")
    #expect(reader.isAtEnd)
}

@Test func writerReaderBytes() throws {
    var writer = BSATNWriter()
    let bytes = Data([1, 2, 3, 4, 5])
    writer.putBytes(bytes)

    var reader = BSATNReader(data: writer.data)
    #expect(try reader.readBytes() == bytes)
    #expect(reader.isAtEnd)
}

@Test func readerInsufficientData() {
    var reader = BSATNReader(data: Data([1]))
    #expect(throws: BSATNDecodeError.self) { try reader.readU32LE() }
}

@Test func readerInvalidBool() {
    var reader = BSATNReader(data: Data([2]))
    #expect(throws: BSATNDecodeError.self) { try reader.readBool() }
}

// MARK: - Encoder/Decoder round-trip tests

@Test func roundTripBool() throws {
    let data = try BSATN.encode(true)
    #expect(data == Data([1]))
    let decoded = try BSATN.decode(Bool.self, from: data)
    #expect(decoded == true)

    let dataFalse = try BSATN.encode(false)
    #expect(dataFalse == Data([0]))
    let decodedFalse = try BSATN.decode(Bool.self, from: dataFalse)
    #expect(decodedFalse == false)
}

@Test func roundTripUInt8() throws {
    let data = try BSATN.encode(UInt8(42))
    #expect(data == Data([42]))
    let decoded = try BSATN.decode(UInt8.self, from: data)
    #expect(decoded == 42)
}

@Test func roundTripUInt16() throws {
    let value: UInt16 = 0x1234
    let data = try BSATN.encode(value)
    #expect(data == Data([0x34, 0x12])) // little-endian
    let decoded = try BSATN.decode(UInt16.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripUInt32() throws {
    let value: UInt32 = 0x12345678
    let data = try BSATN.encode(value)
    #expect(data == Data([0x78, 0x56, 0x34, 0x12])) // little-endian
    let decoded = try BSATN.decode(UInt32.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripUInt64() throws {
    let value: UInt64 = 0x0102030405060708
    let data = try BSATN.encode(value)
    #expect(data == Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]))
    let decoded = try BSATN.decode(UInt64.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripInt8() throws {
    let value: Int8 = -42
    let data = try BSATN.encode(value)
    let decoded = try BSATN.decode(Int8.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripInt16() throws {
    let value: Int16 = -1234
    let data = try BSATN.encode(value)
    let decoded = try BSATN.decode(Int16.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripInt32() throws {
    let value: Int32 = -123456
    let data = try BSATN.encode(value)
    let decoded = try BSATN.decode(Int32.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripInt64() throws {
    let value: Int64 = -9876543210
    let data = try BSATN.encode(value)
    let decoded = try BSATN.decode(Int64.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripFloat() throws {
    let value: Float = 3.14
    let data = try BSATN.encode(value)
    // Float is encoded as u32 bit pattern
    #expect(data.count == 4)
    let decoded = try BSATN.decode(Float.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripDouble() throws {
    let value: Double = 2.718281828459045
    let data = try BSATN.encode(value)
    #expect(data.count == 8)
    let decoded = try BSATN.decode(Double.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripString() throws {
    let value = "hello world"
    let data = try BSATN.encode(value)
    // u32 length prefix (11) + 11 bytes
    #expect(data.count == 4 + 11)
    // Check length prefix is little-endian 11
    #expect(data[data.startIndex] == 11)
    #expect(data[data.startIndex + 1] == 0)
    #expect(data[data.startIndex + 2] == 0)
    #expect(data[data.startIndex + 3] == 0)
    let decoded = try BSATN.decode(String.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripEmptyString() throws {
    let value = ""
    let data = try BSATN.encode(value)
    #expect(data.count == 4) // just the u32 length prefix
    let decoded = try BSATN.decode(String.self, from: data)
    #expect(decoded == value)
}

// MARK: - Struct (product type) round-trip tests

@Test func roundTripSimpleStruct() throws {
    let value = SimpleStruct(x: 10, y: 20, z: "hello")
    let data = try BSATN.encode(value)
    // 4 bytes (x) + 4 bytes (y) + 4 bytes (len) + 5 bytes ("hello")
    #expect(data.count == 4 + 4 + 4 + 5)
    let decoded = try BSATN.decode(SimpleStruct.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripAllPrimitives() throws {
    let value = AllPrimitives(
        b: true, u8: 255, u16: 1000, u32: 100000,
        u64: 10000000000, i8: -100, i16: -1000, i32: -100000,
        i64: -10000000000, f32: 1.5, f64: 2.5, s: "test"
    )
    let data = try BSATN.encode(value)
    let decoded = try BSATN.decode(AllPrimitives.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripNestedStruct() throws {
    let value = WithNestedStruct(id: 42, location: Point(x: 100, y: -200))
    let data = try BSATN.encode(value)
    // 4 (id) + 8 (x) + 8 (y)
    #expect(data.count == 4 + 8 + 8)
    let decoded = try BSATN.decode(WithNestedStruct.self, from: data)
    #expect(decoded == value)
}

// MARK: - Optional round-trip tests

@Test func roundTripOptionalSome() throws {
    let value = WithOptional(name: "Alice", age: 30)
    let data = try BSATN.encode(value)
    let decoded = try BSATN.decode(WithOptional.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripOptionalNone() throws {
    let value = WithOptional(name: "Bob", age: nil)
    let data = try BSATN.encode(value)
    let decoded = try BSATN.decode(WithOptional.self, from: data)
    #expect(decoded == value)
    #expect(decoded.age == nil)
}

@Test func optionalEncodingFormat() throws {
    // Some(42u32): tag 0 + u32 LE
    let some = WithOptional(name: "x", age: 42)
    let someData = try BSATN.encode(some)
    // name: u32 len(1) + "x" = 5 bytes, then tag 0 byte + u32(42) = 5 bytes
    #expect(someData.count == 5 + 1 + 4)
    // tag byte at offset 5 should be 0 (Some)
    #expect(someData[someData.startIndex + 5] == 0)

    // None: tag 1
    let none = WithOptional(name: "x", age: nil)
    let noneData = try BSATN.encode(none)
    #expect(noneData.count == 5 + 1) // name + tag byte only
    #expect(noneData[noneData.startIndex + 5] == 1)
}

// MARK: - Array round-trip tests

@Test func roundTripArray() throws {
    let value = WithArray(values: [1, 2, 3, 4, 5])
    let data = try BSATN.encode(value)
    // u32 count (4) + 5 * u32 (20) = 24 bytes
    #expect(data.count == 4 + 5 * 4)
    let decoded = try BSATN.decode(WithArray.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripEmptyArray() throws {
    let value = WithArray(values: [])
    let data = try BSATN.encode(value)
    #expect(data.count == 4) // just the u32 count prefix
    let decoded = try BSATN.decode(WithArray.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripNestedArray() throws {
    let value = WithNestedArray(points: [
        Point(x: 1, y: 2),
        Point(x: 3, y: 4),
        Point(x: 5, y: 6),
    ])
    let data = try BSATN.encode(value)
    // u32 count (4) + 3 * (i64 + i64) = 4 + 48 = 52
    #expect(data.count == 4 + 3 * 16)
    let decoded = try BSATN.decode(WithNestedArray.self, from: data)
    #expect(decoded == value)
}

// MARK: - Enum (sum type) round-trip tests

// Simple enum without associated values — uses rawValue Codable (string key)
// For BSATN we need integer-tagged enums. Let's test with manual Codable.

enum SimpleEnum: Codable, Equatable, Sendable {
    case foo
    case bar
    case baz(String)

    enum CodingKeys: Int, CodingKey {
        case foo = 0
        case bar = 1
        case baz = 2
    }

    func encode(to encoder: any Encoder) throws {
        if let bsatnEncoder = encoder as? _BSATNEncoderImpl {
            bsatnEncoder.isEnumContext = true
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .foo:
            // Unit variant: just the tag, write an empty struct (no payload)
            try container.encode(true, forKey: .foo) // dummy value for unit variant
        case .bar:
            try container.encode(true, forKey: .bar)
        case .baz(let value):
            try container.encode(value, forKey: .baz)
        }
    }

    init(from decoder: any Decoder) throws {
        if let bsatnDecoder = decoder as? _BSATNDecoderImpl {
            let tag = try bsatnDecoder.reader.readU8()
            bsatnDecoder.enumTag = tag
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.foo) {
            _ = try container.decode(Bool.self, forKey: .foo)
            self = .foo
        } else if container.contains(.bar) {
            _ = try container.decode(Bool.self, forKey: .bar)
            self = .bar
        } else if container.contains(.baz) {
            let value = try container.decode(String.self, forKey: .baz)
            self = .baz(value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Unknown enum case")
            )
        }
    }
}

@Test func roundTripEnumUnitVariant() throws {
    let value = SimpleEnum.foo
    let data = try BSATN.encode(value)
    // u8 tag (0) + bool payload (1 byte)
    #expect(data[data.startIndex] == 0) // tag for .foo
    let decoded = try BSATN.decode(SimpleEnum.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripEnumWithPayload() throws {
    let value = SimpleEnum.baz("hello")
    let data = try BSATN.encode(value)
    #expect(data[data.startIndex] == 2) // tag for .baz
    let decoded = try BSATN.decode(SimpleEnum.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripEnumAllCases() throws {
    for value in [SimpleEnum.foo, SimpleEnum.bar, SimpleEnum.baz("test")] {
        let data = try BSATN.encode(value)
        let decoded = try BSATN.decode(SimpleEnum.self, from: data)
        #expect(decoded == value)
    }
}

// MARK: - SpacetimeDB built-in type round-trips

@Test func roundTripTimestamp() throws {
    let value = Timestamp(microseconds: 1234567890)
    let data = try BSATN.encode(value)
    #expect(data.count == 8) // i64
    let decoded = try BSATN.decode(Timestamp.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripTimeDuration() throws {
    let value = TimeDuration(microseconds: -5000)
    let data = try BSATN.encode(value)
    #expect(data.count == 8) // i64
    let decoded = try BSATN.decode(TimeDuration.self, from: data)
    #expect(decoded == value)
}

// MARK: - Data (bytes) round-trip

@Test func roundTripData() throws {
    let value = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let data = try BSATN.encode(value)
    // u32 len + 4 bytes
    #expect(data.count == 4 + 4)
    let decoded = try BSATN.decode(Data.self, from: data)
    #expect(decoded == value)
}

// MARK: - Byte-level format verification

@Test func u32LittleEndianFormat() throws {
    let value: UInt32 = 0x01020304
    let data = try BSATN.encode(value)
    #expect(Array(data) == [0x04, 0x03, 0x02, 0x01])
}

@Test func i32LittleEndianFormat() throws {
    let value: Int32 = -1
    let data = try BSATN.encode(value)
    #expect(Array(data) == [0xFF, 0xFF, 0xFF, 0xFF])
}

@Test func floatBitPatternFormat() throws {
    let value: Float = 1.0
    let data = try BSATN.encode(value)
    // 1.0f bit pattern = 0x3F800000, LE = [0x00, 0x00, 0x80, 0x3F]
    #expect(Array(data) == [0x00, 0x00, 0x80, 0x3F])
}

@Test func doubleBitPatternFormat() throws {
    let value: Double = 1.0
    let data = try BSATN.encode(value)
    // 1.0 bit pattern = 0x3FF0000000000000, LE = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F]
    #expect(Array(data) == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F])
}

@Test func stringFormat() throws {
    let data = try BSATN.encode("AB")
    // u32 len (2) LE + 'A' 'B'
    #expect(Array(data) == [0x02, 0x00, 0x00, 0x00, 0x41, 0x42])
}

@Test func structSequentialFormat() throws {
    let value = Point(x: 1, y: 2)
    let data = try BSATN.encode(value)
    // i64(1) LE + i64(2) LE, no framing
    var expected = Data()
    expected.append(contentsOf: withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) })
    expected.append(contentsOf: withUnsafeBytes(of: Int64(2).littleEndian) { Array($0) })
    #expect(data == expected)
}

// MARK: - Edge cases

@Test func roundTripUnicodeString() throws {
    let value = "Hello \u{1F30D}" // globe emoji
    let data = try BSATN.encode(value)
    let decoded = try BSATN.decode(String.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripZeroValues() throws {
    let value = AllPrimitives(
        b: false, u8: 0, u16: 0, u32: 0, u64: 0,
        i8: 0, i16: 0, i32: 0, i64: 0,
        f32: 0.0, f64: 0.0, s: ""
    )
    let data = try BSATN.encode(value)
    let decoded = try BSATN.decode(AllPrimitives.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripMaxValues() throws {
    let value = AllPrimitives(
        b: true, u8: UInt8.max, u16: UInt16.max, u32: UInt32.max, u64: UInt64.max,
        i8: Int8.max, i16: Int16.max, i32: Int32.max, i64: Int64.max,
        f32: Float.greatestFiniteMagnitude, f64: Double.greatestFiniteMagnitude, s: "max"
    )
    let data = try BSATN.encode(value)
    let decoded = try BSATN.decode(AllPrimitives.self, from: data)
    #expect(decoded == value)
}

@Test func roundTripMinValues() throws {
    let value = AllPrimitives(
        b: false, u8: UInt8.min, u16: UInt16.min, u32: UInt32.min, u64: UInt64.min,
        i8: Int8.min, i16: Int16.min, i32: Int32.min, i64: Int64.min,
        f32: -Float.greatestFiniteMagnitude, f64: -Double.greatestFiniteMagnitude, s: ""
    )
    let data = try BSATN.encode(value)
    let decoded = try BSATN.decode(AllPrimitives.self, from: data)
    #expect(decoded == value)
}
