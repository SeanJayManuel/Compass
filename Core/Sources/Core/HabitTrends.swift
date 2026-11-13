import Foundation

/// Days in a row a habit was done.
public struct DayStreak: Hashable, Sendable {
    /// Up to today, or up to yesterday while today is still open.
    public var current: Int
    /// The longest run so far.
    public var best: Int

    public init(current: Int, best: Int) {
        self.current = current
        self.best = best
    }
}

/// Days done out of the days that count.
public struct Tally: Hashable, Sendable {
    public var done: Int
    public var of: Int

    public init(done: Int, of: Int) {
        self.done = done
        self.of = of
    }

    /// From 0 to 1; nil with nothing to count.
    public var fraction: Double? { of == 0 ? nil : Double(done) / Double(of) }
}

/// How a habit has gone over time, day by day, for the Habits screen: the
/// momentum on top of `Habits`' weekly results.
public enum HabitTrends {
    public static func dayStreak(_ habit: Habit, today: Day) -> DayStreak {
        let done = Set(habit.checkIns.filter { $0 <= today }.map(\.ordinal))
        var best = 0, run = 0, previous: Int?
        for ordinal in done.sorted() {
            run = previous == ordinal - 1 ? run + 1 : 1
            best = max(best, run)
            previous = ordinal
        }
        var current = 0
        var ordinal = done.contains(today.ordinal) ? today.ordinal : today.ordinal - 1
        while done.contains(ordinal) {
            current += 1
            ordinal -= 1
        }
        return DayStreak(current: current, best: best)
    }

    /// Days done in the last `days` days, today included. Days before the
    /// habit started don't count, and today counts only once it's done:
    /// until then it's still open, not missed.
    public static func consistency(_ habit: Habit, days: Int, today: Day) -> Tally {
        countedDays(habit, days: days, today: today).reduce(into: Tally(done: 0, of: 0)) { tally, day in
            tally.of += 1
            if day.done { tally.done += 1 }
        }
    }

    /// One day across all their habits: how many were done, of those started
    /// by then and still tracked. The shade of that day's square.
    public static func allHabits(_ habits: [Habit], on day: Day) -> Tally {
        let counted = habits.filter { !$0.archived && $0.startedOn <= day }
        return Tally(done: counted.filter { $0.checkIns.contains(day) }.count, of: counted.count)
    }

    /// Each day that counts in the last `days` days, oldest first, and whether it was done.
    static func countedDays(_ habit: Habit, days: Int, today: Day) -> [(day: Day, done: Bool)] {
        let done = Set(habit.checkIns)
        let first = max(today.ordinal - days + 1, habit.startedOn.ordinal)
        guard first <= today.ordinal else { return [] }
        return (first...today.ordinal).map { Day(ordinal: $0) }
            .filter { $0 != today || done.contains($0) }
            .map { ($0, done.contains($0)) }
    }
}
