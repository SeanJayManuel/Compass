import Core
import Foundation
import Testing

@Suite struct PlaybookTests {
    // Friday Oct 30, 2026.
    let today = Day(year: 2026, month: 10, day: 30)
    func day(_ month: Int, _ day: Int) -> Day { Day(year: 2026, month: month, day: day) }

    func nails(lastDone: Day?) -> PlaybookEntry {
        PlaybookEntry(area: "Grooming", kind: .pick, title: "Nails", repeatEveryDays: 10, lastDone: lastDone)
    }

    @Test func aRepeatIsDueItsIntervalAfterItWasLastDone() {
        #expect(Playbook.nextDue(nails(lastDone: day(10, 22)), today: today) == day(11, 1))
    }

    @Test func aRepeatNeverDoneIsDueToday() {
        #expect(Playbook.nextDue(nails(lastDone: nil), today: today) == today)
    }

    @Test func anOverdueRepeatKeepsItsDueDay() {
        #expect(Playbook.nextDue(nails(lastDone: day(10, 1)), today: today) == day(10, 11))
    }

    @Test func anEntryWithoutARepeatIsNeverDue() {
        let tee = PlaybookEntry(area: "Clothes", kind: .pick, title: "Plain tee")
        #expect(Playbook.nextDue(tee, today: today) == nil)
    }

    @Test func doingItMovesTheNextDueDay() {
        let done = Playbook.markDone(nails(lastDone: day(10, 1)), on: today)
        #expect(done.lastDone == today)
        #expect(Playbook.nextDue(done, today: today) == day(11, 9))
    }

    // Weekdays: 0 is Monday. Oct 30, 2026 is a Friday (4).
    let shampoo = PlaybookStep(text: "Shampoo, scalp only", weekdays: [0, 3])
    let conditioner = PlaybookStep(text: "Conditioner, ends only")
    var shower: PlaybookEntry {
        PlaybookEntry(area: "Hair", kind: .routine, title: "Shower", steps: [shampoo, conditioner])
    }

    @Test func weekdaysStartOnMonday() {
        #expect(Playbook.weekday(day(11, 2)) == 0)
        #expect(Playbook.weekday(today) == 4)
        #expect(Playbook.weekday(day(11, 1)) == 6)
    }

    @Test func aRoutineDayHoldsEveryDayStepsAndTodaysWeekdaySteps() {
        let friday = Playbook.routineDay(shower, on: today)
        #expect(friday.steps == [conditioner])
        let thursday = Playbook.routineDay(shower, on: day(10, 29))
        #expect(thursday.steps == [shampoo, conditioner])
    }

    @Test func aStepSkippedTodaySaysWhenItComesNext() {
        let friday = Playbook.routineDay(shower, on: today)
        #expect(friday.next == [Playbook.NextStep(step: shampoo, day: day(11, 2))])
        // Monday's shampoo comes back on Thursday.
        let monday = Playbook.routineDay(shower, on: day(11, 2))
        #expect(monday.next.isEmpty)
        let tuesday = Playbook.routineDay(shower, on: day(11, 3))
        #expect(tuesday.next == [Playbook.NextStep(step: shampoo, day: day(11, 5))])
    }

    @Test func aWorkoutSplitShowsOnlyTodaysDay() {
        let push = PlaybookStep(text: "Push: bench, overhead press, dips", weekdays: [0])
        let pull = PlaybookStep(text: "Pull: rows, pull-ups, curls", weekdays: [2])
        let legs = PlaybookStep(text: "Legs: squats, RDLs, calves", weekdays: [4])
        let split = PlaybookEntry(area: "Fitness", kind: .routine, title: "Workout", steps: [push, pull, legs])
        #expect(Playbook.routineDay(split, on: today).steps == [legs])
        // Saturday is a rest day; Monday's push is next.
        let saturday = Playbook.routineDay(split, on: day(10, 31))
        #expect(saturday.steps.isEmpty)
        #expect(saturday.next.first == Playbook.NextStep(step: push, day: day(11, 2)))
    }

    @Test func todayHoldsRoutinesAndRepeatsDueWithinTwoDays() {
        let skincare = PlaybookEntry(area: "Skin", kind: .routine, title: "Skincare", steps: [PlaybookStep(text: "Moisturise")])
        let haircut = PlaybookEntry(area: "Hair", kind: .pick, title: "Haircut", repeatEveryDays: 28, lastDone: day(10, 15))
        let toothbrush = PlaybookEntry(area: "Teeth", kind: .pick, title: "Toothbrush head", repeatEveryDays: 90, lastDone: day(8, 2))
        let overdue = PlaybookEntry(area: "Grooming", kind: .pick, title: "Razor blade", repeatEveryDays: 14, lastDone: day(10, 1))
        let entries = [shower, skincare, nails(lastDone: day(10, 22)), haircut, toothbrush, overdue]
        let line = Playbook.today(entries, today: today)
        // Skincare's steps are every day, so it shows every day.
        #expect(line.routines.map(\.entry.title) == ["Shower", "Skincare"])
        #expect(line.routines.first?.day.steps == [conditioner])
        // Razor (Oct 15, overdue), toothbrush (Oct 31), nails (Nov 1); the haircut (Nov 12) is too far off.
        #expect(line.due.map(\.entry.title) == ["Razor blade", "Toothbrush head", "Nails"])
        #expect(line.due.map(\.day) == [day(10, 15), day(10, 31), day(11, 1)])
    }

    @Test func aRepeatJoinsThisWeeksRemindersFromTheDayBeforeItsDue() {
        // Oct 31 is tomorrow, so nails and the toothbrush show, and the overdue razor; Nov 2's trim waits.
        let razor = PlaybookEntry(area: "Grooming", kind: .pick, title: "Razor blade", repeatEveryDays: 14, lastDone: day(10, 1))
        let toothbrush = PlaybookEntry(area: "Teeth", kind: .pick, title: "Toothbrush head", repeatEveryDays: 90, lastDone: day(8, 2))
        let later = PlaybookEntry(area: "Hair", kind: .pick, title: "Beard trim", repeatEveryDays: 7, lastDone: day(10, 26))
        let due = Playbook.dueForReminders([nails(lastDone: day(10, 21)), later, toothbrush, razor], today: today)
        #expect(due.map(\.entry.title) == ["Razor blade", "Nails", "Toothbrush head"])
        // Done today, nails move on and leave.
        #expect(Playbook.dueForReminders([Playbook.markDone(nails(lastDone: day(10, 21)), on: today)], today: today).isEmpty)
    }

    @Test func aRepeatingRoutineShowsOnlyWhenItsDue() {
        let clip = PlaybookEntry(
            area: "Grooming", kind: .routine, title: "Fingernails", steps: [PlaybookStep(text: "Clip straight across")],
            repeatEveryDays: 7, lastDone: day(10, 20))
        let line = Playbook.today([clip], today: today)
        #expect(line.routines.isEmpty)
        #expect(line.due.map(\.entry.title) == ["Fingernails"])
    }

    // Saturday Oct 31: a warm-up with nothing on Saturday, then a split.
    let saturdayOff = Day(year: 2026, month: 10, day: 31)
    var warmUp: PlaybookEntry {
        PlaybookEntry(
            area: "Fitness", kind: .routine, title: "Warm-up",
            steps: [
                PlaybookStep(text: "Easy bike or row, 2 min", weekdays: [0, 1]),
                PlaybookStep(text: "Cat-cow, 10 reps", weekdays: [0, 1]),
                PlaybookStep(text: "Glute bridges, 15 reps", weekdays: [0]),
                PlaybookStep(text: "Band pull-aparts", weekdays: [1])
            ])
    }

    @Test func aRoutineOffTodayPreviewsHowManyStepsAreNext() {
        let preview = Playbook.nextSession(warmUp, today: saturdayOff)
        #expect(preview == Playbook.NextSession(name: nil, steps: 3, day: day(11, 2)))
    }

    @Test func aRoutineOffTodayPreviewsANamedSessionByName() {
        let split = PlaybookEntry(
            area: "Fitness", kind: .routine, title: "Split",
            steps: [
                PlaybookStep(text: "Lower A: squat 4x5, RDL 3x8", weekdays: [0]),
                PlaybookStep(text: "Upper A: bench 4x5", weekdays: [1])
            ])
        #expect(Playbook.nextSession(split, today: saturdayOff) == Playbook.NextSession(name: "Lower A", steps: 1, day: day(11, 2)))
    }

    @Test func aRoutineWithStepsTodayHasNoPreview() {
        #expect(Playbook.nextSession(warmUp, today: day(11, 2)) == nil)
    }

    @Test func todayIsEmptyWithNothingScheduled() {
        let tee = PlaybookEntry(area: "Clothes", kind: .pick, title: "Plain tee", size: "M")
        let line = Playbook.today([tee], today: today)
        #expect(line.routines.isEmpty && line.due.isEmpty)
    }

    @Test func searchMatchesAnyWordIgnoringCaseAcrossWhatAnEntrySays() {
        let suit = PlaybookEntry(area: "Clothes", kind: .pick, title: "Suit", detail: "Suitsupply Lazio, navy", size: "38S")
        let tee = PlaybookEntry(area: "Clothes", kind: .pick, title: "Plain tee", source: "Uniqlo", notes: "Wash cold")
        #expect(Playbook.search([suit, tee, shower], "suit size").map(\.title) == ["Suit"])
        #expect(Playbook.search([suit, tee, shower], "UNIQLO").map(\.title) == ["Plain tee"])
        #expect(Playbook.search([suit, tee, shower], "shampoo").map(\.title) == ["Shower"])
        #expect(Playbook.search([suit, tee, shower], "clothes").map(\.title) == ["Suit", "Plain tee"])
        #expect(Playbook.search([suit, tee, shower], "  ").count == 3)
    }
}
