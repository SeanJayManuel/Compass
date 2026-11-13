import Foundation

/// Goals go from active to achieved, or are retired; none is ever deleted.
public enum GoalLifecycle {
    /// Records the first day the measured value reached the target, with that
    /// day's value. Achieved and retired goals don't change.
    public static func update(_ goal: Goal, measured: [DailyTotal]) -> Goal {
        guard goal.status == .active else { return goal }
        let target = goal.effectiveTarget
        guard target > 0, let crossing = measured.first(where: { $0.total >= target }) else { return goal }
        var achieved = goal
        achieved.status = .achieved(on: crossing.day, value: crossing.total)
        return achieved
    }

    public static func retire(_ goal: Goal, reason: String) -> Goal {
        var retired = goal
        retired.status = .retired(reason: reason)
        return retired
    }

    /// A draft of the next goal: the next round number, same kind, linked to
    /// this one. Never saved without the person accepting it.
    public static func successor(of goal: Goal) -> Goal {
        let next = nextRoundNumber(after: goal.target)
        let oldLabel = compactDollars(goal.target)
        let name =
            goal.name.contains(oldLabel)
            ? goal.name.replacingOccurrences(of: oldLabel, with: compactDollars(next))
            : compactDollars(next)
        return Goal(name: name, kind: goal.kind, target: next, predecessorID: goal.id)
    }

    /// The goals this one follows, oldest first, ending with this one.
    public static func chain(endingWith goal: Goal, in goals: [Goal]) -> [Goal] {
        let byID = Dictionary(goals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chain = [goal]
        var seen: Set<UUID> = [goal.id]
        while let previousID = chain.first?.predecessorID, let previous = byID[previousID], seen.insert(previousID).inserted {
            chain.insert(previous, at: 0)
        }
        return chain
    }

    /// Every reached goal and claimed reward, newest first. Retired goals
    /// are not milestones.
    public static func milestones(in goals: [Goal]) -> [Milestone] {
        let byID = Dictionary(goals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [Milestone] = []
        for goal in goals {
            if case .achieved(let day, _) = goal.status {
                var months: Int?
                if let previousID = goal.predecessorID,
                    case .achieved(let previousDay, _)? = byID[previousID]?.status
                {
                    var exact = GoalProgress.monthsBetween(previousDay, day)
                    var rounded = Decimal()
                    NSDecimalRound(&rounded, &exact, 0, .plain)
                    months = NSDecimalNumber(decimal: rounded).intValue
                }
                events.append(
                    Milestone(
                        kind: .reached, day: day, goal: goal, monthsSincePrevious: months,
                        previousName: goal.predecessorID.flatMap { byID[$0]?.name }))
            }
            if let claimed = goal.reward?.claimedOn {
                events.append(Milestone(kind: .rewardClaimed, day: claimed, goal: goal))
            }
        }
        return events.sorted { $0.day > $1.day }
    }

    /// The next of 1, 1.5, 2, 2.5, 3, 4, 5, 7.5 or 10 times a power of ten.
    static func nextRoundNumber(after value: Decimal) -> Decimal {
        guard value > 0 else { return 1_000 }
        let steps: [Decimal] = [1, Decimal(string: "1.5")!, 2, Decimal(string: "2.5")!, 3, 4, 5, Decimal(string: "7.5")!, 10]
        var scale: Decimal = 1
        while scale * 10 <= value { scale *= 10 }
        return steps.map { $0 * scale }.first { $0 > value } ?? scale * 15
    }

    /// "$150K", "$1.5M", "$750".
    public static func compactDollars(_ value: Decimal) -> String {
        func trimmed(_ number: Decimal) -> String {
            var number = number
            var rounded = Decimal()
            NSDecimalRound(&rounded, &number, 1, .plain)
            return NSDecimalNumber(decimal: rounded).stringValue
        }
        if value >= 1_000_000 { return "$\(trimmed(value / 1_000_000))M" }
        if value >= 1_000 { return "$\(trimmed(value / 1_000))K" }
        return "$\(trimmed(value))"
    }
}

public struct Milestone: Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        case reached
        case rewardClaimed
    }

    public var kind: Kind
    public var day: Day
    public var goal: Goal
    /// For a goal in a chain: whole months since the previous goal was reached.
    public var monthsSincePrevious: Int?
    public var previousName: String?

    public var id: String { "\(kind)-\(goal.id)" }

    public init(kind: Kind, day: Day, goal: Goal, monthsSincePrevious: Int? = nil, previousName: String? = nil) {
        self.kind = kind
        self.day = day
        self.goal = goal
        self.monthsSincePrevious = monthsSincePrevious
        self.previousName = previousName
    }
}
