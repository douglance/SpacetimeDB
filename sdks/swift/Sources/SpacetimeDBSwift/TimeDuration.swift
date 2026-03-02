/// A duration of time, represented as microseconds.
public struct TimeDuration: Codable, Equatable, Comparable, Sendable {
    public var microseconds: Int64

    public init(microseconds: Int64) {
        self.microseconds = microseconds
    }

    public static func < (lhs: TimeDuration, rhs: TimeDuration) -> Bool {
        lhs.microseconds < rhs.microseconds
    }
}
