import Core
import Testing

@Suite struct HabitTrendsTests {
    // Wednesday Oct 28, 2026; the week started Monday Oct 26.
    let today = Day(year: 2026, month: 10, day: 28)
    func day(_ month: Int, _ day: Int) -> Day { Day(year: 2026, month: month, day: day) }

    func daily(startedOn: Day, done: [Day]) -> Habit {
        Habit(title: "Meditate", perWeek: 7, startedOn: startedOn, checkIns: done)
    }

    @Test func aStreakRunsToTodayOrToYesterdayWhileTodayIsStillOpen() {
        // Five days running up to yesterday, and an older run of seven.
        let older = (10...16).map { day(10, $0) }
        let recent = (23...27).map { day(10, $0) }
        let habit = daily(startedOn: day(10, 1), done: older + recent)
        #expect(HabitTrends.dayStreak(habit, today: today) == DayStreak(current: 5, best: 7))
        // Ticking today adds to it.
        #expect(HabitTrends.dayStreak(Habits.toggle(habit, on: today), today: today).current == 6)
        // A gap yesterday ends it, even with today open.
        let broken = daily(startedOn: day(10, 1), done: [day(10, 25), day(10, 26)])
        #expect(HabitTrends.dayStreak(broken, today: today) == DayStreak(current: 0, best: 2))
    }

    @Test func consistencyCountsDaysSinceTheHabitStartedAndTodayOnlyOnceDone() {
        // Started Thursday Oct 22: seven days, today still open, so six count. Done on four of them.
        let habit = daily(startedOn: day(10, 22), done: [day(10, 22), day(10, 24), day(10, 25), day(10, 27)])
        #expect(HabitTrends.consistency(habit, days: 30, today: today) == Tally(done: 4, of: 6))
        // Today done: seven of seven count.
        #expect(HabitTrends.consistency(Habits.toggle(habit, on: today), days: 30, today: today) == Tally(done: 5, of: 7))
        // The last three days only: Oct 26 and 27 count, today's still open.
        #expect(HabitTrends.consistency(habit, days: 3, today: today) == Tally(done: 1, of: 2))
        // A habit starting today with nothing done yet has nothing to count.
        #expect(HabitTrends.consistency(daily(startedOn: today, done: []), days: 30, today: today) == Tally(done: 0, of: 0))
    }

    @Test func aDayAcrossHabitsCountsTheOnesStartedByThenAndNotArchived() {
        let meditate = daily(startedOn: day(10, 1), done: [day(10, 20), day(10, 27)])
        let read = daily(startedOn: day(10, 21), done: [day(10, 21), day(10, 27)])
        var gone = daily(startedOn: day(10, 1), done: [day(10, 20), day(10, 27)])
        gone.archived = true
        let habits = [meditate, read, gone]
        // Before Read started, only Meditate counts.
        #expect(HabitTrends.allHabits(habits, on: day(10, 20)) == Tally(done: 1, of: 1))
        #expect(HabitTrends.allHabits(habits, on: day(10, 21)) == Tally(done: 1, of: 2))
        #expect(HabitTrends.allHabits(habits, on: day(10, 27)) == Tally(done: 2, of: 2))
        #expect(HabitTrends.allHabits(habits, on: day(9, 30)) == Tally(done: 0, of: 0))
    }
}
