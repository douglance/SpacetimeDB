import Foundation

/// Protocol for types that use BSATN enum encoding (u8 tag + payload).
/// Conforming types get automatic BSATN-compatible Codable synthesis
/// when they implement `encode(to:)` and `init(from:)` using integer-keyed containers.
public protocol BSATNEnum: Codable {}

/// Convenience functions for BSATN encoding/decoding.
public enum BSATN {
    /// Encode a Codable value to BSATN binary format.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try BSATNEncoder().encode(value)
    }

    /// Decode a Codable value from BSATN binary format.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try BSATNDecoder().decode(type, from: data)
    }
}
