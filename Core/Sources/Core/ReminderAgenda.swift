import Foundation

/// When a reminder is due: a day, and the minute of that day for a timed one.
public struct ReminderDue: Hashable, Comparable, Codable, Sendable {
    public var day: Day
    /// Minutes after local midnight; nil for a reminder due on a day, not at a time.
    public var minute: Int?

    public init(day: Day, minute: Int? = nil) {
        self.day = day
        self.minute = minute
    }

    /// A reminder's due date as Reminders stores it. A timed one with a zone
    /// of its own lands on the local day and minute it falls on in
    /// `timeZone`; one with no zone keeps its clock time. Midnight means a
    /// day was meant, so it's that day with no time. Nil without a date.
    public init?(_ components: DateComponents, in timeZone: TimeZone) {
        guard let year = components.year, let month = components.month, let dayOfMonth = components.day else { return nil }
        guard let hour = components.hour, hour != 0 || (components.minute ?? 0) != 0 else {
            self.init(day: Day(year: year, month: month, day: dayOfMonth))
            return
        }
        var source = Calendar(identifier: .gregorian)
        source.timeZone = components.timeZone ?? timeZone
        let parts = DateComponents(year: year, month: month, day: dayOfMonth, hour: hour, minute: components.minute ?? 0)
        guard let date = source.date(from: parts) else { return nil }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let clock = local.dateComponents([.hour, .minute], from: date)
        self.init(day: Day(date, in: timeZone), minute: clock.hour! * 60 + clock.minute!)
    }

    /// By day; on one day, all-day reminders before timed ones.
    public static func < (lhs: ReminderDue, rhs: ReminderDue) -> Bool {
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        return (lhs.minute ?? -1) < (rhs.minute ?? -1)
    }
}

/// A list in Reminders.
public struct ReminderList: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

extension ReminderList {
    /// Whether the list is called `name`, ignoring case and spaces around it.
    public func named(_ name: String) -> Bool { title.sameTitle(as: name) }
}

extension String {
    /// The same words, ignoring case and spaces around them.
    func sameTitle(as other: String) -> Bool {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(other.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}

/// An open reminder, as much of it as the Life overview needs.
public struct Reminder: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var listID: String
    public var due: ReminderDue?
    /// Repeats every day, like taking supplements.
    public var repeatsDaily: Bool
    /// Repeats at all, like a monthly check-in.
    public var repeats: Bool
    /// Its repeat, when Compass can describe it; nil for a one-off and for
    /// one repeating in a way only Reminders can (`repeats` still true).
    public var repeatRule: ReminderRepeat?
    public var notes: String?

    public init(
        id: String, title: String, listID: String, due: ReminderDue? = nil, repeatsDaily: Bool = false,
        repeats: Bool = false, repeatRule: ReminderRepeat? = nil, notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.listID = listID
        self.due = due
        self.repeatsDaily = repeatsDaily || repeatRule?.isDaily == true
        self.repeats = repeats || self.repeatsDaily || repeatRule != nil
        self.repeatRule = repeatRule
        self.notes = notes
    }
}

/// Open reminders sorted for the Life overview by horizon, the way their
/// lists already are: what's to do this week, daily repeats still to do
/// today, admin, the quarter, what's coming up in the next few months,
/// and the living list.
public struct ReminderAgenda: Hashable, Sendable {
    /// Due by the end of this (Sunday to Saturday) week, overdue first, then the rest of
    /// a list named This Week. A repeat waits until the day before it's due:
    /// it comes round every time, so it isn't a to-do until then.
    public var thisWeek: [Reminder] = []
    public var everyDay: [Reminder] = []
    /// A list named Admin or Errands, whatever their dates.
    public var admin: [Reminder] = []
    /// A list named This Quarter: its goals stay together, even in their deadline week.
    public var quarter: [Reminder] = []
    /// Things with a deadline in the next few months that aren't quarter
    /// goals: a list named Coming Up or Long Term, apart from what's due this week.
    public var comingUp: [Reminder] = []
    /// A list named Living List, apart from what's due this week.
    public var livingList: [Reminder] = []
    /// Undated reminders in a list named Inbox, still to sort.
    public var inbox = 0

    /// Reminders in `hidden` lists are left out, and so are `linked` ones:
    /// their habit stands in for them. A reminder in any other list shows
    /// only once it's due this week.
    public init(
        reminders: [Reminder], lists: [ReminderList], hidden: Set<String> = [], linked: Set<String> = [],
        names: ReminderListNames = .saved, today: Day
    ) {
        let weekEnd = Week(today).end
        func ids(_ role: ReminderListNames.Role) -> Set<String> {
            Set(lists.filter { names.matches(role, $0.title) }.map(\.id))
        }
        let weekLists = ids(.week), quarterLists = ids(.quarter), comingLists = ids(.comingUp)
        let livingLists = ids(.living), adminLists = ids(.admin), inboxLists = ids(.inbox)
        for reminder in reminders where !hidden.contains(reminder.listID) && !linked.contains(reminder.id) {
            let list = reminder.listID
            let showFrom = reminder.repeats ? Day(ordinal: today.ordinal + 1) : weekEnd
            let dueSoon = reminder.due.map { $0.day <= showFrom } ?? false
            if reminder.repeatsDaily {
                // A daily repeat due tomorrow was already done today.
                if let due = reminder.due, due.day <= today { everyDay.append(reminder) }
            } else if quarterLists.contains(list) {
                quarter.append(reminder)
            } else if adminLists.contains(list) {
                admin.append(reminder)
            } else if dueSoon || (weekLists.contains(list) && !reminder.repeats) {
                thisWeek.append(reminder)
            } else if comingLists.contains(list) {
                comingUp.append(reminder)
            } else if livingLists.contains(list) {
                livingList.append(reminder)
            } else if inboxLists.contains(list) && reminder.due == nil {
                inbox += 1
            }
        }
        // Dated first, by when; undated after, by title.
        let byDue: (Reminder, Reminder) -> Bool = { a, b in
            if a.due != b.due {
                guard let x = a.due, let y = b.due else { return a.due != nil }
                return x < y
            }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        thisWeek.sort(by: byDue)
        everyDay.sort(by: byDue)
        admin.sort(by: byDue)
        quarter.sort(by: byDue)
        comingUp.sort(by: byDue)
        livingList.sort(by: byDue)
    }

    /// What's overdue or due today, from every section, by when: the menu bar panel's Today.
    public func today(_ day: Day) -> [Reminder] {
        var seen = Set<String>()
        return (thisWeek + everyDay + admin + quarter + comingUp + livingList)
            .filter { reminder in reminder.due.map { $0.day <= day } ?? false }
            .filter { seen.insert($0.id).inserted }
            .sorted { a, b in
                a.due != b.due ? a.due! < b.due! : a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
    }

    /// The rest of this week's to-dos, after `today(_:)`: This Week's
    /// undated ones and anything due later this week.
    public func laterThisWeek(_ day: Day) -> Int {
        let weekEnd = Week(day).end
        return thisWeek.count { reminder in reminder.due.map { $0.day > day } ?? true }
            + (admin + quarter).count { reminder in reminder.due.map { $0.day > day && $0.day <= weekEnd } ?? false }
    }

    /// The title without a leading copy of its list's name, so "Living List:
    /// Learn French" reads "Learn French" under Living list.
    public static func shortTitle(_ title: String, list: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let breaks = " :-–—"
        guard !list.isEmpty, let range = trimmed.range(of: list, options: [.anchored, .caseInsensitive]),
            let next = trimmed[range.upperBound...].first, breaks.contains(next)
        else { return title }
        let rest = trimmed[range.upperBound...].drop { breaks.contains($0) }
        return rest.isEmpty ? title : String(rest)
    }
}

extension ReminderAgenda {
    /// Shopping lists, left out until they choose otherwise: they're for the
    /// shop, not the week.
    public static func hiddenByDefault(_ lists: [ReminderList]) -> Set<String> {
        Set(lists.filter { list in ["grocery", "groceries", "shopping"].contains { list.named($0) } }.map(\.id))
    }
}

/// A quarter reminder followed by one of Compass's own numbers, like "$50k
/// net worth by year-end" against net worth. The one piece of the quarter
/// Compass keeps, so it goes into the backup.
public struct ReminderMeasure: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var reminderID: String
    /// Finds the reminder again if Reminders hands back a new identifier.
    public var title: String
    public var measure: LinkedMeasure
    public var target: Decimal
    /// What they'll buy once it's reached, like a money goal's reward.
    public var reward: Reward?

    public init(id: UUID = UUID(), reminderID: String, title: String, measure: LinkedMeasure, target: Decimal, reward: Reward? = nil) {
        self.id = id
        self.reminderID = reminderID
        self.title = title
        self.measure = measure
        self.target = target
        self.reward = reward
    }

    /// Progress from 0 to 1, or nil while the number isn't known.
    public func fraction(values: [LinkedMeasure: Decimal]) -> Decimal? {
        guard let value = values[measure], target > 0 else { return nil }
        return min(max(value / target, 0), 1)
    }

    /// The link for `reminder`: by identifier, else by the same title.
    public static func link(for reminder: Reminder, in links: [ReminderMeasure]) -> ReminderMeasure? {
        links.first { $0.reminderID == reminder.id } ?? links.first { $0.title.sameTitle(as: reminder.title) }
    }

    /// The link Claude names: by its reminder's identifier, else the one
    /// link with that title, so a reminder ticked off can still be named.
    public static func link(named wanted: String, in links: [ReminderMeasure]) -> ReminderMeasure? {
        if let same = links.first(where: { $0.reminderID == wanted }) { return same }
        let titled = links.filter { $0.title.sameTitle(as: wanted) }
        return titled.count == 1 ? titled[0] : nil
    }

    /// A dollar amount in the title, like "$50k", "$4,000" or "$1.2M".
    public static func suggestedTarget(in title: String) -> Decimal? {
        guard let match = title.firstMatch(of: /\$\s?([\d,]+(?:\.\d+)?)\s?([kKmM])?\b/),
            let number = Decimal(string: match.1.replacingOccurrences(of: ",", with: ""))
        else { return nil }
        switch match.2?.lowercased() {
        case "k": return number * 1_000
        case "m": return number * 1_000_000
        default: return number
        }
    }
}
