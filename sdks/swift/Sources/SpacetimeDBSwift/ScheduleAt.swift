/// Represents a scheduled point in time or a recurring interval.
public enum ScheduleAt: Codable, Equatable, Sendable {
    case time(Timestamp)
    case interval(TimeDuration)
}
