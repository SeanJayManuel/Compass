import Foundation

/// A Sunday-to-Saturday week, everywhere in Compass.
public struct Week: Hashable, Comparable, Codable, Sendable {
    /// The Sunday.
    public let start: Day

    public init(_ day: Day) {
        // Day 0 (Jan 1, 2001) was a Monday, so day -1 was a Sunday.
        let offset = (((day.ordinal + 1) % 7) + 7) % 7
        start = Day(ordinal: day.ordinal - offset)
    }

    /// Weekdays as Compass numbers them (0 is Monday, 6 Sunday, as stored
    /// on Playbook steps and repeats) in the order a week runs: Sunday first.
    public static let weekdays = [6, 0, 1, 2, 3, 4, 5]

    /// Weekday numbers in week order, Sunday first.
    public static func sorted(_ days: some Sequence<Int>) -> [Int] {
        days.sorted { (($0 + 1) % 7) < (($1 + 1) % 7) }
    }

    public var end: Day { Day(ordinal: start.ordinal + 6) }
    public var next: Week { Week(Day(ordinal: start.ordinal + 7)) }
    public var previous: Week { Week(Day(ordinal: start.ordinal - 7)) }

    public func contains(_ day: Day) -> Bool { day >= start && day <= end }

    public static func < (lhs: Week, rhs: Week) -> Bool { lhs.start < rhs.start }
}

/// Something done a number of times each week, like working out four times.
public struct Habit: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var perWeek: Int
    public var startedOn: Day
    /// The resolution it serves, if any.
    public var parentID: UUID?
    /// Days it was done; one per day at most.
    public var checkIns: [Day]
    public var archived: Bool
    /// The daily reminder in Reminders that prompts it, if they linked one.
    public var reminder: HabitReminder?

    public init(
        id: UUID = UUID(), title: String, perWeek: Int, startedOn: Day,
        parentID: UUID? = nil, checkIns: [Day] = [], archived: Bool = false, reminder: HabitReminder? = nil
    ) {
        self.id = id
        self.title = title
        self.perWeek = perWeek
        self.startedOn = startedOn
        self.parentID = parentID
        self.checkIns = checkIns
        self.archived = archived
        self.reminder = reminder
    }
}

public enum WeekResult: Hashable, Sendable {
    case hit
    case missed
    /// The current week, not over yet.
    case inProgress(done: Int)
    /// A week the habit only started partway through (or hadn't started yet)
    /// that didn't reach the target: neither hit nor missed.
    case notCounted
}

public struct WeekRecord: Hashable, Sendable {
    public var week: Week
    public var result: WeekResult
}

public enum Habits {
    /// Checks in for a day, or undoes that day's check-in.
    public static func toggle(_ habit: Habit, on day: Day) -> Habit {
        var updated = habit
        if let index = updated.checkIns.firstIndex(of: day) {
            updated.checkIns.remove(at: index)
        } else {
            updated.checkIns.append(day)
            updated.checkIns.sort()
        }
        return updated
    }

    /// Whether a day can be ticked or unticked: any day up to today from the
    /// Sunday of the week the habit started (days done before adding it that
    /// week still count), and a stray earlier tick can always be undone.
    public static func canCheckIn(_ habit: Habit, on day: Day, today: Day) -> Bool {
        day <= today && (day >= Week(habit.startedOn).start || habit.checkIns.contains(day))
    }

    public static func done(_ habit: Habit, in week: Week) -> Int {
        Set(habit.checkIns.filter(week.contains)).count
    }

    /// For this week: how many more check-ins the habit needs, and the days
    /// left to make them, today included. A habit added midweek keeps the full
    /// target and counts the days ticked since that week's Sunday, as
    /// `canCheckIn` allows. One that starts in a later week has no day to tick
    /// this week, so `daysLeft` is 0.
    public static func stillToDo(_ habit: Habit, today: Day) -> (needed: Int, daysLeft: Int) {
        let week = Week(today)
        let needed = max(habit.perWeek - done(habit, in: week), 0)
        guard week >= Week(habit.startedOn) else { return (needed, 0) }
        return (needed, week.end.ordinal - today.ordinal + 1)
    }

    /// How a week went. A habit started after its first week's Sunday has
    /// fewer days that week, so the week is never missed: it counts as hit
    /// if the full target was reached anyway (an early win is still a win),
    /// and otherwise doesn't count either way, for streaks and weeks hit
    /// alike. Weeks before the habit started work the same way.
    public static func result(_ habit: Habit, week: Week, today: Day) -> WeekResult {
        let done = done(habit, in: week)
        if done >= habit.perWeek { return .hit }
        if week.contains(today) { return .inProgress(done: done) }
        return week.start < habit.startedOn ? .notCounted : .missed
    }

    /// Up to `weeks` weeks ending with the current one, never before the
    /// habit started; oldest first. A short first week shows as hit or not
    /// counted, never missed.
    public static func history(_ habit: Habit, weeks: Int, today: Day) -> [WeekRecord] {
        let first = Week(habit.startedOn)
        var week = Week(today)
        var records: [WeekRecord] = []
        while records.count < weeks && week >= first {
            records.append(WeekRecord(week: week, result: result(habit, week: week, today: today)))
            week = week.previous
        }
        return records.reversed()
    }

    /// Finished weeks since the habit started, oldest first.
    static func finishedWeeks(_ habit: Habit, today: Day) -> [WeekResult] {
        var results: [WeekResult] = []
        var week = Week(habit.startedOn)
        let current = Week(today)
        while week < current {
            results.append(result(habit, week: week, today: today))
            week = week.next
        }
        return results
    }

    /// Hit weeks in a row, counting back from the last finished week (or
    /// from this week, if it's already hit).
    public static func streak(_ habit: Habit, today: Day) -> Int {
        var results = finishedWeeks(habit, today: today)
        if result(habit, week: Week(today), today: today) == .hit { results.append(.hit) }
        return results.reversed().prefix { $0 == .hit }.count
    }

    /// Weeks hit in a quarter (weeks starting in it), out of its weeks so
    /// far: finished ones, plus this one once it's hit.
    public static func weeksHit(_ habit: Habit, in quarter: Quarter, today: Day) -> (hit: Int, total: Int) {
        var week = Week(quarter.start)
        if week.start < quarter.start { week = week.next }
        var hit = 0, total = 0
        while week.start <= quarter.end && week.start <= today {
            if week.end >= habit.startedOn {
                switch result(habit, week: week, today: today) {
                case .hit: hit += 1; total += 1
                case .missed: total += 1
                case .inProgress, .notCounted: break
                }
            }
            week = week.next
        }
        return (hit, total)
    }
}
