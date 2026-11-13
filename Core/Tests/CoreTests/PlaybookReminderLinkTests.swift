import Core
import Foundation
import Testing

@Suite struct PlaybookReminderLinkTests {
    // Monday Nov 2, 2026.
    let today = Day(year: 2026, month: 11, day: 2)
    func day(_ month: Int, _ day: Int) -> Day { Day(year: 2026, month: month, day: day) }

    func nails(
        lastDone: Day? = Day(year: 2026, month: 11, day: 1), reminder: PlaybookReminder? = .linked(id: "r1", externalID: "x1"),
        every: Int? = 7
    ) -> PlaybookEntry {
        PlaybookEntry(area: "Grooming", kind: .routine, title: "Fingernails", repeatEveryDays: every, lastDone: lastDone, reminder: reminder)
    }

    func state(
        of entry: PlaybookEntry, id: String = "r1", externalID: String = "x1", title: String = "Fingernails",
        due: Day? = Day(year: 2026, month: 11, day: 8), completedOn: Day? = nil
    ) -> PlaybookReminderState {
        PlaybookReminderState(id: id, externalID: externalID, entryID: entry.id, title: title, due: due, completedOn: completedOn)
    }

    func sync(_ entries: [PlaybookEntry], found: [PlaybookReminderState] = [], gone: Set<String> = []) -> PlaybookReminderLink.Plan {
        PlaybookReminderLink.sync(entries, found: found, gone: gone, today: today)
    }

    // MARK: Linking

    @Test func aRepeatWithNoReminderGetsOneDueOnItsNextDueDay() {
        let entry = nails(reminder: nil)
        let plan = sync([entry])
        #expect(plan.actions == [.create(entry: entry.id, title: "Fingernails", due: day(11, 8))])
        #expect(plan.entries.isEmpty)
    }

    @Test func aRepeatNeverDoneIsDueToday() {
        let entry = nails(lastDone: nil, reminder: nil)
        #expect(sync([entry]).actions == [.create(entry: entry.id, title: "Fingernails", due: today)])
    }

    @Test func anEntryThatDoesNotRepeatGetsNoReminder() {
        let tee = PlaybookEntry(area: "Clothes", kind: .pick, title: "Plain tee")
        #expect(sync([tee]).actions.isEmpty)
    }

    @Test func anUnlinkedEntryTakesBackTheReminderCarryingItsLink() {
        let entry = nails(reminder: nil)
        let plan = sync([entry], found: [state(of: entry, id: "r9", externalID: "x9")])
        #expect(plan.actions.isEmpty)
        #expect(plan.entries.map(\.reminder) == [.linked(id: "r9", externalID: "x9")])
    }

    @Test func aReminderWithANewIdentifierIsFoundByItsLink() {
        let entry = nails()
        let plan = sync([entry], found: [state(of: entry, id: "r2", externalID: "x2")])
        #expect(plan.entries.map(\.reminder) == [.linked(id: "r2", externalID: "x2")])
        #expect(plan.actions.isEmpty)
    }

    @Test func aSecondReminderForTheSameEntryIsDeleted() {
        let entry = nails()
        let plan = sync([entry], found: [state(of: entry), state(of: entry, id: "r2", externalID: "x2")])
        #expect(plan.actions == [.delete(id: "r2")])
    }

    @Test func aReminderInStepChangesNothing() {
        let entry = nails()
        let plan = sync([entry], found: [state(of: entry)])
        #expect(plan.actions.isEmpty)
        #expect(plan.entries.isEmpty)
    }

    // MARK: Ticked in Reminders

    @Test func aTickMadeWhileCompassWasClosedCountsOnTheDayItWasMade() {
        let entry = nails(lastDone: day(10, 20))
        let plan = sync([entry], found: [state(of: entry, due: day(10, 27), completedOn: day(10, 30))])
        #expect(plan.entries.map(\.lastDone) == [day(10, 30)])
        #expect(plan.actions == [.update(id: "r1", title: "Fingernails", due: day(11, 6), reopen: true)])
    }

    @Test func tickingItTwiceInADayMovesItOnOnce() {
        // The first tick today was already carried over; it's ticked again.
        let entry = nails(lastDone: today)
        let plan = sync([entry], found: [state(of: entry, due: day(11, 9), completedOn: today)])
        #expect(plan.entries.isEmpty)
        #expect(plan.actions == [.update(id: "r1", title: "Fingernails", due: day(11, 9), reopen: true)])
    }

    @Test func aTickFromBeforeItWasLastDoneOnlyReopensIt() {
        let entry = nails(lastDone: today)
        let plan = sync([entry], found: [state(of: entry, due: day(11, 8), completedOn: day(11, 1))])
        #expect(plan.entries.isEmpty)
        #expect(plan.actions == [.update(id: "r1", title: "Fingernails", due: day(11, 9), reopen: true)])
    }

    @Test func aTickDatedAfterTodayCountsAsToday() {
        let entry = nails()
        let plan = sync([entry], found: [state(of: entry, completedOn: day(11, 3))])
        #expect(plan.entries.map(\.lastDone) == [today])
    }

    // MARK: Changed in Compass

    @Test func doneInCompassMovesTheReminderOn() {
        let entry = nails(lastDone: today)
        let plan = sync([entry], found: [state(of: entry, due: day(11, 8))])
        #expect(plan.actions == [.update(id: "r1", title: "Fingernails", due: day(11, 9), reopen: false)])
    }

    @Test func aRenamedEntryRenamesItsReminder() {
        let entry = nails()
        let plan = sync([entry], found: [state(of: entry, title: "Nails")])
        #expect(plan.actions == [.update(id: "r1", title: "Fingernails", due: day(11, 8), reopen: false)])
    }

    @Test func aChangedRepeatMovesTheDueDay() {
        let entry = nails(every: 14)
        #expect(sync([entry], found: [state(of: entry)]).actions == [.update(id: "r1", title: "Fingernails", due: day(11, 15), reopen: false)])
    }

    @Test func stoppingTheRepeatDeletesTheReminderAndForgetsIt() {
        let entry = nails(every: nil)
        let plan = sync([entry], found: [state(of: entry)])
        #expect(plan.actions == [.delete(id: "r1")])
        // Forgotten, not turned off: Compass deleted it, they didn't.
        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].reminder == nil)
    }

    @Test func aReminderWhoseEntryIsGoneIsDeleted() {
        let deleted = nails()
        #expect(sync([], found: [state(of: deleted)]).actions == [.delete(id: "r1")])
    }

    // MARK: Deleted in Reminders

    @Test func aReminderHeDeletedTurnsTheEntryOffInsteadOfComingBack() {
        let entry = nails()
        let plan = sync([entry], gone: ["r1"])
        #expect(plan.actions.isEmpty)
        #expect(plan.entries.map(\.reminder) == [.off])
    }

    @Test func anEntryTurnedOffStaysOff() {
        let plan = sync([nails(reminder: .off)])
        #expect(plan.actions.isEmpty)
        #expect(plan.entries.isEmpty)
    }

    @Test func aReminderNotFoundButNotKnownGoneIsLeftAlone() {
        // Reminders hasn't answered yet, or the lookup failed: no conclusion.
        let plan = sync([nails()])
        #expect(plan.actions.isEmpty)
        #expect(plan.entries.isEmpty)
    }

    @Test func onlyLinkedRemindersLeaveTheAgenda() {
        let ids = PlaybookReminderLink.linkedIDs([nails(), nails(reminder: .off), nails(reminder: nil)])
        #expect(ids == ["r1"])
    }

    @Test func theLinkReadsBackFromItsAddress() {
        let id = UUID()
        #expect(PlaybookReminderLink.entryID(in: PlaybookReminderLink.address(for: id)) == id)
        #expect(PlaybookReminderLink.entryID(in: URL(string: "https://example.com/playbook/\(id)")!) == nil)
    }

    // MARK: Undo

    @Test func undoingAnEditKeepsTheReminderItHasNow() {
        let before = nails(reminder: nil)
        var after = before
        after.title = "Nails"
        var current = after
        current.reminder = .linked(id: "r1", externalID: "x1")
        let restored = ClaudeRules.restoreEntry(current: current, before: before, after: after)
        #expect(restored?.title == "Fingernails")
        #expect(restored?.reminder == .linked(id: "r1", externalID: "x1"))
    }

    @Test func undoingAnEditChangedSinceIsRefused() {
        let before = nails()
        var after = before
        after.title = "Nails"
        var current = after
        current.lastDone = today
        #expect(ClaudeRules.restoreEntry(current: current, before: before, after: after) == nil)
    }

    @Test func aNewEntryCanBeUndoneOnceItHasAReminder() {
        let created = nails(reminder: nil)
        var current = created
        current.reminder = .linked(id: "r1", externalID: "x1")
        #expect(ClaudeRules.canUndoNewEntry(current: current, created: created))
    }

    @Test func aDeletedEntryComesBackWithAFreshReminder() {
        #expect(ClaudeRules.restoringDeleted(nails()).reminder == nil)
        #expect(ClaudeRules.restoringDeleted(nails(reminder: .off)).reminder == .off)
    }
}
