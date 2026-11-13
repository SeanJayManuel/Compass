import Foundation

/// The daily reminder a habit is linked to, so ticking one ticks the other.
/// The title and list find it again if Reminders gives it a new identifier,
/// and match the done copies Reminders keeps of a repeat.
public struct HabitReminder: Hashable, Codable, Sendable {
    /// Its `calendarItemIdentifier` in EventKit.
    public var id: String
    public var title: String
    public var listID: String
    /// Recent days already settled between the two: carried over from
    /// Reminders, or ticked or unticked in Compass. A settled day is their
    /// call, so an untick sticks.
    public var settled: [Day]

    public init(id: String, title: String, listID: String, settled: [Day] = []) {
        self.id = id
        self.title = title
        self.listID = listID
        self.settled = settled
    }
}

/// A reminder ticked off in the last few days, as Reminders keeps it.
public struct CompletedReminder: Hashable, Sendable {
    public var id: String
    public var title: String
    public var listID: String
    /// The local day it was ticked off.
    public var day: Day

    public init(id: String, title: String, listID: String, day: Day) {
        self.id = id
        self.title = title
        self.listID = listID
        self.day = day
    }
}

/// Ticking off a habit's reminder in Reminders.
public struct ReminderCompletion: Hashable, Sendable {
    public var id: String
    /// It's days behind: set it due today first, so ticking it moves it on
    /// to tomorrow rather than to another day already past.
    public var moveToToday: Bool

    public init(id: String, moveToToday: Bool) {
        self.id = id
        self.moveToToday = moveToToday
    }
}

extension HabitReminder {
    /// Settles a day, keeping only the days Reminders' done copies are read back for.
    mutating func settle(_ day: Day, today: Day) {
        if !settled.contains(day) { settled.append(day) }
        settled = settled.filter { $0.ordinal > today.ordinal - HabitReminderLink.lookback }.sorted()
    }
}

public enum HabitReminderLink {
    /// How many days back, today included, done copies of a repeat are read:
    /// about three months, so a new habit starts with its recent history.
    public static let lookback = 90

    /// Ticks or unticks a day, and settles it. Ticking today also ticks off
    /// the linked reminder when it's still to do today; an untick, or any
    /// other day, leaves Reminders alone.
    public static func toggle(
        _ habit: Habit, on day: Day, reminders: [Reminder],
        today: Day
    ) -> (habit: Habit, complete: ReminderCompletion?) {
        var updated = Habits.toggle(habit, on: day)
        guard var link = updated.reminder else { return (updated, nil) }
        link.settle(day, today: today)
        updated.reminder = link
        return (updated, day == today ? completion(for: updated, reminders: reminders, today: today) : nil)
    }

    /// The tick its reminder needs once today's checked in: none when today
    /// isn't, or the reminder is already done for today.
    public static func completion(for habit: Habit, reminders: [Reminder], today: Day) -> ReminderCompletion? {
        guard habit.checkIns.contains(today), let link = habit.reminder, let reminder = find(link, in: reminders),
            let due = reminder.due, due.day <= today
        else { return nil }
        return ReminderCompletion(id: reminder.id, moveToToday: due.day < today)
    }

    /// The open daily repeat a link points at: by identifier, else the one
    /// with its title (in its list, if there are several).
    public static func find(_ link: HabitReminder, in reminders: [Reminder]) -> Reminder? {
        let daily = reminders.filter(\.repeatsDaily)
        if let same = daily.first(where: { $0.id == link.id }) { return same }
        let titled = daily.filter { $0.title.sameTitle(as: link.title) }
        if titled.count == 1 { return titled[0] }
        let inList = titled.filter { $0.listID == link.listID }
        return inList.count == 1 ? inList[0] : nil
    }

    /// The reminders that habits still tracked stand in for, to leave out of the agenda.
    public static func linkedIDs(_ habits: [Habit], reminders: [Reminder]) -> Set<String> {
        Set(habits.filter { !$0.archived }.compactMap { $0.reminder.flatMap { find($0, in: reminders)?.id } })
    }

    /// The daily repeats `habit` can be linked to, by title: its own, and
    /// any not already standing in for another habit.
    public static func candidates(for habit: Habit, among habits: [Habit], reminders: [Reminder]) -> [Reminder] {
        let own = habit.reminder.flatMap { find($0, in: reminders)?.id }
        let taken = linkedIDs(habits.filter { $0.id != habit.id }, reminders: reminders)
        return reminders.filter { $0.repeatsDaily && ($0.id == own || !taken.contains($0.id)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Checks in the days its reminder was ticked off in Reminders (on their
    /// phone, say): each done copy of it from the last few days, and today
    /// when the repeat is next due tomorrow. A day already settled is left
    /// as it is, and so is one before the habit's first week. The link
    /// follows a renamed reminder.
    public static func carryOver(
        _ habit: Habit, reminders: [Reminder], completed: [CompletedReminder],
        today: Day
    ) -> Habit {
        guard !habit.archived, var link = habit.reminder else { return habit }
        let open = find(link, in: reminders)
        // Done copies from before a rename still carry the old title.
        let titles = [link.title] + (open.map { [$0.title] } ?? [])
        if let open { (link.id, link.title, link.listID) = (open.id, open.title, open.listID) }
        var days = doneDays(link, titles: titles, in: completed)
        if let due = open?.due, due.day.ordinal == today.ordinal + 1 { days.insert(today) }
        var updated = habit
        for day in days.sorted()
        where day <= today && day.ordinal > today.ordinal - lookback
            && !link.settled.contains(day) && Habits.canCheckIn(updated, on: day, today: today)
        {
            if !updated.checkIns.contains(day) { updated = Habits.toggle(updated, on: day) }
            link.settle(day, today: today)
        }
        updated.reminder = link
        return updated
    }

    /// A habit for each daily repeat that has none, so every daily reminder
    /// is tracked: seven times a week, from its oldest tick still in reach
    /// (else today), with its ticks since carried over. A reminder whose
    /// habit was archived gets no new one: archiving is how they stop
    /// tracking it.
    public static func newHabits(
        for reminders: [Reminder], habits: [Habit], completed: [CompletedReminder],
        today: Day
    ) -> [Habit] {
        let taken = Set(habits.compactMap { $0.reminder.flatMap { find($0, in: reminders)?.id } })
        return reminders.filter { $0.repeatsDaily && !taken.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { reminder in
                let link = HabitReminder(id: reminder.id, title: reminder.title, listID: reminder.listID)
                let first = doneDays(link, titles: [link.title], in: completed)
                    .filter { $0 <= today && $0.ordinal > today.ordinal - lookback }.min()
                let habit = Habit(title: reminder.title, perWeek: 7, startedOn: first ?? today, reminder: link)
                return carryOver(habit, reminders: reminders, completed: completed, today: today)
            }
    }

    /// The days a linked reminder's done copies were ticked off: by its
    /// identifier, or by any of `titles` in its list.
    private static func doneDays(_ link: HabitReminder, titles: [String], in completed: [CompletedReminder]) -> Set<Day> {
        Set(
            completed.filter { done in
                done.id == link.id || (done.listID == link.listID && titles.contains { done.title.sameTitle(as: $0) })
            }.map(\.day))
    }
}
