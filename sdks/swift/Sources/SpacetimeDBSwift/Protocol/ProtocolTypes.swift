import Foundation

// MARK: - QuerySetId

public struct QuerySetId: Codable, Equatable, Sendable {
    public var id: UInt32

    public init(id: UInt32) {
        self.id = id
    }
}

// MARK: - Subscribe

public struct Subscribe: Codable, Equatable, Sendable {
    public var requestId: UInt32
    public var querySetId: QuerySetId
    public var queryStrings: [String]

    public init(requestId: UInt32, querySetId: QuerySetId, queryStrings: [String]) {
        self.requestId = requestId
        self.querySetId = querySetId
        self.queryStrings = queryStrings
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case querySetId = "query_set_id"
        case queryStrings = "query_strings"
    }
}

// MARK: - Unsubscribe

public struct Unsubscribe: Codable, Equatable, Sendable {
    public var requestId: UInt32
    public var querySetId: QuerySetId
    public var flags: UInt8

    public init(requestId: UInt32, querySetId: QuerySetId, flags: UInt8 = 0) {
        self.requestId = requestId
        self.querySetId = querySetId
        self.flags = flags
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case querySetId = "query_set_id"
        case flags
    }
}

// MARK: - OneOffQuery

public struct OneOffQuery: Codable, Equatable, Sendable {
    public var requestId: UInt32
    public var queryString: String

    public init(requestId: UInt32, queryString: String) {
        self.requestId = requestId
        self.queryString = queryString
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case queryString = "query_string"
    }
}

// MARK: - CallReducer

public struct CallReducer: Codable, Equatable, Sendable {
    public var requestId: UInt32
    public var flags: UInt8
    public var reducer: String
    public var args: Data

    public init(requestId: UInt32, flags: UInt8 = 0, reducer: String, args: Data) {
        self.requestId = requestId
        self.flags = flags
        self.reducer = reducer
        self.args = args
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case flags, reducer, args
    }
}

// MARK: - CallProcedure

public struct CallProcedure: Codable, Equatable, Sendable {
    public var requestId: UInt32
    public var flags: UInt8
    public var procedure: String
    public var args: Data

    public init(requestId: UInt32, flags: UInt8 = 0, procedure: String, args: Data) {
        self.requestId = requestId
        self.flags = flags
        self.procedure = procedure
        self.args = args
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case flags, procedure, args
    }
}

// MARK: - InitialConnection

public struct InitialConnection: Equatable, Sendable {
    public var identity: Identity
    public var connectionId: ConnectionId
    public var token: String

    public init(identity: Identity, connectionId: ConnectionId, token: String) {
        self.identity = identity
        self.connectionId = connectionId
        self.token = token
    }
}

extension InitialConnection: Codable {
    enum CodingKeys: String, CodingKey {
        case identity
        case connectionId = "connection_id"
        case token
    }
}

// MARK: - BsatnRowList

public struct BsatnRowList: Equatable, Sendable {
    public var sizeHint: RowSizeHint
    public var rowsData: Data

    public init(sizeHint: RowSizeHint, rowsData: Data) {
        self.sizeHint = sizeHint
        self.rowsData = rowsData
    }

    /// Split the flat row data into individual row byte arrays.
    public func splitRows() -> [Data] {
        switch sizeHint {
        case .fixedSize(let size):
            let rowSize = Int(size)
            guard rowSize > 0 else { return [] }
            var rows: [Data] = []
            var offset = 0
            while offset + rowSize <= rowsData.count {
                let start = rowsData.startIndex + offset
                rows.append(rowsData[start ..< start + rowSize])
                offset += rowSize
            }
            return rows
        case .rowOffsets(let offsets):
            var rows: [Data] = []
            for (i, offsetVal) in offsets.enumerated() {
                let start = rowsData.startIndex + Int(offsetVal)
                let end: Int
                if i + 1 < offsets.count {
                    end = rowsData.startIndex + Int(offsets[i + 1])
                } else {
                    end = rowsData.startIndex + rowsData.count
                }
                rows.append(rowsData[start ..< end])
            }
            return rows
        }
    }
}

extension BsatnRowList: Codable {
    public func encode(to encoder: Encoder) throws {
        // Product: sizeHint then rowsData sequentially
        try sizeHint.encode(to: encoder)
        try rowsData.encode(to: encoder)
    }

    public init(from decoder: Decoder) throws {
        self.sizeHint = try RowSizeHint(from: decoder)
        if let bsatn = decoder as? _BSATNDecoderImpl {
            self.rowsData = try bsatn.reader.readBytes()
        } else {
            let container = try decoder.singleValueContainer()
            self.rowsData = try container.decode(Data.self)
        }
    }
}

// MARK: - RowSizeHint

public enum RowSizeHint: Equatable, Sendable {
    case fixedSize(UInt16)   // tag 0
    case rowOffsets([UInt64]) // tag 1
}

extension RowSizeHint: Codable {
    public func encode(to encoder: Encoder) throws {
        if let bsatn = encoder as? _BSATNEncoderImpl {
            switch self {
            case .fixedSize(let size):
                bsatn.writer.putU8(0)
                bsatn.writer.putU16LE(size)
            case .rowOffsets(let offsets):
                bsatn.writer.putU8(1)
                bsatn.writer.putU32LE(UInt32(offsets.count))
                for offset in offsets {
                    bsatn.writer.putU64LE(offset)
                }
            }
        } else {
            // Fallback for non-BSATN encoders
            var container = encoder.singleValueContainer()
            try container.encode("RowSizeHint")
        }
    }

    public init(from decoder: Decoder) throws {
        if let bsatn = decoder as? _BSATNDecoderImpl {
            let tag = try bsatn.reader.readU8()
            switch tag {
            case 0:
                self = .fixedSize(try bsatn.reader.readU16LE())
            case 1:
                let count = try bsatn.reader.readU32LE()
                var offsets: [UInt64] = []
                for _ in 0 ..< count {
                    offsets.append(try bsatn.reader.readU64LE())
                }
                self = .rowOffsets(offsets)
            default:
                throw BSATNDecodeError.invalidTag(tag)
            }
        } else {
            self = .fixedSize(0)
        }
    }
}

// MARK: - QueryRows

public struct QueryRows: Codable, Equatable, Sendable {
    public var tables: [SingleTableRows]

    public init(tables: [SingleTableRows]) {
        self.tables = tables
    }
}

// MARK: - SingleTableRows

public struct SingleTableRows: Codable, Equatable, Sendable {
    public var table: String
    public var rows: BsatnRowList

    public init(table: String, rows: BsatnRowList) {
        self.table = table
        self.rows = rows
    }
}

// MARK: - SubscribeApplied

public struct SubscribeApplied: Codable, Equatable, Sendable {
    public var requestId: UInt32
    public var querySetId: QuerySetId
    public var rows: QueryRows

    public init(requestId: UInt32, querySetId: QuerySetId, rows: QueryRows) {
        self.requestId = requestId
        self.querySetId = querySetId
        self.rows = rows
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case querySetId = "query_set_id"
        case rows
    }
}

// MARK: - UnsubscribeApplied

public struct UnsubscribeApplied: Equatable, Sendable {
    public var requestId: UInt32
    public var querySetId: QuerySetId
    public var rows: QueryRows? // Option<QueryRows>

    public init(requestId: UInt32, querySetId: QuerySetId, rows: QueryRows?) {
        self.requestId = requestId
        self.querySetId = querySetId
        self.rows = rows
    }
}

extension UnsubscribeApplied: Codable {
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case querySetId = "query_set_id"
        case rows
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(querySetId, forKey: .querySetId)
        try container.encodeIfPresent(rows, forKey: .rows)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestId = try container.decode(UInt32.self, forKey: .requestId)
        self.querySetId = try container.decode(QuerySetId.self, forKey: .querySetId)
        self.rows = try container.decodeIfPresent(QueryRows.self, forKey: .rows)
    }
}

// MARK: - SubscriptionError

public struct SubscriptionError: Equatable, Sendable {
    public var requestId: UInt32? // Option<u32>
    public var querySetId: QuerySetId
    public var error: String

    public init(requestId: UInt32?, querySetId: QuerySetId, error: String) {
        self.requestId = requestId
        self.querySetId = querySetId
        self.error = error
    }
}

extension SubscriptionError: Codable {
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case querySetId = "query_set_id"
        case error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(requestId, forKey: .requestId)
        try container.encode(querySetId, forKey: .querySetId)
        try container.encode(error, forKey: .error)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestId = try container.decodeIfPresent(UInt32.self, forKey: .requestId)
        self.querySetId = try container.decode(QuerySetId.self, forKey: .querySetId)
        self.error = try container.decode(String.self, forKey: .error)
    }
}

// MARK: - TransactionUpdate

public struct TransactionUpdate: Codable, Equatable, Sendable {
    public var querySets: [QuerySetUpdate]

    public init(querySets: [QuerySetUpdate]) {
        self.querySets = querySets
    }

    enum CodingKeys: String, CodingKey {
        case querySets = "query_sets"
    }
}

// MARK: - QuerySetUpdate

public struct QuerySetUpdate: Codable, Equatable, Sendable {
    public var querySetId: QuerySetId
    public var tables: [TableUpdate]

    public init(querySetId: QuerySetId, tables: [TableUpdate]) {
        self.querySetId = querySetId
        self.tables = tables
    }

    enum CodingKeys: String, CodingKey {
        case querySetId = "query_set_id"
        case tables
    }
}

// MARK: - TableUpdate

public struct TableUpdate: Codable, Equatable, Sendable {
    public var tableName: String
    public var rows: [TableUpdateRows]

    public init(tableName: String, rows: [TableUpdateRows]) {
        self.tableName = tableName
        self.rows = rows
    }

    enum CodingKeys: String, CodingKey {
        case tableName = "table_name"
        case rows
    }
}

// MARK: - TableUpdateRows

public enum TableUpdateRows: Equatable, Sendable {
    case persistentTable(PersistentTableRows)  // tag 0
    case eventTable(EventTableRows)            // tag 1
}

extension TableUpdateRows: Codable {
    public func encode(to encoder: Encoder) throws {
        if let bsatn = encoder as? _BSATNEncoderImpl {
            switch self {
            case .persistentTable(let rows):
                bsatn.writer.putU8(0)
                try rows.encode(to: encoder)
            case .eventTable(let rows):
                bsatn.writer.putU8(1)
                try rows.encode(to: encoder)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        if let bsatn = decoder as? _BSATNDecoderImpl {
            let tag = try bsatn.reader.readU8()
            switch tag {
            case 0: self = .persistentTable(try PersistentTableRows(from: decoder))
            case 1: self = .eventTable(try EventTableRows(from: decoder))
            default: throw BSATNDecodeError.invalidTag(tag)
            }
        } else {
            throw BSATNDecodeError.custom("TableUpdateRows only supports BSATN decoding")
        }
    }
}

// MARK: - PersistentTableRows

public struct PersistentTableRows: Codable, Equatable, Sendable {
    public var inserts: BsatnRowList
    public var deletes: BsatnRowList

    public init(inserts: BsatnRowList, deletes: BsatnRowList) {
        self.inserts = inserts
        self.deletes = deletes
    }
}

// MARK: - EventTableRows

public struct EventTableRows: Codable, Equatable, Sendable {
    public var events: BsatnRowList

    public init(events: BsatnRowList) {
        self.events = events
    }
}

// MARK: - OneOffQueryResult

/// Result of a one-off query. Either rows or an error string.
public enum OneOffQueryOutcome: Equatable, Sendable {
    case ok(QueryRows)
    case err(String)
}

extension OneOffQueryOutcome: Codable {
    public func encode(to encoder: Encoder) throws {
        if let bsatn = encoder as? _BSATNEncoderImpl {
            switch self {
            case .ok(let rows):
                bsatn.writer.putU8(0)
                try rows.encode(to: encoder)
            case .err(let msg):
                bsatn.writer.putU8(1)
                bsatn.writer.putString(msg)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        if let bsatn = decoder as? _BSATNDecoderImpl {
            let tag = try bsatn.reader.readU8()
            switch tag {
            case 0: self = .ok(try QueryRows(from: decoder))
            case 1: self = .err(try bsatn.reader.readString())
            default: throw BSATNDecodeError.invalidTag(tag)
            }
        } else {
            throw BSATNDecodeError.custom("OneOffQueryOutcome only supports BSATN decoding")
        }
    }
}

public struct OneOffQueryResult: Codable, Equatable, Sendable {
    public var requestId: UInt32
    public var result: OneOffQueryOutcome

    public init(requestId: UInt32, result: OneOffQueryOutcome) {
        self.requestId = requestId
        self.result = result
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case result
    }
}

// MARK: - ReducerResult

public struct ReducerResult: Codable, Equatable, Sendable {
    public var requestId: UInt32
    public var timestamp: Timestamp
    public var result: ReducerOutcome

    public init(requestId: UInt32, timestamp: Timestamp, result: ReducerOutcome) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.result = result
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case timestamp, result
    }
}

// MARK: - ReducerOutcome

public enum ReducerOutcome: Equatable, Sendable {
    case ok(ReducerOk)           // tag 0
    case okEmpty                  // tag 1
    case err(Data)               // tag 2
    case internalError(String)   // tag 3
}

extension ReducerOutcome: Codable {
    public func encode(to encoder: Encoder) throws {
        if let bsatn = encoder as? _BSATNEncoderImpl {
            switch self {
            case .ok(let value):
                bsatn.writer.putU8(0)
                try value.encode(to: encoder)
            case .okEmpty:
                bsatn.writer.putU8(1)
            case .err(let data):
                bsatn.writer.putU8(2)
                bsatn.writer.putBytes(data)
            case .internalError(let msg):
                bsatn.writer.putU8(3)
                bsatn.writer.putString(msg)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        if let bsatn = decoder as? _BSATNDecoderImpl {
            let tag = try bsatn.reader.readU8()
            switch tag {
            case 0: self = .ok(try ReducerOk(from: decoder))
            case 1: self = .okEmpty
            case 2: self = .err(try bsatn.reader.readBytes())
            case 3: self = .internalError(try bsatn.reader.readString())
            default: throw BSATNDecodeError.invalidTag(tag)
            }
        } else {
            throw BSATNDecodeError.custom("ReducerOutcome only supports BSATN decoding")
        }
    }
}

// MARK: - ReducerOk

public struct ReducerOk: Codable, Equatable, Sendable {
    public var retValue: Data
    public var transactionUpdate: TransactionUpdate

    public init(retValue: Data, transactionUpdate: TransactionUpdate) {
        self.retValue = retValue
        self.transactionUpdate = transactionUpdate
    }

    enum CodingKeys: String, CodingKey {
        case retValue = "ret_value"
        case transactionUpdate = "transaction_update"
    }
}

// MARK: - ProcedureResult

public struct ProcedureResult: Codable, Equatable, Sendable {
    public var status: ProcedureStatus
    public var timestamp: Timestamp
    public var totalHostExecutionDuration: TimeDuration
    public var requestId: UInt32

    public init(status: ProcedureStatus, timestamp: Timestamp,
                totalHostExecutionDuration: TimeDuration, requestId: UInt32) {
        self.status = status
        self.timestamp = timestamp
        self.totalHostExecutionDuration = totalHostExecutionDuration
        self.requestId = requestId
    }

    enum CodingKeys: String, CodingKey {
        case status, timestamp
        case totalHostExecutionDuration = "total_host_execution_duration"
        case requestId = "request_id"
    }
}

// MARK: - ProcedureStatus

public enum ProcedureStatus: Equatable, Sendable {
    case returned(Data)          // tag 0
    case internalError(String)   // tag 1
}

extension ProcedureStatus: Codable {
    public func encode(to encoder: Encoder) throws {
        if let bsatn = encoder as? _BSATNEncoderImpl {
            switch self {
            case .returned(let data):
                bsatn.writer.putU8(0)
                bsatn.writer.putBytes(data)
            case .internalError(let msg):
                bsatn.writer.putU8(1)
                bsatn.writer.putString(msg)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        if let bsatn = decoder as? _BSATNDecoderImpl {
            let tag = try bsatn.reader.readU8()
            switch tag {
            case 0: self = .returned(try bsatn.reader.readBytes())
            case 1: self = .internalError(try bsatn.reader.readString())
            default: throw BSATNDecodeError.invalidTag(tag)
            }
        } else {
            throw BSATNDecodeError.custom("ProcedureStatus only supports BSATN decoding")
        }
    }
}
