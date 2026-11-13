import Core
import Foundation
import Testing

/// Seam 31: what Claude may change, what's refused, and how undo restores.
@Suite struct ClaudeChangesTests {
    // Friday Oct 23, 2026.
    let today = Day(year: 2026, month: 10, day: 23)
    func day(_ month: Int, _ day: Int) -> Day { Day(year: 2026, month: month, day: day) }

    let checking = Account(name: "Checking", accountClass: .cash, source: .manual)
    let savings = Account(name: "Savings", accountClass: .cash, source: .manual)
    let closed: Account = {
        var account = Account(name: "Old savings", accountClass: .cash, source: .manual)
        account.archivedOn = Day(year: 2026, month: 3, day: 1)
        return account
    }()

    func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let refusal as ClaudeRefusal { return refusal.message } catch { return "\(error)" }
    }

    // MARK: Goals

    @Test func aNewGoalIsValidatedLikeTheEditor() throws {
        let goal = try ClaudeRules.newGoal(
            name: "House fund", measures: .accounts([savings.id]), target: 60_000,
            targetMin: nil, targetDate: day(12, 31), accounts: [checking, savings])
        #expect(goal.kind == .accountTotal([savings.id]))
        #expect(goal.target == 60_000 && goal.targetDate == day(12, 31) && goal.status == .active)

        #expect(refusal { _ = try ClaudeRules.newGoal(name: " ", measures: .netWorth, target: 1, targetMin: nil, targetDate: nil, accounts: []) } != nil)
        #expect(refusal { _ = try ClaudeRules.newGoal(name: "A", measures: .netWorth, target: 0, targetMin: nil, targetDate: nil, accounts: []) } != nil)
        #expect(refusal { _ = try ClaudeRules.newGoal(name: "A", measures: .netWorth, target: 100, targetMin: 100, targetDate: nil, accounts: []) } != nil)
        #expect(refusal { _ = try ClaudeRules.newGoal(name: "A", measures: .accounts([]), target: 100, targetMin: nil, targetDate: nil, accounts: []) } != nil)
        #expect(
            refusal {
                _ = try ClaudeRules.newGoal(name: "A", measures: .accounts([closed.id]), target: 100, targetMin: nil, targetDate: nil, accounts: [closed])
            }?
            .contains("closed") == true)
        #expect(
            refusal {
                _ = try ClaudeRules.newGoal(
                    name: "A", measures: .fire(annualSpending: 0, multiplier: 25), target: nil, targetMin: nil, targetDate: nil, accounts: [])
            } != nil)
    }

    @Test func theEditorAndClaudeShareTheSameProblems() {
        #expect(Goal(name: "A", kind: .netWorth, target: 0).problem == .noTarget)
        #expect(Goal(name: "A", kind: .netWorth, target: 100, targetMin: 120).problem == .minimumNotBelowTarget)
        #expect(Goal(name: "A", kind: .accountTotal([]), target: 100).problem == .noAccounts)
        #expect(Goal(name: "A", kind: .fire(annualSpending: 0, multiplier: 25), target: 0).problem == .noSpending)
        #expect(Goal(name: "A", kind: .fire(annualSpending: 40_000, multiplier: 25), target: 0).problem == nil)
        #expect(Goal(name: "A", kind: .netWorth, target: 100, targetMin: 80).problem == nil)
    }

    @Test func changingAGoalTouchesOnlyItsDefinition() throws {
        let goal = Goal(name: "Emergency fund", kind: .accountTotal([checking.id]), target: 25_000, targetMin: 22_000)
        let changed = try ClaudeRules.changeGoal(
            goal, target: 30_000, targetMin: nil, targetDate: .some(day(6, 30)),
            accountIDs: [checking.id, savings.id], accounts: [checking, savings])
        #expect(changed.target == 30_000 && changed.targetMin == 22_000 && changed.targetDate == day(6, 30))
        #expect(changed.kind == .accountTotal([checking.id, savings.id]))
        #expect(changed.id == goal.id && changed.name == goal.name && changed.status == .active)

        // Clearing the date.
        let dated = Goal(name: "A", kind: .netWorth, target: 100, targetDate: day(6, 30))
        #expect(try ClaudeRules.changeGoal(dated, target: nil, targetMin: nil, targetDate: .some(nil), accountIDs: nil, accounts: []).targetDate == nil)
    }

    @Test func claudeCanWriteAGoalsNoteAndUndoTakesItBack() throws {
        let goal = Goal(name: "$100K Net Worth", kind: .netWorth, target: 100_000)
        let changed = try ClaudeRules.changeGoal(
            goal, target: nil, targetMin: nil, targetDate: nil, accountIDs: nil,
            note: "By my 30th birthday", accounts: [])
        #expect(changed.note == "By my 30th birthday")
        #expect(ClaudeRules.undoGoalChange(current: changed, before: goal, after: changed)?.note == "")
        let created = try ClaudeRules.newGoal(
            name: "House", measures: .netWorth, target: 50_000, targetMin: nil, targetDate: nil,
            note: "Somewhere with a yard", accounts: [])
        #expect(created.note == "Somewhere with a yard")
    }

    @Test func goalChangesThatDontFitAreRefused() {
        let netWorth = Goal(name: "Net worth", kind: .netWorth, target: 150_000, targetMin: 140_000)
        let fire = Goal(name: "FI", kind: .fire(annualSpending: 40_000, multiplier: 25), target: 0)
        let achieved = Goal(name: "Done", kind: .netWorth, target: 50_000, status: .achieved(on: day(5, 1), value: 50_100))
        let accounts = [checking, savings, closed]
        func change(_ goal: Goal, target: Decimal? = nil, ids: Set<UUID>? = nil) -> String? {
            refusal { _ = try ClaudeRules.changeGoal(goal, target: target, targetMin: nil, targetDate: nil, accountIDs: ids, accounts: accounts) }
        }
        #expect(change(netWorth, target: 130_000)?.contains("minimum") == true)
        #expect(change(fire, target: 2_000_000)?.contains("spending") == true)
        #expect(change(netWorth, ids: [checking.id])?.contains("net worth") == true)
        #expect(change(achieved, target: 60_000)?.contains("achieved") == true)
        #expect(change(Goal(name: "A", kind: .accountTotal([checking.id]), target: 1), ids: [closed.id])?.contains("closed") == true)
        #expect(change(netWorth) != nil, "nothing to change")
        // The editor never keeps a minimum on a financial independence goal.
        #expect(
            refusal { _ = try ClaudeRules.changeGoal(fire, target: nil, targetMin: .some(500_000), targetDate: nil, accountIDs: nil, accounts: accounts) }?
                .contains("minimum") == true)
    }

    @Test func undoingAGoalChangeRestoresTheEarlierDefinitionUnlessItChangedSince() {
        let before = Goal(name: "Emergency fund", kind: .netWorth, target: 25_000)
        var after = before
        after.target = 30_000
        after.targetDate = day(6, 30)

        // Reached since: the status isn't part of the change, so undo still works and keeps it.
        var reached = after
        reached.status = .achieved(on: day(10, 20), value: 30_100)
        let restored = ClaudeRules.undoGoalChange(current: reached, before: before, after: after)
        #expect(restored?.target == 25_000 && restored?.targetDate == nil)
        #expect(restored?.status == reached.status)

        var edited = after
        edited.target = 35_000
        #expect(ClaudeRules.undoGoalChange(current: edited, before: before, after: after) == nil)
    }

    // MARK: Habits and the vision

    @Test func aNewHabitFollowsTheEditorsRules() throws {
        let habit = try ClaudeRules.newHabit(title: " Stretch ", perWeek: 3, startedOn: today, habits: [])
        #expect(habit.title == "Stretch" && habit.perWeek == 3 && habit.checkIns.isEmpty)
        #expect(refusal { _ = try ClaudeRules.newHabit(title: "Run", perWeek: 0, startedOn: today, habits: []) } != nil)
        #expect(refusal { _ = try ClaudeRules.newHabit(title: "Run", perWeek: 8, startedOn: today, habits: []) } != nil)
        #expect(refusal { _ = try ClaudeRules.newHabit(title: "", perWeek: 2, startedOn: today, habits: []) } != nil)
        #expect(
            refusal { _ = try ClaudeRules.newHabit(title: "stretch", perWeek: 2, startedOn: today, habits: [habit]) }?
                .contains("already") == true)
    }

    @Test func aCheckInIsAddedNeverTakenAway() throws {
        let habit = Habit(title: "Run", perWeek: 3, startedOn: day(10, 21), checkIns: [day(10, 22)])
        let checked = try ClaudeRules.checkIn(habit, on: today, today: today, reminders: [])
        #expect(checked?.checkIns == [day(10, 22), today])
        // Already ticked: nothing changes (a toggle would have removed it).
        #expect(try ClaudeRules.checkIn(habit, on: day(10, 22), today: today, reminders: []) == nil)
        // The Sunday of its first week counts; the week before and tomorrow don't.
        #expect(try ClaudeRules.checkIn(habit, on: day(10, 18), today: today, reminders: [])?.checkIns.contains(day(10, 18)) == true)
        #expect(refusal { _ = try ClaudeRules.checkIn(habit, on: day(10, 17), today: today, reminders: []) } != nil)
        #expect(refusal { _ = try ClaudeRules.checkIn(habit, on: day(10, 24), today: today, reminders: []) } != nil)
        var archived = habit
        archived.archived = true
        #expect(refusal { _ = try ClaudeRules.checkIn(archived, on: today, today: today, reminders: []) } != nil)
    }

    @Test func aCheckInOnALinkedHabitSettlesTheDaySoRemindersDoesntUndoIt() throws {
        var habit = Habit(title: "French", perWeek: 5, startedOn: day(9, 7))
        habit.reminder = HabitReminder(id: "r", title: "Practise French", listID: "daily")
        let checked = try #require(try ClaudeRules.checkIn(habit, on: today, today: today, reminders: []))
        #expect(checked.reminder?.settled == [today])
        let undone = try #require(ClaudeRules.undoCheckIn(current: checked, day: today, today: today))
        #expect(undone.checkIns.isEmpty && undone.reminder?.settled == [today])
        // Unticked since: nothing left to undo.
        #expect(ClaudeRules.undoCheckIn(current: undone, day: today, today: today) == nil)
    }

    @Test func undoingANewHabitRemovesItOnlyWhileItHasNoCheckIns() throws {
        let habit = try ClaudeRules.newHabit(title: "Stretch", perWeek: 3, startedOn: today, habits: [])
        #expect(ClaudeRules.canUndoNewHabit(current: habit, created: habit))
        #expect(!ClaudeRules.canUndoNewHabit(current: Habits.toggle(habit, on: today), created: habit))
    }

    @Test func theVisionIsReplacedNeverWipedAndUndoRestoresIt() {
        #expect(refusal { try ClaudeRules.checkVision("  ", current: "A calm life") } != nil)
        #expect(refusal { try ClaudeRules.checkVision("A calm life", current: "A calm life") } != nil)
        #expect(refusal { try ClaudeRules.checkVision("A calm life, near the sea", current: "A calm life") } == nil)
        #expect(ClaudeRules.restore(current: "A calm life, near the sea", before: "A calm life", after: "A calm life, near the sea") == "A calm life")
        #expect(ClaudeRules.restore(current: "Edited by hand", before: "A calm life", after: "A calm life, near the sea") == nil)
    }

    @Test func claudeReplacesAYearsBetsButNeverClearsThem() throws {
        #expect(try ClaudeRules.bets(["Gym consistency", " ", "Career progress "], current: "") == "Gym consistency\nCareer progress")
        #expect(refusal { _ = try ClaudeRules.bets(["  "], current: "Gym") } != nil)
        #expect(refusal { _ = try ClaudeRules.bets(["Gym"], current: "- Gym") } != nil)
        let change = ClaudeChange.betsEdited(year: 2026, before: "Gym", after: "Gym\nCareer progress")
        #expect(change != ClaudeChange.betsEdited(year: 2027, before: "Gym", after: "Gym\nCareer progress"))
    }

    // MARK: Reminders

    let lists = [
        ReminderList(id: "week", title: "This Week"), ReminderList(id: "quarter", title: "This Quarter"),
        ReminderList(id: "admin", title: "Admin"), ReminderList(id: "admin2", title: "admin ")
    ]

    @Test func aListIsFoundByNameAndAWrongNameListsTheNames() throws {
        #expect(try ClaudeRules.list(named: "this week", in: lists).id == "week")
        #expect(refusal { _ = try ClaudeRules.list(named: "Someday", in: lists) }?.contains("This Quarter") == true)
        #expect(refusal { _ = try ClaudeRules.list(named: "Admin", in: lists) }?.contains("more than one") == true)
    }

    @Test func aReminderIsFoundByIdOrOneTitle() throws {
        let reminders = [
            Reminder(id: "1", title: "Back up the laptop", listID: "week"),
            Reminder(id: "2", title: "Renew passport", listID: "admin"),
            Reminder(id: "3", title: "Renew passport", listID: "week")
        ]
        #expect(try ClaudeRules.reminder("1", in: reminders).id == "1")
        #expect(try ClaudeRules.reminder("back up the LAPTOP", in: reminders).id == "1")
        #expect(refusal { _ = try ClaudeRules.reminder("Renew passport", in: reminders) }?.contains("id") == true)
        #expect(refusal { _ = try ClaudeRules.reminder("Call mum", in: reminders) } != nil)
        // The reminders tool drops a leading list name, so that short title finds it too.
        let living = [ReminderList(id: "living", title: "Living List")]
        let lights = Reminder(id: "40", title: "Living List: See the northern lights", listID: "living")
        #expect(try ClaudeRules.reminder("See the northern lights", in: [lights], lists: living).id == "40")
    }

    @Test func aReminderEditUndoesOnlyWhileItHoldsClaudesEdit() {
        let before = ReminderEdit(title: "Renew passport", due: nil)
        let after = ReminderEdit(title: "Renew passport", due: ReminderDue(day: day(10, 30), minute: 9 * 60))
        #expect(ClaudeRules.restore(current: after, before: before, after: after) == before)
        #expect(
            ClaudeRules.restore(
                current: ReminderEdit(title: "Renew passport", due: ReminderDue(day: day(11, 2))),
                before: before, after: after) == nil)
        #expect(refusal { try ClaudeRules.checkEdit(ReminderEdit(title: " ", due: nil), current: before) } != nil)
        #expect(refusal { try ClaudeRules.checkEdit(before, current: before) } != nil)
    }

    // MARK: The Compass calendar

    func event(_ id: String, calendar: String = "compass", hour: Int = 9) -> CalendarEvent {
        let start = today.startDate(in: .current).addingTimeInterval(TimeInterval(hour * 3600))
        return CalendarEvent(id: id, title: "Focus", calendarID: calendar, start: start, end: start.addingTimeInterval(3600))
    }

    @Test func onlyEventsClaudeMadeInTheCompassCalendarCanBeMovedOrDeleted() {
        #expect(refusal { try ClaudeRules.checkOwn(self.event("a"), compassCalendarID: "compass", own: ["a"]) } == nil)
        #expect(refusal { try ClaudeRules.checkOwn(self.event("b"), compassCalendarID: "compass", own: ["a"]) }?.contains("didn't create") == true)
        #expect(
            refusal { try ClaudeRules.checkOwn(self.event("a", calendar: "work"), compassCalendarID: "compass", own: ["a"]) }?.contains("Compass calendar")
                == true)
        #expect(refusal { try ClaudeRules.checkOwn(self.event("a"), compassCalendarID: nil, own: ["a"]) } != nil)
    }

    // Nov 1, 2026: their other calendars too, for moving and editing.
    let personal = EventAccess(calendarTitle: "Personal", allowsChanges: true, organizedBySomeoneElse: false)

    @Test func anEventOnAnotherCalendarHeReadsCanBeChanged() {
        #expect(
            refusal {
                try ClaudeRules.checkChange(
                    self.event("haircut", calendar: "personal"), access: self.personal, hidden: [],
                    compassCalendarID: "compass", own: [])
            } == nil)
        // In the Compass calendar, still only Claude's own.
        #expect(
            refusal {
                try ClaudeRules.checkChange(
                    self.event("b"), access: self.personal, hidden: [],
                    compassCalendarID: "compass", own: ["a"])
            }?.contains("didn't create") == true)
    }

    @Test func aCalendarHeHidesReadOnlyOnesAndInvitesAreRefused() {
        let haircut = event("haircut", calendar: "personal")
        #expect(
            refusal {
                try ClaudeRules.checkChange(
                    haircut, access: self.personal, hidden: ["personal"],
                    compassCalendarID: "compass", own: [])
            }?.contains("hide") == true)
        let holidays = EventAccess(calendarTitle: "US Holidays", allowsChanges: false, organizedBySomeoneElse: false)
        #expect(
            refusal { try ClaudeRules.checkChange(haircut, access: holidays, hidden: [], compassCalendarID: "compass", own: []) }?
                .contains("read-only") == true)
        let invite = EventAccess(calendarTitle: "Personal", allowsChanges: true, organizedBySomeoneElse: true)
        #expect(
            refusal { try ClaudeRules.checkChange(haircut, access: invite, hidden: [], compassCalendarID: "compass", own: []) }?
                .contains("organizes") == true)
        // Their own event with guests: a change would send them an update.
        let guests = EventAccess(calendarTitle: "Personal", allowsChanges: true, organizedBySomeoneElse: false, hasGuests: true)
        #expect(
            refusal { try ClaudeRules.checkChange(haircut, access: guests, hidden: [], compassCalendarID: "compass", own: []) }?
                .contains("guests") == true)
    }

    @Test func aRepeatingEventsDateHasAnIdOfItsOwn() {
        let saturday = Date(timeIntervalSince1970: 1_793_448_000)
        let id = ClaudeRules.occurrenceID("ABC-123", start: saturday)
        #expect(id != "ABC-123")
        #expect(ClaudeRules.occurrence(id).itemID == "ABC-123" && ClaudeRules.occurrence(id).start == saturday)
        // A plain id, or an external one with an @ of its own, is the event itself.
        #expect(ClaudeRules.occurrence("ABC-123").itemID == "ABC-123" && ClaudeRules.occurrence("ABC-123").start == nil)
        #expect(ClaudeRules.occurrence("x9@google.com").itemID == "x9@google.com" && ClaudeRules.occurrence("x9@google.com").start == nil)
    }

    @Test func eventTimesMustMakeSense() {
        let start = today.startDate(in: .current)
        #expect(refusal { try ClaudeRules.checkTimes(start: start, end: start.addingTimeInterval(3600)) } == nil)
        #expect(refusal { try ClaudeRules.checkTimes(start: start, end: start) } != nil)
        #expect(refusal { try ClaudeRules.checkTimes(start: start, end: start.addingTimeInterval(15 * 86_400)) } != nil)
    }

    // MARK: The log

    @Test func theLogKnowsWhichEventsClaudeMade() {
        let made = ClaudeEvent(id: "a", externalID: "ext-a", title: "Focus", start: .now, end: .now.addingTimeInterval(60), isAllDay: false)
        let other = ClaudeEvent(id: "b", externalID: nil, title: "Walk", start: .now, end: .now.addingTimeInterval(60), isAllDay: false)
        var restored = ClaudeActivity(tool: "delete_event", summary: "Deleted Walk", change: .eventDeleted(other))
        restored.undoneAt = .now
        restored.restoredEventID = "c"
        let log = [
            ClaudeActivity(tool: "create_event", summary: "Added Focus", change: .eventCreated(made)), restored,
            ClaudeActivity(tool: "edit_vision", summary: "Edited the vision", change: .visionEdited(before: "a", after: "b"))
        ]
        #expect(ClaudeRules.ownEvents(log) == ["a", "ext-a", "c"])
    }

    @Test func aLogEntryReadsBackExactly() throws {
        let goal = Goal(name: "House", kind: .accountTotal([checking.id]), target: 60_000.25, targetDate: day(12, 31))
        let entry = ClaudeActivity(
            tool: "update_goal", summary: "Raised House to $60,000.25",
            change: .goalChanged(before: goal, after: goal))
        let data = try JSONEncoder().encode(entry)
        #expect(try JSONDecoder().decode(ClaudeActivity.self, from: data) == entry)
    }

    @Test func moneyChangesAreRefusedInPlainWords() {
        for name in ["update_account", "set_balance", "delete_transaction", "set_amount", "set_category", "set_budget", "sync", "delete_goal"] {
            let message = ClaudeRules.refusal(forTool: name)
            #expect(message.contains("read-only") && message.contains("never deleted"), "\(name)")
        }
    }
}

/// Seam 31+: what Claude may change in the Playbook.
@Suite struct ClaudePlaybookTests {
    // Friday Oct 30, 2026.
    let today = Day(year: 2026, month: 10, day: 30)
    let tee = PlaybookEntry(area: "Clothes", kind: .pick, title: "Plain tee", size: "M")
    let nails = PlaybookEntry(area: "Grooming", kind: .pick, title: "Nails", repeatEveryDays: 10, lastDone: Day(year: 2026, month: 10, day: 22))

    @Test func anEntryNeedsATitleAnAreaAndASensibleRepeat() throws {
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.checkPlaybookEntry(PlaybookEntry(area: "Clothes", kind: .pick, title: " "), among: []) }
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.checkPlaybookEntry(PlaybookEntry(area: "", kind: .pick, title: "Socks"), among: []) }
        #expect(throws: ClaudeRefusal.self) {
            try ClaudeRules.checkPlaybookEntry(PlaybookEntry(area: "Hair", kind: .pick, title: "Haircut", repeatEveryDays: 0), among: [])
        }
        try ClaudeRules.checkPlaybookEntry(PlaybookEntry(area: "Hair", kind: .pick, title: "Haircut", repeatEveryDays: 28), among: [tee])
    }

    @Test func onlyARoutineHasStepsAndStepsKeepToRealWeekdays() throws {
        #expect(throws: ClaudeRefusal.self) {
            try ClaudeRules.checkPlaybookEntry(PlaybookEntry(area: "Clothes", kind: .pick, title: "Socks", steps: [PlaybookStep(text: "Buy")]), among: [])
        }
        #expect(throws: ClaudeRefusal.self) {
            try ClaudeRules.checkPlaybookEntry(
                PlaybookEntry(
                    area: "Fitness", kind: .routine, title: "Workout",
                    steps: [PlaybookStep(text: "Push", weekdays: [7])]), among: [])
        }
        try ClaudeRules.checkPlaybookEntry(
            PlaybookEntry(
                area: "Fitness", kind: .routine, title: "Workout",
                steps: [PlaybookStep(text: "Push", weekdays: [0])]), among: [])
    }

    @Test func notASecondEntryOfTheSameTitleInAnArea() throws {
        #expect(throws: ClaudeRefusal.self) {
            try ClaudeRules.checkPlaybookEntry(PlaybookEntry(area: "clothes", kind: .pick, title: "plain tee"), among: [tee])
        }
        // Editing an entry isn't a clash with itself.
        var edited = tee
        edited.size = "L"
        try ClaudeRules.checkPlaybookEntry(edited, among: [tee])
    }

    @Test func doneIsForARepeatOnTodayOrEarlierNotBeforeItWasLastDone() throws {
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.markDone(tee, on: today, today: today) }
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.markDone(nails, on: Day(year: 2026, month: 10, day: 31), today: today) }
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.markDone(nails, on: Day(year: 2026, month: 10, day: 20), today: today) }
        #expect(try ClaudeRules.markDone(nails, on: Day(year: 2026, month: 10, day: 22), today: today) == nil)
        #expect(try ClaudeRules.markDone(nails, on: today, today: today)?.lastDone == today)
    }

    @Test func aSizeIsSetByItsLabelOrAdded() throws {
        let sizes = PlaybookSizes(rows: [PlaybookSize(label: "Suit", value: "38S")])
        let changed = try ClaudeRules.setSize(sizes, label: "suit", value: "42R")
        #expect(changed.rows.map(\.value) == ["42R"])
        #expect(changed.rows.first?.label == "Suit")
        let added = try ClaudeRules.setSize(sizes, label: "Shoes", value: "10.5")
        #expect(added.rows.map(\.label) == ["Suit", "Shoes"])
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.setSize(sizes, label: "Suit", value: "38S") }
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.setSize(sizes, label: "Shoes", value: " ") }
    }

    @Test func undoRemovesAnAddedEntryOnlyWhileItsAsClaudeMadeIt() {
        #expect(ClaudeRules.canUndoNewEntry(current: tee, created: tee))
        var edited = tee
        edited.notes = "Wash cold"
        #expect(!ClaudeRules.canUndoNewEntry(current: edited, created: tee))
    }
}

/// Seam 31+: what Claude may change in the budget (round 3: "just be able to
/// tell Claude to do something … and it do it"), as the budget's editor does.
@Suite struct ClaudeBudgetTests {
    let october = Month(year: 2026, month: 10)
    let brokerage = UUID()
    var schedule: BudgetSchedule {
        BudgetSchedule(
            BudgetPlan(
                flexibleBudget: 1_000, roles: ["Rent": .fixed], expected: ["Rent": 2_300],
                plannedIncome: ["Paychecks": 5_000], savings: [brokerage: 1_100]))
    }

    func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let refusal as ClaudeRefusal { return refusal.message } catch { return "\(error)" }
    }

    @Test func amountsChangeFromAMonthOnOrForOneMonth() throws {
        let onward = try ClaudeRules.editBudget(schedule, .saving(brokerage, 500), in: october, .onward, today: october)
        #expect(onward.plan(for: october).savings[brokerage] == 500 && onward.plan(for: october.adding(3)).savings[brokerage] == 500)
        #expect(onward.plan(for: october.adding(-1)).savings[brokerage] == 1_100)
        let once = try ClaudeRules.editBudget(schedule, .flexible(1_400), in: october.adding(1), .onlyThisMonth, today: october)
        #expect(once.plan(for: october.adding(1)).flexibleBudget == 1_400 && once.plan(for: october.adding(2)).flexibleBudget == 1_000)
        // Nil takes a line out.
        #expect(
            try ClaudeRules.editBudget(schedule, .income("Paychecks", nil), in: october, .onward, today: october)
                .plan(for: october).plannedIncome["Paychecks"] == nil)
    }

    @Test func rolesApplyToEveryMonthAndFlexibleDropsTheBill() throws {
        let irregular = try ClaudeRules.editBudget(schedule, .role("Charity", .irregular, expected: 200), in: october, .onward, today: october)
        #expect(irregular.plan(for: october.adding(-6)).role(of: "Charity") == .irregular)
        #expect(irregular.plan(for: october).expected["Charity"] == 200)
        let flexible = try ClaudeRules.editBudget(schedule, .role("Rent", .flexible, expected: nil), in: october, .onward, today: october)
        #expect(flexible.plan(for: october).role(of: "Rent") == .flexible && flexible.plan(for: october).expected["Rent"] == nil)
    }

    @Test func whatTheEditorWouldntAllowIsRefused() {
        #expect(refusal { _ = try ClaudeRules.editBudget(schedule, .flexible(-5), in: october, .onward, today: october) } != nil)
        // A bill amount on a flexible category: make it fixed or irregular first.
        #expect(
            refusal { _ = try ClaudeRules.editBudget(schedule, .bill("Groceries", 300), in: october, .onward, today: october) }?
                .contains("set_budget_role") == true)
        #expect(refusal { _ = try ClaudeRules.editBudget(schedule, .role("Charity", .flexible, expected: 50), in: october, .onward, today: october) } != nil)
        // More than a year ahead, as the budget plans.
        #expect(refusal { _ = try ClaudeRules.editBudget(schedule, .flexible(900), in: october.adding(13), .onward, today: october) } != nil)
        // Nothing would change.
        #expect(refusal { _ = try ClaudeRules.editBudget(schedule, .saving(brokerage, 1_100), in: october, .onward, today: october) } != nil)
    }

    /// Undo puts back what the change touched, keeping changes made since to
    /// anything else; refused when what it touched changed since.
    @Test func undoPutsBackWhatTheChangeTouched() throws {
        let first = try ClaudeRules.editBudget(schedule, .saving(brokerage, 500), in: october, .onward, today: october)
        let second = try ClaudeRules.editBudget(first, .flexible(2_000), in: october, .onward, today: october)
        let undone = try #require(ClaudeRules.undoBudget(current: second, before: schedule, after: first, today: october))
        #expect(undone.plan(for: october).savings[brokerage] == 1_100 && undone.plan(for: october).flexibleBudget == 2_000)
        let role = try ClaudeRules.editBudget(schedule, .role("Charity", .irregular, expected: 200), in: october, .onward, today: october)
        let back = try #require(ClaudeRules.undoBudget(current: role, before: schedule, after: role, today: october))
        #expect(back.plan(for: october) == schedule.plan(for: october))
        let since = first.setting(.saving(brokerage), to: 700, in: october, .onward)
        #expect(ClaudeRules.undoBudget(current: since, before: schedule, after: first, today: october) == nil)
    }

    /// With income planned, the flexible budget is what's left; Claude changes the lines instead.
    @Test func flexibleIsntSetWhileItsTheRemainder() {
        #expect(
            refusal {
                _ = try ClaudeRules.editBudget(
                    schedule, .flexible(900), in: october, .onward, today: october,
                    flexibleIsRemainder: true)
            }?.contains("what's left") == true)
    }

    @Test func pastMonthsKeepWhatTheyPlanned() {
        #expect(refusal { _ = try ClaudeRules.editBudget(schedule, .flexible(900), in: october.adding(-1), .onward, today: october) } != nil)
    }
}

/// Seam 31+: what Claude may do with notes, and how undo takes it back.
@Suite struct ClaudeNotesTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000.6)
    let rent = Note(topic: "Money", title: "Rent", body: "Paid from checking, never the card", updatedAt: Date(timeIntervalSince1970: 1_789_000_000))

    @Test func aNoteNeedsATopicATitleAndAShortBody() throws {
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.newNote(topic: " ", title: "Buffer", body: "A month", among: [], now: now) }
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.newNote(topic: "Money", title: "", body: "A month", among: [], now: now) }
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.newNote(topic: "Money", title: "Buffer", body: " \n", among: [], now: now) }
        #expect(throws: ClaudeRefusal.self) {
            try ClaudeRules.newNote(topic: "Money", title: "Buffer", body: String(repeating: "a", count: 1_001), among: [], now: now)
        }
        let note = try ClaudeRules.newNote(topic: "money", title: " Buffer ", body: "Keep a month in checking", among: [rent], now: now)
        #expect(note.topic == "Money")
        #expect(note.title == "Buffer")
        // Stamped to the second, so a backup reads it back exactly.
        #expect(note.updatedAt == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func notASecondNoteOfTheSameTitleEvenByRenaming() throws {
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.newNote(topic: "Life", title: "rent", body: "Due the 1st", among: [rent], now: now) }
        let buffer = Note(topic: "Money", title: "Buffer", body: "A month", updatedAt: now)
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.editNote(buffer, title: "RENT", body: nil, among: [rent, buffer], now: now) }
    }

    @Test func anEditChangesOnlyWhatsGivenKeepsTheRulesAndRefusesNoChange() throws {
        let edited = try ClaudeRules.editNote(rent, title: nil, body: "Paid from checking on the 1st", among: [rent], now: now)
        #expect(edited.id == rent.id)
        #expect(edited.title == "Rent")
        #expect(edited.body == "Paid from checking on the 1st")
        #expect(edited.updatedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.editNote(rent, title: "Rent", body: rent.body, among: [rent], now: now) }
        #expect(try ClaudeRules.editNote(rent, topic: "life", title: nil, body: nil, among: [rent], now: now).topic == "Life")
        #expect(throws: ClaudeRefusal.self) {
            try ClaudeRules.editNote(rent, title: nil, body: String(repeating: "a", count: 1_001), among: [rent], now: now)
        }
    }

    @Test func aNoteIsFoundByIdOrATitleOnlyOneHas() throws {
        let buffer = Note(topic: "Money", title: "Buffer", body: "A month", updatedAt: now)
        #expect(try ClaudeRules.note(rent.id.uuidString.lowercased(), in: [rent, buffer]) == rent)
        #expect(try ClaudeRules.note(" buffer", in: [rent, buffer]) == buffer)
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.note("Taxes", in: [rent, buffer]) }
    }

    @Test func undoTakesBackANoteOnlyWhileItsAsClaudeLeftIt() throws {
        #expect(ClaudeRules.canUndoNewEntry(current: rent, created: rent))
        let edited = try ClaudeRules.editNote(rent, title: nil, body: "On the 1st", among: [rent], now: now)
        #expect(!ClaudeRules.canUndoNewEntry(current: edited, created: rent))
        #expect(ClaudeRules.restore(current: edited, before: rent, after: edited) == rent)
        // A deleted note comes back unless one of its title is there by then.
        #expect(ClaudeRules.canRestoreDeleted(rent, among: []))
        let another = Note(topic: "Life", title: "rent", body: "Due the 1st", updatedAt: now)
        #expect(!ClaudeRules.canRestoreDeleted(rent, among: [another]))
    }
}
