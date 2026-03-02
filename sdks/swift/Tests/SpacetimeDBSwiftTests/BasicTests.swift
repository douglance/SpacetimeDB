import Foundation
import Testing
@testable import SpacetimeDBSwift

@Test func identityCreation() {
    let identity = Identity(data: Data(repeating: 0, count: 32))
    #expect(identity.data.count == 32)
}

@Test func connectionIdCreation() {
    let connectionId = ConnectionId(data: Data(repeating: 0, count: 16))
    #expect(connectionId.data.count == 16)
}

@Test func timestampComparable() {
    let t1 = Timestamp(microseconds: 100)
    let t2 = Timestamp(microseconds: 200)
    #expect(t1 < t2)
}

@Test func scheduleAtEnumCases() {
    let byTime = ScheduleAt.time(Timestamp(microseconds: 1000))
    let byInterval = ScheduleAt.interval(TimeDuration(microseconds: 5000))
    #expect(byTime != byInterval)
}

@Test func tableProtocolExists() {
    // Verify the protocol compiles correctly
    struct TestRow: SpacetimeDBTable {
        static var tableName: String { "test" }
        static var primaryKey: String? { "id" }
        var id: Int32
    }
    #expect(TestRow.tableName == "test")
    #expect(TestRow.primaryKey == "id")
}

@Test func bigIntegerTypes() {
    let i256 = I256(data: Data(repeating: 0, count: 32))
    let u256 = U256(data: Data(repeating: 0, count: 32))
    #expect(i256.data.count == 32)
    #expect(u256.data.count == 32)
}
