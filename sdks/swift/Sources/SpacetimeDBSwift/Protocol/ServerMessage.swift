import Foundation

/// Messages sent by the server to the client.
/// BSATN: u8 tag + variant payload.
public enum ServerMessage: Equatable, Sendable {
    case initialConnection(InitialConnection)       // tag 0
    case subscribeApplied(SubscribeApplied)         // tag 1
    case unsubscribeApplied(UnsubscribeApplied)     // tag 2
    case subscriptionError(SubscriptionError)       // tag 3
    case transactionUpdate(TransactionUpdate)       // tag 4
    case oneOffQueryResult(OneOffQueryResult)        // tag 5
    case reducerResult(ReducerResult)               // tag 6
    case procedureResult(ProcedureResult)           // tag 7
}

extension ServerMessage: Codable {
    public func encode(to encoder: Encoder) throws {
        if let bsatn = encoder as? _BSATNEncoderImpl {
            switch self {
            case .initialConnection(let value):
                bsatn.writer.putU8(0)
                try value.encode(to: encoder)
            case .subscribeApplied(let value):
                bsatn.writer.putU8(1)
                try value.encode(to: encoder)
            case .unsubscribeApplied(let value):
                bsatn.writer.putU8(2)
                try value.encode(to: encoder)
            case .subscriptionError(let value):
                bsatn.writer.putU8(3)
                try value.encode(to: encoder)
            case .transactionUpdate(let value):
                bsatn.writer.putU8(4)
                try value.encode(to: encoder)
            case .oneOffQueryResult(let value):
                bsatn.writer.putU8(5)
                try value.encode(to: encoder)
            case .reducerResult(let value):
                bsatn.writer.putU8(6)
                try value.encode(to: encoder)
            case .procedureResult(let value):
                bsatn.writer.putU8(7)
                try value.encode(to: encoder)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        if let bsatn = decoder as? _BSATNDecoderImpl {
            let tag = try bsatn.reader.readU8()
            switch tag {
            case 0: self = .initialConnection(try InitialConnection(from: decoder))
            case 1: self = .subscribeApplied(try SubscribeApplied(from: decoder))
            case 2: self = .unsubscribeApplied(try UnsubscribeApplied(from: decoder))
            case 3: self = .subscriptionError(try SubscriptionError(from: decoder))
            case 4: self = .transactionUpdate(try TransactionUpdate(from: decoder))
            case 5: self = .oneOffQueryResult(try OneOffQueryResult(from: decoder))
            case 6: self = .reducerResult(try ReducerResult(from: decoder))
            case 7: self = .procedureResult(try ProcedureResult(from: decoder))
            default: throw BSATNDecodeError.invalidTag(tag)
            }
        } else {
            throw BSATNDecodeError.custom("ServerMessage only supports BSATN decoding")
        }
    }
}
