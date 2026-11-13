import Core
import Foundation
import Testing

@Suite struct FreeTimeTests {
    let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    func event(_ start: Double, _ end: Double, allDay: Bool = false, calendar: String = "home") -> CalendarEvent {
        CalendarEvent(id: "\(start)-\(end)", title: "E", calendarID: calendar, start: at(start), end: at(end), isAllDay: allDay)
    }

    func gaps(
        _ events: [CalendarEvent], from: Double = 0, to: Double = 10, minimum: Double = 0,
        hidden: Set<String> = []
    ) -> [[Double]] {
        FreeTime.gaps(events: events, from: at(from), to: at(to), minimum: minimum * 3600, hidden: hidden)
            .map { [$0.start.timeIntervalSince(base) / 3600, $0.end.timeIntervalSince(base) / 3600] }
    }

    @Test func theGapsBetweenEventsInTheRange() {
        #expect(gaps([event(2, 3), event(5, 6)]) == [[0, 2], [3, 5], [6, 10]])
        #expect(gaps([]) == [[0, 10]])
    }

    @Test func overlappingEventsBlockTogether() {
        #expect(gaps([event(2, 4), event(3, 5), event(3.5, 4)]) == [[0, 2], [5, 10]])
    }

    @Test func backToBackEventsLeaveNoGap() {
        #expect(gaps([event(2, 3), event(3, 4)]) == [[0, 2], [4, 10]])
    }

    @Test func eventsReachingPastTheRangeAreClipped() {
        #expect(gaps([event(-1, 1), event(9, 12)]) == [[1, 9]])
    }

    @Test func gapsShorterThanTheMinimumAreLeftOut() {
        #expect(gaps([event(2, 3), event(3.5, 6)], minimum: 1) == [[0, 2], [6, 10]])
        // Exactly the minimum is long enough.
        #expect(gaps([event(1, 9)], minimum: 1) == [[0, 1], [9, 10]])
    }

    @Test func allDayEventsAndHiddenCalendarsDoNotBlockTime() {
        // A birthday or a holiday doesn't make them busy.
        #expect(gaps([event(0, 24, allDay: true), event(2, 3, calendar: "work")], hidden: ["work"]) == [[0, 10]])
    }
}
