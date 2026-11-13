import Core
import Foundation
import Testing

/// Seams 26 and 26+: the week grid in the Life overview's "This week" card.
@Suite struct CalendarWeekTests {
    let zone = TimeZone(identifier: "America/New_York")!
    /// Sunday Nov 1 to Saturday Nov 7, 2026; clocks go back an hour early on Sunday.
    let week = Week(Day(year: 2026, month: 11, day: 4))

    /// A local time on a day counted from this week's Sunday (0), so 6 is Saturday Nov 7.
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 1 + day, hour: hour, minute: minute))!
    }

    func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false, calendar: String = "home") -> CalendarEvent {
        CalendarEvent(id: title, title: title, calendarID: calendar, start: start, end: end, isAllDay: allDay)
    }

    func grid(_ events: [CalendarEvent], hidden: Set<String> = []) -> CalendarWeek {
        CalendarWeek(events: events, hidden: hidden, week: week, timeZone: zone)
    }

    /// Each timed piece as title, day index, start and end minute.
    func pieces(_ grid: CalendarWeek) -> [String] {
        grid.timed.map { "\($0.event.title) \($0.day) \($0.startMinute)-\($0.endMinute)" }
    }

    @Test func theGridIsTheWholeSundayWeek() {
        let grid = grid([
            event("Last Saturday", at(-1, 9), at(-1, 10)), event("Sunday", at(0, 9), at(0, 10)),
            event("Saturday", at(6, 18), at(6, 19)), event("Next Sunday", at(7, 9), at(7, 10))
        ])
        #expect(grid.days.map(\.dayOfMonth) == [1, 2, 3, 4, 5, 6, 7])
        #expect(pieces(grid) == ["Sunday 0 540-600", "Saturday 6 1080-1140"])
    }

    @Test func timesAreTheClockOnTheDaylightSavingSunday() {
        // Sunday Nov 1 has 25 hours; 9 AM is still drawn at 9.
        let grid = grid([event("Brunch", at(0, 9), at(0, 10, 30))])
        #expect(pieces(grid) == ["Brunch 0 540-630"])
    }

    @Test func anEventPastMidnightShowsOnBothDays() {
        let grid = grid([event("Late show", at(4, 22), at(5, 1, 30)), event("Overnight", at(2, 20), at(3, 0))])
        #expect(pieces(grid) == ["Overnight 2 1200-1440", "Late show 4 1320-1440", "Late show 5 0-90"])
    }

    @Test func overlappingEventsSitSideBySide() {
        let grid = grid([
            event("Standup", at(1, 9), at(1, 10)), event("Call", at(1, 9, 30), at(1, 10, 30)),
            event("Lunch", at(1, 12), at(1, 13)), event("Review", at(1, 10), at(1, 11))
        ])
        let lanes = Dictionary(uniqueKeysWithValues: grid.timed.map { ($0.event.title, "\($0.lane)/\($0.lanes)") })
        // Standup, Call and Review overlap in a chain; Review takes Standup's lane once it ends.
        #expect(lanes == ["Standup": "0/2", "Call": "1/2", "Review": "0/2", "Lunch": "0/1"])
    }

    @Test func aShortEventGetsRoomButStaysAtItsTime() {
        // Shown at least 30 minutes tall, so the next one sits beside it rather than under its title.
        let grid = grid([event("Deadline", at(2, 17), at(2, 17)), event("Drinks", at(2, 17, 15), at(2, 18))])
        #expect(pieces(grid) == ["Deadline 2 1020-1050", "Drinks 2 1035-1080"])
        #expect(grid.timed.map(\.lanes) == [2, 2])
    }

    @Test func allDayEventsSpanTheirDaysInRows() {
        // EventKit ends an all-day event at 23:59:59 on its last day.
        let grid = grid([
            event("Trip", at(1, 0), at(3, 23, 59).addingTimeInterval(59), allDay: true),
            event("Birthday", at(2, 0), at(2, 23, 59), allDay: true),
            event("Halloween", at(5, 0), at(5, 23, 59), allDay: true),
            event("Conference", at(4, 9), at(6, 17))
        ])
        let spans = grid.allDay.map { "\($0.event.title) \($0.firstDay)-\($0.lastDay) row \($0.row)" }
        // A timed event a day or longer goes in the strip too, as Calendar draws it.
        #expect(spans == ["Trip 1-3 row 0", "Birthday 2-2 row 1", "Conference 4-6 row 0", "Halloween 5-5 row 1"])
        #expect(grid.allDayRows == 2 && grid.timed.isEmpty)
    }

    @Test func anAllDayEventFromLastWeekIsClippedToThisOne() {
        let grid = grid([event("Holiday", at(-3, 0), at(1, 23, 59), allDay: true)])
        #expect(grid.allDay.map { "\($0.firstDay)-\($0.lastDay)" } == ["0-1"])
    }

    @Test func theHoursAreEightToNineWidenedToFitTheWeek() {
        #expect(grid([]).hours == 8..<21)
        #expect(grid([event("Run", at(3, 6, 30), at(3, 7, 30)), event("Late call", at(4, 21, 15), at(4, 22, 5))]).hours == 6..<23)
        #expect(grid([event("Late show", at(4, 22), at(5, 1, 30))]).hours == 0..<24)
    }

    @Test func hiddenCalendarsAreLeftOut() {
        let grid = grid([event("Standup", at(2, 9), at(2, 10), calendar: "work"), event("Gym", at(2, 7), at(2, 8))], hidden: ["work"])
        #expect(pieces(grid) == ["Gym 2 420-480"])
    }
}
