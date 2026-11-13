import Foundation

/// A calendar day with no time or zone attached. Balances are recorded per day,
/// and a day's identity must not shift when the Mac changes time zone.
public struct Day: Hashable, Comparable, Codable, Sendable {
    /// Days since 2001-01-01, so the next day is plain addition.
    public let ordinal: Int

    public init(ordinal: Int) {
        self.ordinal = ordinal
    }

    public init(year: Int, month: Int, day: Int) {
        let date = Self.utc.date(from: DateComponents(year: year, month: month, day: day))!
        ordinal = Int((date.timeIntervalSinceReferenceDate / 86_400).rounded(.down))
    }

    /// The day `date` falls on in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// The start of this day in `timeZone`, for handing to a chart axis.
    public func startDate(in timeZone: TimeZone) -> Date {
        let parts = components
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: parts)!
    }

    public var year: Int { components.year! }
    public var month: Int { components.month! }
    public var dayOfMonth: Int { components.day! }

    /// The same day of the month `months` months away, clamped to the month's
    /// last day (Mar 31 minus one month is Feb 28).
    public func addingMonths(_ months: Int) -> Day {
        let moved = Self.utc.date(byAdding: .month, value: months, to: utcMidnight)!
        return Day(moved, in: Self.utc.timeZone)
    }

    private var utcMidnight: Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(ordinal) * 86_400)
    }

    private var components: DateComponents {
        Self.utc.dateComponents([.year, .month, .day], from: utcMidnight)
    }

    public static func < (lhs: Day, rhs: Day) -> Bool {
        lhs.ordinal < rhs.ordinal
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
