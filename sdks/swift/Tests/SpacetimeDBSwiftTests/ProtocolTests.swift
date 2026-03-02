import Foundation
import Testing
@testable import SpacetimeDBSwift

// MARK: - Identity BSATN encoding

@Test func identityBSATNRoundTrip() throws {
    let bytes = Data((0..<32).map { UInt8($0) })
    let identity = Identity(data: bytes)
    let encoded = try BSATN.encode(identity)
    // Should be exactly 32 raw bytes, no length prefix
    #expect(encoded.count == 32)
    #expect(encoded == bytes)
    let decoded = try BSATN.decode(Identity.self, from: encoded)
    #expect(decoded == identity)
}

@Test func connectionIdBSATNRoundTrip() throws {
    let bytes = Data((0..<16).map { UInt8($0) })
    let connId = ConnectionId(data: bytes)
    let encoded = try BSATN.encode(connId)
    // Should be exactly 16 raw bytes, no length prefix
    #expect(encoded.count == 16)
    #expect(encoded == bytes)
    let decoded = try BSATN.decode(ConnectionId.self, from: encoded)
    #expect(decoded == connId)
}

// MARK: - ClientMessage encoding

@Test func clientMessageSubscribeEncoding() throws {
    let msg = ClientMessage.subscribe(Subscribe(
        requestId: 1,
        querySetId: QuerySetId(id: 42),
        queryStrings: ["SELECT * FROM foo"]
    ))

    let data = try BSATN.encode(msg)

    // Verify: tag(1) + request_id(4) + query_set_id.id(4) + array_count(4) + string
    #expect(data[data.startIndex] == 0) // tag 0 = Subscribe

    // Round-trip
    let decoded = try BSATN.decode(ClientMessage.self, from: data)
    #expect(decoded == msg)
}

@Test func clientMessageCallReducerEncoding() throws {
    let args = Data([0xDE, 0xAD])
    let msg = ClientMessage.callReducer(CallReducer(
        requestId: 5,
        flags: 0,
        reducer: "set_heading",
        args: args
    ))

    let data = try BSATN.encode(msg)
    #expect(data[data.startIndex] == 3) // tag 3 = CallReducer

    let decoded = try BSATN.decode(ClientMessage.self, from: data)
    #expect(decoded == msg)
}

// MARK: - ServerMessage encoding

@Test func serverMessageInitialConnectionEncoding() throws {
    let identity = Identity(data: Data(repeating: 0xAB, count: 32))
    let connId = ConnectionId(data: Data(repeating: 0xCD, count: 16))

    let msg = ServerMessage.initialConnection(InitialConnection(
        identity: identity,
        connectionId: connId,
        token: "test-token-123"
    ))

    let data = try BSATN.encode(msg)
    #expect(data[data.startIndex] == 0) // tag 0 = InitialConnection

    let decoded = try BSATN.decode(ServerMessage.self, from: data)
    #expect(decoded == msg)
}

// MARK: - BsatnRowList splitting

@Test func bsatnRowListFixedSizeSplit() {
    // 3 rows of 4 bytes each
    let rowData = Data([1, 0, 0, 0,  2, 0, 0, 0,  3, 0, 0, 0])
    let rowList = BsatnRowList(sizeHint: .fixedSize(4), rowsData: rowData)

    let rows = rowList.splitRows()
    #expect(rows.count == 3)
    #expect(rows[0] == Data([1, 0, 0, 0]))
    #expect(rows[1] == Data([2, 0, 0, 0]))
    #expect(rows[2] == Data([3, 0, 0, 0]))
}

@Test func bsatnRowListRowOffsetsSplit() {
    // 2 rows: "abc" (3 bytes) and "de" (2 bytes)
    let rowData = Data([0x61, 0x62, 0x63, 0x64, 0x65])
    let rowList = BsatnRowList(sizeHint: .rowOffsets([0, 3]), rowsData: rowData)

    let rows = rowList.splitRows()
    #expect(rows.count == 2)
    #expect(rows[0] == Data([0x61, 0x62, 0x63]))
    #expect(rows[1] == Data([0x64, 0x65]))
}

@Test func bsatnRowListEmptyFixedSize() {
    let rowList = BsatnRowList(sizeHint: .fixedSize(4), rowsData: Data())
    let rows = rowList.splitRows()
    #expect(rows.isEmpty)
}

@Test func bsatnRowListEmptyOffsets() {
    let rowList = BsatnRowList(sizeHint: .rowOffsets([]), rowsData: Data())
    let rows = rowList.splitRows()
    #expect(rows.isEmpty)
}

// MARK: - ReducerOutcome encoding

@Test func reducerOutcomeOkEmptyRoundTrip() throws {
    let outcome = ReducerOutcome.okEmpty
    let data = try BSATN.encode(outcome)
    #expect(data.count == 1)
    #expect(data[data.startIndex] == 1)
    let decoded = try BSATN.decode(ReducerOutcome.self, from: data)
    #expect(decoded == outcome)
}

@Test func reducerOutcomeInternalErrorRoundTrip() throws {
    let outcome = ReducerOutcome.internalError("something went wrong")
    let data = try BSATN.encode(outcome)
    #expect(data[data.startIndex] == 3) // tag 3
    let decoded = try BSATN.decode(ReducerOutcome.self, from: data)
    #expect(decoded == outcome)
}

// MARK: - QuerySetId encoding

@Test func querySetIdRoundTrip() throws {
    let qsid = QuerySetId(id: 42)
    let data = try BSATN.encode(qsid)
    #expect(data.count == 4) // u32
    let decoded = try BSATN.decode(QuerySetId.self, from: data)
    #expect(decoded == qsid)
}
