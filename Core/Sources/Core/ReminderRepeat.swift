import Foundation

/// How a reminder repeats, as Claude sets it (seam 31): every day, week,
/// month or year, every so many of them, on chosen weekdays (weekly only)
/// and until a day. Reminders can do more (the second Sunday of each
/// month); those read as no rule here and are left to Reminders.
public struct ReminderRepeat: Hashable, Codable, Sendable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily, weekly, monthly, yearly

        /// "day" for daily, as in "every 10 days".
        public var unit: String {
            switch self {
            case .daily: "day"
            case .weekly: "week"
            case .monthly: "month"
            case .yearly: "year"
            }
        }
    }

    public var frequency: Frequency
    /// Every this many days, weeks, months or years.
    public var every: Int
    /// 0 is Monday, 6 is Sunday; empty is the due date's own day.
    public var weekdays: Set<Int>
    /// The last day it repeats on.
    public var until: Day?

    public init(frequency: Frequency, every: Int = 1, weekdays: Set<Int> = [], until: Day? = nil) {
        self.frequency = frequency
        self.every = every
        self.weekdays = weekdays
        self.until = until
    }

    /// Every day, like taking supplements.
    public var isDaily: Bool { frequency == .daily && every == 1 }

    static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// "daily", "every 10 days", "weekly on Sun, Wed" (Sunday first, as weeks
    /// run), "every 2 months until 2026-12-31".
    public var text: String {
        var text = every == 1 ? frequency.rawValue : "every \(every) \(frequency.unit)s"
        if !weekdays.isEmpty { text += " on " + Week.sorted(weekdays).map { Self.weekdayNames[$0] }.joined(separator: ", ") }
        if let until { text += " until \(until.iso)" }
        return text
    }
}

/// A repeat an edit sets: none, or a rule.
public enum Repeating: Hashable, Codable, Sendable {
    case never
    case rule(ReminderRepeat)

    public var repeatRule: ReminderRepeat? {
        if case .rule(let rule) = self { rule } else { nil }
    }
}

extension ClaudeRules {
    /// A repeat from Claude's words: daily, weekly, monthly or yearly (or
    /// "every 10 days", "every week"), every 1 to 365, weekdays by name on a weekly one;
    /// "none" for no repeat.
    public static func reminderRepeat(_ frequency: String, every: Int?, weekdays: [String], until: Day?) throws -> Repeating {
        let words = frequency.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if words == ["none"] { return .never }
        var every = every
        let kind: ReminderRepeat.Frequency
        if let named = ReminderRepeat.Frequency(rawValue: words.joined()) {
            kind = named
        } else if words.first == "every", (2...3).contains(words.count), let count = words.count == 2 ? 1 : Int(words[1]),
            let named = ReminderRepeat.Frequency.allCases.first(where: { words.last == $0.unit || words.last == $0.unit + "s" })
        {
            kind = named
            every = every ?? count
        } else {
            throw ClaudeRefusal("A repeat is daily, weekly, monthly or yearly (or \"every 10 days\"), or none.")
        }
        let interval = every ?? 1
        guard (1...365).contains(interval) else { throw ClaudeRefusal("A repeat is every 1 to 365 \(kind == .daily ? "days" : "times").") }
        var days: Set<Int> = []
        for name in weekdays {
            let prefix = name.trimmingCharacters(in: .whitespaces).lowercased().prefix(3)
            guard let index = ReminderRepeat.weekdayNames.firstIndex(where: { $0.lowercased() == prefix }),
                name.trimmingCharacters(in: .whitespaces).count >= 3
            else {
                throw ClaudeRefusal("\(name) isn't a weekday; use mon, tue, wed, thu, fri, sat or sun.")
            }
            days.insert(index)
        }
        guard days.isEmpty || kind == .weekly else { throw ClaudeRefusal("Weekdays go only on a weekly repeat.") }
        return .rule(ReminderRepeat(frequency: kind, every: interval, weekdays: days, until: until))
    }

    /// Sets `repeating` on an edit (nil leaves the repeat alone), as Reminders
    /// needs it: a repeat has a due date (today, when it has none) and ends
    /// on or after it. A habit's reminder and one repeating in a way Compass
    /// can't describe keep their repeat.
    public static func setRepeat(
        _ repeating: Repeating?, on edit: inout ReminderEdit, reminder: Reminder?, linkedToHabit: Bool,
        today: Day
    ) throws {
        guard let repeating else {
            if reminder?.repeats == true, edit.due == nil {
                throw ClaudeRefusal("\(edit.title) repeats, so it needs a due date; take the repeat off with repeat \"none\" first.")
            }
            return
        }
        if linkedToHabit { throw ClaudeRefusal("\(edit.title) is a habit's reminder; its daily repeat stays (edit the habit instead).") }
        if let reminder, reminder.repeats, reminder.repeatRule == nil {
            throw ClaudeRefusal("\(edit.title) repeats in a way Compass can't describe or put back; change its repeat in Reminders.")
        }
        if case .rule(let rule) = repeating {
            if edit.due == nil { edit.due = ReminderDue(day: today) }
            if let until = rule.until, let due = edit.due, until < due.day {
                throw ClaudeRefusal("The repeat ends \(until.iso), before it's due (\(due.day.iso)).")
            }
        }
        edit.repeating = repeating
    }
}
