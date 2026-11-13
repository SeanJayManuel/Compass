import Core
import Foundation
import SwiftData

/// Claude's read tools for Life: reminders, habits, the vision, the
/// calendar and free time.
extension ClaudeTools {
    // MARK: - Life

    static let noReminders = "Compass can't read Reminders; they can allow it in the Life overview."

    func remindersAgenda() async throws -> [String: Any] {
        guard var answer = try agendaAnswer() else { return ["note": Self.noReminders] }
        answer["livingListDoneThisYear"] = await livingListDone()
        return answer
    }

    /// The Life overview's Reminders sections, or nil without access.
    func agendaAnswer() throws -> [String: Any]? {
        guard
            let agenda = ReminderAgenda.life(
                reminders, habits: try store.habits(), playbook: try store.playbook(),
                today: today)
        else { return nil }
        let lists = reminders.lists
        let listNames = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.title) })
        let links = try store.reminderMeasures()
        let values = netWorth.linkedValues
        func rows(_ items: [Reminder], measured: Bool = false) -> [[String: Any]] {
            items.map { reminder in
                let list = listNames[reminder.listID] ?? ""
                var row: [String: Any] = ["id": reminder.id, "title": ReminderAgenda.shortTitle(reminder.title, list: list), "list": list]
                if let due = reminder.due {
                    row["due"] = iso(due.day)
                    if let minute = due.minute { row["time"] = String(format: "%02d:%02d", minute / 60, minute % 60) }
                    if due.day < today { row["overdue"] = true }
                }
                if reminder.repeats { row["repeat"] = reminder.repeatRule?.text ?? "custom" }
                if let notes = reminder.notes { row["notes"] = notes }
                if measured, let link = ReminderMeasure.link(for: reminder, in: links) {
                    row["target"] = dollars(link.target)
                    row["progress"] = link.fraction(values: values).map(fraction) ?? NSNull()
                    if let reward = link.reward { row["reward"] = rewardRow(reward) }
                }
                return row
            }
        }
        // Playbook repeats due by tomorrow sit with them, ticked by done_playbook_entry.
        let playbook = Playbook.dueForReminders(try store.playbook(), today: today).map { due -> [String: Any] in
            var row: [String: Any] = [
                "playbookEntry": due.entry.id.uuidString, "title": due.entry.title, "area": due.entry.area,
                "due": iso(due.day), "repeat": ReminderRepeat(frequency: .daily, every: due.entry.repeatEveryDays ?? 1).text
            ]
            if due.day < today { row["overdue"] = true }
            return row
        }
        return [
            "today": iso(today), "thisWeek": rows(agenda.thisWeek) + playbook, "everyDay": rows(agenda.everyDay),
            "admin": rows(agenda.admin), "thisQuarter": rows(agenda.quarter, measured: true),
            "comingUp": rows(agenda.comingUp), "livingList": rows(agenda.livingList), "inboxToSort": agenda.inbox,
            // So Claude can reopen one (uncomplete_reminder).
            "doneLately": reminders.completed.filter { $0.day.ordinal >= today.ordinal - 13 }.sorted { $0.day > $1.day }.prefix(30)
                .map { ["id": $0.id, "title": $0.title, "list": listNames[$0.listID] ?? "", "doneOn": iso($0.day)] }
        ]
    }

    func rewardRow(_ reward: Reward) -> [String: Any] {
        ["name": reward.name, "cost": dollars(reward.cost), "claimedOn": reward.claimedOn.map(iso) ?? NSNull()]
    }

    /// Living List items ticked off since Jan 1, newest first.
    func livingListDone() async -> [[String: Any]] {
        let lists = reminders.lists.filter { ReminderListNames.saved.matches(.living, $0.title) }
        let names = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.title) })
        let done = await reminders.completed(since: Day(year: today.year, month: 1, day: 1), in: Set(names.keys))
        return done.map { ["title": ReminderAgenda.shortTitle($0.title, list: names[$0.listID] ?? ""), "doneOn": iso($0.day)] }
    }

    func habits() throws -> [String: Any] {
        [
            "today": iso(today),
            "habits": try store.habits().filter { !$0.archived }.map { habit -> [String: Any] in
                let left = Habits.stillToDo(habit, today: today)
                var row: [String: Any] = [
                    "id": habit.id.uuidString, "title": habit.title, "perWeek": habit.perWeek, "startedOn": iso(habit.startedOn),
                    "doneThisWeek": Habits.done(habit, in: Week(today)), "stillNeeded": left.needed, "daysLeftThisWeek": left.daysLeft,
                    "streakWeeks": Habits.streak(habit, today: today),
                    "lastWeeks": Habits.history(habit, weeks: 8, today: today).map { record -> [String: Any] in
                        let result: String =
                            switch record.result {
                            case .hit: "hit"
                            case .missed: "missed"
                            case .inProgress(let done): "in progress (\(done))"
                            case .notCounted: "not counted"
                            }
                        return ["weekOf": iso(record.week.start), "result": result]
                    }
                ]
                if let reminder = habit.reminder { row["linkedReminder"] = reminder.title }
                return row
            }
        ]
    }

    /// The vision, this year's bets, the quarter's goals (the This Quarter
    /// list, as `reminders` gives it) and the living list.
    func vision() async throws -> [String: Any] {
        let year = today.year
        var answer: [String: Any] = [
            "vision": try store.vision(), "year": year,
            "yearlyBets": try store.yearlyBets().first { $0.year == year }?.bets ?? []
        ]
        if let agenda = try agendaAnswer() {
            answer["quarterGoals"] = agenda["thisQuarter"]
            answer["livingList"] = agenda["livingList"]
            answer["livingListDoneThisYear"] = await livingListDone()
        } else {
            answer["note"] = "Quarter goals and the living list live in Reminders. " + Self.noReminders
        }
        return answer
    }

    func calendarEvents(_ args: Arguments) throws -> [String: Any] {
        guard calendar.access == .granted else { return ["note": "Compass can't read Calendar; they can allow it in the Life overview."] }
        let first = try args.day("start") ?? today
        let last = try args.day("end") ?? Day(ordinal: first.ordinal + 6)
        guard last >= first, last.ordinal - first.ordinal <= 92 else { throw Problem("end must be on or after start, and at most 92 days on.") }
        let events = shownEvents(from: first.startDate(in: .current), to: Day(ordinal: last.ordinal + 1).startDate(in: .current))
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        let names = Dictionary(calendar.calendars.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let own = ClaudeRules.ownEvents(try store.claudeActivity())
        let compassID = calendar.compassCalendarID
        let hidden = CalendarLists.hidden(UserDefaults.standard.string(forKey: CalendarLists.hiddenKey) ?? "")
        let read = calendar.calendars.filter { !hidden.contains($0.id) || $0.id == compassID }
        return [
            "start": iso(first), "end": iso(last),
            "calendars": read.map { ["name": $0.title, "compass": $0.id == compassID] as [String: Any] },
            "compassCalendar": compassID == nil ? "Not made yet: create_event makes it, in the account new events go to." : ClaudeRules.calendarName,
            "events": events.map { event -> [String: Any] in
                var row: [String: Any] = ["title": event.title, "calendar": names[event.calendarID] ?? ""]
                // Every event carries an id for move_event and edit_event; Claude's
                // own (delete_event too) by identifier, others by date, since a
                // repeating event's dates share one.
                let id = Self.itemID(event.id)
                if event.calendarID == compassID {
                    row["id"] = id
                    row["createdByClaude"] = own.contains(id)
                } else {
                    row["id"] = ClaudeRules.occurrenceID(id, start: event.start)
                }
                if event.isAllDay {
                    row["allDay"] = true
                    row["date"] = iso(Day(event.start, in: .current))
                    let lastDay = Day(event.end.addingTimeInterval(-1), in: .current)
                    if lastDay != Day(event.start, in: .current) { row["through"] = iso(lastDay) }
                } else {
                    row["start"] = isoTime(event.start)
                    row["end"] = isoTime(event.end)
                }
                return row
            }
        ]
    }

    func freeTime(_ args: Arguments) throws -> [String: Any] {
        guard calendar.access == .granted else { return ["note": "Compass can't read Calendar; they can allow it in the Life overview."] }
        let start = try args.moment("start", endOfDay: false) ?? .now
        let end = try args.moment("end", endOfDay: true) ?? start.addingTimeInterval(7 * 86_400)
        guard end > start, end.timeIntervalSince(start) <= 92 * 86_400 else { throw Problem("end must be after start, and at most 92 days on.") }
        let minimum = max(try args.int("minimum_minutes") ?? 30, 0)
        let gaps = FreeTime.gaps(events: shownEvents(from: start, to: end), from: start, to: end, minimum: TimeInterval(minimum * 60))
        return [
            "start": isoTime(start), "end": isoTime(end), "minimumMinutes": minimum,
            "gaps": gaps.map {
                [
                    "start": isoTime($0.start), "end": isoTime($0.end),
                    "minutes": Int($0.end.timeIntervalSince($0.start) / 60)
                ] as [String: Any]
            }
        ]
    }

    /// From the calendars they show in Compass (Settings > Data), and always
    /// the Compass calendar, so Claude sees the events it made.
    func shownEvents(from start: Date, to end: Date) -> [CalendarEvent] {
        let hidden = CalendarLists.hidden(UserDefaults.standard.string(forKey: CalendarLists.hiddenKey) ?? "")
            .subtracting([calendar.compassCalendarID].compactMap { $0 })
        return calendar.events(from: start, to: end).filter { !hidden.contains($0.calendarID) }
    }
}
