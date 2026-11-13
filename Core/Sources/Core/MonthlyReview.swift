import Foundation

/// A category's month against its usual, scaled to the days so far when the
/// month isn't over.
public struct CategoryVersusUsual: Hashable, Sendable {
    public var category: String
    public var thisMonth: Decimal
    public var usual: Decimal

    public init(category: String, thisMonth: Decimal, usual: Decimal) {
        self.category = category
        self.thisMonth = thisMonth
        self.usual = usual
    }

    /// Above usual is positive.
    public var difference: Decimal { thisMonth - usual }
}

/// Where a goal's measured value started and ended the month.
public struct GoalMovement: Hashable, Sendable {
    public var goalID: UUID
    public var start: Decimal?
    public var end: Decimal?
    /// Opening balances of accounts it measures that were linked this month.
    public var openingBalances: Decimal

    public init(goalID: UUID, start: Decimal?, end: Decimal?, openingBalances: Decimal = 0) {
        self.goalID = goalID
        self.start = start
        self.end = end
        self.openingBalances = openingBalances
    }

    /// Leaves out opening balances.
    public var change: Decimal? {
        guard let start, let end else { return nil }
        return end - start - openingBalances
    }
}

/// A month's report card, from the same figures the screens show. The
/// verdict is left to whoever reads it.
public struct MonthlyReview: Hashable, Sendable {
    public var month: Month
    /// The current month, counted through today.
    public var isMonthToDate: Bool
    /// The month's last day, or today for the current month.
    public var through: Day
    /// Net worth at the end of the month before; nil before any balance.
    public var netWorthStart: Decimal?
    public var netWorthEnd: Decimal?
    /// What accounts linked this month already held when they were linked.
    public var openingBalances: Decimal
    /// Every investing account's month (`Contributions`).
    public var investing: [ContributionMonth]
    public var flexible: FlexBudgetMonth
    /// Under income categories, as on the budget sheet.
    public var income: Decimal
    public var plannedIncome: Decimal
    /// Every spending category, furthest from usual first.
    public var categories: [CategoryVersusUsual]
    public var goals: [GoalMovement]

    /// Leaves out opening balances: linking an account isn't growth.
    public var netWorthChange: Decimal? {
        guard let netWorthStart, let netWorthEnd else { return nil }
        return netWorthEnd - netWorthStart - openingBalances
    }

    /// Money they put into investing, net, over the accounts where it can be told.
    public var contributions: Decimal {
        investing.compactMap(\.netContributions).reduce(0, +)
    }

    /// What the market did, over the accounts where it can be told.
    public var marketChange: Decimal {
        investing.compactMap(\.marketChange).reduce(0, +)
    }

    /// The rest of the net worth change: saving, spending, debt, and the
    /// accounts whose split can't be told. Moving money into investing
    /// doesn't change net worth, so contributions aren't part of the sum.
    public var otherChange: Decimal? { netWorthChange.map { $0 - marketChange } }

    /// Investing accounts whose market change can't be told this month
    /// (contributions unknown, a balance gap, or balances starting this month).
    public var untold: [UUID] {
        investing.filter { $0.marketChange == nil }.map(\.accountID)
    }

    public static func make(
        month: Month, today: Day, accounts: [Account], snapshots: [BalanceSnapshot],
        breakdown: [DailyBreakdown], transactions: [Transaction],
        kinds: [String: CategoryKind], plan: BudgetPlan, goals: [Goal],
        payroll: Payroll = Payroll()
    ) -> MonthlyReview {
        let isMonthToDate = month == Month(today)
        let through = isMonthToDate ? today : month.lastDay
        let before = month.firstDay.adding(-1)
        let netWorth = breakdown.map(\.netWorth)
        /// Opening balances counted between the month before's end and `through`.
        func openings(_ series: [DailyTotal]) -> Decimal {
            let opened = series.map { DailyTotal(day: $0.day, total: $0.opened) }
            return (Contributions.value(on: through, in: opened) ?? 0) - (Contributions.value(on: before, in: opened) ?? 0)
        }

        let investing = Contributions.report(
            accounts: accounts, snapshots: snapshots, transactions: transactions,
            kinds: kinds, today: today, months: month...month, payroll: payroll
        )
        .compactMap(\.months.first)

        // A month to date is compared with the share of usual its days make.
        let elapsed = Decimal(through.dayOfMonth), days = Decimal(month.daysInMonth)
        let categories = Spending.month(month, transactions: transactions, kinds: kinds)
            .map {
                CategoryVersusUsual(
                    category: $0.category, thisMonth: $0.thisMonth,
                    usual: isMonthToDate ? $0.sixMonthAverage * elapsed / days : $0.sixMonthAverage)
            }
            .sorted { (abs($0.difference), $0.thisMonth, $1.category) > (abs($1.difference), $1.thisMonth, $0.category) }

        let moves = NetWorthSeries.moves(in: transactions, kinds: kinds)
        let movements = goals.map { goal in
            let measured = GoalProgress.measured(
                goal, accounts: accounts, snapshots: snapshots, today: today,
                breakdown: breakdown, moves: moves)
            return GoalMovement(
                goalID: goal.id, start: Contributions.value(on: before, in: measured),
                end: Contributions.value(on: through, in: measured), openingBalances: openings(measured))
        }

        // Moves out of a fund that paid for its spending aren't saving taken back, as on the budget.
        let settling = GoalFunding.ledger(goals: goals, transactions: transactions, kinds: kinds).settling
        let sheet = FlexBudget.sheet(month, transactions: transactions, kinds: kinds, plan: plan, settling: settling)
        return MonthlyReview(
            month: month, isMonthToDate: isMonthToDate, through: through,
            netWorthStart: Contributions.value(on: before, in: netWorth),
            netWorthEnd: Contributions.value(on: through, in: netWorth),
            openingBalances: openings(netWorth),
            investing: investing,
            flexible: FlexBudget.month(month, today: today, transactions: transactions, kinds: kinds, plan: plan),
            income: sheet.income.actual, plannedIncome: sheet.income.planned,
            categories: categories, goals: movements)
    }
}
