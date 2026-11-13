import Core
import Foundation
import Testing

@Suite struct HabitsTests {
    // Sunday Oct 18, 2026 starts the current week; today is Tuesday Oct 20.
    let today = Day(year: 2026, month: 10, day: 20)
    func day(_ month: Int, _ day: Int) -> Day { Day(year: 2026, month: month, day: day) }

    func gym(_ checkIns: [Day], started: Day? = nil) -> Habit {
        Habit(title: "Work out", perWeek: 4, startedOn: started ?? day(9, 7), checkIns: checkIns)
    }

    @Test func weeksStartOnSunday() {
        // Oct 18, 2026 is a Sunday.
        #expect(Week(day(10, 20)).start == day(10, 18))
        #expect(Week(day(10, 24)).start == day(10, 18))
        #expect(Week(day(10, 24)).end == day(10, 24))
        #expect(Week(day(10, 25)).start == day(10, 25))
        #expect(Week(day(10, 18)).previous.start == day(10, 11))
    }

    @Test func weekdaysListFromSunday() {
        // Compass numbers weekdays from Monday (0) to Sunday (6).
        #expect(Week.weekdays == [6, 0, 1, 2, 3, 4, 5])
        #expect(Week.sorted([0, 3, 6]) == [6, 0, 3])
    }

    @Test func aWeekIsHitWhenItReachesTheTargetAndTheCurrentWeekIsStillInProgress() {
        let habit = gym([day(10, 12), day(10, 13), day(10, 15), day(10, 17), day(10, 19)])
        #expect(Habits.result(habit, week: Week(day(10, 12)), today: today) == .hit)
        #expect(Habits.result(habit, week: Week(day(10, 5)), today: today) == .missed)
        #expect(Habits.result(habit, week: Week(today), today: today) == .inProgress(done: 1))
    }

    @Test func twoCheckInsOnOneDayCountOnce() {
        var habit = gym([])
        habit = Habits.toggle(habit, on: day(10, 12))
        habit = Habits.toggle(habit, on: day(10, 13))
        habit = Habits.toggle(habit, on: day(10, 13))  // undo
        #expect(habit.checkIns == [day(10, 12)])
    }

    @Test func aHabitSavedWithARuleStillReads() {
        // Habits had a rule (no missed weeks, or never two misses in a row) until Nov 2, 2026.
        let stored =
            #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Work out","perWeek":4,"rule":"noRepeatMisses","startedOn":{"ordinal":740000},"checkIns":[],"archived":false}"#
        let habit = try? JSONDecoder().decode(Habit.self, from: Data(stored.utf8))
        #expect(habit?.title == "Work out" && habit?.perWeek == 4)
    }

    @Test func theStreakCountsHitWeeksBackFromTheLastFinishedWeek() {
        let fourDays: (Int, Int) -> [Day] = { month, start in (0..<4).map { Day(year: 2026, month: month, day: start + $0) } }
        let habit = gym(fourDays(9, 14) + fourDays(9, 28) + fourDays(10, 5) + fourDays(10, 12))
        #expect(Habits.streak(habit, today: today) == 3)
    }

    @Test func historyStartsWhenTheHabitDid() {
        let habit = gym([], started: day(10, 5))
        #expect(Habits.history(habit, weeks: 12, today: today).map(\.week.start) == [day(10, 4), day(10, 11), day(10, 18)])
    }

    @Test func aQuarterCountsTheWeeksHitOutOfItsFinishedWeeks() {
        let fourDays: (Int, Int) -> [Day] = { month, start in (0..<4).map { Day(year: 2026, month: month, day: start + $0) } }
        let habit = gym(fourDays(7, 6) + fourDays(7, 13) + fourDays(9, 28), started: day(7, 1))
        let q3 = Habits.weeksHit(habit, in: Quarter(year: 2026, quarter: 3), today: today)
        #expect(q3.hit == 3)
        #expect(q3.total == 13)
    }

    @Test func anyDayFromTheStartingWeeksSundayToTodayCanBeTicked() {
        // Added Wednesday Oct 14, after working out Sunday and Monday.
        let habit = gym([day(10, 5)], started: day(10, 14))
        #expect(Habits.canCheckIn(habit, on: day(10, 11), today: today))
        #expect(Habits.canCheckIn(habit, on: day(10, 12), today: today))
        #expect(Habits.canCheckIn(habit, on: day(10, 13), today: today))
        #expect(Habits.canCheckIn(habit, on: today, today: today))
        // Not tomorrow, nor the week before it started, unless it's a stray tick to undo.
        #expect(!Habits.canCheckIn(habit, on: day(10, 21), today: today))
        #expect(!Habits.canCheckIn(habit, on: day(10, 10), today: today))
        #expect(Habits.canCheckIn(habit, on: day(10, 5), today: today))
    }

    @Test func daysTickedBeforeAMidweekStartCountTowardThatWeek() {
        // Monday to Friday, with the habit added on Wednesday.
        let habit = gym(fourDays(from: day(10, 12)) + [day(10, 16)], started: day(10, 14))
        #expect(Habits.result(habit, week: Week(day(10, 12)), today: today) == .hit)
        #expect(Habits.streak(habit, today: today) == 1)
    }

    // A habit started midweek has fewer days in its first week.

    func fourDays(from start: Day) -> [Day] { (0..<4).map { Day(ordinal: start.ordinal + $0) } }

    @Test func aFirstWeekThatStartedAfterItsSundayIsNotMissed() {
        // Started Wednesday Oct 7 and done twice that week, then a full week.
        let habit = gym([day(10, 8), day(10, 9)] + fourDays(from: day(10, 12)), started: day(10, 7))
        #expect(Habits.result(habit, week: Week(day(10, 7)), today: today) == .notCounted)
        #expect(Habits.history(habit, weeks: 8, today: today).map(\.result) == [.notCounted, .hit, .inProgress(done: 0)])
    }

    @Test func aShortFirstWeekThatStillReachedTheTargetCountsAsHit() {
        // Started Wednesday Oct 7 and done Wednesday to Saturday, then a full week.
        let habit = gym(fourDays(from: day(10, 7)) + fourDays(from: day(10, 12)), started: day(10, 7))
        #expect(Habits.result(habit, week: Week(day(10, 7)), today: today) == .hit)
        #expect(Habits.streak(habit, today: today) == 2)
        let q4 = Habits.weeksHit(habit, in: Quarter(year: 2026, quarter: 4), today: today)
        #expect(q4.hit == 2)
        #expect(q4.total == 2)
    }

    @Test func aShortFirstWeekThatFellShortIsLeftOutOfTheQuarter() {
        // Started Wednesday Jul 8 and done twice that week, then two full weeks;
        // Q3 has 13 weeks starting in it, the first of them Jul 6.
        let habit = gym([day(7, 9), day(7, 10)] + fourDays(from: day(7, 13)) + fourDays(from: day(7, 20)), started: day(7, 8))
        let q3 = Habits.weeksHit(habit, in: Quarter(year: 2026, quarter: 3), today: today)
        #expect(q3.hit == 2)
        #expect(q3.total == 12)
    }

    // MARK: What's still to do this week

    @Test func twoOfFourOnAThursdayNeedsTwoMoreInThreeDays() {
        let habit = gym([day(10, 19), day(10, 21)])
        let left = Habits.stillToDo(habit, today: day(10, 22))
        #expect(left.needed == 2)
        #expect(left.daysLeft == 3)
    }

    @Test func aHabitThatHitItsTargetNeedsNothingMore() {
        let habit = gym(fourDays(from: day(10, 19)))
        #expect(Habits.stillToDo(habit, today: day(10, 22)).needed == 0)
        // Ticking extra days never makes the need negative.
        let extra = gym(fourDays(from: day(10, 19)) + [day(10, 23)])
        #expect(Habits.stillToDo(extra, today: day(10, 23)).needed == 0)
    }

    @Test func onSaturdayThereIsOneDayLeftEvenWhenTheTargetCantBeMet() {
        let left = Habits.stillToDo(gym([day(10, 19)]), today: day(10, 24))
        #expect(left.needed == 3)
        #expect(left.daysLeft == 1)
    }

    @Test func onlyThisWeeksCheckInsCount() {
        // Four last week do nothing for this one, and Sunday has all seven days left.
        let habit = gym(fourDays(from: day(10, 12)))
        let left = Habits.stillToDo(habit, today: day(10, 18))
        #expect(left.needed == 4)
        #expect(left.daysLeft == 7)
    }

    @Test func aHabitStartedMidweekKeepsTheFullTargetAndCountsDaysTickedBeforeItsStart() {
        // Added Wednesday Oct 21; Monday's workout was done before adding it.
        let habit = gym([day(10, 19), day(10, 21)], started: day(10, 21))
        let left = Habits.stillToDo(habit, today: day(10, 22))
        #expect(left.needed == 2)
        #expect(left.daysLeft == 3)
    }

    @Test func aHabitThatStartsNextWeekHasNoDaysToDoItInThisWeek() {
        // Planned for Monday Oct 26: no day of this week can be ticked.
        let habit = gym([], started: day(10, 26))
        let left = Habits.stillToDo(habit, today: day(10, 22))
        #expect(left.needed == 4)
        #expect(left.daysLeft == 0)
    }
}
