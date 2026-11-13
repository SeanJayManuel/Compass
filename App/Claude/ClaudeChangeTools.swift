import Core
import Foundation

/// The tools that let Claude change things (seam 31): goals' definitions,
/// reminders, habits and check-ins, the vision, the Playbook
/// (`ClaudePlaybookTools`) and events in the Compass calendar. The rules are `ClaudeRules`, in Core. Every change is logged
/// (Settings > Security > Changes by Claude), and undo takes it back while
/// it still holds.
extension ClaudeTools {
    var changeTools: [ClaudeTool] {
        func text(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        let amount = text("Dollars, like \"60000\" or \"60,000.50\".")
        let accounts: [String: Any] = [
            "type": "array", "items": ["type": "string"],
            "description": "Account names or ids (from accounts). Not closed ones."
        ]
        let when = "YYYY-MM-DD for a day, or an ISO 8601 time like 2026-10-30T09:00 (their local time without an offset)."
        let repeating: [String: Any] = [
            "type": ["object", "string"],
            "description":
                "How it repeats: a frequency as text (\"weekly\", \"every 10 days\") or an object; \"none\" removes a repeat. A repeat needs a due date (today if none is given). Check the reminders tool's repeat field first so as not to add a second reminder for something already repeating.",
            "properties": [
                "frequency": text("daily, weekly, monthly or yearly (or \"every 10 days\")."),
                "every": ["type": "integer", "description": "Every this many days, weeks, months or years, 1 to 365. Default 1."],
                "weekdays": ["type": "array", "items": ["type": "string"], "description": "For weekly only: days like [\"sun\"]."],
                "until": text("YYYY-MM-DD, the last day it repeats (optional).")
            ]
        ]
        return [
            tool(
                "create_goal",
                "Create a money goal. It measures net worth, chosen accounts' total, or investable assets against annual spending (financial independence). Balances are never touched.",
                [
                    "name": text("What they'd call it, like \"House deposit\"."),
                    "measures": ["type": "string", "enum": ["net_worth", "accounts", "fire"], "description": "Default net_worth."],
                    "target": amount, "target_min": text("The bottom of a range, below target (optional)."),
                    "target_date": text("YYYY-MM-DD (optional)."), "accounts": accounts,
                    "annual_spending": text("For fire: annual spending in dollars."),
                    "multiplier": text("For fire: spending times this is the target. Default 25."),
                    "note": text("Why it matters to them, in their words (optional), like \"by my 30th birthday\".")
                ],
                required: ["name"], changes: true, destructive: false, run: { args in try self.createGoal(args) }),
            tool(
                "update_goal",
                "Change an active money goal's target, minimum, date, accounts (only for one measuring chosen accounts) or note. Goals are never deleted, and balances never touched.",
                [
                    "goal": text("The goal's name or id (from goals)."), "target": amount,
                    "target_min": text("Dollars, or \"none\" to drop the range."),
                    "target_date": text("YYYY-MM-DD, or \"none\" for no date."), "accounts": accounts,
                    "note": text("Why it matters to them; \"none\" clears it.")
                ],
                required: ["goal"], changes: true, run: { args in try self.updateGoal(args) }),
            tool(
                "add_reminder", "Add a reminder to one of their Reminders lists by name, like This Week, This Quarter, Long Term, Living List or Admin.",
                [
                    "title": text("The reminder."), "list": text("The list's name. Default This Week."), "due": text("Optional. " + when),
                    "notes": text("Optional notes."), "repeat": repeating
                ],
                required: ["title"], changes: true, destructive: false, run: { args in try self.addReminder(args) }),
            tool(
                "edit_reminder",
                "Change an open reminder's title, due date, notes or repeat. A habit's reminder keeps its daily repeat, and a repeat the reminders tool shows as custom is changed in Reminders.",
                [
                    "reminder": text("Its id (from reminders), or a title only one open reminder has."),
                    "title": text("The new title."), "due": text(when + " Or \"none\" for no date."),
                    "notes": text("Its notes, replacing any; empty clears them."), "repeat": repeating
                ],
                required: ["reminder"], changes: true, run: { args in try self.editReminder(args) }),
            tool(
                "complete_reminder", "Tick off an open reminder. A repeating one moves on to its next date, as in Reminders.",
                ["reminder": text("Its id (from reminders), or a title only one open reminder has.")],
                required: ["reminder"], changes: true, run: { args in try self.completeReminder(args) }),
            tool(
                "add_habit", "Add a weekly habit, like working out three times a week.",
                [
                    "title": text("The habit."), "per_week": ["type": "integer", "description": "1 to 7."],
                    "started_on": text("YYYY-MM-DD. Default today.")
                ],
                required: ["title", "per_week"], changes: true, destructive: false, run: { args in try self.addHabit(args) }),
            tool(
                "check_in_habit",
                "Record a habit's check-in for a day (today or earlier, from its first week). Already ticked is left as is. A linked reminder in Reminders is left alone.",
                ["habit": text("The habit's title or id (from habits)."), "date": text("YYYY-MM-DD. Default today.")],
                required: ["habit"], changes: true, destructive: false, run: { args in try self.checkIn(args) }),
            tool(
                "edit_vision",
                "Replace their vision (what a good life looks like) with new text. Read it with vision first and keep their words unless they asked otherwise.",
                ["text": text("The whole vision.")], required: ["text"], changes: true, run: { args in try self.editVision(args) }),
            tool(
                "edit_bets",
                "Replace this year's bets (the few things they're betting the year on, under the vision) with a new list. Read them with vision first and keep their words unless they asked otherwise.",
                ["bets": ["type": "array", "items": ["type": "string"], "description": "Every bet, one an item."]],
                required: ["bets"], changes: true, run: { args in try self.editBets(args) }),
            tool(
                "edit_transaction",
                "Change one transaction's note, whether it's a one-off, whether someone owes them for it (all of it, or reimbursable_amount; what's owed back isn't counted as spending), which goal paid for it (paid_from_goal: a cash goal like the Travel Fund pays for a flight, so it stays in Spending but out of the budget, and the money they move out of the fund to cover it isn't counted as saving taken back), or its category. Only the fields given change. A new category files only this transaction (no merchant rule is learned) and must be one Compass already has (see categories). Amounts, dates and merchants can't change.",
                [
                    "transaction": text("Its id (from transactions)."), "note": text("Their note; empty clears it."),
                    "one_off": ["type": "boolean", "description": "Not a usual charge."],
                    "reimbursable": ["type": "boolean", "description": "Someone owes them for it. Money out only."],
                    "reimbursable_amount": text("What's owed back, like \"40\"; leave out for all of it."),
                    "paid_from_goal": text(
                        "The goal's name or id (from goals) whose money paid for it, or \"none\" to take that off. Only an active goal of cash accounts; spending only, not a split one."
                    ),
                    "paid_from_goal_amount": text("How much the goal paid, like \"250\"; leave out for all of it."),
                    "category": text("A category Compass already has.")
                ],
                required: ["transaction"], changes: true, run: { args in try self.editTransaction(args) }),
            tool(
                "set_budget_amount",
                "Change one amount in their budget, as the budget editor does: a fixed or irregular bill's expected amount, an income category's planned amount, what they plan to move into a savings or investing account a month, or (only in a month with no income planned) the flexible budget. With income planned, the flexible budget is what's left after bills and savings, so changing those changes it. From a month on (the default) or for that month only. This month or later. Read budget first.",
                [
                    "what": ["type": "string", "enum": ["flexible", "bill", "income", "savings"], "description": "Which kind of amount."],
                    "name": text("The category (bill or income) or the account (savings), by name or id. Not for flexible."),
                    "amount": text("Dollars a month, like \"500\"; \"remove\" takes a bill, income or savings line out."),
                    "month": text("YYYY-MM. Default this month."),
                    "scope": ["type": "string", "enum": ["onward", "this_month"], "description": "Default onward: this month and every one after."]
                ],
                required: ["what", "amount"], changes: true, run: { args in try self.setBudgetAmount(args) }),
            tool(
                "set_budget_role",
                "Set a spending category's budget role, the same in every month: fixed (a bill with an expected amount), flexible (shares the flexible budget) or irregular (annual or occasional costs like a card fee or charity, kept out of the flexible budget and its pace). Fixed and irregular can take an expected amount.",
                [
                    "category": text("A category Compass already has."),
                    "role": ["type": "string", "enum": ["fixed", "flexible", "irregular"]],
                    "expected": text("For fixed or irregular: dollars a month, like \"200\". Optional."),
                    "month": text("YYYY-MM the expected amount starts in. Default this month.")
                ],
                required: ["category", "role"], changes: true, run: { args in try self.setBudgetRole(args) }),
            tool(
                "create_event", "Add an event to the Compass calendar in Apple Calendar (made on first use). Claude can't add events to their other calendars.",
                [
                    "title": text("The event."), "start": text(when),
                    "end": text(when + " For all-day, the last day. Default an hour after start, or the same day."),
                    "all_day": ["type": "boolean", "description": "Default false."], "notes": text("Optional.")
                ],
                required: ["title", "start"], changes: true, destructive: false, run: { args in try self.createEvent(args) }),
            tool(
                "move_event",
                "Move an event: one Claude created in the Compass calendar, or one on any other calendar they read (ask them first, naming the event and the new time). Read-only calendars and invites someone else organizes are refused. One date of a repeating event moves by its id from the calendar tool; the rest of the series stays.",
                [
                    "event": text("Its id (from calendar or create_event)."), "start": text(when),
                    "end": text(when + " Default keeps its length.")
                ],
                required: ["event", "start"], changes: true, run: { args in try self.moveEvent(args) }),
            tool(
                "delete_event", "Delete an event Claude created in the Compass calendar. Other events are refused.",
                ["event": text("Its id (from calendar or create_event).")], required: ["event"], changes: true, run: { args in try self.deleteEvent(args) }),
            tool(
                "changes", "The changes Claude has made through Compass, newest first, with whether each was undone.",
                ["limit": ["type": "integer", "description": "At most this many (default 20, up to 200)."]], run: { args in try self.changes(args) }),
            tool(
                "undo_change", "Take back one change Claude made, as Undo in Compass does. Refused when what it changed was changed again since.",
                ["change": text("Its id (from changes).")], required: ["change"], changes: true, run: { args in try self.undoChange(args) })
        ] + playbookChangeTools + noteChangeTools + upkeepChangeTools + categoryChangeTools
    }

    private func undoChange(_ args: Arguments) throws -> [String: Any] {
        guard let id = UUID(uuidString: try args.required("change")) else { throw Problem("change must be an id from changes.") }
        let entry = try undo(id)
        return ["undone": entry.summary, "change": id.uuidString]
    }

    // MARK: - Goals

    private func createGoal(_ args: Arguments) throws -> [String: Any] {
        let accounts = try store.accounts()
        let kind = try args.choice("measures", in: ["net_worth", "accounts", "fire"]) ?? "net_worth"
        // Arguments for another kind of goal mean Claude meant that kind; say so rather than drop them.
        if kind != "accounts", args.values["accounts"] != nil { throw Problem("accounts only go with measures \"accounts\".") }
        if kind != "fire", args.values["annual_spending"] != nil || args.values["multiplier"] != nil {
            throw Problem("annual_spending and multiplier only go with measures \"fire\".")
        }
        let measures: ClaudeRules.Measures =
            switch kind {
            case "accounts": .accounts(try accountIDs(args, in: accounts) ?? [])
            case "fire": .fire(annualSpending: try args.money("annual_spending") ?? 0, multiplier: try args.money("multiplier") ?? 25)
            default: .netWorth
            }
        let goal = try ClaudeRules.newGoal(
            name: try args.required("name"), measures: measures, target: try args.money("target"),
            targetMin: try args.money("target_min"), targetDate: try args.day("target_date"),
            note: args.string("note") ?? "", accounts: accounts)
        try store.save(goal)
        try store.refreshGoals(today: today)
        var summary = "Created the goal “\(goal.name)”: \(Self.money(goal.effectiveTarget))"
        if let date = goal.targetDate { summary += " by \(Self.longDay(date))" }
        try log("create_goal", summary, .goalCreated(goal))
        return ["created": summary, "goal": goal.id.uuidString]
    }

    private func updateGoal(_ args: Arguments) throws -> [String: Any] {
        let accounts = try store.accounts()
        let goal = try findGoal(try args.required("goal"))
        let changed = try ClaudeRules.changeGoal(
            goal, target: try args.money("target"),
            targetMin: try args.isNone("target_min") ? .some(nil) : try args.money("target_min").map { .some($0) },
            targetDate: try args.isNone("target_date") ? .some(nil) : try args.day("target_date").map { .some($0) },
            accountIDs: try accountIDs(args, in: accounts),
            note: try args.isNone("note") ? "" : args.string("note"), accounts: accounts)
        try store.save(changed)
        try store.refreshGoals(today: today)
        var parts: [String] = []
        if changed.target != goal.target { parts.append("target \(Self.money(goal.target)) → \(Self.money(changed.target))") }
        if changed.targetMin != goal.targetMin {
            parts.append("minimum \(goal.targetMin.map(Self.money) ?? "none") → \(changed.targetMin.map(Self.money) ?? "none")")
        }
        if changed.targetDate != goal.targetDate {
            parts.append("date \(goal.targetDate.map(Self.longDay) ?? "none") → \(changed.targetDate.map(Self.longDay) ?? "none")")
        }
        if changed.kind != goal.kind, case .accountTotal(let ids) = changed.kind {
            parts.append("accounts → \(accounts.filter { ids.contains($0.id) }.map { Self.displayName($0.name) }.sorted().joined(separator: ", "))")
        }
        if changed.note != goal.note { parts.append(changed.note.isEmpty ? "note cleared" : "note “\(changed.note)”") }
        let summary = "Changed “\(goal.name)”: \(parts.joined(separator: "; "))"
        try log("update_goal", summary, .goalChanged(before: goal, after: changed))
        return ["changed": summary, "goal": goal.id.uuidString]
    }

    func findGoal(_ wanted: String) throws -> Goal {
        let goals = try store.goals()
        if let goal = goals.first(where: { $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame }) { return goal }
        let named = goals.filter { $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
        if named.count == 1 { return named[0] }
        throw Problem(
            named.count > 1
                ? "More than one goal is called \(wanted); use its id from goals."
                : "No goal called \(wanted). Goals: \(goals.map(\.name).joined(separator: ", ")).")
    }

    private func accountIDs(_ args: Arguments, in accounts: [Account]) throws -> Set<UUID>? {
        guard let names = try args.strings("accounts") else { return nil }
        return Set(try names.map { try find($0, in: accounts).id })
    }

    // MARK: - Reminders

    func remindersReady() throws {
        guard reminders.access == .granted else { throw Problem("Compass can't use Reminders; they can allow it in the Life overview.") }
    }

    private func addReminder(_ args: Arguments) throws -> [String: Any] {
        try remindersReady()
        let title = try args.required("title")
        let list = try ClaudeRules.list(named: args.string("list") ?? ReminderListNames.saved.week.first ?? "This Week", in: reminders.lists)
        var edit = ReminderEdit(title: title, due: try args.due("due"))
        let repeating = try args.repeating("repeat")
        if case .rule = repeating, try args.isNone("due") { throw Problem("A repeat needs a due date; give one, or leave due out for today.") }
        if repeating != .never { try ClaudeRules.setRepeat(repeating, on: &edit, reminder: nil, linkedToHabit: false, today: today) }
        let rule = edit.repeating?.repeatRule
        let id = try reminders.add(title: title, listID: list.id, due: edit.due, notes: args.string("notes"), repeatRule: rule)
        let summary = "Added “\(title)” to \(list.title)" + (edit.due.map { ", due \(Self.due($0))" } ?? "") + (rule.map { ", repeating \($0.text)" } ?? "")
        try log("add_reminder", summary, .reminderAdded(id: id, title: title))
        return ["added": summary, "reminder": id]
    }

    private func editReminder(_ args: Arguments) throws -> [String: Any] {
        try remindersReady()
        let reminder = try ClaudeRules.reminder(try args.required("reminder"), in: reminders.reminders, lists: reminders.lists)
        var before = ReminderEdit(title: reminder.title, due: reminder.due)
        var after = before
        if let title = args.string("title") { after.title = title }
        if try args.isNone("due") { after.due = nil } else if let due = try args.due("due") { after.due = due }
        if let notes = args.values["notes"] {
            guard let text = notes as? String else { throw Problem("notes must be text.") }
            // Notes go in the log only when this edit changes them, so undo leaves others alone.
            before.notes = reminder.notes ?? ""
            after.notes = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let repeating = try args.repeating("repeat")
        if case .rule = repeating, try args.isNone("due") { throw Problem("A repeat needs a due date; give one, or leave due out for today.") }
        if repeating != nil {
            // Like notes: in the log only when this edit sets it.
            before.repeating = reminder.repeatRule.map(Repeating.rule) ?? (reminder.repeats ? nil : .never)
        }
        let linked = HabitReminderLink.linkedIDs(try store.habits(), reminders: reminders.reminders).contains(reminder.id)
        try ClaudeRules.setRepeat(repeating, on: &after, reminder: reminder, linkedToHabit: linked, today: today)
        try ClaudeRules.checkEdit(after, current: before)
        try reminders.edit(reminder.id, to: after)
        var parts: [String] = []
        if after.title != before.title { parts.append("now “\(after.title)”") }
        if after.due != before.due { parts.append("due \(before.due.map(Self.due) ?? "none") → \(after.due.map(Self.due) ?? "none")") }
        if after.notes != before.notes { parts.append(after.notes?.isEmpty == true ? "notes cleared" : "notes “\(after.notes ?? "")”") }
        if after.repeating != before.repeating { parts.append(after.repeating?.repeatRule.map { "repeats \($0.text)" } ?? "no longer repeats") }
        let summary = "Changed “\(before.title)”: \(parts.joined(separator: "; "))"
        try log("edit_reminder", summary, .reminderEdited(id: reminder.id, before: before, after: after))
        return ["changed": summary, "reminder": reminder.id]
    }

    private func completeReminder(_ args: Arguments) throws -> [String: Any] {
        try remindersReady()
        let reminder = try ClaudeRules.reminder(try args.required("reminder"), in: reminders.reminders, lists: reminders.lists)
        try reminders.setDone(reminder.id, true)
        guard reminder.repeats else {
            let summary = "Ticked off “\(reminder.title)”"
            try log("complete_reminder", summary, .reminderCompleted(id: reminder.id, title: reminder.title))
            return ["done": summary, "reminder": reminder.id]
        }
        let next = reminders.current(reminder.id)?.edit.due
        let summary = "Ticked off “\(reminder.title)”" + (next.map { ", next due \(Self.due($0))" } ?? "")
        try log(
            "complete_reminder", summary,
            .repeatCompleted(
                id: reminder.id, title: reminder.title, listID: reminder.listID,
                due: reminder.due, day: today))
        var answer: [String: Any] = ["done": summary, "reminder": reminder.id]
        if let next { answer["nextDue"] = iso(next.day) }
        return answer
    }

    // MARK: - Habits and the vision

    private func addHabit(_ args: Arguments) throws -> [String: Any] {
        guard let perWeek = try args.int("per_week") else { throw Problem("per_week is required.") }
        let habit = try ClaudeRules.newHabit(
            title: try args.required("title"), perWeek: perWeek,
            startedOn: try args.day("started_on") ?? today, habits: try store.habits())
        try store.save(habit)
        let summary = "Added the habit “\(habit.title)”, \(perWeek) \(perWeek == 1 ? "time" : "times") a week"
        try log("add_habit", summary, .habitCreated(habit))
        return ["added": summary, "habit": habit.id.uuidString]
    }

    private func checkIn(_ args: Arguments) throws -> [String: Any] {
        let habit = try findHabit(try args.required("habit"))
        let day = try args.day("date") ?? today
        guard let checked = try ClaudeRules.checkIn(habit, on: day, today: today, reminders: reminders.reminders) else {
            return ["note": "\(habit.title) is already ticked for \(iso(day)); nothing changed."]
        }
        try store.save(checked)
        let summary = "Checked in “\(habit.title)” for \(Self.longDay(day))"
        try log("check_in_habit", summary, .checkIn(habitID: habit.id, title: habit.title, day: day))
        var answer: [String: Any] = [
            "done": summary, "habit": habit.id.uuidString,
            "doneThisWeek": Habits.done(checked, in: Week(today)), "perWeek": checked.perWeek
        ]
        if habit.reminder != nil { answer["note"] = "Its linked reminder in Reminders was left as it is." }
        return answer
    }

    func findHabit(_ wanted: String, includingArchived: Bool = false) throws -> Habit {
        let habits = try store.habits().filter { includingArchived || !$0.archived }
        if let habit = habits.first(where: { $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame }) { return habit }
        let named = habits.filter { $0.title.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
        if named.count == 1 { return named[0] }
        throw Problem(
            named.count > 1
                ? "More than one habit is called \(wanted); use its id from habits."
                : "No habit called \(wanted). Habits: \(habits.map(\.title).joined(separator: ", ")).")
    }

    private func editVision(_ args: Arguments) throws -> [String: Any] {
        guard let text = args.values["text"] as? String else { throw Problem("text is required.") }
        let before = try store.vision()
        try ClaudeRules.checkVision(text, current: before)
        try store.saveVision(text)
        let summary = before.isEmpty ? "Wrote the vision" : "Edited the vision"
        try log("edit_vision", summary, .visionEdited(before: before, after: text))
        return ["changed": summary]
    }

    // MARK: - The Compass calendar

    func calendarReady() throws {
        guard calendar.access == .granted else { throw Problem("Compass can't use Calendar; they can allow it in the Life overview.") }
    }

    private func createEvent(_ args: Arguments) throws -> [String: Any] {
        try calendarReady()
        let title = try args.required("title")
        let allDay = try args.bool("all_day") ?? false
        let (start, end) = try times(args, allDay: allDay, length: allDay ? 86_400 : 3600)
        try ClaudeRules.checkTimes(start: start, end: end)
        let event = try calendar.create(title: title, start: start, end: end, isAllDay: allDay, notes: args.string("notes"))
        let summary = "Added “\(title)” to the Compass calendar, \(Self.when(start, end, allDay: allDay))"
        try log("create_event", summary, .eventCreated(event))
        return ["added": summary, "event": event.id]
    }

    private func moveEvent(_ args: Arguments) throws -> [String: Any] {
        try calendarReady()
        let (event, externalID, _, calendarName) = try changeableEvent(try args.required("event"))
        let (start, end) = try times(args, allDay: event.isAllDay, length: event.end.timeIntervalSince(event.start))
        try ClaudeRules.checkTimes(start: start, end: end)
        try calendar.move(event.id, start: start, end: end)
        let before = ClaudeEvent(id: event.id, externalID: externalID, title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay)
        var after = before
        (after.start, after.end) = (start, end)
        // One date of a repeating event is named by its start, which moved.
        if let itemID = Self.dateOf(event.id) { after.id = ClaudeRules.occurrenceID(itemID, start: start) }
        let summary = "Moved “\(event.title)”" + (calendarName.map { " in \($0)" } ?? "") + " to \(Self.when(start, end, allDay: event.isAllDay))"
        try log("move_event", summary, .eventMoved(before: before, after: after))
        return ["moved": summary, "event": after.id]
    }

    private func deleteEvent(_ args: Arguments) throws -> [String: Any] {
        try calendarReady()
        let (event, externalID, notes) = try ownEvent(try args.required("event"))
        try calendar.delete(event.id)
        let summary = "Deleted “\(event.title)” from the Compass calendar"
        try log(
            "delete_event", summary,
            .eventDeleted(
                ClaudeEvent(
                    id: event.id, externalID: externalID, title: event.title,
                    start: event.start, end: event.end, isAllDay: event.isAllDay, notes: notes)))
        return ["deleted": summary]
    }

    /// An event Claude may move or edit: its own in the Compass calendar, or
    /// one on another calendar they read (seam 31, Nov 1, 2026), with that
    /// calendar's name. Other calendars' events are named by date, so
    /// they're logged without an external id (which names the whole series).
    func changeableEvent(_ id: String) throws -> (CalendarEvent, String?, String?, String?) {
        guard let (event, externalID, notes) = calendar.event(id) else { throw Problem("No event with id \(id); the calendar tool lists them with ids.") }
        let compassID = calendar.compassCalendarID
        if event.calendarID == compassID {
            let (own, externalID, notes) = try ownEvent(id)
            return (own, externalID, notes, nil)
        }
        guard let access = calendar.access(id) else { throw Problem("No event with id \(id); the calendar tool lists them with ids.") }
        let hidden = CalendarLists.hidden(UserDefaults.standard.string(forKey: CalendarLists.hiddenKey) ?? "")
        try ClaudeRules.checkChange(event, access: access, hidden: hidden, compassCalendarID: compassID, own: [])
        return (event, Self.dateOf(event.id) == nil ? externalID : nil, notes, access.calendarTitle)
    }

    /// The event's identifier when `id` names one of its dates.
    static func dateOf(_ id: String) -> String? {
        let occurrence = ClaudeRules.occurrence(id)
        return occurrence.start == nil ? nil : occurrence.itemID
    }

    /// An event Claude may touch: one it made, in the Compass calendar.
    func ownEvent(_ id: String) throws -> (CalendarEvent, String?, String?) {
        guard let (event, externalID, notes) = calendar.event(Self.itemID(id)) else {
            throw Problem("No event with id \(id); the calendar tool lists events with ids.")
        }
        let own = ClaudeRules.ownEvents(try store.claudeActivity())
        var checked = event
        // An iCloud sync can change the identifier; the external one stays.
        if !own.contains(event.id), let externalID, own.contains(externalID) { checked.id = externalID }
        try ClaudeRules.checkOwn(checked, compassCalendarID: calendar.compassCalendarID, own: own)
        return (event, externalID, notes)
    }

    /// Start and end from the arguments. All-day events take days, and end on the last one.
    private func times(_ args: Arguments, allDay: Bool, length: TimeInterval) throws -> (Date, Date) {
        if allDay {
            guard let first = try args.day("start") else { throw Problem("An all-day event's start is a day, YYYY-MM-DD.") }
            let last = try args.day("end") ?? Day(ordinal: first.ordinal + max(Int((length / 86_400).rounded()), 1) - 1)
            return (first.startDate(in: .current), Day(ordinal: last.ordinal + 1).startDate(in: .current))
        }
        guard let start = try args.moment("start", endOfDay: false) else { throw Problem("start is required.") }
        return (start, try args.moment("end", endOfDay: false) ?? start.addingTimeInterval(length))
    }

    // MARK: - The log and undo

    private func changes(_ args: Arguments) throws -> [String: Any] {
        let limit = min(max(try args.int("limit") ?? 20, 1), 200)
        return [
            "changes": try store.claudeActivity().prefix(limit).map { entry -> [String: Any] in
                var row: [String: Any] = [
                    "id": entry.id.uuidString, "at": isoTime(entry.at), "tool": entry.tool, "summary": entry.summary,
                    "undone": entry.undoneAt != nil
                ]
                if let undone = entry.undoneAt { row["undoneAt"] = isoTime(undone) }
                return row
            }
        ]
    }

    func log(_ tool: String, _ summary: String, _ change: ClaudeChange) throws {
        try store.save(ClaudeActivity(tool: tool, summary: summary, change: change))
    }

    /// Takes a change back, for Undo in Settings and for undo_change. Throws,
    /// in words, when it was already undone or changed again since.
    @discardableResult
    private func editBets(_ args: Arguments) throws -> [String: Any] {
        guard let bets = args.values["bets"] as? [String] else { throw Problem("bets is required, as a list of strings.") }
        let year = today.year
        let before = try store.betsText(year: year)
        let after = try ClaudeRules.bets(bets, current: before)
        try store.saveBets(after, year: year)
        let summary = "\(before.isEmpty ? "Wrote" : "Edited") the \(String(year)) bets"
        try log("edit_bets", summary, .betsEdited(year: year, before: before, after: after))
        return ["changed": summary, "bets": YearlyBets.lines(after)]
    }

    private func editTransaction(_ args: Arguments) throws -> [String: Any] {
        guard let id = UUID(uuidString: try args.required("transaction")),
            let transaction = try store.transaction(id)
        else { throw Problem("No transaction with that id; ids come from transactions.") }
        var change = TransactionEdit(transaction)
        if let note = args.values["note"] {
            guard let text = note as? String else { throw Problem("note must be text.") }
            change.note = text
        }
        if let oneOff = try args.bool("one_off") { change.oneOff = oneOff }
        if let reimbursable = try args.bool("reimbursable") { change.reimbursable = reimbursable }
        // An amount marks it reimbursable; reimbursable alone keeps any amount already set.
        if let owed = try args.amount("reimbursable_amount") {
            change.reimbursableAmount = owed
            if try args.bool("reimbursable") == nil { change.reimbursable = true }
        }
        if let category = args.string("category") {
            guard try store.categoryExists(category) else {
                throw Problem("Compass has no category called \(category); categories lists them. create_category adds one.")
            }
            change.category = try store.existingCategory(matching: category)
        }
        // A goal paying is checked on the transaction as the rest of the edit leaves it.
        // An amount alone changes what the goal already paying for it pays.
        let wanted = args.string("paid_from_goal")
        if wanted != nil || args.values["paid_from_goal_amount"] != nil {
            var edited = transaction
            change.apply(to: &edited)
            let goal: Goal?
            if let wanted {
                goal = wanted.lowercased() == "none" ? nil : try findGoal(wanted)
            } else if let current = transaction.paidFromGoal, let paying = try store.goals().first(where: { $0.id == current }) {
                goal = paying
            } else {
                throw Problem("No goal pays for it yet; give paid_from_goal, the goal that paid.")
            }
            if goal == nil, args.values["paid_from_goal_amount"] != nil {
                throw Problem("paid_from_goal_amount goes with a goal, not \"none\".")
            }
            change = TransactionEdit(
                try GoalFunding.pay(
                    edited, from: goal, amount: try args.amount("paid_from_goal_amount"),
                    accounts: try store.accounts(), kinds: try store.kinds()))
        }
        let after = try ClaudeRules.editTransaction(transaction, to: change)
        let (before, edited) = (TransactionEdit(transaction), TransactionEdit(after))
        try store.save(edited, for: id)
        let what = [
            before.note != edited.note ? (edited.note.isEmpty ? "cleared the note" : "noted “\(edited.note)”") : nil,
            before.oneOff != edited.oneOff ? (edited.oneOff ? "marked a one-off" : "unmarked one-off") : nil,
            before.reimbursable != edited.reimbursable || before.reimbursableAmount != edited.reimbursableAmount
                ? (edited.reimbursable ? "marked \(after.owedBack.formatted(.currency(code: "USD"))) owed back" : "unmarked owed back") : nil,
            before.paidFromGoal != edited.paidFromGoal || before.paidFromGoalAmount != edited.paidFromGoalAmount
                ? (edited.paidFromGoal.flatMap { id in try? store.goals().first { $0.id == id } }
                    .map { "\(after.paidByGoal.formatted(.currency(code: "USD"))) paid from \($0.name)" } ?? "no goal paid for it") : nil,
            before.category != edited.category ? "filed under \(edited.category ?? "nothing")" : nil,
            !before.splits.isEmpty && edited.splits.isEmpty ? "split taken off" : nil
        ].compactMap { $0 }
        let summary =
            "\(transaction.merchant) on \(transaction.day.startDate(in: .current).formatted(.dateTime.month(.abbreviated).day())): "
            + what.joined(separator: ", ")
        try log("edit_transaction", summary, .transactionEdited(id: id, before: before, after: edited))
        return ["changed": summary, "transaction": id.uuidString]
    }

    private func setBudgetAmount(_ args: Arguments) throws -> [String: Any] {
        let what = try args.choice("what", in: ["flexible", "bill", "income", "savings"]) ?? "flexible"
        let month = try args.month("month") ?? Month(today)
        let scope: BudgetSchedule.Scope = try args.choice("scope", in: ["onward", "this_month"]) == "this_month" ? .onlyThisMonth : .onward
        let typed = try args.required("amount")
        let amount: Decimal? = typed.lowercased() == "remove" ? nil : try args.amount("amount")
        if what == "flexible", amount == nil { throw Problem("The flexible budget can't be removed; set it to 0 instead.") }
        let edit: BudgetEdit, label: String
        switch what {
        case "flexible":
            edit = .flexible(amount ?? 0); label = "the flexible budget"
        case "savings":
            let account = try find(try args.required("name"), in: try store.accounts().filter { $0.archivedOn == nil && $0.accountClass != .debt })
            edit = .saving(account.id, amount); label = "savings into \(Self.displayName(account.name))"
        default:
            let category = try knownCategory(try args.required("name"))
            let kind = try store.kinds()[category] ?? CategoryKind.guess(category)
            if what == "income", kind != .income { throw Problem("\(category) isn't an income category; categories lists each one's kind.") }
            if what == "bill", kind != .spending { throw Problem("\(category) isn't a spending category; categories lists each one's kind.") }
            edit = what == "income" ? .income(category, amount) : .bill(category, amount)
            label = what == "income" ? "planned \(category)" : category
        }
        let amountText = amount.map { $0.formatted(.currency(code: "USD")) } ?? "nothing"
        let when = scope == .onward ? "from \(monthName(month)) on" : "in \(monthName(month)) only"
        var answer = try changeBudget(
            edit, month: month, scope: scope, tool: "set_budget_amount",
            summary: amount == nil ? "Took \(label) out of the budget \(when)" : "Set \(label) to \(amountText) \(when)")
        let profile = try store.payProfile()
        if case .income(let category, _) = edit, category == profile.incomeCategory, profile.planIncomeFromPay {
            answer["note"] =
                "\(category) is planned from their pay settings, so the budget shows two paychecks at the latest net, not this amount, while that's on (Settings › Pay)."
        }
        return answer
    }

    private func setBudgetRole(_ args: Arguments) throws -> [String: Any] {
        let category = try knownCategory(try args.required("category"))
        guard (try store.kinds()[category] ?? CategoryKind.guess(category)) == .spending else {
            throw Problem("Only spending categories have a budget role; \(category) isn't one.")
        }
        guard let role = BudgetRole(rawValue: try args.choice("role", in: ["fixed", "flexible", "irregular"]) ?? "") else {
            throw Problem("role must be fixed, flexible or irregular.")
        }
        let expected = try args.amount("expected"), month = try args.month("month") ?? Month(today)
        let summary =
            "Made \(category) \(role.rawValue)" + (expected.map { " at \($0.formatted(.currency(code: "USD"))) a month from \(monthName(month)) on" } ?? "")
        return try changeBudget(.role(category, role, expected: expected), month: month, scope: .onward, tool: "set_budget_role", summary: summary)
    }

    private func changeBudget(_ edit: BudgetEdit, month: Month, scope: BudgetSchedule.Scope, tool: String, summary: String) throws -> [String: Any] {
        let before = try store.budgetSchedule(), kinds = try store.kinds()
        let incomePlanned = try store.budgetPlan(for: month).plannedIncome(kinds: kinds) > 0
        let after = try ClaudeRules.editBudget(before, edit, in: month, scope, today: Month(today), flexibleIsRemainder: incomePlanned)
        try store.save(after)
        try log(tool, summary, .budgetChanged(before: before, after: after))
        return ["changed": summary]
    }

    /// A category Compass already has, matched as the category menus match typing.
    private func knownCategory(_ typed: String) throws -> String {
        guard try store.categoryExists(typed) else {
            throw Problem("Compass has no category called \(typed); categories lists them.")
        }
        return try store.existingCategory(matching: typed)
    }

    private func monthName(_ month: Month) -> String {
        month.firstDay.startDate(in: .current).formatted(.dateTime.month(.abbreviated).year())
    }

    func undo(_ id: UUID) throws -> ClaudeActivity {
        guard var entry = try store.claudeActivity().first(where: { $0.id == id }) else { throw Problem("No change with id \(id.uuidString).") }
        guard entry.undoneAt == nil else { throw Problem("That change was already undone.") }
        let changedSince = Self.changedSince
        switch entry.change {
        case .goalCreated(let created):
            guard let current = try store.goals().first(where: { $0.id == created.id }) else { throw Problem("That goal is gone already.") }
            guard ClaudeRules.canUndoNewGoal(current: current, created: created) else { throw changedSince }
            try store.deleteGoal(created.id)
        case .goalChanged(let before, let after):
            guard let current = try store.goals().first(where: { $0.id == after.id }) else { throw Problem("That goal is gone.") }
            guard let restored = ClaudeRules.undoGoalChange(current: current, before: before, after: after) else { throw changedSince }
            try store.save(restored)
            try store.refreshGoals(today: today)
        case .habitCreated(let created):
            guard let current = try store.habits().first(where: { $0.id == created.id }) else { throw Problem("That habit is gone already.") }
            guard ClaudeRules.canUndoNewHabit(current: current, created: created) else {
                throw Problem("It has check-ins or was edited since. Archive it in the habit's editor instead.")
            }
            try store.deleteHabit(created.id)
        case .checkIn(let habitID, _, let day):
            guard let current = try store.habits().first(where: { $0.id == habitID }) else { throw Problem("That habit is gone.") }
            guard let undone = ClaudeRules.undoCheckIn(current: current, day: day, today: today) else { throw Problem("That day is unticked already.") }
            try store.save(undone)
        case .transactionEdited(let transactionID, let before, let after):
            guard let current = try store.transaction(transactionID) else { throw Problem("That transaction is gone.") }
            guard let restored = ClaudeRules.restore(current: TransactionEdit(current), before: before, after: after) else { throw changedSince }
            try store.save(restored, for: transactionID)
        case .budgetChanged(let before, let after):
            guard
                let restored = ClaudeRules.undoBudget(
                    current: try store.budgetSchedule(), before: before, after: after,
                    today: Month(today))
            else { throw changedSince }
            try store.save(restored)
        case .betsEdited(let year, let before, let after):
            guard let restored = ClaudeRules.restore(current: try store.betsText(year: year), before: before, after: after) else { throw changedSince }
            try store.saveBets(restored, year: year)
        case .visionEdited(let before, let after):
            guard let restored = ClaudeRules.restore(current: try store.vision(), before: before, after: after) else { throw changedSince }
            try store.saveVision(restored)
        case .reminderAdded(let reminder, _):
            try reminders.remove(reminder)
        case .reminderEdited(let reminder, let before, let after):
            guard let current = reminders.current(reminder) else { throw Problem("That reminder isn't in Reminders any more.") }
            guard let restored = ClaudeRules.undoReminderEdit(current: current.edit, before: before, after: after) else { throw changedSince }
            try reminders.edit(reminder, to: restored)
        case .reminderCompleted(let reminder, _):
            guard let current = reminders.current(reminder) else { throw Problem("That reminder isn't in Reminders any more.") }
            guard current.done else { throw Problem("It's open again already.") }
            try reminders.setDone(reminder, false)
        case .eventCreated(let event):
            guard let current = calendar.event(event.id) ?? event.externalID.flatMap(calendar.event) else { throw Problem("That event is gone already.") }
            try calendar.delete(current.event.id)
        case .eventMoved(let before, let after):
            guard let current = calendar.event(after.id) ?? after.externalID.flatMap(calendar.event) else { throw Problem("That event is gone.") }
            guard (current.event.start, current.event.end) == (after.start, after.end) else { throw changedSince }
            try calendar.move(current.event.id, start: before.start, end: before.end)
        case .eventDeleted(let event):
            entry.restoredEventID = try calendar.create(
                title: event.title, start: event.start, end: event.end,
                isAllDay: event.isAllDay, notes: event.notes
            ).id
        case .playbookAdded, .playbookEdited, .sizesEdited:
            try undoPlaybook(entry.change)
        case .noteAdded, .noteEdited, .noteDeleted:
            try undoNote(entry.change)
        case .playbookDeleted:
            try undoPlaybook(entry.change)
        default:
            if try !undoCategory(entry.change) { try undoUpkeep(entry.change) }
        }
        entry.undoneAt = .now
        try store.save(entry)
        return entry
    }

    static let changedSince = Problem("It's been changed since, so undo would lose that. Change it back by hand.")

    // MARK: - Words

    /// "$60,000", or "$60,000.50" with cents.
    static func money(_ amount: Decimal) -> String {
        var source = amount, rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        let whole = rounded == amount
        return amount.formatted(.currency(code: "USD").precision(.fractionLength(whole ? 0 : 2)).locale(Locale(identifier: "en_US")))
    }

    /// "Dec 31, 2026".
    static func longDay(_ day: Day) -> String {
        day.startDate(in: .current).formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "Oct 30" or "Oct 30 at 9:00 AM".
    static func due(_ due: ReminderDue) -> String {
        let date = due.day.startDate(in: .current).addingTimeInterval(TimeInterval((due.minute ?? 0) * 60))
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        return due.minute == nil ? day : "\(day) at \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// "Thu, Oct 29, 9:00 AM – 10:00 AM", or the days of an all-day event.
    static func when(_ start: Date, _ end: Date, allDay: Bool) -> String {
        if allDay {
            let last = end.addingTimeInterval(-1)
            let first = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            return Calendar.current.isDate(start, inSameDayAs: last)
                ? "\(first), all day"
                : "\(first) to \(last.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())), all day"
        }
        return (start..<end).formatted(.interval.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

extension Arguments {
    /// Refuses keys a tool doesn't take, so a stray "balance" or "status" is
    /// an error rather than quietly dropped.
    func onlyKnown(_ known: some Sequence<String>) throws {
        let unknown = Set(values.keys).subtracting(known)
        guard unknown.isEmpty else {
            throw Problem("This tool doesn't take \(unknown.sorted().joined(separator: ", ")). It takes \(Set(known).sorted().joined(separator: ", ")).")
        }
    }

    /// An amount that must not be negative.
    func money(_ key: String) throws -> Decimal? {
        guard let value = values[key] else { return nil }
        let text = ((value as? String) ?? (value as? NSNumber)?.stringValue ?? "")
            .replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), amount >= 0 else {
            throw Problem("\(key) must be an amount like \"60000\" or \"60,000.50\", not negative.")
        }
        return amount
    }

    /// An amount that keeps its sign, like a balance.
    func signedAmount(_ key: String) throws -> Decimal? {
        guard let value = values[key] else { return nil }
        let text = ((value as? String) ?? (value as? NSNumber)?.stringValue ?? "")
            .replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            throw Problem("\(key) must be an amount like \"18500\" or \"-20.50\".")
        }
        return amount
    }

    func strings(_ key: String) throws -> [String]? {
        guard let value = values[key] else { return nil }
        if let text = value as? String { return [text] }
        guard let list = value as? [Any], let strings = list as? [String] else { throw Problem("\(key) must be a list of names.") }
        return strings
    }

    /// Whether the value is "none", which clears it.
    func isNone(_ key: String) throws -> Bool {
        string(key)?.lowercased() == "none"
    }

    /// A reminder's repeat: text ("weekly", "every 10 days", "none") or an
    /// object with a frequency, every, weekdays and until; nil when not given.
    func repeating(_ key: String) throws -> Repeating? {
        guard let value = values[key] else { return nil }
        if let text = value as? String { return try ClaudeRules.reminderRepeat(text, every: nil, weekdays: [], until: nil) }
        guard let object = value as? [String: Any] else { throw Problem("\(key) must be text like \"weekly\" or an object with a frequency.") }
        let rule = Arguments(object)
        return try ClaudeRules.reminderRepeat(
            try rule.required("frequency"), every: try rule.int("every"),
            weekdays: try rule.strings("weekdays") ?? [], until: try rule.day("until"))
    }

    /// A reminder's due date: a day, or a time on one.
    func due(_ key: String) throws -> ReminderDue? {
        guard let value = string(key), value.lowercased() != "none" else { return nil }
        if let day = Self.day(value) { return ReminderDue(day: day) }
        guard let date = try moment(key, endOfDay: false) else { return nil }
        let clock = Calendar.current.dateComponents([.hour, .minute], from: date)
        return ReminderDue(day: Day(date, in: .current), minute: (clock.hour ?? 0) * 60 + (clock.minute ?? 0))
    }
}
