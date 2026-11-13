import Foundation

/// An event from Apple Calendar, as plain values.
public struct CalendarEvent: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var calendarID: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool

    public init(id: String, title: String, calendarID: String, start: Date, end: Date, isAllDay: Bool = false) {
        self.id = id
        self.title = title
        self.calendarID = calendarID
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }
}

/// This week's events laid out as Calendar's week view lays them out, for the
/// Life overview's "This week" card: seven days from Sunday, an all-day strip,
/// and timed events placed by the clock, overlapping ones side by side.
public struct CalendarWeek: Hashable, Sendable {
    /// An all-day event (or a timed one a day or longer) across the days it covers.
    public struct AllDay: Hashable, Sendable {
        public var event: CalendarEvent
        /// Indexes into `days`, clipped to this week.
        public var firstDay: Int
        public var lastDay: Int
        /// Its row in the strip, so spans never overlap.
        public var row: Int
    }

    /// A timed event's piece on one day.
    public struct Timed: Hashable, Sendable {
        public var event: CalendarEvent
        public var day: Int
        /// Minutes after midnight by the clock (a daylight-saving day still
        /// runs 0 to 1440), clipped to the day. A short event is given at
        /// least `shortest` minutes, so nothing is too thin to read.
        public var startMinute: Int
        public var endMinute: Int
        /// Its column among the events it overlaps, of `lanes`.
        public var lane: Int
        public var lanes: Int
    }

    /// The shortest an event is drawn, in minutes.
    public static let shortest = 30

    public var days: [Day]
    public var allDay: [AllDay] = []
    public var allDayRows = 0
    /// By day, then start, then title.
    public var timed: [Timed] = []
    /// The hours the grid shows: 8 AM to 9 PM, widened to fit the week.
    public var hours: Range<Int> = 8..<21

    public init(events: [CalendarEvent], hidden: Set<String>, week: Week, timeZone: TimeZone) {
        days = (0..<7).map { Day(ordinal: week.start.ordinal + $0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let shown = events.filter { !hidden.contains($0.calendarID) }
        let weekStart = week.start.startDate(in: timeZone)
        let weekEnd = Day(ordinal: week.end.ordinal + 1).startDate(in: timeZone)

        // The strip: all-day events, and timed ones a day or longer.
        var spans: [(event: CalendarEvent, first: Int, last: Int)] = []
        for event in shown where event.isAllDay || event.end.timeIntervalSince(event.start) >= 86_400 {
            guard event.start < weekEnd, event.end > weekStart else { continue }
            // EventKit ends an all-day event at 23:59:59, or at the next midnight.
            let first = Day(max(event.start, weekStart), in: timeZone).ordinal - week.start.ordinal
            let last = Day(min(event.end, weekEnd).addingTimeInterval(-1), in: timeZone).ordinal - week.start.ordinal
            spans.append((event, first, max(first, last)))
        }
        spans.sort { ($0.first, $1.last - $1.first, $0.event.title) < ($1.first, $0.last - $0.first, $1.event.title) }
        var rowEnds: [Int] = []
        for span in spans {
            let row = rowEnds.firstIndex { $0 < span.first } ?? rowEnds.count
            if row == rowEnds.count { rowEnds.append(span.last) } else { rowEnds[row] = span.last }
            allDay.append(AllDay(event: span.event, firstDay: span.first, lastDay: span.last, row: row))
        }
        allDayRows = rowEnds.count

        // Timed events, cut at midnight.
        for (index, day) in days.enumerated() {
            let start = day.startDate(in: timeZone)
            let end = Day(ordinal: day.ordinal + 1).startDate(in: timeZone)
            func minute(_ date: Date) -> Int {
                let clock = calendar.dateComponents([.hour, .minute], from: date)
                return clock.hour! * 60 + clock.minute!
            }
            var pieces: [Timed] = shown.compactMap { event in
                guard !event.isAllDay, event.end.timeIntervalSince(event.start) < 86_400 else { return nil }
                // A zero-length event still shows at its time.
                guard event.start < end, event.end > start || event.start == event.end && event.start >= start else { return nil }
                let from = event.start <= start ? 0 : minute(event.start)
                let to = event.end >= end ? 1440 : minute(event.end)
                let shown = min(max(to, from + Self.shortest), 1440)
                return Timed(event: event, day: index, startMinute: min(from, 1440 - Self.shortest), endMinute: shown, lane: 0, lanes: 1)
            }
            pieces.sort { ($0.startMinute, $1.endMinute, $0.event.title) < ($1.startMinute, $0.endMinute, $1.event.title) }
            Self.assignLanes(&pieces)
            timed += pieces
        }
        if let earliest = timed.map(\.startMinute).min(), let latest = timed.map(\.endMinute).max() {
            hours = min(8, earliest / 60)..<max(21, (latest + 59) / 60)
        }
    }

    /// Overlapping pieces share the width: each takes the first column free
    /// at its start, and every piece in a run of overlaps gets the run's count.
    private static func assignLanes(_ pieces: inout [Timed]) {
        var cluster: [Int] = []
        var laneEnds: [Int] = []
        var clusterEnd = -1
        func close() {
            for index in cluster { pieces[index].lanes = laneEnds.count }
            cluster = []
            laneEnds = []
        }
        for index in pieces.indices {
            if pieces[index].startMinute >= clusterEnd { close() }
            let lane = laneEnds.firstIndex { $0 <= pieces[index].startMinute } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(pieces[index].endMinute) } else { laneEnds[lane] = pieces[index].endMinute }
            pieces[index].lane = lane
            cluster.append(index)
            clusterEnd = max(clusterEnd, pieces[index].endMinute)
        }
        close()
    }
}
