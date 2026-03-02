import Foundation

/// Messages sent by the client to the server.
/// BSATN: u8 tag + variant payload.
public enum ClientMessage: Equatable, Sendable {
    case subscribe(Subscribe)         // tag 0
    case unsubscribe(Unsubscribe)     // tag 1
    case oneOffQuery(OneOffQuery)     // tag 2
    case callReducer(CallReducer)     // tag 3
    case callProcedure(CallProcedure) // tag 4
}

extension ClientMessage: Codable {
    public func encode(to encoder: Encoder) throws {
        if let bsatn = encoder as? _BSATNEncoderImpl {
            switch self {
            case .subscribe(let value):
                bsatn.writer.putU8(0)
                try value.encode(to: encoder)
            case .unsubscribe(let value):
                bsatn.writer.putU8(1)
                try value.encode(to: encoder)
            case .oneOffQuery(let value):
                bsatn.writer.putU8(2)
                try value.encode(to: encoder)
            case .callReducer(let value):
                bsatn.writer.putU8(3)
                try value.encode(to: encoder)
            case .callProcedure(let value):
                bsatn.writer.putU8(4)
                try value.encode(to: encoder)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        if let bsatn = decoder as? _BSATNDecoderImpl {
            let tag = try bsatn.reader.readU8()
            switch tag {
            case 0: self = .subscribe(try Subscribe(from: decoder))
            case 1: self = .unsubscribe(try Unsubscribe(from: decoder))
            case 2: self = .oneOffQuery(try OneOffQuery(from: decoder))
            case 3: self = .callReducer(try CallReducer(from: decoder))
            case 4: self = .callProcedure(try CallProcedure(from: decoder))
            default: throw BSATNDecodeError.invalidTag(tag)
            }
        } else {
            throw BSATNDecodeError.custom("ClientMessage only supports BSATN decoding")
        }
    }
}
