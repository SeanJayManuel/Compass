import Foundation

/// A calendar quarter, like Q4 2026.
public struct Quarter: Hashable, Comparable, Codable, Sendable {
    public var year: Int
    public var quarter: Int

    public init(year: Int, quarter: Int) {
        self.year = year
        self.quarter = quarter
    }

    public init(_ day: Day) {
        self.init(year: day.year, quarter: (day.month - 1) / 3 + 1)
    }

    public var next: Quarter {
        quarter == 4 ? Quarter(year: year + 1, quarter: 1) : Quarter(year: year, quarter: quarter + 1)
    }

    public var start: Day { Day(year: year, month: (quarter - 1) * 3 + 1, day: 1) }
    public var end: Day { Day(ordinal: next.start.ordinal - 1) }
    public var name: String { "Q\(quarter) \(year)" }

    public static func < (lhs: Quarter, rhs: Quarter) -> Bool {
        (lhs.year, lhs.quarter) < (rhs.year, rhs.quarter)
    }
}

extension Quarter {
    /// Days in the quarter (90 to 92).
    public var days: Int { end.ordinal - start.ordinal + 1 }

    /// Which day of the quarter `day` is, 1 to `days`; a day outside it
    /// is clamped to the first or last.
    public func dayNumber(of day: Day) -> Int {
        min(max(day.ordinal - start.ordinal + 1, 1), days)
    }
}

/// How a life goal measures progress: done or not, a count toward a
/// target, or a percentage set by hand.
public enum LifeProgress: Hashable, Codable, Sendable {
    case checkbox(done: Bool)
    case count(current: Int, target: Int)
    case percent(Int)
    /// Measured from Compass's own numbers, like net worth reaching $50,000.
    case linked(LinkedMeasure, target: Decimal)

    /// Progress from 0 to 1. A linked goal needs live values; see
    /// `LifeGoals.fraction(of:values:)`.
    public var fraction: Decimal {
        switch self {
        case .checkbox(let done): done ? 1 : 0
        case .count(let current, let target): target > 0 ? min(max(Decimal(current) / Decimal(target), 0), 1) : 0
        case .percent(let value): min(max(Decimal(value) / 100, 0), 1)
        case .linked: 0
        }
    }

    public var isComplete: Bool { fraction >= 1 }

    /// The same measure, started again (for a goal carried into a new quarter).
    var reset: LifeProgress {
        switch self {
        case .checkbox: .checkbox(done: false)
        case .count(_, let target): .count(current: 0, target: target)
        case .percent: .percent(0)
        case .linked: self
        }
    }
}

/// A number Compass already knows, for a life goal to follow.
public enum LinkedMeasure: Hashable, Codable, Sendable {
    case netWorth
    /// A money goal's measured value (its accounts, or investable assets).
    case moneyGoal(UUID)
}

/// One logged step, with an optional reflection.
public struct LifeEntry: Hashable, Codable, Sendable {
    public var day: Day
    public var note: String

    public init(day: Day, note: String) {
        self.day = day
        self.note = note
    }
}

public enum LifePeriod: Hashable, Codable, Sendable {
    /// A yearly resolution.
    case year(Int)
    /// A quarterly goal.
    case quarter(Quarter)
}

/// Like money goals, life goals are never deleted: they're done, dropped
/// with a reason, or carried into the next quarter.
public enum LifeGoalStatus: Hashable, Codable, Sendable {
    case active
    case done(on: Day)
    case dropped(reason: String, on: Day)
    case carriedOver(to: Quarter)
}

public struct LifeGoal: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var note: String
    public var period: LifePeriod
    public var progress: LifeProgress
    public var status: LifeGoalStatus
    /// For a quarterly goal: the resolution it serves.
    public var parentID: UUID?
    /// For a carried-over copy: the goal it continues.
    public var carriedFromID: UUID?
    /// Logged steps and reflections, oldest first.
    public var entries: [LifeEntry]

    public init(
        id: UUID = UUID(), title: String, note: String = "", period: LifePeriod, progress: LifeProgress,
        status: LifeGoalStatus = .active, parentID: UUID? = nil, carriedFromID: UUID? = nil, entries: [LifeEntry] = []
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.period = period
        self.progress = progress
        self.status = status
        self.parentID = parentID
        self.carriedFromID = carriedFromID
        self.entries = entries
    }

    /// Active or done; not let go or carried into another quarter.
    public var isOpenOrDone: Bool {
        switch status {
        case .active, .done: true
        case .dropped, .carriedOver: false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, note, period, progress, status, parentID, carriedFromID, entries
    }

    /// Goals saved before reflections existed load with none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        period = try container.decode(LifePeriod.self, forKey: .period)
        progress = try container.decode(LifeProgress.self, forKey: .progress)
        status = try container.decode(LifeGoalStatus.self, forKey: .status)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        carriedFromID = try container.decodeIfPresent(UUID.self, forKey: .carriedFromID)
        entries = try container.decodeIfPresent([LifeEntry].self, forKey: .entries) ?? []
    }
}

/// Something to do someday. Done items become milestones.
public struct ListItem: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var addedOn: Day
    public var doneOn: Day?
    /// The year's list it belongs to, like "2026 living list"; nil for someday.
    public var year: Int?

    public init(id: UUID = UUID(), title: String, addedOn: Day, doneOn: Day? = nil, year: Int? = nil) {
        self.id = id
        self.title = title
        self.addedOn = addedOn
        self.doneOn = doneOn
        self.year = year
    }
}

public struct LifeMilestone: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var day: Day
    /// "Resolution", "Quarterly goal" or "From your list".
    public var source: String
}

public enum LifeGoals {
    /// Sets progress; reaching 100% marks the goal done today, and falling
    /// back below reopens it. A goal that follows a number keeps its status:
    /// only `refreshLinked` (and editing its target) changes that.
    public static func setProgress(_ goal: LifeGoal, to progress: LifeProgress, today: Day) -> LifeGoal {
        var updated = goal
        updated.progress = progress
        if case .linked = progress { return updated }
        switch (goal.status, progress.isComplete) {
        case (.active, true): updated.status = .done(on: today)
        case (.done, false): updated.status = .active
        default: break
        }
        return updated
    }

    /// Saves an edit: the title, note, resolution and progress come from the
    /// editor, laid over the goal as stored now, whose status and reflections
    /// may have moved on while the editor was open (a sync can mark a linked
    /// goal done). A count or checkbox the edit finishes is done, and one it
    /// leaves unfinished reopens. A linked goal whose number or target changed
    /// reopens if the number is short of it; reaching it stays `refreshLinked`'s job.
    public static func applyEdit(
        _ edited: LifeGoal, over stored: LifeGoal?, values: [LinkedMeasure: Decimal],
        today: Day
    ) -> LifeGoal {
        var goal = stored ?? edited
        goal.title = edited.title
        goal.note = edited.note
        goal.parentID = edited.parentID
        guard case .linked = edited.progress else { return setProgress(goal, to: edited.progress, today: today) }
        let changed = goal.progress != edited.progress
        goal.progress = edited.progress
        if changed, case .done = goal.status, fraction(of: goal, values: values) < 1 { goal.status = .active }
        return goal
    }

    /// A goal's progress from 0 to 1, reading live values for linked goals.
    public static func fraction(of goal: LifeGoal, values: [LinkedMeasure: Decimal]) -> Decimal {
        guard case .linked(let measure, let target) = goal.progress else { return goal.progress.fraction }
        guard let value = values[measure], target > 0 else { return 0 }
        return min(max(value / target, 0), 1)
    }

    /// Marks linked goals done the first time their value reaches the target.
    /// Like money goals, reaching it once is what counts.
    public static func refreshLinked(_ goals: [LifeGoal], values: [LinkedMeasure: Decimal], today: Day) -> [LifeGoal] {
        goals.map { goal in
            guard case .linked = goal.progress, goal.status == .active, fraction(of: goal, values: values) >= 1 else { return goal }
            var done = goal
            done.status = .done(on: today)
            return done
        }
    }

    /// Logs one step: a count goes up by one, a checkbox is ticked. The note,
    /// if any, is kept as a reflection.
    public static func log(_ goal: LifeGoal, note: String, today: Day) -> LifeGoal {
        let progress: LifeProgress =
            switch goal.progress {
            case .count(let current, let target): .count(current: current + 1, target: target)
            case .checkbox: .checkbox(done: true)
            case .percent, .linked: goal.progress
            }
        var logged = setProgress(goal, to: progress, today: today)
        logged.entries.append(LifeEntry(day: today, note: note.trimmingCharacters(in: .whitespacesAndNewlines)))
        return logged
    }

    /// A resolution's progress: the average of its quarterly goals (leaving
    /// out dropped and carried-over ones), or its own when it has none.
    public static func progress(of resolution: LifeGoal, children: [LifeGoal], values: [LinkedMeasure: Decimal] = [:]) -> Decimal {
        let counted = children.filter { $0.parentID == resolution.id && $0.isOpenOrDone }
        guard !counted.isEmpty else { return fraction(of: resolution, values: values) }
        return counted.reduce(Decimal(0)) { $0 + fraction(of: $1, values: values) } / Decimal(counted.count)
    }

    /// This year's resolutions, and this quarter's goals still open or done.
    /// Goals let go or carried over are history, so a resolution's card and
    /// its ring (`progress(of:children:)` over these) leave them out alike.
    public static func now(_ goals: [LifeGoal], today: Day) -> (resolutions: [LifeGoal], quarterGoals: [LifeGoal]) {
        let quarter = Quarter(today)
        return (
            goals.filter { $0.period == .year(today.year) },
            goals.filter { $0.period == .quarter(quarter) && $0.isOpenOrDone }
        )
    }

    /// A quarter's goals still open when it ends: carry each over or drop it.
    public static func toReview(_ goals: [LifeGoal], quarter: Quarter) -> [LifeGoal] {
        goals.filter { $0.period == .quarter(quarter) && $0.status == .active }
    }

    /// The original is marked carried over; a fresh copy starts next quarter,
    /// still serving the same resolution.
    public static func carryOver(_ goal: LifeGoal) -> (original: LifeGoal, copy: LifeGoal) {
        guard case .quarter(let quarter) = goal.period else { return (goal, goal) }
        var original = goal
        original.status = .carriedOver(to: quarter.next)
        let copy = LifeGoal(
            title: goal.title, note: goal.note, period: .quarter(quarter.next), progress: goal.progress.reset,
            parentID: goal.parentID, carriedFromID: goal.id)
        return (original, copy)
    }

    public static func drop(_ goal: LifeGoal, reason: String, today: Day) -> LifeGoal {
        var dropped = goal
        dropped.status = .dropped(reason: reason, on: today)
        return dropped
    }

    /// Finished goals and done list items, newest first.
    public static func milestones(goals: [LifeGoal], list: [ListItem]) -> [LifeMilestone] {
        let fromGoals = goals.compactMap { goal -> LifeMilestone? in
            guard case .done(let day) = goal.status else { return nil }
            let source = if case .year = goal.period { "Resolution" } else { "Quarterly goal" }
            return LifeMilestone(id: goal.id, title: goal.title, day: day, source: source)
        }
        let fromList = list.compactMap { item in
            item.doneOn.map { LifeMilestone(id: item.id, title: item.title, day: $0, source: "From your list") }
        }
        return (fromGoals + fromList).sorted { ($0.day, $0.title) > ($1.day, $1.title) }
    }
}

/// The few things they're betting a year on (savings, the gym, friendships,
/// career), apart from the living list's things to try. Kept per year.
public struct YearlyBets: Hashable, Codable, Sendable {
    public var year: Int
    public var bets: [String]

    public init(year: Int, bets: [String]) {
        self.year = year
        self.bets = bets
    }

    /// Their text as bets: one a line, blank lines and leading bullets dropped.
    public static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var bet = line.trimmingCharacters(in: .whitespaces)
            while let first = bet.first, "-•*".contains(first) { bet = String(bet.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return bet.isEmpty ? nil : bet
        }
    }
}
