import Foundation

/// A change Claude asked for that Compass won't make, in words Claude can act on.
public struct ClaudeRefusal: Error, Hashable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// What Claude may change through Compass's endpoint (seam 31): money goals'
/// definitions (never deleted), reminders, habits and check-ins, the vision,
/// the Playbook and its sizes, notes, a transaction's note, flags and
/// category, the budget's amounts and roles, and events in the Compass
/// calendar, only its own; the rest of what Claude keeps up is in
/// `ClaudeUpkeep`. Synced balances, a transaction's amount, date and
/// merchant, and sync stay read-only. Every change is logged with what undo
/// needs, and undo restores only what still holds Claude's change.
public enum ClaudeRules {
    // MARK: Goals

    /// What a new goal measures.
    public enum Measures: Hashable, Sendable {
        case netWorth
        case accounts(Set<UUID>)
        case fire(annualSpending: Decimal, multiplier: Decimal)
    }

    public static func newGoal(
        name: String, measures: Measures, target: Decimal?, targetMin: Decimal?,
        targetDate: Day?, note: String = "", accounts: [Account]
    ) throws -> Goal {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ClaudeRefusal("A goal needs a name.") }
        let kind: GoalKind =
            switch measures {
            case .netWorth: .netWorth
            case .accounts(let ids): .accountTotal(ids)
            case .fire(let spending, let multiplier): .fire(annualSpending: spending, multiplier: multiplier)
            }
        if case .fire = kind, target != nil {
            throw ClaudeRefusal("A financial independence goal's target is annual spending times the multiplier; give annual_spending, not target.")
        }
        let goal = Goal(
            name: name, kind: kind, target: target ?? 0, targetMin: targetMin, targetDate: targetDate,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        try check(goal, accounts: accounts)
        return goal
    }

    /// Changes a goal's target, minimum, date (`.some(nil)` clears it),
    /// accounts or note. Only an active goal changes; its status, reward and
    /// history are left alone.
    public static func changeGoal(
        _ goal: Goal, target: Decimal?, targetMin: Decimal??, targetDate: Day??,
        accountIDs: Set<UUID>?, note: String? = nil, accounts: [Account]
    ) throws -> Goal {
        switch goal.status {
        case .active: break
        case .achieved:
            throw ClaudeRefusal(
                "\(goal.name) is already achieved, so it stays as it was reached. The owner can edit it in Goals, or Claude can create the next goal.")
        case .retired: throw ClaudeRefusal("\(goal.name) is retired. The owner can edit it in Goals, or Claude can create a new goal.")
        }
        var changed = goal
        if let target {
            if case .fire = goal.kind {
                throw ClaudeRefusal(
                    "\(goal.name) is a financial independence goal: its target is annual spending times the multiplier, so it can't be set directly.")
            }
            changed.target = target
        }
        if let targetMin { changed.targetMin = targetMin }
        if let targetDate { changed.targetDate = targetDate }
        if let note { changed.note = note.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let accountIDs {
            guard case .accountTotal = goal.kind else {
                throw ClaudeRefusal(
                    "\(goal.name) measures \(goal.kind == .netWorth ? "net worth" : "investable assets"), not chosen accounts, so it has no accounts to change."
                )
            }
            changed.kind = .accountTotal(accountIDs)
        }
        guard changed != goal else { throw ClaudeRefusal("That's what \(goal.name) already is; nothing to change.") }
        try check(changed, accounts: accounts)
        return changed
    }

    /// The earlier definition back, keeping what happened since (reached,
    /// a reward claimed); nil when the definition changed since Claude's change.
    public static func undoGoalChange(current: Goal, before: Goal, after: Goal) -> Goal? {
        guard definition(current) == definition(after) else { return nil }
        var restored = current
        restored.name = before.name
        restored.kind = before.kind
        restored.target = before.target
        restored.targetMin = before.targetMin
        restored.targetDate = before.targetDate
        restored.note = before.note
        return restored
    }

    /// Whether a goal Claude created is still as it made it, so undo can remove it.
    public static func canUndoNewGoal(current: Goal, created: Goal) -> Bool {
        definition(current) == definition(created)
    }

    // MARK: Habits

    /// As the habit editor allows: a title, one to seven times a week, any
    /// start day. Not a second active habit with the same title.
    public static func newHabit(title: String, perWeek: Int, startedOn: Day, habits: [Habit]) throws -> Habit {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ClaudeRefusal("A habit needs a title.") }
        guard (1...7).contains(perWeek) else { throw ClaudeRefusal("per_week must be from 1 to 7.") }
        if habits.contains(where: { !$0.archived && $0.title.sameTitle(as: title) }) {
            throw ClaudeRefusal("There's already a habit called \(title); check in on it instead.")
        }
        return Habit(title: title, perWeek: perWeek, startedOn: startedOn)
    }

    /// Ticks a day as the Life overview does, settling it for a linked
    /// reminder. Nil when it's already ticked: Claude only adds check-ins.
    public static func checkIn(_ habit: Habit, on day: Day, today: Day, reminders: [Reminder]) throws -> Habit? {
        guard !habit.archived else { throw ClaudeRefusal("\(habit.title) is archived.") }
        guard day <= today else { throw ClaudeRefusal("\(day.iso) hasn't happened yet; check-ins are for today or earlier.") }
        guard !habit.checkIns.contains(day) else { return nil }
        guard Habits.canCheckIn(habit, on: day, today: today) else {
            throw ClaudeRefusal("\(habit.title) started the week of \(Week(habit.startedOn).start.iso); days before that can't be ticked.")
        }
        return HabitReminderLink.toggle(habit, on: day, reminders: reminders, today: today).habit
    }

    /// The day unticked again; nil when it already was.
    public static func undoCheckIn(current: Habit, day: Day, today: Day) -> Habit? {
        guard current.checkIns.contains(day) else { return nil }
        return HabitReminderLink.toggle(current, on: day, reminders: [], today: today).habit
    }

    /// A habit Claude added goes again only while it's as Claude made it, with no check-ins.
    public static func canUndoNewHabit(current: Habit, created: Habit) -> Bool {
        current.checkIns.isEmpty && current.title == created.title && current.perWeek == created.perWeek && current.startedOn == created.startedOn
    }

    // MARK: The vision

    /// The vision is replaced whole, never emptied.
    public static func checkVision(_ text: String, current: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeRefusal("The vision can't be emptied through Claude; the owner can clear it in Vision.")
        }
        guard text != current else { throw ClaudeRefusal("That's the vision already; nothing to change.") }
    }

    /// A year's bets, replaced whole as one a line, never cleared.
    public static func bets(_ bets: [String], current: String) throws -> String {
        let lines = bets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw ClaudeRefusal("The bets can't be cleared through Claude; the owner can clear them on the vision card.") }
        guard lines != YearlyBets.lines(current) else { throw ClaudeRefusal("Those are the bets already; nothing to change.") }
        return lines.joined(separator: "\n")
    }

    // MARK: The budget

    /// One change to the budget, as the budget's editor makes it: the flexible
    /// budget, a fixed or irregular bill's amount, planned income or a savings
    /// line (nil takes the line out) for a month or from it on, or a
    /// category's role, which is the same in every month. Amounts can't be
    /// below zero, a flexible category has no amount of its own, the budget
    /// plans up to a year ahead, and something has to change.
    public static func editBudget(
        _ schedule: BudgetSchedule, _ edit: BudgetEdit, in month: Month,
        _ scope: BudgetSchedule.Scope, today: Month, flexibleIsRemainder: Bool = false
    ) throws -> BudgetSchedule {
        guard month <= today.adding(12) else { throw ClaudeRefusal("The budget plans up to a year ahead.") }
        guard month >= today else { throw ClaudeRefusal("Past months keep what they planned; the owner can change them in Spending.") }
        func check(_ amount: Decimal?) throws {
            if let amount, amount < 0 { throw ClaudeRefusal("Budget amounts can't be below zero.") }
        }
        let plan = schedule.plan(for: month)
        let after: BudgetSchedule
        switch edit {
        case .flexible(let amount):
            guard !flexibleIsRemainder else {
                throw ClaudeRefusal(
                    "With income planned, the flexible budget is what's left after bills and savings; change income, a bill or a savings line instead.")
            }
            try check(amount)
            after = schedule.setting(.flexible, to: amount, in: month, scope)
        case .bill(let category, let amount):
            try check(amount)
            guard plan.role(of: category) != .flexible else {
                throw ClaudeRefusal(
                    "\(category) is flexible, so it shares the flexible budget and has no amount of its own; use set_budget_role to make it fixed or irregular with an amount."
                )
            }
            after = schedule.setting(.bill(category), to: amount, in: month, scope)
        case .income(let category, let amount):
            try check(amount)
            after = schedule.setting(.income(category), to: amount, in: month, scope)
        case .saving(let account, let amount):
            try check(amount)
            after = schedule.setting(.saving(account), to: amount, in: month, scope)
        case .role(let category, let role, let expected):
            try check(expected)
            if role == .flexible, expected != nil {
                throw ClaudeRefusal("A flexible category has no amount of its own; it shares the flexible budget.")
            }
            after = schedule.changing(month, scope) { plan in
                plan.roles[category] = role
                if role == .flexible { plan.expected[category] = nil } else if let expected { plan.expected[category] = expected }
            }
        }
        guard after != schedule else { throw ClaudeRefusal("That's the budget already; nothing to change.") }
        return after
    }

    /// Undoes one budget change: the amounts and roles it touched go back
    /// to what they were, month by month, and anything changed since stays.
    /// Nil when something it touched changed since. Months from a year back
    /// to a year ahead, the reach of the change and of its undo.
    public static func undoBudget(current: BudgetSchedule, before: BudgetSchedule, after: BudgetSchedule, today: Month) -> BudgetSchedule? {
        let months = (0...24).map { today.adding($0 - 12) }
        var touched = Set<BudgetAmount>()
        for month in months {
            let was = before.plan(for: month), now = after.plan(for: month)
            if was.flexibleBudget != now.flexibleBudget { touched.insert(.flexible) }
            for key in Set(was.expected.keys).union(now.expected.keys) where was.expected[key] != now.expected[key] { touched.insert(.bill(key)) }
            for key in Set(was.plannedIncome.keys).union(now.plannedIncome.keys) where was.plannedIncome[key] != now.plannedIncome[key] {
                touched.insert(.income(key))
            }
            for key in Set(was.savings.keys).union(now.savings.keys) where was.savings[key] != now.savings[key] { touched.insert(.saving(key)) }
        }
        let roles = Set(before.base.roles.keys).union(after.base.roles.keys).filter { before.base.roles[$0] != after.base.roles[$0] }
        for month in months {
            for amount in touched where current.plan(for: month)[amount] != after.plan(for: month)[amount] { return nil }
        }
        guard roles.allSatisfy({ current.base.roles[$0] == after.base.roles[$0] }) else { return nil }
        var restored = current
        for (index, month) in months.enumerated() {
            for amount in touched where restored.plan(for: month)[amount] != before.plan(for: month)[amount] {
                // The last month carries on past the window, as the change did.
                restored = restored.setting(
                    amount, to: before.plan(for: month)[amount], in: month,
                    index == months.count - 1 ? .onward : .onlyThisMonth)
            }
        }
        if !roles.isEmpty {
            restored = restored.changing(months[0], .onward) { plan in for key in roles { plan.roles[key] = before.base.roles[key] } }
        }
        return restored
    }

    // MARK: Transactions

    /// A transaction's note, one-off and reimbursable flags and category, as
    /// Claude may change them: the note tidied, an amount owed back above
    /// zero and no more than the charge, only on money out, and something
    /// has to change. The category must be one Compass knows (the caller checks).
    public static func editTransaction(_ transaction: Transaction, to edit: TransactionEdit) throws -> Transaction {
        var changed = transaction
        edit.saving(over: TransactionEdit(transaction)).apply(to: &changed)
        changed.note = changed.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !changed.reimbursable { changed.reimbursableAmount = nil }
        if changed.reimbursable {
            guard transaction.amount < 0 else { throw ClaudeRefusal("Only money out can be reimbursable.") }
            if let owed = changed.reimbursableAmount {
                guard owed > 0, owed <= -transaction.amount else {
                    throw ClaudeRefusal("The amount owed back must be above zero and no more than the charge (\(-transaction.amount)).")
                }
            }
        }
        guard TransactionEdit(changed) != TransactionEdit(transaction) else {
            throw ClaudeRefusal("That's how the transaction is already; nothing to change.")
        }
        return changed
    }

    // MARK: The Playbook

    /// As the Playbook's editor allows: a title and an area, a repeat of 1
    /// to 365 days, steps only on a routine and only on real weekdays, and
    /// not a second entry of the same title in its area.
    public static func checkPlaybookEntry(_ entry: PlaybookEntry, among entries: [PlaybookEntry]) throws {
        guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClaudeRefusal("An entry needs a title.") }
        guard !entry.area.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeRefusal("An entry needs an area, like Clothes, Hair, Grooming, Skin, Teeth or Fitness.")
        }
        if let every = entry.repeatEveryDays, !(1...365).contains(every) { throw ClaudeRefusal("repeat_every_days must be from 1 to 365.") }
        if entry.kind != .routine, !entry.steps.isEmpty { throw ClaudeRefusal("Only a routine has steps; make it kind routine.") }
        if entry.steps.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw ClaudeRefusal("Every step needs some text.")
        }
        if entry.steps.contains(where: { !$0.weekdays.isSubset(of: 0...6) }) { throw ClaudeRefusal("Weekdays run mon to sun.") }
        if entries.contains(where: { $0.id != entry.id && $0.area.sameTitle(as: entry.area) && $0.title.sameTitle(as: entry.title) }) {
            throw ClaudeRefusal("\(entry.area) already has \(entry.title); edit that one instead.")
        }
    }

    /// Done on a day, for a repeat: today or earlier, and not before it was
    /// last done. Nil when that's its last done day already.
    public static func markDone(_ entry: PlaybookEntry, on day: Day, today: Day) throws -> PlaybookEntry? {
        guard entry.repeatEveryDays != nil else {
            throw ClaudeRefusal("\(entry.title) doesn't repeat; give it repeat_every_days with edit_playbook_entry first.")
        }
        guard day <= today else { throw ClaudeRefusal("\(day.iso) hasn't happened yet.") }
        if let last = entry.lastDone {
            if last == day { return nil }
            if day < last { throw ClaudeRefusal("\(entry.title) was last done \(last.iso), after \(day.iso).") }
        }
        return Playbook.markDone(entry, on: day)
    }

    /// Sets the size on the line with this label (ignoring case), or adds a line.
    public static func setSize(_ sizes: PlaybookSizes, label: String, value: String) throws -> PlaybookSizes {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !value.isEmpty else { throw ClaudeRefusal("A size needs a label, like Suit, and a value, like 38S.") }
        var changed = sizes
        if let index = changed.rows.firstIndex(where: { $0.label.sameTitle(as: label) }) {
            guard changed.rows[index].value != value else { throw ClaudeRefusal("\(changed.rows[index].label) is \(value) already; nothing to change.") }
            changed.rows[index].value = value
        } else {
            changed.rows.append(PlaybookSize(label: label, value: value))
        }
        return changed
    }

    /// A Playbook entry or note Claude added goes again only while it's as Claude made it.
    public static func canUndoNewEntry<Entry: Equatable>(current: Entry, created: Entry) -> Bool {
        current == created
    }

    /// The same for a Playbook entry, whose reminder link the sync sets
    /// (seam 46) and undo leaves to it.
    public static func canUndoNewEntry(current: PlaybookEntry, created: PlaybookEntry) -> Bool {
        current.withoutReminder == created.withoutReminder
    }

    /// An edit to a Playbook entry, taken back while the entry is as Claude
    /// left it, keeping the reminder it's linked to now.
    public static func restoreEntry(current: PlaybookEntry, before: PlaybookEntry, after: PlaybookEntry) -> PlaybookEntry? {
        guard current.withoutReminder == after.withoutReminder else { return nil }
        var restored = before
        restored.reminder = current.reminder
        return restored
    }

    /// A deleted entry brought back: Compass deleted its reminder with it, so
    /// it gets a fresh one. One they'd turned off stays off.
    public static func restoringDeleted(_ entry: PlaybookEntry) -> PlaybookEntry {
        var restored = entry
        if restored.reminder != .off { restored.reminder = nil }
        return restored
    }

    // MARK: Notes

    /// The longest a note's body may be: notes are short rules and reasons.
    public static let longestNote = 1_000

    public static func newNote(topic: String, title: String, body: String, among notes: [Note], now: Date) throws -> Note {
        let note = Note(
            topic: Notes.topic(topic, existing: notes), title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines), updatedAt: stamp(now))
        try checkNote(note, among: notes)
        return note
    }

    /// Only the topic, title or body given changes; refused when none does.
    public static func editNote(
        _ note: Note, topic: String? = nil, title: String?, body: String?, among notes: [Note],
        now: Date
    ) throws -> Note {
        var edited = note
        if let topic { edited.topic = Notes.topic(topic, existing: notes.filter { $0.id != note.id }) }
        if let title { edited.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let body { edited.body = body.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (edited.topic, edited.title, edited.body) != (note.topic, note.title, note.body) else {
            throw ClaudeRefusal("That's what \(note.title) already says; nothing to change.")
        }
        edited.updatedAt = stamp(now)
        try checkNote(edited, among: notes)
        return edited
    }

    /// A note by its id, or by a title only one has.
    public static func note(_ wanted: String, in notes: [Note]) throws -> Note {
        if let same = notes.first(where: { $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame }) { return same }
        let titled = notes.filter { $0.title.sameTitle(as: wanted) }
        if titled.count == 1 { return titled[0] }
        throw ClaudeRefusal(
            titled.isEmpty
                ? "No note called \(wanted); the notes tool lists them with ids."
                : "More than one note is called \(wanted); use its id from the notes tool.")
    }

    /// A deleted note comes back unless a note of its title is there by then.
    public static func canRestoreDeleted(_ note: Note, among notes: [Note]) -> Bool {
        !notes.contains { $0.id == note.id || $0.title.sameTitle(as: note.title) }
    }

    /// As the notes screen allows: a topic, a title only it has, and a short body.
    public static func checkNote(_ note: Note, among notes: [Note]) throws {
        guard !note.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeRefusal("A note needs a topic: Money, Goals, Career, Life, or another.")
        }
        guard !note.title.isEmpty else { throw ClaudeRefusal("A note needs a title.") }
        guard !note.body.isEmpty else { throw ClaudeRefusal("A note needs some text.") }
        guard note.body.count <= longestNote else {
            throw ClaudeRefusal("A note is at most \(longestNote) characters; this one is \(note.body.count). Keep it to the rule and its reason.")
        }
        if let clash = notes.first(where: { $0.id != note.id && $0.title.sameTitle(as: note.title) }) {
            throw ClaudeRefusal("There's already a note called \(clash.title); edit that one instead.")
        }
    }

    /// To the second, as a backup writes it, so a note reads back exactly.
    private static func stamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    // MARK: Reminders

    /// A list by name, ignoring case and spaces around it.
    public static func list(named name: String, in lists: [ReminderList]) throws -> ReminderList {
        let matches = lists.filter { $0.named(name) }
        if matches.count == 1 { return matches[0] }
        throw ClaudeRefusal(
            matches.isEmpty
                ? "No Reminders list called \(name). Lists: \(lists.map(\.title).joined(separator: ", "))."
                : "There's more than one Reminders list called \(name); the owner can rename one in Reminders.")
    }

    /// An open reminder by its id, or by a title only one has: as Reminders
    /// has it, or as the reminders tool shows it (without its list's name).
    public static func reminder(_ wanted: String, in reminders: [Reminder], lists: [ReminderList] = []) throws -> Reminder {
        if let same = reminders.first(where: { $0.id == wanted }) { return same }
        let names = Dictionary(lists.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let titled = reminders.filter {
            $0.title.sameTitle(as: wanted) || ReminderAgenda.shortTitle($0.title, list: names[$0.listID] ?? "").sameTitle(as: wanted)
        }
        if titled.count == 1 { return titled[0] }
        throw ClaudeRefusal(
            titled.isEmpty
                ? "No open reminder called \(wanted); the reminders tool lists them with ids."
                : "More than one open reminder is called \(wanted); use its id from the reminders tool.")
    }

    public static func checkEdit(_ edit: ReminderEdit, current: ReminderEdit) throws {
        guard !edit.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClaudeRefusal("A reminder needs a title.") }
        guard edit != current else { throw ClaudeRefusal("That's what the reminder already says; nothing to change.") }
    }

    // MARK: The Compass calendar

    /// Claude's events go in a calendar of this name, made on first use.
    public static let calendarName = "Compass"

    /// The longest event Claude may make or move to.
    public static let longestEvent: TimeInterval = 14 * 86_400

    /// In the Compass calendar Claude touches only events it made; it deletes nowhere else.
    public static func checkOwn(_ event: CalendarEvent, compassCalendarID: String?, own: Set<String>) throws {
        guard let compassCalendarID, event.calendarID == compassCalendarID else {
            throw ClaudeRefusal(
                "\(event.title) isn't in the Compass calendar. Claude deletes only events it created there (move_event and edit_event work on their other calendars)."
            )
        }
        guard own.contains(event.id) else {
            throw ClaudeRefusal("Claude didn't create \(event.title), so it can't change or delete it in the Compass calendar.")
        }
    }

    /// Claude moves or edits an event on any calendar they read (Nov 1, 2026),
    /// once they've said yes: in the Compass calendar only its own, elsewhere
    /// not on a calendar they hide or one that's read-only, nor an invite
    /// someone else organizes or one of theirs with guests (a change tells them).
    public static func checkChange(
        _ event: CalendarEvent, access: EventAccess, hidden: Set<String>,
        compassCalendarID: String?, own: Set<String>
    ) throws {
        if event.calendarID == compassCalendarID {
            return try checkOwn(event, compassCalendarID: compassCalendarID, own: own)
        }
        guard !hidden.contains(event.calendarID) else {
            throw ClaudeRefusal("They hide the \(access.calendarTitle) calendar from Compass, so Claude doesn't change \(event.title).")
        }
        guard access.allowsChanges else { throw ClaudeRefusal("The \(access.calendarTitle) calendar is read-only, so \(event.title) can't change.") }
        guard !access.organizedBySomeoneElse else {
            throw ClaudeRefusal("Someone else organizes \(event.title), and changing it could notify them; they can change it in Calendar.")
        }
        guard !access.hasGuests else {
            throw ClaudeRefusal("\(event.title) has guests, and changing it would send them an update; they can change it in Calendar.")
        }
    }

    /// One date of an event: a repeating event's dates share its identifier,
    /// so the id Claude is given adds the date's start ("ABC@1793448000").
    public static func occurrenceID(_ itemID: String, start: Date) -> String {
        "\(itemID)@\(Int(start.timeIntervalSince1970))"
    }

    /// An id's event and, when it names one date, that date's start. An id
    /// ending in anything but whole seconds (an external one's "@google.com")
    /// is the event itself.
    public static func occurrence(_ id: String) -> (itemID: String, start: Date?) {
        guard let at = id.lastIndex(of: "@"), case let seconds = id[id.index(after: at)...],
            !seconds.isEmpty, seconds.allSatisfy(\.isNumber), let value = TimeInterval(seconds)
        else { return (id, nil) }
        return (String(id[..<at]), Date(timeIntervalSince1970: value))
    }

    public static func checkTimes(start: Date, end: Date) throws {
        guard end > start else { throw ClaudeRefusal("end must be after start.") }
        guard end.timeIntervalSince(start) <= longestEvent else { throw ClaudeRefusal("An event can be at most 14 days long.") }
    }

    /// The events Claude made: each it created, and each brought back by undoing a delete.
    public static func ownEvents(_ log: [ClaudeActivity]) -> Set<String> {
        var own: Set<String> = []
        for entry in log {
            if case .eventCreated(let event) = entry.change {
                own.insert(event.id)
                if let external = event.externalID { own.insert(external) }
            }
            if let restored = entry.restoredEventID { own.insert(restored) }
        }
        return own
    }

    // MARK: Refusals

    /// For a tool Compass doesn't have, like one that would change money.
    public static func refusal(forTool name: String) -> String {
        "Compass has no tool called \(name). Synced balances, balance history, sync and transactions' amounts, dates and merchants are read-only for Claude, "
            + "nothing moves money, and goals and synced transactions are never deleted. Claude can create, change or retire money goals and set their rewards, "
            + "add, edit, move, tick off, reopen or delete reminders, add, edit, archive or delete habits and check-ins, edit the vision and this year's bets, "
            + "keep up the Playbook and its sizes, add, edit or delete notes, change pay settings and expected bonuses and vests, "
            + "create manual accounts, rename or archive accounts and enter manual accounts' balances, set or delete merchant rules, "
            + "create, rename or merge categories, add a transaction to a manual account (add_transaction), split one into categories, "
            + "change a transaction's note, one-off and reimbursable flags or category (edit_transaction), "
            + "change the budget's amounts and categories' roles (set_budget_amount, set_budget_role), "
            + "create events in the Compass calendar (deleting only its own), and move or edit events on any calendar Compass reads."
    }

    // MARK: Undo

    /// `before`, when what's there is still Claude's `after`; nil when it changed since.
    public static func restore<Value: Equatable>(current: Value, before: Value, after: Value) -> Value? {
        current == after ? before : nil
    }

    private static func definition(_ goal: Goal) -> [AnyHashable] {
        [goal.name, goal.kind, goal.target, goal.targetMin, goal.targetDate, goal.note]
    }

    private static func check(_ goal: Goal, accounts: [Account]) throws {
        if case .fire = goal.kind, goal.targetMin != nil {
            throw ClaudeRefusal("A financial independence goal has no minimum; its target is annual spending times the multiplier.")
        }
        if case .accountTotal(let ids) = goal.kind {
            let known = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            for id in ids {
                guard let account = known[id] else { throw ClaudeRefusal("No account with id \(id.uuidString).") }
                if account.archivedOn != nil { throw ClaudeRefusal("\(account.name) is closed (archived), so a goal can't count it.") }
            }
        }
        switch goal.problem {
        case nil: return
        case .noAccounts: throw ClaudeRefusal("An account-total goal needs at least one account.")
        case .noSpending: throw ClaudeRefusal("A financial independence goal needs annual spending above zero.")
        case .noTarget: throw ClaudeRefusal("A goal needs a target above zero.")
        case .minimumNotBelowTarget:
            throw ClaudeRefusal("The minimum (\(goal.targetMin ?? 0)) must be below the target (\(goal.target)); change target_min too.")
        }
    }
}

/// A reminder's title, due date, notes and repeat, as an edit sets them.
/// Notes and the repeat are nil when the edit leaves them alone (and in
/// edits logged before them).
public struct ReminderEdit: Hashable, Codable, Sendable {
    public var title: String
    public var due: ReminderDue?
    public var notes: String?
    public var repeating: Repeating?

    public init(title: String, due: ReminderDue?, notes: String? = nil) {
        self.title = title
        self.due = due
        self.notes = notes
    }
}

/// An event Claude made, moved or deleted, with enough to make it again.
/// What Calendar says about an event's calendar and invite.
public struct EventAccess: Hashable, Sendable {
    public var calendarTitle: String
    public var allowsChanges: Bool
    public var organizedBySomeoneElse: Bool
    /// Others are invited, so a change sends them an update.
    public var hasGuests: Bool

    public init(calendarTitle: String, allowsChanges: Bool, organizedBySomeoneElse: Bool, hasGuests: Bool = false) {
        self.calendarTitle = calendarTitle
        self.allowsChanges = allowsChanges
        self.organizedBySomeoneElse = organizedBySomeoneElse
        self.hasGuests = hasGuests
    }
}

public struct ClaudeEvent: Hashable, Codable, Sendable {
    /// Its `calendarItemIdentifier` in EventKit.
    public var id: String
    /// Its `calendarItemExternalIdentifier`, which survives an iCloud sync
    /// that changes the identifier.
    public var externalID: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var notes: String?

    public init(id: String, externalID: String?, title: String, start: Date, end: Date, isAllDay: Bool, notes: String? = nil) {
        self.id = id
        self.externalID = externalID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.notes = notes
    }
}

/// One change, with what was there before.
public enum ClaudeChange: Hashable, Codable, Sendable {
    case goalCreated(Goal)
    case goalChanged(before: Goal, after: Goal)
    case habitCreated(Habit)
    case checkIn(habitID: UUID, title: String, day: Day)
    case visionEdited(before: String, after: String)
    case betsEdited(year: Int, before: String, after: String)
    case transactionEdited(id: UUID, before: TransactionEdit, after: TransactionEdit)
    case budgetChanged(before: BudgetSchedule, after: BudgetSchedule)
    case reminderAdded(id: String, title: String)
    case reminderEdited(id: String, before: ReminderEdit, after: ReminderEdit)
    case reminderCompleted(id: String, title: String)
    case eventCreated(ClaudeEvent)
    case eventMoved(before: ClaudeEvent, after: ClaudeEvent)
    case eventDeleted(ClaudeEvent)
    case playbookAdded(PlaybookEntry)
    case playbookEdited(before: PlaybookEntry, after: PlaybookEntry)
    case sizesEdited(before: PlaybookSizes, after: PlaybookSizes)
    case noteAdded(Note)
    case noteEdited(before: Note, after: Note)
    case noteDeleted(Note)
    // Full write coverage (Oct 31, 2026).
    case eventEdited(before: ClaudeEvent, after: ClaudeEvent)
    case playbookDeleted(PlaybookEntry)
    case habitEdited(before: Habit, after: Habit)
    case habitDeleted(Habit)
    case checkInRemoved(habitID: UUID, title: String, day: Day)
    case goalRetired(before: Goal, after: Goal)
    case rewardSet(goalID: UUID, before: Reward?, after: Reward)
    case reminderMoved(id: String, title: String, fromListID: String, toListID: String)
    case reminderDeleted(DeletedReminder)
    case reminderReopened(id: String, title: String)
    /// A repeat ticked: it moved on from `due`, leaving a done copy that day.
    case repeatCompleted(id: String, title: String, listID: String, due: ReminderDue?, day: Day)
    case payChanged(before: PayProfile, after: PayProfile)
    case accountEdited(before: Account, after: Account)
    case balanceEntered(before: BalanceSnapshot?, after: BalanceSnapshot)
    case ruleSet(key: String, before: String?, after: String, refiled: [Refiled])
    case ruleDeleted(key: String, category: String)
    case categoryCreated(name: String, kind: CategoryKind)
    case categoryRenamed(from: String, to: String)
    case categoryMerged(CategoryMerge)
    case transactionAdded(Transaction)
    case accountCreated(Account, opening: BalanceSnapshot)
    /// A This Quarter reminder's reward, kept on its target link (Nov 1, 2026).
    case quarterRewardSet(linkID: UUID, title: String, before: Reward?, after: Reward)
}

/// A reminder Claude deleted, with enough to make it again.
public struct DeletedReminder: Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var listID: String
    public var due: ReminderDue?
    public var notes: String?

    public init(id: String, title: String, listID: String, due: ReminderDue?, notes: String?) {
        self.id = id
        self.title = title
        self.listID = listID
        self.due = due
        self.notes = notes
    }
}

/// An entry in Compass's list of changes Claude made.
public struct ClaudeActivity: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var at: Date
    /// The tool's name, like add_reminder.
    public var tool: String
    /// In plain words: "Added “Renew passport” to Admin, due Oct 30".
    public var summary: String
    public var change: ClaudeChange
    public var undoneAt: Date?
    /// Undoing a delete makes the event again, under a new identifier.
    public var restoredEventID: String?

    public init(id: UUID = UUID(), at: Date = .now, tool: String, summary: String, change: ClaudeChange) {
        self.id = id
        self.at = at
        self.tool = tool
        self.summary = summary
        self.change = change
    }
}

extension Day {
    /// YYYY-MM-DD.
    public var iso: String { String(format: "%04d-%02d-%02d", year, month, dayOfMonth) }
}

/// What Claude may change on a transaction, for its edit and its undo.
public struct TransactionEdit: Hashable, Codable, Sendable {
    public var category: String?
    public var note: String
    public var oneOff: Bool
    public var reimbursable: Bool
    public var reimbursableAmount: Decimal?
    public var splits: [TransactionSplit]
    /// The goal that paid for it (seam 44), and how much (all of it when nil).
    public var paidFromGoal: UUID?
    public var paidFromGoalAmount: Decimal?

    public init(_ transaction: Transaction) {
        category = transaction.category
        note = transaction.note
        oneOff = transaction.oneOff
        reimbursable = transaction.reimbursable
        reimbursableAmount = transaction.reimbursableAmount
        splits = transaction.splits
        paidFromGoal = transaction.paidFromGoal
        paidFromGoalAmount = transaction.paidFromGoalAmount
    }

    public func apply(to transaction: inout Transaction) {
        transaction.category = category
        transaction.note = note
        transaction.oneOff = oneOff
        transaction.reimbursable = reimbursable
        transaction.reimbursableAmount = reimbursableAmount
        transaction.splits = splits
        transaction.paidFromGoal = paidFromGoal
        transaction.paidFromGoalAmount = paidFromGoalAmount
    }

    /// This edit as saved over what's there: filing the whole transaction
    /// under another category takes its split off (seam 43), unless the
    /// edit sets the split itself, as splitting and undo do.
    public func saving(over current: TransactionEdit) -> TransactionEdit {
        var saved = self
        if category != current.category, splits == current.splits { saved.splits = [] }
        return saved
    }

    /// Edits logged before splits, or a goal paying, read back with none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        note = try container.decode(String.self, forKey: .note)
        oneOff = try container.decode(Bool.self, forKey: .oneOff)
        reimbursable = try container.decode(Bool.self, forKey: .reimbursable)
        reimbursableAmount = try container.decodeIfPresent(Decimal.self, forKey: .reimbursableAmount)
        splits = try container.decodeIfPresent([TransactionSplit].self, forKey: .splits) ?? []
        paidFromGoal = try container.decodeIfPresent(UUID.self, forKey: .paidFromGoal)
        paidFromGoalAmount = try container.decodeIfPresent(Decimal.self, forKey: .paidFromGoalAmount)
    }
}

/// One change Claude makes to the budget (`ClaudeRules.editBudget`).
public enum BudgetEdit: Hashable, Sendable {
    case flexible(Decimal)
    case bill(String, Decimal?)
    case income(String, Decimal?)
    /// Money moved into an account (its id) a month.
    case saving(UUID, Decimal?)
    case role(String, BudgetRole, expected: Decimal?)
}
