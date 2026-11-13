import Foundation

/// The free stretches in a range: every gap between events. Compass sets no
/// booking hours; whoever asks judges which suit them.
public enum FreeTime {
    public struct Gap: Hashable, Sendable {
        public var start: Date
        public var end: Date
    }

    /// Gaps of at least `minimum` seconds between `from` and `to`. All-day
    /// events (birthdays, holidays) and hidden calendars don't block time.
    public static func gaps(
        events: [CalendarEvent], from: Date, to: Date, minimum: TimeInterval,
        hidden: Set<String> = []
    ) -> [Gap] {
        let busy = events.filter { !$0.isAllDay && !hidden.contains($0.calendarID) && $0.end > from && $0.start < to }
            .sorted { $0.start < $1.start }
        var gaps: [Gap] = []
        var cursor = from
        for event in busy {
            if event.start > cursor { gaps.append(Gap(start: cursor, end: event.start)) }
            cursor = max(cursor, event.end)
        }
        if cursor < to { gaps.append(Gap(start: cursor, end: to)) }
        return gaps.filter { $0.end.timeIntervalSince($0.start) >= minimum }
    }
}
