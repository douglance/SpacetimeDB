import Foundation

/// A unique identifier for a SpacetimeDB user identity.
/// In BSATN, serialized as 32 raw bytes (u256 little-endian), no length prefix.
public struct Identity: Equatable, Hashable, Sendable {
    public static let byteCount = 32

    public var data: Data

    public init(data: Data) {
        self.data = data
    }
}

extension Identity: Codable {
    public func encode(to encoder: Encoder) throws {
        if encoder is _BSATNEncoderImpl {
            // BSATN: 32 raw bytes, no length prefix
            let bsatnEncoder = encoder as! _BSATNEncoderImpl
            bsatnEncoder.writer.putSlice(data)
        } else {
            // JSON/other: use default Data encoding
            var container = encoder.singleValueContainer()
            try container.encode(data)
        }
    }

    public init(from decoder: Decoder) throws {
        if let bsatnDecoder = decoder as? _BSATNDecoderImpl {
            // BSATN: 32 raw bytes
            self.data = try bsatnDecoder.reader.readRawBytes(Identity.byteCount)
        } else {
            // JSON/other: use default Data decoding
            let container = try decoder.singleValueContainer()
            self.data = try container.decode(Data.self)
        }
    }
}
