import Core
import Foundation

/// The rest of what Claude keeps up through chat (seam 31, full write
/// coverage): events' titles and notes, reminders moved, deleted and
/// reopened, habits edited, archived or deleted and check-ins removed,
/// goals retired and their rewards, pay, and accounts' names, archiving and
/// manual balances. The rules are in Core (`ClaudeUpkeep`); every change is
/// logged with undo.
extension ClaudeTools {
    var upkeepChangeTools: [ClaudeTool] {
        func text(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        let reminder = text("Its id (from reminders), or a title only one open reminder has.")
        let habit = text("The habit's title or id (from habits).")
        let goal = text("The goal's name or id (from goals).")
        let account = text("The account's name or id (from accounts).")
        let payWhen = text("YYYY-MM-DD when the day is known, or YYYY-MM for just the month.")
        let expectedFields: [String: Any] = [
            "kind": ["type": "string", "enum": ["bonus", "vest"]], "amount": text("Gross dollars, like \"9000\"."),
            "when": payWhen, "estimate": ["type": "boolean", "description": "The amount is a guess. Default false."],
            "title": text("Like \"Annual bonus\" or \"RSU vest\". Default Bonus or Vest."), "note": text("Optional.")
        ]
        func percent(_ what: String) -> [String: Any] { text("\(what), 0 to 100, like \"6\".") }
        return [
            tool(
                "edit_event",
                "Change the title or notes of an event (move_event changes its time): one Claude created in the Compass calendar, or one on any other calendar they read (ask them first). Read-only calendars and invites someone else organizes are refused; one date of a repeating event changes alone.",
                [
                    "event": text("Its id (from calendar or create_event)."), "title": text("The new title."),
                    "notes": text("Its notes, replacing any; empty clears them.")
                ],
                required: ["event"], changes: true, run: { args in try self.editEvent(args) }),
            tool(
                "move_reminder", "Move an open reminder to another of their Reminders lists, like This Week to This Quarter.",
                ["reminder": reminder, "list": text("The list's name.")], required: ["reminder", "list"], changes: true,
                run: { args in try self.moveReminder(args) }),
            tool(
                "delete_reminder", "Delete an open reminder. Undo makes it again. Repeating ones are refused (delete those in Reminders).",
                ["reminder": reminder], required: ["reminder"], changes: true, run: { args in try self.deleteReminder(args) }),
            tool(
                "uncomplete_reminder", "Reopen a reminder ticked off in the last 90 days (reminders lists the last two weeks' as doneLately).",
                ["reminder": text("Its id (from doneLately), or its title (the latest ticked off with it).")],
                required: ["reminder"], changes: true, run: { args in try self.uncompleteReminder(args) }),
            tool(
                "edit_habit",
                "Change an active habit's title or times a week. A habit linked to a daily reminder takes that reminder's title (rename it with edit_reminder).",
                ["habit": habit, "title": text("The new title."), "per_week": ["type": "integer", "description": "1 to 7."]],
                required: ["habit"], changes: true, run: { args in try self.editHabit(args) }),
            tool(
                "archive_habit", "Archive a habit (pause it: tracking stops, its history stays) or bring an archived one back.",
                ["habit": habit, "archived": ["type": "boolean", "description": "Default true; false brings it back."]],
                required: ["habit"], changes: true, run: { args in try self.archiveHabit(args) }),
            tool(
                "delete_habit", "Delete a habit and its check-ins. Undo brings it back whole. One linked to a daily reminder is refused (archive it instead).",
                ["habit": habit], required: ["habit"], changes: true, run: { args in try self.deleteHabit(args) }),
            tool(
                "remove_check_in", "Untick a habit's day. A linked reminder in Reminders is left alone.",
                ["habit": habit, "date": text("YYYY-MM-DD. Default today.")], required: ["habit"], changes: true, run: { args in try self.removeCheckIn(args) }),
            tool(
                "retire_goal",
                "Retire an active money goal they've changed their mind about. Goals are never deleted; a retired one stays in history. Reached goals stay reached.",
                ["goal": goal, "reason": text("Why, in their words.")], required: ["goal", "reason"], changes: true, run: { args in try self.retireGoal(args) }),
            tool(
                "set_reward",
                "Set the reward (what they'll buy when it's reached, and its cost) of a money goal or of a This Quarter reminder that has a target and progress, or claim it once reached: a goal once it's reached, a quarter reminder once its progress is 1. Give goal or reminder, not both. Only the fields given change. A reward is spending, never an asset.",
                [
                    "goal": goal,
                    "reminder": text("A This Quarter reminder with a target: its id (from reminders) or title. One ticked off can still be named."),
                    "name": text("Like \"Tudor BB54\"."), "cost": text("Dollars, like \"4300\"."),
                    "claimed_on": text("YYYY-MM-DD they claimed it, not after today; for a goal, on or after the day it was reached.")
                ],
                changes: true, run: { args in try self.setReward(args) }),
            tool(
                "set_expected_pay",
                "Add a bonus or stock vest they expect, as in Settings › Pay. It shows in pay and overview as upcoming, never in the monthly budget.",
                expectedFields, required: ["kind", "amount"], changes: true, destructive: false, run: { args in try self.setExpectedPay(args) }),
            tool(
                "edit_expected_pay", "Change an expected bonus or vest. Only the fields given change.",
                expectedFields.merging([
                    "item": text("Its id (from pay's upcoming) or title."),
                    "when": text("YYYY-MM-DD, YYYY-MM, or \"none\" for not known yet.")
                ]) { _, new in new },
                required: ["item"], changes: true, run: { args in try self.editExpectedPay(args) }),
            tool(
                "remove_expected_pay", "Remove an expected bonus or vest.",
                ["item": text("Its id (from pay's upcoming) or title.")], required: ["item"], changes: true, run: { args in try self.removeExpectedPay(args) }),
            tool(
                "edit_pay_settings", "Change Settings › Pay, like a raise. Only the fields given change; each paycheck's figures follow from them.",
                [
                    "annual_salary": text("Base pay a year in dollars, like \"86000\"."),
                    "every_days": ["type": "integer", "enum": [7, 14], "description": "Days between paydays."],
                    "known_payday": text("YYYY-MM-DD of any one payday."),
                    "retirement_percent": percent("Their 401(k) percent of pay"),
                    "retirement_pre_tax": ["type": "boolean", "description": "true for pre-tax, false for Roth."],
                    "match_percent": percent("The employer matches this percent of what they put in"),
                    "match_up_to_percent": percent("…on up to this percent of pay"),
                    "stock_per_check": text("Their stock plan purchase a paycheck, in dollars."),
                    "stock_company_per_check": text("What the company adds to it a paycheck, in dollars.")
                ],
                changes: true, run: { args in try self.editPaySettings(args) }),
            tool(
                "create_account",
                "Add a manual account, like Cash, with its balance today. Its balances are entered by hand (update_balance) and it takes added transactions (add_transaction).",
                [
                    "name": text("Like \"Cash\". No account numbers."),
                    "class": ["type": "string", "enum": ["cash", "taxable", "retirement", "equity", "otherAssets", "debt"], "description": "Default cash."],
                    "balance": text("Dollars today, like \"120\"; a debt is what's owed. Default 0.")
                ],
                required: ["name"], changes: true, destructive: false, run: { args in try self.createAccount(args) }),
            tool(
                "rename_account", "Rename an account. Account numbers never go in a name.",
                ["account": account, "name": text("The new name.")], required: ["account", "name"], changes: true, run: { args in try self.renameAccount(args) }
            ),
            tool(
                "archive_account", "Archive an account they've closed or sold (kept in history, out of totals from today), or open it again.",
                ["account": account, "archived": ["type": "boolean", "description": "Default true; false opens it again."]],
                required: ["account"], changes: true, run: { args in try self.archiveAccount(args) }),
            tool(
                "update_balance",
                "Enter a manual account's balance, like the car's value, as Log Balance does. A debt is what's owed. Synced accounts are refused (sync sets them).",
                ["account": account, "balance": text("Dollars, like \"18500\"."), "date": text("YYYY-MM-DD. Default today.")],
                required: ["account", "balance"], changes: true, run: { args in try self.updateBalance(args) })
        ]
    }

    // MARK: - Events

    private func editEvent(_ args: Arguments) throws -> [String: Any] {
        try calendarReady()
        let (event, externalID, notes, calendarName) = try changeableEvent(try args.required("event"))
        let before = ClaudeEvent(
            id: event.id, externalID: externalID, title: event.title, start: event.start, end: event.end,
            isAllDay: event.isAllDay, notes: notes.flatMap { $0.isEmpty ? nil : $0 })
        let after = try ClaudeRules.editEvent(before, title: args.string("title"), notes: args.values["notes"] as? String)
        try calendar.edit(event.id, title: after.title, notes: after.notes)
        var parts: [String] = []
        if after.title != before.title { parts.append("now “\(after.title)”") }
        if after.notes != before.notes { parts.append(after.notes == nil ? "notes cleared" : "notes changed") }
        let summary = "Changed “\(before.title)” in \(calendarName ?? "the Compass calendar"): \(parts.joined(separator: "; "))"
        try log("edit_event", summary, .eventEdited(before: before, after: after))
        return ["changed": summary, "event": event.id]
    }

    // MARK: - Reminders

    private func moveReminder(_ args: Arguments) throws -> [String: Any] {
        try remindersReady()
        let reminder = try ClaudeRules.reminder(try args.required("reminder"), in: reminders.reminders, lists: reminders.lists)
        let list = try ClaudeRules.list(named: try args.required("list"), in: reminders.lists)
        try ClaudeRules.checkMove(reminder, to: list)
        try reminders.move(reminder.id, toList: list.id)
        let from = reminders.lists.first { $0.id == reminder.listID }?.title ?? "its list"
        let summary = "Moved “\(reminder.title)” from \(from) to \(list.title)"
        try log("move_reminder", summary, .reminderMoved(id: reminder.id, title: reminder.title, fromListID: reminder.listID, toListID: list.id))
        return ["moved": summary, "reminder": reminder.id]
    }

    private func deleteReminder(_ args: Arguments) throws -> [String: Any] {
        try remindersReady()
        let reminder = try ClaudeRules.reminder(try args.required("reminder"), in: reminders.reminders, lists: reminders.lists)
        try ClaudeRules.checkDelete(reminder)
        try reminders.remove(reminder.id)
        let summary = "Deleted “\(reminder.title)”"
        try log(
            "delete_reminder", summary,
            .reminderDeleted(
                DeletedReminder(
                    id: reminder.id, title: reminder.title, listID: reminder.listID,
                    due: reminder.due, notes: reminder.notes)))
        return ["deleted": summary]
    }

    private func uncompleteReminder(_ args: Arguments) throws -> [String: Any] {
        try remindersReady()
        let done = try ClaudeRules.doneReminder(try args.required("reminder"), in: reminders.completed)
        guard let current = reminders.current(done.id), current.done else { throw Problem("\(done.title) is open already.") }
        try reminders.setDone(done.id, false)
        let summary = "Reopened “\(done.title)”"
        try log("uncomplete_reminder", summary, .reminderReopened(id: done.id, title: done.title))
        return ["reopened": summary, "reminder": done.id]
    }

    // MARK: - Habits

    private func editHabit(_ args: Arguments) throws -> [String: Any] {
        // Archived ones too, so the rules can say to unarchive first.
        let habit = try findHabit(try args.required("habit"), includingArchived: true)
        let edited = try ClaudeRules.editHabit(
            habit, title: args.string("title"), perWeek: try args.int("per_week"),
            among: try store.habits())
        try store.save(edited)
        var parts: [String] = []
        if edited.title != habit.title { parts.append("now “\(edited.title)”") }
        if edited.perWeek != habit.perWeek { parts.append("\(habit.perWeek) → \(edited.perWeek) a week") }
        let summary = "Changed the habit “\(habit.title)”: \(parts.joined(separator: "; "))"
        try log("edit_habit", summary, .habitEdited(before: habit, after: edited))
        return ["changed": summary, "habit": habit.id.uuidString]
    }

    private func archiveHabit(_ args: Arguments) throws -> [String: Any] {
        let archived = try args.bool("archived") ?? true
        let habit = try findHabit(try args.required("habit"), includingArchived: !archived)
        let changed = try ClaudeRules.archiveHabit(habit, archived: archived, among: try store.habits())
        try store.save(changed)
        let summary = archived ? "Archived the habit “\(habit.title)”" : "Brought back the habit “\(habit.title)”"
        try log("archive_habit", summary, .habitEdited(before: habit, after: changed))
        return ["changed": summary, "habit": habit.id.uuidString]
    }

    private func deleteHabit(_ args: Arguments) throws -> [String: Any] {
        let habit = try findHabit(try args.required("habit"), includingArchived: true)
        try ClaudeRules.checkDelete(habit)
        try store.deleteHabit(habit.id)
        let count = habit.checkIns.count
        let summary = "Deleted the habit “\(habit.title)” and its \(count) \(count == 1 ? "check-in" : "check-ins")"
        try log("delete_habit", summary, .habitDeleted(habit))
        return ["deleted": summary]
    }

    private func removeCheckIn(_ args: Arguments) throws -> [String: Any] {
        let habit = try findHabit(try args.required("habit"), includingArchived: true)
        let day = try args.day("date") ?? today
        guard let unticked = try ClaudeRules.removeCheckIn(habit, on: day, today: today) else {
            return ["note": "\(habit.title) isn't ticked for \(iso(day)); nothing changed."]
        }
        try store.save(unticked)
        let summary = "Unticked “\(habit.title)” for \(Self.longDay(day))"
        try log("remove_check_in", summary, .checkInRemoved(habitID: habit.id, title: habit.title, day: day))
        var answer: [String: Any] = ["done": summary, "habit": habit.id.uuidString]
        if habit.reminder != nil { answer["note"] = "Its linked reminder in Reminders was left as it is." }
        return answer
    }

    // MARK: - Goals

    private func retireGoal(_ args: Arguments) throws -> [String: Any] {
        let goal = try findGoal(try args.required("goal"))
        let retired = try ClaudeRules.retireGoal(goal, reason: try args.required("reason"))
        try store.save(retired)
        let summary = "Retired “\(goal.name)”"
        try log("retire_goal", summary, .goalRetired(before: goal, after: retired))
        return ["changed": summary, "goal": goal.id.uuidString]
    }

    private func setReward(_ args: Arguments) throws -> [String: Any] {
        switch (args.string("goal"), args.string("reminder")) {
        case (let wanted?, nil): try setGoalReward(wanted, args)
        case (nil, let wanted?): try setQuarterReward(wanted, args)
        case (nil, nil): throw Problem("Give goal (a money goal) or reminder (a This Quarter reminder with a target).")
        default: throw Problem("Give goal or reminder, not both.")
        }
    }

    private func setGoalReward(_ wanted: String, _ args: Arguments) throws -> [String: Any] {
        let goal = try findGoal(wanted)
        let changed = try ClaudeRules.setReward(
            goal, name: args.string("name"), cost: try args.money("cost"),
            claimedOn: try args.day("claimed_on"), today: today)
        guard let reward = changed.reward else { throw Problem("A reward needs a name.") }
        try store.save(changed)
        let cost = reward.cost.map { ", \(Self.money($0))" } ?? ""
        let summary =
            reward.claimedOn != nil && reward.claimedOn != goal.reward?.claimedOn
            ? "Claimed “\(reward.name)”\(cost) for “\(goal.name)” on \(Self.longDay(reward.claimedOn!))"
            : "Set “\(goal.name)”'s reward: “\(reward.name)”\(cost)"
        try log("set_reward", summary, .rewardSet(goalID: goal.id, before: goal.reward, after: reward))
        return ["changed": summary, "goal": goal.id.uuidString]
    }

    /// A This Quarter reminder's reward, on the link that gives it a target.
    private func setQuarterReward(_ wanted: String, _ args: Arguments) throws -> [String: Any] {
        let links = try store.reminderMeasures()
        let open =
            reminders.access == .granted
            ? try? ClaudeRules.reminder(wanted, in: reminders.reminders, lists: reminders.lists) : nil
        guard let link = open.flatMap({ ReminderMeasure.link(for: $0, in: links) }) ?? ReminderMeasure.link(named: wanted, in: links) else {
            throw Problem("\(wanted) has no target. Only a This Quarter reminder that follows a number (set in the Life overview) takes a reward.")
        }
        let changed = try ClaudeRules.setReward(
            link, name: args.string("name"), cost: try args.money("cost"), claimedOn: try args.day("claimed_on"),
            progress: link.fraction(values: netWorth.linkedValues), today: today)
        guard let reward = changed.reward else { throw Problem("A reward needs a name.") }
        try store.save(changed)
        let cost = reward.cost.map { ", \(Self.money($0))" } ?? ""
        let summary =
            reward.claimedOn != nil && reward.claimedOn != link.reward?.claimedOn
            ? "Claimed “\(reward.name)”\(cost) for “\(link.title)” on \(Self.longDay(reward.claimedOn!))"
            : "Set “\(link.title)”'s reward: “\(reward.name)”\(cost)"
        try log("set_reward", summary, .quarterRewardSet(linkID: link.id, title: link.title, before: link.reward, after: reward))
        return ["changed": summary, "reminder": link.reminderID]
    }

    // MARK: - Pay

    private func payWhen(_ args: Arguments) throws -> ClaudeRules.PayWhen? {
        guard let text = args.string("when"), text.lowercased() != "none" else { return nil }
        if text.count == 7, let month = try args.month("when") { return .month(month) }
        guard let day = try args.day("when") else { throw Problem("when is YYYY-MM-DD or YYYY-MM.") }
        return .day(day)
    }

    private func expectedKind(_ args: Arguments) throws -> ExpectedPay.Kind? {
        try args.choice("kind", in: ["bonus", "vest"]).flatMap(ExpectedPay.Kind.init(rawValue:))
    }

    private func setExpectedPay(_ args: Arguments) throws -> [String: Any] {
        guard let kind = try expectedKind(args) else { throw Problem("kind is bonus or vest.") }
        guard let gross = try args.money("amount") else { throw Problem("amount is required.") }
        let item = try ClaudeRules.expectedPay(
            kind: kind, title: args.string("title"), gross: gross, on: try payWhen(args),
            estimate: try args.bool("estimate") ?? false, note: args.string("note") ?? "")
        var after = try store.payProfile()
        after.expected.append(item)
        return try savePay(
            after, tool: "set_expected_pay",
            summary: "Added an expected \(kind.rawValue), “\(item.title)”, \(Self.money(gross))\(whenWords(item))")
    }

    private func editExpectedPay(_ args: Arguments) throws -> [String: Any] {
        let profile = try store.payProfile()
        let old = try expectedItem(try args.required("item"), in: profile)
        let when: ClaudeRules.PayWhen? =
            args.values["when"] == nil
            ? (old.day.map { .day($0) } ?? old.month.map { .month($0) }) : try payWhen(args)
        let kind = try expectedKind(args) ?? old.kind
        // A default title follows a change of kind.
        let defaultTitle = old.title == (old.kind == .bonus ? "Bonus" : "Vest")
        let item = try ClaudeRules.expectedPay(
            kind: kind, title: args.string("title") ?? (defaultTitle ? nil : old.title),
            gross: try args.money("amount") ?? old.gross, on: when,
            estimate: try args.bool("estimate") ?? old.estimate,
            note: (args.values["note"] as? String) ?? old.note, id: old.id)
        guard item != old else { throw Problem("That's what “\(old.title)” already says; nothing to change.") }
        var after = profile
        after.expected[after.expected.firstIndex { $0.id == old.id }!] = item
        return try savePay(
            after, tool: "edit_expected_pay",
            summary: "Changed the expected “\(old.title)”: \(Self.money(item.gross))\(whenWords(item))\(item.estimate ? " (estimate)" : "")")
    }

    private func removeExpectedPay(_ args: Arguments) throws -> [String: Any] {
        var after = try store.payProfile()
        let item = try expectedItem(try args.required("item"), in: after)
        after.expected.removeAll { $0.id == item.id }
        return try savePay(after, tool: "remove_expected_pay", summary: "Removed the expected “\(item.title)”")
    }

    private func editPaySettings(_ args: Arguments) throws -> [String: Any] {
        let edit = PayEdit(
            annualSalary: try args.money("annual_salary"), everyDays: try args.int("every_days"),
            knownPayday: try args.day("known_payday"), retirementPercent: try args.money("retirement_percent"),
            retirementPreTax: try args.bool("retirement_pre_tax"), matchPercent: try args.money("match_percent"),
            matchUpToPercent: try args.money("match_up_to_percent"), stockPerCheck: try args.money("stock_per_check"),
            stockCompanyPerCheck: try args.money("stock_company_per_check"))
        let before = try store.payProfile()
        let after = try ClaudeRules.editPay(before, edit)
        var parts: [String] = []
        if after.annualSalary != before.annualSalary { parts.append("salary \(Self.money(before.annualSalary)) → \(Self.money(after.annualSalary))") }
        if after.everyDays != before.everyDays { parts.append("paid every \(after.everyDays) days") }
        if after.knownPayday != before.knownPayday, let payday = after.knownPayday { parts.append("a payday on \(Self.longDay(payday))") }
        if after.retirementPercent != before.retirementPercent { parts.append("401(k) \(before.retirementPercent)% → \(after.retirementPercent)%") }
        if after.retirementPreTax != before.retirementPreTax { parts.append(after.retirementPreTax ? "401(k) pre-tax" : "401(k) Roth") }
        if after.matchPercent != before.matchPercent || after.matchUpToPercent != before.matchUpToPercent {
            parts.append("match \(after.matchPercent)% on up to \(after.matchUpToPercent)%")
        }
        if after.stockPerCheck != before.stockPerCheck || after.stockCompanyPerCheck != before.stockCompanyPerCheck {
            parts.append("stock \(Self.money(after.stockPerCheck)) + \(Self.money(after.stockCompanyPerCheck)) a check")
        }
        return try savePay(after, tool: "edit_pay_settings", summary: "Changed pay settings: \(parts.joined(separator: "; "))")
    }

    private func savePay(_ after: PayProfile, tool: String, summary: String) throws -> [String: Any] {
        let before = try store.payProfile()
        try store.save(after)
        try log(tool, summary, .payChanged(before: before, after: after))
        return ["changed": summary]
    }

    private func expectedItem(_ wanted: String, in profile: PayProfile) throws -> ExpectedPay {
        if let item = profile.expected.first(where: { $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame }) { return item }
        let titled = profile.expected.filter { $0.title.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
        if titled.count == 1 { return titled[0] }
        throw Problem(
            titled.isEmpty
                ? "No expected bonus or vest called \(wanted); pay lists them with ids."
                : "More than one is called \(wanted); use its id from pay.")
    }

    private func whenWords(_ item: ExpectedPay) -> String {
        if let day = item.day { return " on \(Self.longDay(day))" }
        if let month = item.month { return " in \(month.firstDay.startDate(in: .current).formatted(.dateTime.month(.wide).year()))" }
        return ""
    }

    // MARK: - Accounts

    private func createAccount(_ args: Arguments) throws -> [String: Any] {
        let accountClass = AccountClass(rawValue: try args.choice("class", in: AccountClass.allCases.map(\.rawValue)) ?? "cash") ?? .cash
        let (account, opening) = try ClaudeRules.newAccount(
            name: try args.required("name"), accountClass: accountClass,
            balance: try args.signedAmount("balance") ?? 0, on: today, among: try store.accounts())
        try store.add(account, opening: opening)
        let summary = "Added the manual account “\(account.name)” at \(Self.money(abs(opening.balance)))"
        try log("create_account", summary, .accountCreated(account, opening: opening))
        return ["added": summary, "account": account.id.uuidString]
    }

    private func renameAccount(_ args: Arguments) throws -> [String: Any] {
        let accounts = try store.accounts()
        let account = try find(try args.required("account"), in: accounts)
        let renamed = try ClaudeRules.renameAccount(account, to: try args.required("name"), among: accounts)
        try store.update(renamed)
        let summary = "Renamed “\(Self.displayName(account.name))” to “\(renamed.name)”"
        try log("rename_account", summary, .accountEdited(before: account, after: renamed))
        return ["changed": summary, "account": account.id.uuidString]
    }

    private func archiveAccount(_ args: Arguments) throws -> [String: Any] {
        let account = try find(try args.required("account"), in: try store.accounts())
        let archived = try args.bool("archived") ?? true
        let changed = try ClaudeRules.archiveAccount(account, archived: archived, today: today)
        try store.update(changed)
        let summary = archived ? "Archived “\(Self.displayName(account.name))”" : "Opened “\(Self.displayName(account.name))” again"
        try log("archive_account", summary, .accountEdited(before: account, after: changed))
        return ["changed": summary, "account": account.id.uuidString]
    }

    private func updateBalance(_ args: Arguments) throws -> [String: Any] {
        let account = try find(try args.required("account"), in: try store.accounts())
        guard let entered = try args.signedAmount("balance") else { throw Problem("balance is required.") }
        let day = try args.day("date") ?? today
        let snapshot = try ClaudeRules.balance(entered, for: account, on: day, today: today)
        let before = try store.manualSnapshot(for: account.id, on: day)
        guard before?.balance != snapshot.balance else {
            throw Problem("\(Self.displayName(account.name)) is \(Self.money(entered)) on \(iso(day)) already; nothing to change.")
        }
        try store.saveManualSnapshot(snapshot)
        let summary = "Set “\(Self.displayName(account.name))” to \(Self.money(entered)) on \(Self.longDay(day))"
        try log("update_balance", summary, .balanceEntered(before: before, after: snapshot))
        return ["changed": summary, "account": account.id.uuidString]
    }

    // MARK: - Undo

    /// Takes back one of these changes, for `undo`.
    func undoUpkeep(_ change: ClaudeChange) throws {
        let changedSince = Self.changedSince
        switch change {
        case .eventEdited(let before, let after):
            guard let current = calendar.event(after.id) ?? after.externalID.flatMap(calendar.event) else { throw Problem("That event is gone.") }
            guard current.event.title == after.title, current.notes.flatMap({ $0.isEmpty ? nil : $0 }) == after.notes else { throw changedSince }
            try calendar.edit(current.event.id, title: before.title, notes: before.notes)
        case .reminderMoved(let id, _, let from, let to):
            guard let current = reminders.current(id) else { throw Problem("That reminder isn't in Reminders any more.") }
            guard current.listID == to else { throw changedSince }
            try reminders.move(id, toList: from)
        case .reminderDeleted(let deleted):
            guard reminders.lists.contains(where: { $0.id == deleted.listID }) else { throw Problem("Its Reminders list is gone.") }
            _ = try reminders.add(title: deleted.title, listID: deleted.listID, due: deleted.due, notes: deleted.notes)
        case .reminderReopened(let id, _):
            guard let current = reminders.current(id) else { throw Problem("That reminder isn't in Reminders any more.") }
            guard !current.done else { throw Problem("It's ticked off already.") }
            try reminders.setDone(id, true)
        case .repeatCompleted(let id, let title, let listID, let due, let day):
            guard let current = reminders.current(id) else { throw Problem("That reminder isn't in Reminders any more.") }
            guard !current.done else { throw Problem("It's ticked off in Reminders now; reopen it there.") }
            var restored = current.edit
            (restored.due, restored.notes) = (due, nil)
            try reminders.edit(id, to: restored)
            if let copy = ClaudeRules.doneCopy(title: title, listID: listID, on: day, among: reminders.completed) { try reminders.remove(copy) }
        case .habitEdited(let before, let after):
            guard let current = try store.habits().first(where: { $0.id == after.id }) else { throw Problem("That habit is gone.") }
            guard let restored = ClaudeRules.undoHabitEdit(current: current, before: before, after: after) else { throw changedSince }
            try store.save(restored)
        case .habitDeleted(let habit):
            guard ClaudeRules.canRestoreDeleted(habit, among: try store.habits()) else {
                throw Problem("There's an active habit called \(habit.title) now, so it can't come back beside it.")
            }
            try store.save(habit)
        case .checkInRemoved(let habitID, _, let day):
            guard let current = try store.habits().first(where: { $0.id == habitID }) else { throw Problem("That habit is gone.") }
            guard !current.checkIns.contains(day) else { throw Problem("That day is ticked already.") }
            try store.save(HabitReminderLink.toggle(current, on: day, reminders: [], today: today).habit)
        case .goalRetired(let before, let after):
            guard let current = try store.goals().first(where: { $0.id == after.id }) else { throw Problem("That goal is gone.") }
            guard let restored = ClaudeRules.undoRetire(current: current, before: before, after: after) else { throw changedSince }
            try store.save(restored)
            try store.refreshGoals(today: today)
        case .rewardSet(let goalID, let before, let after):
            guard var current = try store.goals().first(where: { $0.id == goalID }) else { throw Problem("That goal is gone.") }
            guard let restored = ClaudeRules.restore(current: current.reward, before: before, after: after) else { throw changedSince }
            current.reward = restored
            try store.save(current)
        case .quarterRewardSet(let linkID, let title, let before, let after):
            guard var current = try store.reminderMeasures().first(where: { $0.id == linkID }) else {
                throw Problem("“\(title)” no longer has a target, so its reward is gone.")
            }
            guard let restored = ClaudeRules.restore(current: current.reward, before: before, after: after) else { throw changedSince }
            current.reward = restored
            try store.save(current)
        case .payChanged(let before, let after):
            guard let restored = ClaudeRules.undoPay(current: try store.payProfile(), before: before, after: after) else { throw changedSince }
            try store.save(restored)
        case .accountEdited(let before, let after):
            guard var current = try store.accounts().first(where: { $0.id == after.id }) else { throw Problem("That account is gone.") }
            guard (current.name, current.archivedOn) == (after.name, after.archivedOn) else { throw changedSince }
            (current.name, current.archivedOn) = (before.name, before.archivedOn)
            try store.update(current)
        case .accountCreated(let account, let opening):
            guard try store.deleteUntouchedAccount(account.id, opening: opening) else {
                throw Problem("\(account.name) has balances or transactions since, so it stays. Archive it instead.")
            }
        case .balanceEntered(let before, let after):
            guard try store.manualSnapshot(for: after.accountID, on: after.day) == after else { throw changedSince }
            if let before { try store.saveManualSnapshot(before) } else { try store.deleteManualSnapshot(after) }
        default:
            throw Problem("Compass can't undo that change.")
        }
    }
}
