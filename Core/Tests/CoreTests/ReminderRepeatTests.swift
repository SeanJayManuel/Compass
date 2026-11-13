import Core
import Foundation
import Testing

/// Seam 31 (Nov 1, 2026): a reminder's repeat as
/// Claude sets it, what's refused, and how undo restores.
@Suite struct ReminderRepeatTests {
    // Sunday Nov 1, 2026.
    let today = Day(year: 2026, month: 11, day: 1)
    func day(_ month: Int, _ day: Int) -> Day { Day(year: 2026, month: month, day: day) }

    func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let refusal as ClaudeRefusal { return refusal.message } catch { return "\(error)" }
    }

    func rule(_ frequency: String, every: Int? = nil, weekdays: [String] = [], until: Day? = nil) throws -> Repeating {
        try ClaudeRules.reminderRepeat(frequency, every: every, weekdays: weekdays, until: until)
    }

    // MARK: Reading a rule

    @Test func aFrequencyReadsAsARule() throws {
        #expect(try rule("weekly", weekdays: ["Sun"]) == .rule(ReminderRepeat(frequency: .weekly, weekdays: [6])))
        #expect(try rule("Monthly") == .rule(ReminderRepeat(frequency: .monthly)))
        #expect(try rule("daily", every: 3) == .rule(ReminderRepeat(frequency: .daily, every: 3)))
        #expect(try rule("every 10 days") == .rule(ReminderRepeat(frequency: .daily, every: 10)))
        #expect(try rule("every week") == .rule(ReminderRepeat(frequency: .weekly)))
        #expect(
            try rule("weekly", weekdays: ["monday", "WED"], until: day(12, 31))
                == .rule(ReminderRepeat(frequency: .weekly, weekdays: [0, 2], until: day(12, 31))))
        #expect(try rule("none") == .never)
    }

    @Test func aRuleThatDoesntMakeSenseIsRefused() {
        #expect(refusal { _ = try rule("fortnightly") } != nil)
        #expect(refusal { _ = try rule("daily", every: 0) } != nil)
        #expect(refusal { _ = try rule("daily", every: 366) } != nil)
        #expect(refusal { _ = try rule("monthly", weekdays: ["sun"]) }?.contains("weekly") == true)
        #expect(refusal { _ = try rule("weekly", weekdays: ["someday"]) } != nil)
    }

    @Test func aRuleSaysWhatItIs() {
        #expect(ReminderRepeat(frequency: .daily).text == "daily")
        #expect(ReminderRepeat(frequency: .daily, every: 10).text == "every 10 days")
        #expect(ReminderRepeat(frequency: .yearly, every: 2).text == "every 2 years")
        #expect(ReminderRepeat(frequency: .weekly, weekdays: [6, 2]).text == "weekly on Sun, Wed")
        #expect(ReminderRepeat(frequency: .monthly, every: 2, until: day(12, 31)).text == "every 2 months until 2026-12-31")
    }

    // MARK: Setting it on a reminder

    let pay = Reminder(id: "r", title: "Pay the card", listID: "admin", due: ReminderDue(day: Day(year: 2026, month: 11, day: 5)))

    @Test func aRepeatWithoutADueDateStartsToday() throws {
        var edit = ReminderEdit(title: "Water the plants", due: nil)
        try ClaudeRules.setRepeat(.rule(ReminderRepeat(frequency: .weekly)), on: &edit, reminder: nil, linkedToHabit: false, today: today)
        #expect(edit.due == ReminderDue(day: today) && edit.repeating == .rule(ReminderRepeat(frequency: .weekly)))
    }

    @Test func aRepeatCantEndBeforeItsDueDay() {
        var edit = ReminderEdit(title: pay.title, due: pay.due)
        #expect(
            refusal {
                try ClaudeRules.setRepeat(
                    .rule(ReminderRepeat(frequency: .monthly, until: day(11, 4))), on: &edit,
                    reminder: pay, linkedToHabit: false, today: today)
            } != nil)
    }

    @Test func aHabitsReminderKeepsItsRepeat() {
        var edit = ReminderEdit(title: pay.title, due: pay.due)
        #expect(refusal { try ClaudeRules.setRepeat(.never, on: &edit, reminder: pay, linkedToHabit: true, today: today) }?.contains("habit") == true)
    }

    @Test func aRepeatCompassCantDescribeIsLeftToReminders() {
        // Made in Reminders, like the second Sunday of each month.
        let custom = Reminder(id: "c", title: "Deep clean", listID: "home", due: ReminderDue(day: day(11, 8)), repeats: true)
        var edit = ReminderEdit(title: custom.title, due: custom.due)
        #expect(refusal { try ClaudeRules.setRepeat(.never, on: &edit, reminder: custom, linkedToHabit: false, today: today) }?.contains("Reminders") == true)
        // An edit that leaves the repeat alone is fine.
        #expect(refusal { try ClaudeRules.setRepeat(nil, on: &edit, reminder: custom, linkedToHabit: false, today: today) } == nil)
        #expect(edit.repeating == nil)
    }

    @Test func aRepeatingReminderKeepsADueDate() {
        let weekly = Reminder(
            id: "w", title: "Week review", listID: "week", due: ReminderDue(day: day(11, 7)),
            repeatRule: ReminderRepeat(frequency: .weekly))
        var edit = ReminderEdit(title: weekly.title, due: nil)
        #expect(refusal { try ClaudeRules.setRepeat(nil, on: &edit, reminder: weekly, linkedToHabit: false, today: today) }?.contains("none") == true)
        // Taking the repeat off at the same time is fine.
        #expect(refusal { try ClaudeRules.setRepeat(.never, on: &edit, reminder: weekly, linkedToHabit: false, today: today) } == nil)
    }

    @Test func theSameRepeatIsNothingToChange() throws {
        let weekly = Reminder(
            id: "w", title: "Week review", listID: "week", due: ReminderDue(day: day(11, 7)),
            repeatRule: ReminderRepeat(frequency: .weekly))
        var before = ReminderEdit(title: weekly.title, due: weekly.due)
        before.repeating = .rule(ReminderRepeat(frequency: .weekly))
        var after = ReminderEdit(title: weekly.title, due: weekly.due)
        try ClaudeRules.setRepeat(.rule(ReminderRepeat(frequency: .weekly)), on: &after, reminder: weekly, linkedToHabit: false, today: today)
        #expect(refusal { try ClaudeRules.checkEdit(after, current: before) } != nil)
    }

    // MARK: Undo

    @Test func undoPutsBackTheRepeatOnlyWhileItsClaudes() {
        var before = ReminderEdit(title: "Nails", due: ReminderDue(day: day(11, 8)))
        before.repeating = .never
        var after = before
        after.repeating = .rule(ReminderRepeat(frequency: .daily, every: 10))
        var current = after
        current.notes = ""
        #expect(ClaudeRules.undoReminderEdit(current: current, before: before, after: after) == before)
        current.repeating = .rule(ReminderRepeat(frequency: .weekly))
        #expect(ClaudeRules.undoReminderEdit(current: current, before: before, after: after) == nil)
    }

    @Test func anEditThatLeftTheRepeatAloneIgnoresIt() {
        let before = ReminderEdit(title: "Nails", due: nil)
        let after = ReminderEdit(title: "Cut nails", due: nil)
        var current = after
        current.repeating = .rule(ReminderRepeat(frequency: .weekly))
        #expect(ClaudeRules.undoReminderEdit(current: current, before: before, after: after) == before)
    }

    @Test func anEditLoggedBeforeRepeatsReadsBack() throws {
        let old = #"{"title":"Nails","due":null,"notes":"x"}"#
        let edit = try JSONDecoder().decode(ReminderEdit.self, from: Data(old.utf8))
        #expect(edit.repeating == nil && edit.notes == "x")
    }
}
