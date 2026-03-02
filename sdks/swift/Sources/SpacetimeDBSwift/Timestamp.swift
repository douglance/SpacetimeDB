/// A point in time, represented as microseconds since the Unix epoch.
public struct Timestamp: Codable, Equatable, Comparable, Sendable {
    public var microseconds: Int64

    public init(microseconds: Int64) {
        self.microseconds = microseconds
    }

    public static func < (lhs: Timestamp, rhs: Timestamp) -> Bool {
        lhs.microseconds < rhs.microseconds
    }
}
