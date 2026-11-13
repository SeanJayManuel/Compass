import AppKit
import Core
import SwiftUI

/// This week at the top of the life overview, as the Workbench draft: a
/// tile a day with its events as small chips (all-day ones
/// first, then by start time), today outlined. Hidden when Calendar is off.
struct WeekBand: View {
    let today: Day
    @Environment(CalendarService.self) private var calendar
    @AppStorage(CalendarLists.hiddenKey) private var hiddenCalendars = ""

    var body: some View {
        let week = CalendarWeek(
            events: calendar.events, hidden: CalendarLists.hidden(hiddenCalendars),
            week: Week(today), timeZone: .current)
        if calendar.access != .denied {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text("This week").font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text(range(of: Week(today))).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
                switch calendar.access {
                case .notAsked:
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        Text("See this week's events here.").font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                        Spacer(minLength: Spacing.s)
                        Button("Show Calendar") { Task { await calendar.requestAccess() } }
                    }
                default:
                    // Seven tiles when there's room; scrolled sideways when not.
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: Spacing.s) {
                            ForEach(Array(week.days.enumerated()), id: \.offset) { index, day in
                                DayTile(day: day, today: today, events: events(on: index, in: week))
                            }
                        }
                        .containerRelativeFrame(.horizontal) { width, _ in max(width, 7 * 112 * TextSize.current.scale) }
                    }
                    .scrollIndicators(.never)
                }
            }
            .card(padding: Spacing.m)
        }
    }

    /// The day's events: all-day ones (and those lasting days) first, then by start.
    private func events(on index: Int, in week: CalendarWeek) -> [CalendarEvent] {
        week.allDay.filter { index >= $0.firstDay && index <= $0.lastDay }.map(\.event)
            + week.timed.filter { $0.day == index }.map(\.event)
    }

    /// "Oct 19–25", or "Oct 26–Nov 1" when the week crosses a month.
    private func range(of week: Week) -> String {
        let start = week.start.startDate(in: .current).formatted(.dateTime.month(.abbreviated).day())
        let sameMonth = week.start.month == week.end.month
        let end = week.end.startDate(in: .current).formatted(sameMonth ? .dateTime.day() : .dateTime.month(.abbreviated).day())
        return "\(start)–\(end)"
    }
}

/// One day: its name and date, then its events as chips in their calendar's
/// colour. Clicking an event opens Calendar.
private struct DayTile: View {
    let day: Day
    let today: Day
    let events: [CalendarEvent]
    @Environment(CalendarService.self) private var calendar
    /// Enough to see the day without the tile growing past its neighbours.
    private static let shown = 4

    var body: some View {
        let isToday = day == today
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(day.startDate(in: .current).formatted(.dateTime.weekday(.abbreviated)))
                Spacer(minLength: 0)
                Text("\(day.dayOfMonth)").monospacedDigit()
                    .foregroundStyle(isToday ? Palette.needleText : Palette.inkSecondary)
                    .fontWeight(isToday ? .semibold : .regular)
            }
            .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            ForEach(events.prefix(Self.shown), id: \.id) { event in chip(event) }
            if events.count > Self.shown {
                Text("\(events.count - Self.shown) more").font(Typeface.caption).foregroundStyle(Palette.inkSecondary)
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, minHeight: 96 * TextSize.current.scale, alignment: .topLeading)
        .background(isToday ? Palette.hover : .clear, in: .rect(cornerRadius: Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(isToday ? Palette.inkSecondary.opacity(0.5) : Palette.rule, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.startDate(in: .current).formatted(.dateTime.weekday(.wide).month(.wide).day()))
    }

    private func chip(_ event: CalendarEvent) -> some View {
        let color = Color(nsColor: calendar.colors[event.calendarID] ?? .systemGray)
        let time = event.isAllDay ? "" : event.start.formatted(date: .omitted, time: .shortened)
        // The time on its own line, then the title on up to two, so neither
        // is cut to "Team planning 2:…".
        return Button {
            NSWorkspace.shared.open(URL(string: "ical://")!)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                if !time.isEmpty {
                    Text(time).foregroundStyle(Palette.inkSecondary).monospacedDigit().lineLimit(1)
                }
                Text(event.title).foregroundStyle(Palette.ink).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Typeface.caption)
            .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.selection, in: .rect(cornerRadius: 4))
            .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2).clipShape(.rect(cornerRadius: 1)) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(event.title)\(time.isEmpty ? "" : ", " + time) · opens Calendar")
    }
}
