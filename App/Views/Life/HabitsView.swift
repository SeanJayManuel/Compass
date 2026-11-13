import Core
import SwiftData
import SwiftUI

/// How consistent they've been: a grid of every day across all their habits,
/// shaded by how many they did, then each habit's run of days, its share of
/// the last 30 days and its weeks of squares. Ticking
/// stays on the Life overview; this is for keeping the momentum in view.
struct HabitsView: View {
    @Query(sort: \HabitRecord.createdAt) private var records: [HabitRecord]

    private var today: Day { Day(.now, in: .current) }

    var body: some View {
        let habits = records.compactMap(\.habit).filter { !$0.archived }
        let todayTally = HabitTrends.allHabits(habits, on: today)
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if !habits.isEmpty {
                        Text("\(todayTally.done) of \(todayTally.of) done today")
                            .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                    }
                }
                if habits.isEmpty {
                    Text(
                        "Each daily reminder becomes a habit here once Compass can see Reminders. You can add one of your own with New Habit on the Life overview."
                    )
                    .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    AllHabitsCard(habits: habits, today: today)
                    MasonryColumns(minimum: 330 * TextSize.current.scale, spacing: Spacing.m) {
                        ForEach(habits) { HabitTrendCard(habit: $0, today: today) }
                    }
                }
            }
            .screenColumn()
        }
        .background(Palette.canvas)
        .perfMark("screen.habits")
    }
}

/// Every day since their first habit began, up to a year (or as many weeks as
/// fit): the darker the square, the more of them they did.
private struct AllHabitsCard: View {
    let habits: [Habit]
    let today: Day

    var body: some View {
        let start = habits.map { min($0.startedOn, $0.checkIns.first ?? $0.startedOn) }.min() ?? today
        let weeks = DayGrid.weeks(since: start, today: today, upTo: 52)
        let first = Week(today).start.ordinal - (weeks - 1) * 7
        let days = (first...today.ordinal).map { Day(ordinal: $0) }
        let complete = days.filter { day in
            let tally = HabitTrends.allHabits(habits, on: day)
            return tally.of > 0 && tally.done == tally.of
        }.count
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Every habit").font(Typeface.section).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.s)
                Text(complete == 1 ? "1 day with all of them done" : "\(complete) days with all of them done")
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            // All of it when there's room, else the most recent weeks that fit.
            ViewThatFits(in: .horizontal) {
                ForEach(Array(Set([weeks, min(weeks, 39), min(weeks, 26), min(weeks, 13)])).sorted(by: >), id: \.self) { weeks in
                    DayGrid(weeks: weeks, today: today, cell: 14) { day in
                        let tally = HabitTrends.allHabits(habits, on: day)
                        return tally.of == 0 ? nil : (tally.fraction ?? 0, "\(tally.done) of \(tally.of)")
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Every habit done on \(complete) days in the last \(weeks) weeks")
            // The shade's key, as a tooltip rather than a legend row.
            .help("Darker green: more of your habits done that day. Hover a day for its count.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Spacing.l)
    }
}

/// One habit: its run of days and its share of the last 30 (for a habit
/// done a few times a week, its run of weeks and the quarter's weeks hit),
/// and its weeks since it began, up to 13.
private struct HabitTrendCard: View {
    let habit: Habit
    let today: Day

    var body: some View {
        let streak = HabitTrends.dayStreak(habit, today: today)
        let month = HabitTrends.consistency(habit, days: 30, today: today)
        let done = Set(habit.checkIns)
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                RowMark(text: habit.title, symbol: HabitIcon.symbol(for: habit.title))
                Text(habit.title).font(Typeface.section).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
                if habit.perWeek >= 7 {
                    figure(
                        "\(streak.current)", streak.current == 1 ? "day in a row" : "days in a row",
                        detail: streak.best > streak.current ? "Best \(streak.best)" : nil)
                    if let fraction = month.fraction {
                        figure(
                            "\(Int((fraction * 100).rounded()))%",
                            "of the last \(month.of) \(month.of == 1 ? "day" : "days")", detail: "\(month.done) done")
                    }
                } else {
                    let weeks = Habits.streak(habit, today: today)
                    let quarter = Habits.weeksHit(habit, in: Quarter(today), today: today)
                    figure(
                        "\(weeks)", weeks == 1 ? "week in a row" : "weeks in a row",
                        detail: "\(habit.perWeek) times a week")
                    if quarter.total > 0 {
                        figure("\(quarter.hit) of \(quarter.total)", "weeks hit this quarter", detail: nil)
                    }
                }
            }
            DayGrid(weeks: DayGrid.weeks(since: habit.startedOn, today: today, upTo: 13), today: today, cell: 12) { day in
                guard day >= habit.startedOn || done.contains(day) else { return nil }
                return (done.contains(day) ? 1 : 0, done.contains(day) ? "Done" : "Not done")
            }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Spacing.l)
    }

    private func figure(_ value: String, _ label: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Typeface.figure).monospacedDigit().foregroundStyle(Palette.ink)
            Text(label).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            if let detail {
                Text(detail).font(Typeface.caption).foregroundStyle(Palette.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Weeks as columns, Sunday at the top, ending with this week, with each
/// month named over the week it starts in and M, W and F down the side; days
/// after today aren't drawn. `shade` gives a day's share done and its help
/// text, or nil for a day that doesn't count (before the habit began).
private struct DayGrid: View {
    let weeks: Int
    let today: Day
    let cell: CGFloat
    let shade: (Day) -> (Double, String)?

    var body: some View {
        let size = cell * TextSize.current.scale
        let first = Week(today).start.ordinal - (weeks - 1) * 7
        let months = monthStarts(first: first)
        HStack(alignment: .top, spacing: 3) {
            VStack(alignment: .leading, spacing: 3) {
                label("")
                ForEach(["", "M", "", "W", "", "F", ""].indices, id: \.self) { row in
                    label(["", "M", "", "W", "", "F", ""][row]).frame(height: size)
                }
            }
            .padding(.trailing, 2)
            ForEach(0..<weeks, id: \.self) { column in
                VStack(spacing: 3) {
                    // Wider than its column, so it runs on over the next ones.
                    label(months[column] ?? "").fixedSize().frame(width: size, alignment: .leading)
                    ForEach(0..<7, id: \.self) { row in
                        let day = Day(ordinal: first + column * 7 + row)
                        if day > today {
                            Color.clear.frame(width: size, height: size)
                        } else if let (fraction, help) = shade(day) {
                            Self.square(fraction: fraction, size: cell)
                                .overlay {
                                    if day == today {
                                        RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.ink, lineWidth: 1)
                                    }
                                }
                                .help("\(day.startDate(in: .current).formatted(.dateTime.month(.abbreviated).day())): \(help)")
                        } else {
                            RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.rule, lineWidth: 1)
                                .frame(width: size, height: size)
                        }
                    }
                }
            }
        }
    }

    /// How many weeks to show for something that began on `start`: from its
    /// week to this one, at least 8 and at most `upTo`.
    static func weeks(since start: Day, today: Day, upTo: Int) -> Int {
        let since = (Week(today).start.ordinal - Week(start).start.ordinal) / 7 + 1
        return min(max(since, 8), upTo)
    }

    /// Month names by column: on the first column, and on each column whose
    /// week holds the 1st. The first column's is left off when the next
    /// month's name comes too soon to fit beside it.
    private func monthStarts(first: Int) -> [Int: String] {
        var names: [Int: String] = [:]
        for column in 0..<weeks {
            let sunday = Day(ordinal: first + column * 7)
            let saturday = Day(ordinal: sunday.ordinal + 6)
            if column == 0 || saturday.month != sunday.month || sunday.dayOfMonth == 1 {
                let day = column == 0 || sunday.dayOfMonth == 1 ? sunday : saturday
                names[column] = day.startDate(in: .current).formatted(.dateTime.month(.abbreviated))
            }
        }
        if names.keys.contains(where: { $0 > 0 && $0 <= 2 }) { names[0] = nil }
        return names
    }

    /// An empty label still takes a line's height (an empty Text has none),
    /// so a column with a month name over it lines up with one without.
    private func label(_ text: String) -> some View {
        Text(text.isEmpty ? " " : text).font(Typeface.caption).foregroundStyle(Palette.inkSecondary).lineLimit(1)
    }

    /// A day's square: the rule colour when nothing was done, deepening
    /// toward green as more was (done is good; the accent only marks what's
    /// selected).
    static func square(fraction: Double, size: CGFloat) -> some View {
        let side = size * TextSize.current.scale
        return RoundedRectangle(cornerRadius: 3)
            .fill(fraction > 0 ? Palette.onPace.opacity(0.3 + 0.7 * fraction) : Palette.rule)
            .frame(width: side, height: side)
    }
}
