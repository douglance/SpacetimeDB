import Foundation

/// A unique identifier for a SpacetimeDB connection.
/// In BSATN, serialized as 16 raw bytes (u128 little-endian), no length prefix.
public struct ConnectionId: Equatable, Hashable, Sendable {
    public static let byteCount = 16

    public var data: Data

    public init(data: Data) {
        self.data = data
    }
}

extension ConnectionId: Codable {
    public func encode(to encoder: Encoder) throws {
        if encoder is _BSATNEncoderImpl {
            let bsatnEncoder = encoder as! _BSATNEncoderImpl
            bsatnEncoder.writer.putSlice(data)
        } else {
            var container = encoder.singleValueContainer()
            try container.encode(data)
        }
    }

    public init(from decoder: Decoder) throws {
        if let bsatnDecoder = decoder as? _BSATNDecoderImpl {
            self.data = try bsatnDecoder.reader.readRawBytes(ConnectionId.byteCount)
        } else {
            let container = try decoder.singleValueContainer()
            self.data = try container.decode(Data.self)
        }
    }
}
