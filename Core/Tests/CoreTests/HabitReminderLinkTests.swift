import Core
import Foundation
import Testing

@Suite struct HabitReminderLinkTests {
    // Monday Oct 19, 2026 starts the week; today is Friday Oct 23.
    let today = Day(year: 2026, month: 10, day: 23)
    func day(_ month: Int, _ day: Int) -> Day { Day(year: 2026, month: month, day: day) }

    let lists = [ReminderList(id: "daily", title: "Repetitive Tasks"), ReminderList(id: "admin", title: "Admin")]

    func daily(_ title: String, id: String? = nil, list: String = "daily", due: Day) -> Reminder {
        Reminder(id: id ?? title, title: title, listID: list, due: ReminderDue(day: due), repeatsDaily: true)
    }

    func habit(_ title: String, linkedTo reminder: Reminder? = nil, checkIns: [Day] = [], archived: Bool = false) -> Habit {
        var habit = Habit(title: title, perWeek: 5, startedOn: day(9, 7), checkIns: checkIns, archived: archived)
        habit.reminder = reminder.map { HabitReminder(id: $0.id, title: $0.title, listID: $0.listID) }
        return habit
    }

    @Test func linkedRemindersAreLeftOutOfTheAgendaAndArchivedHabitsLetThemBack() {
        let french = daily("Practise French", due: today)
        let pills = daily("Take supplements", due: today)
        let stretch = daily("Stretch", due: today)
        let habits = [habit("French", linkedTo: french), habit("Supplements", linkedTo: pills, archived: true)]
        let linked = HabitReminderLink.linkedIDs(habits, reminders: [french, pills, stretch])
        #expect(linked == ["Practise French"])

        let agenda = ReminderAgenda(reminders: [french, pills, stretch], lists: lists, linked: linked, today: today)
        #expect(agenda.everyDay.map(\.title) == ["Stretch", "Take supplements"])
    }

    @Test func aLinkFindsItsReminderByIDThenByTheOneDailyRepeatWithItsTitle() {
        let french = daily("Practise French", id: "new-id", due: today)
        var link = HabitReminder(id: "old-id", title: "practise french ", listID: "daily")
        // The ID changed (an iCloud resync): the one daily repeat with that title is it.
        #expect(HabitReminderLink.find(link, in: [french, daily("Stretch", due: today)])?.id == "new-id")

        // Two with that title: the one in the same list.
        let elsewhere = daily("Practise French", id: "other", list: "admin", due: today)
        #expect(HabitReminderLink.find(link, in: [elsewhere, french])?.id == "new-id")
        link.listID = "gone"
        #expect(HabitReminderLink.find(link, in: [elsewhere, french]) == nil)

        // Never a one-off reminder with the same title.
        let oneOff = Reminder(id: "x", title: "Practise French", listID: "daily", due: ReminderDue(day: today))
        #expect(HabitReminderLink.find(link, in: [oneOff]) == nil)
        #expect(HabitReminderLink.find(HabitReminder(id: "x", title: "", listID: ""), in: [oneOff]) == nil)
    }

    @Test func candidatesAreDailyRepeatsNotLinkedToAnotherHabit() {
        let french = daily("Practise French", due: today)
        let pills = daily("Take supplements", due: today)
        let oneOff = Reminder(id: "call", title: "Call the dentist", listID: "admin", due: ReminderDue(day: today))
        let mine = habit("French", linkedTo: french)
        let others = [mine, habit("Supplements", linkedTo: pills), habit("Gym")]
        let reminders = [pills, oneOff, french, daily("Stretch", due: today)]
        #expect(
            HabitReminderLink.candidates(for: mine, among: others, reminders: reminders).map(\.title)
                == ["Practise French", "Stretch"])
        // Its own reminder stays on offer even if another habit claims it too.
        let twice = others + [habit("Lessons", linkedTo: french)]
        #expect(
            HabitReminderLink.candidates(for: mine, among: twice, reminders: reminders).map(\.title)
                == ["Practise French", "Stretch"])
    }

    @Test func tickingTodayTicksOffTheReminderOnlyWhenItIsStillToDo() {
        let french = daily("Practise French", due: today)
        let linked = habit("French", linkedTo: french)

        let ticked = HabitReminderLink.toggle(linked, on: today, reminders: [french], today: today)
        #expect(ticked.habit.checkIns == [today])
        #expect(ticked.complete == ReminderCompletion(id: "Practise French", moveToToday: false))

        // Unticking takes back only the check-in: Reminders can't undo a repeat.
        let unticked = HabitReminderLink.toggle(ticked.habit, on: today, reminders: [french], today: today)
        #expect(unticked.habit.checkIns.isEmpty)
        #expect(unticked.complete == nil)

        // Already done today in Reminders (next due tomorrow), or a past day: Reminders is left alone.
        let done = daily("Practise French", due: day(10, 24))
        #expect(HabitReminderLink.toggle(linked, on: today, reminders: [done], today: today).complete == nil)
        let past = HabitReminderLink.toggle(linked, on: day(10, 21), reminders: [french], today: today)
        #expect(past.habit.checkIns == [day(10, 21)])
        #expect(past.complete == nil)

        // Days behind: it's moved to today first, so ticking it lands on tomorrow.
        let behind = daily("Practise French", due: day(10, 20))
        #expect(
            HabitReminderLink.toggle(linked, on: today, reminders: [behind], today: today).complete
                == ReminderCompletion(id: "Practise French", moveToToday: true))

        // A habit with no link just toggles.
        let plain = HabitReminderLink.toggle(habit("Gym"), on: today, reminders: [french], today: today)
        #expect(plain.habit.checkIns == [today])
        #expect(plain.complete == nil)
    }

    func done(_ title: String, on day: Day, id: String = "copy", list: String = "daily") -> CompletedReminder {
        CompletedReminder(id: id, title: title, listID: list, day: day)
    }

    @Test func ticksInRemindersAreCarriedOverOnceAndAnUntickSticks() {
        let french = daily("Practise French", due: day(10, 24))  // done today, due again tomorrow
        let linked = habit("French", linkedTo: french, checkIns: [day(10, 19)])
        // Ticked on their phone Tuesday and Wednesday while Compass was closed; Monday was ticked here already.
        let completed = [
            done("Practise French", on: day(10, 20)), done("practise french", on: day(10, 21)),
            done("Practise French", on: day(10, 19)),
            done("Practise French", on: day(10, 22), list: "admin"), done("Stretch", on: day(10, 22))
        ]
        let carried = HabitReminderLink.carryOver(linked, reminders: [french], completed: completed, today: today)
        #expect(carried.checkIns == [day(10, 19), day(10, 20), day(10, 21), today])
        #expect(carried.reminder?.settled == [day(10, 19), day(10, 20), day(10, 21), today])

        // Carrying again adds nothing, and a day they untick afterwards stays unticked.
        let unticked = HabitReminderLink.toggle(carried, on: day(10, 20), reminders: [french], today: today).habit
        #expect(HabitReminderLink.carryOver(unticked, reminders: [french], completed: completed, today: today) == unticked)
    }

    @Test func carryingOverSkipsDaysBeforeTheHabitAndFollowsARenamedReminder() {
        let renamed = daily("French lesson", id: "Practise French", due: today)
        var linked = habit("French", linkedTo: daily("Practise French", due: today))
        linked.startedOn = today
        // Thursday's in the habit's first week, so it counts; last Saturday is before it.
        let completed = [done("French lesson", on: day(10, 22), id: "Practise French"), done("French lesson", on: day(10, 17))]
        let carried = HabitReminderLink.carryOver(linked, reminders: [renamed], completed: completed, today: today)
        #expect(carried.checkIns == [day(10, 22)])
        #expect(
            carried.reminder
                == HabitReminder(
                    id: "Practise French", title: "French lesson", listID: "daily",
                    settled: [day(10, 22)]))

        // Not due today and not done: nothing to carry.
        let plain = habit("Gym")
        #expect(HabitReminderLink.carryOver(plain, reminders: [renamed], completed: completed, today: today) == plain)
    }

    @Test func everyDailyRepeatWithoutAHabitBecomesOneWithItsTicksFromTheLastThreeMonths() {
        let french = daily("Practise French", due: day(10, 24))  // done today
        let pills = daily("Take supplements", due: day(10, 22))  // two days behind
        let stretch = daily("Stretch", due: today)
        let gym = daily("Gym", due: today)
        let oneOff = Reminder(id: "call", title: "Call the dentist", listID: "admin", due: ReminderDue(day: today))
        // Stretch already has a habit, and Gym's was archived: neither gets another.
        let habits = [habit("Stretching", linkedTo: stretch), habit("Gym", linkedTo: gym, archived: true)]
        let completed = [
            done("Practise French", on: day(8, 3)), done("Practise French", on: day(10, 20)),
            done("Practise French", on: day(7, 1))
        ]  // older than three months
        let made = HabitReminderLink.newHabits(
            for: [french, pills, stretch, gym, oneOff], habits: habits,
            completed: completed, today: today)

        #expect(made.map(\.title) == ["Practise French", "Take supplements"])
        #expect(made.allSatisfy { $0.perWeek == 7 && $0.reminder != nil })
        // French starts the week of its oldest tick still in reach, with each tick since and today's.
        #expect(made[0].startedOn == day(8, 3))
        #expect(made[0].checkIns == [day(8, 3), day(10, 20), today])
        #expect(made[0].reminder?.id == "Practise French")
        // Supplements has no ticks to bring: it starts today.
        #expect(made[1].startedOn == today && made[1].checkIns.isEmpty)

        // Once made, nothing more is.
        #expect(
            HabitReminderLink.newHabits(
                for: [french, pills], habits: habits + made, completed: completed,
                today: today
            ).isEmpty)
    }
}
