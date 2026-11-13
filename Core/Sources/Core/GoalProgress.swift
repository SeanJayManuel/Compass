import Foundation

public enum GoalStanding: Hashable, Codable, Sendable {
    case reached
    case onTrack
    case behind
}

/// A goal's standing in words. Without a date, "on track" has nothing to
/// measure against, so an undated goal is growing or not growing.
public enum GoalReadingStanding: String, Hashable, Sendable {
    case reached, onTrack = "on track", behind, growing, notGrowing = "not growing"
}

/// Am I on pace? Everything a goal card shows.
public struct GoalProgress: Hashable, Codable, Sendable {
    public var current: Decimal
    public var target: Decimal
    /// Progress toward the target, 0 to 1.
    public var fraction: Decimal
    public var remaining: Decimal
    public var minimumReached: Bool
    /// Progress from the minimum to the target, once the minimum is reached.
    public var fractionOfRange: Decimal?
    /// The average monthly gain over the last three months, leaving out
    /// accounts' opening balances (or, for an invested goal, its contributions).
    public var pacePerMonth: Decimal?
    /// What each month must add to hit the target date.
    public var neededPerMonth: Decimal?
    public var projectedDate: Day?
    public var standing: GoalStanding
    /// The pace is what they put in (`Contributions.pace`), not the balances' change.
    public var paceFromContributions = false
    /// With a contribution pace: what the market did a month, shown apart,
    /// and accounts whose contributions can't be told, left out of the pace.
    public var marketPerMonth: Decimal?
    public var paceLeavesOut: [UUID] = []

    /// Days in an average month, for turning months of pace into dates.
    static let daysPerMonth = Decimal(string: "30.436875")!

    /// Projections further out than this are not shown.
    static let longestProjectionInMonths: Decimal = 1_200

    public static func evaluate(_ goal: Goal, accounts: [Account], snapshots: [BalanceSnapshot], today: Day) -> GoalProgress {
        evaluate(goal, measured: measured(goal, accounts: accounts, snapshots: snapshots, today: today), today: today)
    }

    /// For callers that already have the measured series (see `measured`).
    /// An invested goal passes `contributionPace`, which replaces the
    /// balances' pace.
    public static func evaluate(
        _ goal: Goal, measured values: [DailyTotal], today: Day,
        contributionPace: Decimal? = nil
    ) -> GoalProgress {
        let current = values.last?.total ?? 0
        let target = goal.effectiveTarget
        let remaining = max(target - current, 0)
        let pace = contributionPace ?? pacePerMonth(values, today: today)

        var neededPerMonth: Decimal?
        if let date = goal.targetDate {
            let months = monthsBetween(today, date)
            neededPerMonth = months > 0 ? remaining / months : remaining
        }

        var projected: Day?
        if remaining == 0 {
            projected = today
        } else if let pace, pace > 0, remaining / pace <= longestProjectionInMonths {
            projected = day(afterMonths: remaining / pace, from: today)
        }

        let standing: GoalStanding
        if remaining == 0 {
            standing = .reached
        } else if let projected {
            standing = goal.targetDate.map { projected <= $0 ? .onTrack : .behind } ?? .onTrack
        } else {
            standing = .behind
        }

        let minimumReached = goal.targetMin.map { current >= $0 } ?? (remaining == 0)
        var fractionOfRange: Decimal?
        if let min = goal.targetMin, current >= min, target > min {
            fractionOfRange = Swift.min((current - min) / (target - min), 1)
        }

        return GoalProgress(
            current: current,
            target: target,
            fraction: target > 0 ? Swift.min(Swift.max(current / target, 0), 1) : 0,
            remaining: remaining,
            minimumReached: minimumReached,
            fractionOfRange: fractionOfRange,
            pacePerMonth: pace,
            neededPerMonth: neededPerMonth,
            projectedDate: projected,
            standing: standing,
            paceFromContributions: contributionPace != nil
        )
    }

    /// The goal's measured value for every day with data, with the opening
    /// balances of the accounts it measures (pace leaves those out). Pass
    /// `breakdown` when evaluating several goals, so net worth and FIRE goals
    /// share it, and `moves` so money moved into a new account isn't an opening.
    public static func measured(
        _ goal: Goal,
        accounts: [Account],
        snapshots: [BalanceSnapshot],
        today: Day,
        breakdown shared: [DailyBreakdown]? = nil,
        moves: [NetWorthSeries.Move] = []
    ) -> [DailyTotal] {
        func breakdown() -> [DailyBreakdown] {
            shared ?? NetWorthSeries.breakdown(accounts: accounts, snapshots: snapshots, through: today, moves: moves)
        }
        switch goal.kind {
        case .netWorth:
            return breakdown().map(\.netWorth)
        case .accountTotal(let ids):
            // Chosen accounts count even if excluded from net worth.
            let chosen = accounts.filter { ids.contains($0.id) }.map { account in
                var counted = account
                counted.excludedFromNetWorth = false
                return counted
            }
            return NetWorthSeries.breakdown(accounts: chosen, snapshots: snapshots, through: today, moves: moves)
                .map(\.netWorth)
        case .fire:
            let investable: Set<AccountClass> = [.taxable, .retirement, .equity]
            return breakdown().map { day in
                DailyTotal(
                    day: day.day, total: day.byClass.filter { investable.contains($0.key) }.values.reduce(0, +),
                    opened: day.openedByClass.filter { investable.contains($0.key) }.values.reduce(0, +))
            }
        }
    }

    /// The straight path from today's value to the target at the current
    /// pace: two points, today and the projected day. Nil when there's no
    /// projection, the goal is reached, or the projection is further out
    /// than `horizonMonths`, so a chart never stretches to draw one.
    public func projectionLine(today: Day, horizonMonths: Int = 60) -> [DailyTotal]? {
        guard standing != .reached, remaining > 0,
            let projectedDate, projectedDate > today,
            Self.monthsBetween(today, projectedDate) <= Decimal(horizonMonths)
        else { return nil }
        return [DailyTotal(day: today, total: current), DailyTotal(day: projectedDate, total: target)]
    }

    /// An account-total goal over investing accounts only, whose pace is its contributions.
    public static func isInvested(_ goal: Goal, accounts: [Account]) -> Bool {
        guard case .accountTotal(let ids) = goal.kind, !ids.isEmpty else { return false }
        let investing: Set<AccountClass> = [.taxable, .retirement, .equity]
        let chosen = accounts.filter { ids.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy { investing.contains($0.accountClass) }
    }

    static func pacePerMonth(_ values: [DailyTotal], today: Day) -> Decimal? {
        guard let first = values.first, let last = values.last else { return nil }
        let windowStart = today.addingMonths(-3)
        let base = values.last(where: { $0.day <= windowStart }) ?? first
        let months = monthsBetween(base.day, today)
        guard months > 0 else { return nil }
        return (last.withoutOpenings - base.withoutOpenings) / months
    }

    /// Whole calendar months plus leftover days as a fraction of an average month.
    static func monthsBetween(_ start: Day, _ end: Day) -> Decimal {
        guard end > start else { return 0 }
        var whole = 0
        while start.addingMonths(whole + 1) <= end { whole += 1 }
        let leftover = end.ordinal - start.addingMonths(whole).ordinal
        return Decimal(whole) + Decimal(leftover) / daysPerMonth
    }

    static func day(afterMonths months: Decimal, from start: Day) -> Day {
        var wholeMonths = months
        var rounded = Decimal()
        NSDecimalRound(&rounded, &wholeMonths, 0, .down)
        let whole = NSDecimalNumber(decimal: rounded).intValue
        var days = (months - rounded) * daysPerMonth
        var roundedDays = Decimal()
        NSDecimalRound(&roundedDays, &days, 0, .plain)
        return Day(ordinal: start.addingMonths(whole).ordinal + NSDecimalNumber(decimal: roundedDays).intValue)
    }
}

extension GoalProgress {
    /// How the standing reads: the same on the goal's card and for Claude.
    public func reading(dated: Bool) -> GoalReadingStanding {
        switch (standing, dated) {
        case (.reached, _): .reached
        case (.onTrack, true): .onTrack
        case (.behind, true): .behind
        // An undated "behind" can mean the target is further than a projection reaches; a positive pace still grows.
        case (.onTrack, false), (.behind, false): (pacePerMonth ?? 0) > 0 ? .growing : .notGrowing
        }
    }
}
