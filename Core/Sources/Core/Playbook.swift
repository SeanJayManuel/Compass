import Foundation

/// What a Playbook entry is: a thing they buy, steps they follow, or just
/// something worth remembering.
public enum PlaybookKind: String, Hashable, Codable, Sendable, CaseIterable {
    case pick
    case routine
    case note
}

/// One step of a routine, on chosen weekdays or every day.
public struct PlaybookStep: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var text: String
    /// 0 is Monday, 6 is Sunday; empty is every day.
    public var weekdays: Set<Int>

    public init(id: UUID = UUID(), text: String, weekdays: Set<Int> = []) {
        self.id = id
        self.text = text
        self.weekdays = weekdays
    }
}

/// Something that works for them, kept so they don't have to figure it out
/// twice: the tee they rebuy, their shower routine, their workout split.
public struct PlaybookEntry: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    /// Clothes, Hair, Fitness and so on.
    public var area: String
    public var kind: PlaybookKind
    public var title: String
    /// What exactly: "Uniqlo Supima Cotton crew, white and black".
    public var detail: String
    /// Where it's from: a shop, a site.
    public var source: String
    public var size: String
    public var notes: String
    /// A routine's steps, in order.
    public var steps: [PlaybookStep]
    /// For something done every so often, like cutting nails.
    public var repeatEveryDays: Int?
    public var lastDone: Day?
    /// A repeat's reminder in Reminders (seam 46); entries saved before it read back with none.
    public var reminder: PlaybookReminder?

    public init(
        id: UUID = UUID(), area: String, kind: PlaybookKind, title: String, detail: String = "", source: String = "",
        size: String = "", notes: String = "", steps: [PlaybookStep] = [], repeatEveryDays: Int? = nil, lastDone: Day? = nil,
        reminder: PlaybookReminder? = nil
    ) {
        self.id = id
        self.area = area
        self.kind = kind
        self.title = title
        self.detail = detail
        self.source = source
        self.size = size
        self.notes = notes
        self.steps = steps
        self.repeatEveryDays = repeatEveryDays
        self.lastDone = lastDone
        self.reminder = reminder
    }
}

/// One line of the sizes card: "Suit", "38S".
public struct PlaybookSize: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var label: String
    public var value: String

    public init(id: UUID = UUID(), label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// Every size they wear in one place, with a note for brand exceptions.
public struct PlaybookSizes: Hashable, Codable, Sendable {
    public var rows: [PlaybookSize]
    public var note: String

    public init(rows: [PlaybookSize] = [], note: String = "") {
        self.rows = rows
        self.note = note
    }
}

/// The Playbook's schedule (seam 36): when a repeat is next due, which of a
/// routine's steps fall today, and the Today line built from both.
public enum Playbook {
    /// The day a repeat is next due: its interval after it was last done, or
    /// today if it never was. Nil for an entry that doesn't repeat.
    public static func nextDue(_ entry: PlaybookEntry, today: Day) -> Day? {
        guard let every = entry.repeatEveryDays else { return nil }
        guard let last = entry.lastDone else { return today }
        return Day(ordinal: last.ordinal + every)
    }

    public static func markDone(_ entry: PlaybookEntry, on day: Day) -> PlaybookEntry {
        var done = entry
        done.lastDone = day
        return done
    }

    /// 0 for Monday through 6 for Sunday.
    public static func weekday(_ day: Day) -> Int {
        // Day 0 (Jan 1, 2001) was a Monday.
        ((day.ordinal % 7) + 7) % 7
    }

    /// A weekday step that isn't today, and the next day it falls on.
    public struct NextStep: Hashable, Sendable {
        public var step: PlaybookStep
        public var day: Day

        public init(step: PlaybookStep, day: Day) {
            self.step = step
            self.day = day
        }
    }

    /// A routine on one day: the steps that fall on it, in order, and when
    /// each weekday step it skips comes next, soonest first.
    public struct RoutineDay: Hashable, Sendable {
        public var steps: [PlaybookStep]
        public var next: [NextStep]
    }

    public static func routineDay(_ routine: PlaybookEntry, on day: Day) -> RoutineDay {
        let weekday = weekday(day)
        var steps: [PlaybookStep] = []
        var next: [NextStep] = []
        for step in routine.steps {
            if step.weekdays.isEmpty || step.weekdays.contains(weekday) {
                steps.append(step)
            } else if let ahead = (1...6).first(where: { step.weekdays.contains((weekday + $0) % 7) }) {
                next.append(NextStep(step: step, day: Day(ordinal: day.ordinal + ahead)))
            }
        }
        return RoutineDay(steps: steps, next: next.sorted { $0.day < $1.day })
    }

    /// The Today line: each routine that doesn't repeat (one the same every
    /// day included) and each repeat due within `soon` days, overdue first.
    /// A repeating routine shows with the repeats, when it's due.
    public struct Today: Hashable, Sendable {
        public struct Routine: Hashable, Sendable {
            public var entry: PlaybookEntry
            public var day: RoutineDay
        }

        public struct Due: Hashable, Sendable {
            public var entry: PlaybookEntry
            public var day: Day
        }

        public var routines: [Routine]
        public var due: [Due]

        public var isEmpty: Bool { routines.isEmpty && due.isEmpty }
    }

    public static func today(_ entries: [PlaybookEntry], today: Day, soon: Int = 2) -> Today {
        let routines =
            entries
            .filter { $0.kind == .routine && $0.repeatEveryDays == nil && !$0.steps.isEmpty }
            .map { Today.Routine(entry: $0, day: routineDay($0, on: today)) }
        let due =
            entries
            .compactMap { entry in nextDue(entry, today: today).map { Today.Due(entry: entry, day: $0) } }
            .filter { $0.day.ordinal <= today.ordinal + soon }
            .sorted { ($0.day, $0.entry.title) < ($1.day, $1.entry.title) }
        return Today(routines: routines, due: due)
    }

    /// What's next for a routine with nothing today: the session by its name
    /// when its first step starts with one ("Lower A: squat…"), else how
    /// many steps that day holds, so a first step doesn't read as the whole session.
    public struct NextSession: Hashable, Sendable {
        public var name: String?
        public var steps: Int
        public var day: Day

        public init(name: String?, steps: Int, day: Day) {
            self.name = name
            self.steps = steps
            self.day = day
        }
    }

    public static func nextSession(_ routine: PlaybookEntry, today: Day) -> NextSession? {
        let now = routineDay(routine, on: today)
        guard now.steps.isEmpty, let first = now.next.first else { return nil }
        let steps = routineDay(routine, on: first.day).steps
        let lead = steps.first?.text ?? first.step.text
        let name = lead.firstIndex(of: ":").map { lead[..<$0].trimmingCharacters(in: .whitespaces) }
        return NextSession(name: name?.isEmpty == false ? name : nil, steps: steps.count, day: first.day)
    }

    /// Repeats for Claude's This week reminders: from the day before each is
    /// due (or overdue), as a repeating reminder shows there; overdue first.
    public static func dueForReminders(_ entries: [PlaybookEntry], today: Day) -> [Today.Due] {
        Self.today(entries, today: today, soon: 1).due
    }

    /// Entries that mention any word of `query` in what they say (area,
    /// title, detail, where from, size, notes, steps), ignoring case; those
    /// matching more words first. A blank query keeps them all.
    public static func search(_ entries: [PlaybookEntry], _ query: String) -> [PlaybookEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        let scored = entries.enumerated().compactMap { index, entry -> (Int, Int, PlaybookEntry)? in
            let text = ([entry.area, entry.title, entry.detail, entry.source, entry.size, entry.notes] + entry.steps.map(\.text))
                .joined(separator: " ").lowercased()
            let hits = words.filter { text.contains($0) }.count
            return hits > 0 ? (hits, index, entry) : nil
        }
        return scored.sorted { ($1.0, $0.1) < ($0.0, $1.1) }.map(\.2)
    }
}
