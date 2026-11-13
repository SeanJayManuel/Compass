import Foundation

public struct HabitWeek: Hashable, Sendable {
    public var habitID: UUID
    public var title: String
    public var done: Int
    public var perWeek: Int
    public var result: WeekResult

    public init(habitID: UUID, title: String, done: Int, perWeek: Int, result: WeekResult) {
        self.habitID = habitID
        self.title = title
        self.done = done
        self.perWeek = perWeek
        self.result = result
    }
}

public struct Reflection: Hashable, Sendable {
    public var goalTitle: String
    public var entry: LifeEntry

    public init(goalTitle: String, entry: LifeEntry) {
        self.goalTitle = goalTitle
        self.entry = entry
    }
}

public struct WeekReview: Hashable, Sendable {
    public var week: Week
    public var habits: [HabitWeek]
    public var reflections: [Reflection]
    public var goalsDone: [LifeGoal]
    public var flexibleSpent: Decimal
    /// The monthly flexible budget; 0 when none is set.
    public var monthlyBudget: Decimal
    /// What the week can spend: an even week's share of the monthly budget,
    /// or less when what's left of the month, spread over its remaining
    /// days, comes to less.
    public var weeklyBudget: Decimal
    /// The month the week is judged in (today's, or the one the week ends
    /// in), and its flexible budget left as of today or the week's end.
    public var month: Month
    public var monthLeft: Decimal

    public var isOverBudget: Bool { monthlyBudget > 0 && flexibleSpent > weeklyBudget }
}

/// The weekly check-in: habits, steps logged, goals finished and spending,
/// for one Sunday-to-Saturday week.
public enum WeeklyReview {
    /// `transactions` need to cover `spendingDays(for: week)`: the month to
    /// date counts against what the week can spend.
    public static func make(
        week: Week, today: Day, habits: [Habit], goals: [LifeGoal], transactions: [Transaction],
        kinds: [String: CategoryKind], plan: BudgetPlan
    ) -> WeekReview {
        let habitWeeks = habits.filter { !$0.archived && Week($0.startedOn) <= week }.map {
            HabitWeek(
                habitID: $0.id, title: $0.title, done: Habits.done($0, in: week), perWeek: $0.perWeek,
                result: Habits.result($0, week: week, today: today))
        }
        let reflections = goals.flatMap { goal in
            goal.entries.filter { week.contains($0.day) }.map { Reflection(goalTitle: goal.title, entry: $0) }
        }
        .sorted { ($0.entry.day, $0.goalTitle) < ($1.entry.day, $1.goalTitle) }
        let done = goals.filter {
            if case .done(let day) = $0.status { return week.contains(day) }
            return false
        }
        func spent(_ days: ClosedRange<Day>) -> Decimal {
            flexibleSpent(in: days, transactions: transactions, kinds: kinds, plan: plan)
        }

        // Each month the week touches gives its days an even share of what it
        // had left when the week (or the month) began.
        var fromMonths: Decimal = 0
        var from = week.start
        while from <= week.end {
            let month = Month(from)
            let monthStart = Day(year: month.year, month: month.month, day: 1)
            let monthEnd = Day(ordinal: monthStart.ordinal + month.daysInMonth - 1)
            let through = min(week.end, monthEnd)
            let left = plan.flexibleBudget - (from > monthStart ? spent(monthStart...Day(ordinal: from.ordinal - 1)) : 0)
            fromMonths += max(left, 0) * Decimal(through.ordinal - from.ordinal + 1) / Decimal(monthEnd.ordinal - from.ordinal + 1)
            from = Day(ordinal: through.ordinal + 1)
        }

        let asOf = min(week.end, today)
        let month = Month(asOf)
        return WeekReview(
            week: week, habits: habitWeeks, reflections: reflections, goalsDone: done,
            flexibleSpent: spent(week.start...week.end), monthlyBudget: plan.flexibleBudget,
            weeklyBudget: min(plan.flexibleBudget * 12 / 52, fromMonths), month: month,
            monthLeft: plan.flexibleBudget - spent(Day(year: month.year, month: month.month, day: 1)...asOf))
    }

    /// The days `make` reads transactions from for a week: from the first of
    /// the month it starts in, through its Sunday.
    public static func spendingDays(for week: Week) -> ClosedRange<Day> {
        let month = Month(week.start)
        return Day(year: month.year, month: month.month, day: 1)...week.end
    }

    /// Money out in flexible categories over some days, net of refunds, less
    /// what a goal paid for.
    static func flexibleSpent(
        in days: ClosedRange<Day>, transactions: [Transaction], kinds: [String: CategoryKind],
        plan: BudgetPlan
    ) -> Decimal {
        var spent: Decimal = 0
        for transaction in Splits.parts(transactions) where days.contains(transaction.day) {
            guard let category = Spending.spendingCategory(of: transaction, kinds: kinds),
                plan.role(of: category) == .flexible
            else { continue }
            spent -= transaction.budgetAmount
        }
        return spent
    }
}
