import Foundation

/// Fixed bills are expected each month; everything else shares one flexible budget.
public enum BudgetRole: String, Codable, Sendable, CaseIterable {
    case fixed
    case flexible
    /// Comes when it comes (an annual card fee, charity): out of the flexible
    /// budget and its pace, shown apart.
    case irregular

    /// A first guess from the category's name; it can be changed.
    public static func guess(_ category: String) -> BudgetRole {
        let lowered = category.lowercased()
        let fixed = [
            "rent", "mortgage", "utilit", "electric", "water", "gas bill", "phone", "internet", "insurance",
            "subscription", "loan", "childcare", "daycare", "tuition", "hoa", "membership"
        ]
        return fixed.contains { lowered.contains($0) } ? .fixed : .flexible
    }
}

/// How spending is budgeted: one flexible amount, an expected amount for
/// each fixed bill, and the income they plan on.
public struct BudgetPlan: Hashable, Codable, Sendable {
    public var flexibleBudget: Decimal
    /// Overrides of the name-based guess.
    public var roles: [String: BudgetRole]
    /// What each fixed category usually costs a month.
    public var expected: [String: Decimal]
    /// What each income category should bring in a month.
    public var plannedIncome: [String: Decimal]
    /// What they mean to move into each account a month (a brokerage, a
    /// Roth IRA, a savings account), by account.
    public var savings: [UUID: Decimal]

    public init(
        flexibleBudget: Decimal, roles: [String: BudgetRole] = [:], expected: [String: Decimal] = [:],
        plannedIncome: [String: Decimal] = [:], savings: [UUID: Decimal] = [:]
    ) {
        self.flexibleBudget = flexibleBudget
        self.roles = roles
        self.expected = expected
        self.plannedIncome = plannedIncome
        self.savings = savings
    }

    /// Plans saved before a field existed read back with it empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flexibleBudget = try container.decodeIfPresent(Decimal.self, forKey: .flexibleBudget) ?? 0
        roles = try container.decodeIfPresent([String: BudgetRole].self, forKey: .roles) ?? [:]
        expected = try container.decodeIfPresent([String: Decimal].self, forKey: .expected) ?? [:]
        plannedIncome = try container.decodeIfPresent([String: Decimal].self, forKey: .plannedIncome) ?? [:]
        savings = try container.decodeIfPresent([UUID: Decimal].self, forKey: .savings) ?? [:]
    }

    public func role(of category: String) -> BudgetRole {
        roles[category] ?? BudgetRole.guess(category)
    }

    /// Planned income, counted as the budget sheet counts it: income categories only.
    public func plannedIncome(kinds: [String: CategoryKind]) -> Decimal {
        plannedIncome.filter { (kinds[$0.key] ?? CategoryKind.guess($0.key)) == .income }.values.reduce(0, +)
    }

    /// Nothing planned yet: no flexible budget, bills, income or savings.
    public var isEmpty: Bool {
        flexibleBudget == 0 && expected.isEmpty && plannedIncome.isEmpty && savings.isEmpty
    }

    /// The plan after `old` is renamed to `new`. When `new` already exists
    /// (`into`, or it's in the plan) it's a merge: the two amounts add up, and
    /// `new` keeps its own role. A bill merged into a category that isn't
    /// fixed loses its expected amount, which would otherwise sit in the plan
    /// unseen; its charges count as flexible spending. A plain rename keeps
    /// the old role, even one that only came from the old name's guess.
    public func renaming(_ old: String, to new: String, into existing: Bool = false) -> BudgetPlan {
        guard old != new else { return self }
        func moved(_ values: [String: Decimal]) -> [String: Decimal] {
            var values = values
            if let amount = values.removeValue(forKey: old) { values[new, default: 0] += amount }
            return values
        }
        let merging = existing || roles[new] != nil || expected[new] != nil || plannedIncome[new] != nil
        let oldRole = role(of: old)
        var plan = self
        plan.roles.removeValue(forKey: old)
        if !merging, oldRole != BudgetRole.guess(new) { plan.roles[new] = oldRole }
        if merging, plan.role(of: new) != .fixed {
            plan.expected.removeValue(forKey: old)
        } else {
            plan.expected = moved(expected)
        }
        plan.plannedIncome = moved(plannedIncome)
        return plan
    }

    /// The expected amount a merge of `old` into `new` would drop, because
    /// `new` isn't a bill. For saying so before the merge.
    public func billDropped(merging old: String, into new: String) -> Decimal? {
        guard let amount = expected[old], role(of: new) != .fixed else { return nil }
        return amount
    }

    /// A planned amount as typed: "$2,000", "1800.50" or "2k". Anything else,
    /// a negative amount or a stray "." included, is nil rather than a guess.
    public static func amount(from text: String) -> Decimal? {
        var cleaned = text.filter { !"$, ".contains($0) }.lowercased()
        var multiplier: Decimal = 1
        if cleaned.hasSuffix("k") {
            cleaned.removeLast()
            multiplier = 1000
        }
        let digits = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard cleaned.contains(where: \.isNumber), digits.count <= 2,
            digits.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
            let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        return value * multiplier
    }
}

public struct BillStatus: Hashable, Sendable {
    public var category: String
    public var expected: Decimal
    public var paid: Decimal
    /// The day of the month it was paid last month, if it was.
    public var usualDay: Int?

    public var isPaid: Bool { paid > 0 }

    public init(category: String, expected: Decimal, paid: Decimal, usualDay: Int?) {
        self.category = category
        self.expected = expected
        self.paid = paid
        self.usualDay = usualDay
    }
}

public struct FlexLine: Hashable, Sendable {
    public var category: String
    public var amount: Decimal
    /// More than one for "Everything else".
    public var categoryCount: Int
}

public enum FlexStanding: Sendable {
    case withinPace, fasterThanPace, overBudget
}

public struct FlexBudgetMonth: Hashable, Sendable {
    public var bills: [BillStatus]
    public var fixedPaid: Decimal
    public var fixedExpected: Decimal
    public var flexibleBudget: Decimal
    public var flexibleSpent: Decimal
    public var flexibleLines: [FlexLine]
    /// Days left in the month, today included; 0 for a past month.
    public var daysLeft: Int
    /// Where flexible spending would be by now at an even pace.
    public var expectedSoFar: Decimal

    public var flexibleRemaining: Decimal { flexibleBudget - flexibleSpent }
    public var isOverPace: Bool { flexibleSpent > expectedSoFar }
    /// Where flexible spending stands: over the budget outranks ahead of pace.
    public var standing: FlexStanding {
        flexibleRemaining < 0 ? .overBudget : isOverPace ? .fasterThanPace : .withinPace
    }
    /// What can be spent per remaining day and still end on budget.
    public var dailyAllowance: Decimal {
        flexibleRemaining > 0 && daysLeft > 0 ? flexibleRemaining / Decimal(daysLeft) : 0
    }
    /// The daily allowance as said in words, rounded down to the dollar,
    /// so spending it every day never ends the month over.
    public var wholeDollarsADay: Decimal {
        var allowance = dailyAllowance, rounded = Decimal()
        NSDecimalRound(&rounded, &allowance, 0, .down)
        return rounded
    }
}

/// Monarch-style flex budgeting for one month.
public enum FlexBudget {
    public static let everythingElse = "Everything else"
    /// Flexible categories under this share of flexible spending fold together.
    static let foldShare = Decimal(string: "0.1")!
    static let maxLines = 4

    public static func month(
        _ month: Month,
        today: Day,
        transactions: [Transaction],
        kinds: [String: CategoryKind],
        plan: BudgetPlan
    ) -> FlexBudgetMonth {
        let spent = spending(in: month, transactions: transactions, kinds: kinds)
        var lastMonthDay: [String: Int] = [:]
        let previous = month.adding(-1)
        for transaction in Splits.parts(transactions) where Month(transaction.day) == previous && transaction.budgetAmount < 0 {
            guard let category = Spending.spendingCategory(of: transaction, kinds: kinds) else { continue }
            lastMonthDay[category] = max(lastMonthDay[category] ?? 0, transaction.day.dayOfMonth)
        }

        let bills = fixedCategories(plan: plan, spent: spent, kinds: kinds).map { category in
            BillStatus(
                category: category, expected: plan.expected[category] ?? 0,
                paid: max(spent[category] ?? 0, 0), usualDay: lastMonthDay[category])
        }
        .sorted { ($0.isPaid ? 1 : 0, $0.category) < ($1.isPaid ? 1 : 0, $1.category) }

        let flexible = spent.filter { plan.role(of: $0.key) == .flexible }
        let flexibleSpent = flexible.values.reduce(0, +)
        let ranked = flexible.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let threshold = flexibleSpent * foldShare
        var lines: [FlexLine] = []
        var folded: [FlexLine] = []
        for (category, amount) in ranked {
            let line = FlexLine(category: category, amount: amount, categoryCount: 1)
            if lines.count < maxLines - 1, amount >= threshold { lines.append(line) } else { folded.append(line) }
        }
        // One leftover keeps its own name; two or more become "Everything else".
        if folded.count == 1 {
            lines.append(folded[0])
        } else if folded.count > 1 {
            lines.append(FlexLine(category: everythingElse, amount: folded.reduce(0) { $0 + $1.amount }, categoryCount: folded.count))
        }

        let days = month.daysInMonth
        let current = Month(today)
        let elapsed = month < current ? days : (month == current ? today.dayOfMonth : 0)
        return FlexBudgetMonth(
            bills: bills,
            fixedPaid: bills.reduce(0) { $0 + $1.paid },
            fixedExpected: bills.reduce(0) { $0 + $1.expected },
            flexibleBudget: plan.flexibleBudget,
            flexibleSpent: flexibleSpent,
            flexibleLines: lines,
            daysLeft: month < current ? 0 : days - elapsed + (month == current ? 1 : 0),
            expectedSoFar: plan.flexibleBudget * Decimal(elapsed) / Decimal(days)
        )
    }

    /// Each spending category's money out in `month`, net of refunds, less
    /// what a goal paid for (`Transaction.budgetAmount`).
    static func spending(in month: Month, transactions: [Transaction], kinds: [String: CategoryKind]) -> [String: Decimal] {
        var spent: [String: Decimal] = [:]
        for transaction in Splits.parts(transactions) where Month(transaction.day) == month {
            guard let category = Spending.spendingCategory(of: transaction, kinds: kinds) else { continue }
            // All of it paid by a goal: nothing for the budget, not even a $0 line.
            if transaction.budgetAmount == 0, transaction.paidByGoal > 0 { continue }
            spent[category, default: 0] -= transaction.budgetAmount
        }
        return spent
    }

    /// Fixed bills: every fixed spending category with an expected amount or
    /// spending. A category that's since become income or a transfer drops
    /// out, whatever the plan still expects of it.
    static func fixedCategories(plan: BudgetPlan, spent: [String: Decimal], kinds: [String: CategoryKind]) -> Set<String> {
        let planned = plan.expected.keys.filter { category in
            plan.role(of: category) == .fixed && (kinds[category] ?? CategoryKind.guess(category)) == .spending
        }
        return Set(planned).union(spent.keys.filter { plan.role(of: $0) == .fixed })
    }
}

extension FlexBudget {
    /// What a category usually costs: the average of its last three months,
    /// to the dollar. For prefilling a fixed bill's expected amount.
    public static func usualMonth(_ category: String, in grid: [CategoryMonths]) -> Decimal? {
        guard let row = grid.first(where: { $0.category == category }) else { return nil }
        return wholeDollars(row.months.suffix(3).reduce(0) { $0 + $1.total } / 3)
    }

    /// A starting flexible budget: the last three months of flexible spending,
    /// averaged, leaving out fixed categories and any marked not spending.
    public static func suggestedFlexibleBudget(from grid: [CategoryMonths], plan: BudgetPlan, excluding: Set<String>) -> Decimal? {
        let total = grid.filter { plan.role(of: $0.category) == .flexible && !excluding.contains($0.category) }
            .reduce(Decimal(0)) { sum, row in sum + row.months.suffix(3).reduce(0) { $0 + $1.total } }
        return total > 0 ? wholeDollars(total / 3) : nil
    }

    /// A starting budget from the last six months of `grid`. A category is a
    /// fixed bill when it's paid a steady amount (within 10% of its median) in
    /// at least five of the six months, or its name says bill and it's paid in
    /// at least three. A bill expects its median month. The flexible budget is
    /// the last three months of everything else, averaged.
    public static func template(from grid: [CategoryMonths]) -> BudgetPlan {
        var plan = BudgetPlan(flexibleBudget: 0)
        var flexibleRecent: Decimal = 0
        for row in grid {
            let recent = row.months.suffix(6).map(\.total)
            let paid = recent.filter { $0 > 0 }
            let median = medianOf(paid)
            let steady = paid.count >= 5 && paid.allSatisfy { abs($0 - median) <= median / 10 }
            let namedBill = BudgetRole.guess(row.category) == .fixed && paid.count >= 3
            if steady || namedBill {
                plan.expected[row.category] = wholeDollars(median)
                if BudgetRole.guess(row.category) != .fixed { plan.roles[row.category] = .fixed }
            } else {
                if BudgetRole.guess(row.category) == .fixed { plan.roles[row.category] = .flexible }
                flexibleRecent += recent.suffix(3).reduce(0, +)
            }
        }
        plan.flexibleBudget = wholeDollars(flexibleRecent / 3)
        return plan
    }

    private static func medianOf(_ values: [Decimal]) -> Decimal {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func wholeDollars(_ value: Decimal) -> Decimal {
        var value = value, result = Decimal()
        NSDecimalRound(&result, &value, 0, .plain)
        return result
    }
}

// MARK: The month's budget sheet

/// One category on the budget sheet. Remaining is planned minus actual: for
/// income, what's still to come; for a bill, what's still to pay.
public struct BudgetLine: Hashable, Sendable {
    public var category: String
    /// Nil when nothing is planned for it: it's unbudgeted.
    public var planned: Decimal?
    public var actual: Decimal

    public init(category: String, planned: Decimal?, actual: Decimal) {
        self.category = category
        self.planned = planned
        self.actual = actual
    }

    public var remaining: Decimal { (planned ?? 0) - actual }
}

/// Income or fixed bills: the planned lines, and those with an actual but no
/// plan ("unbudgeted"). The actual total counts both. What's still to come
/// is worked out line by line, so an overpaid bill never covers an unpaid
/// one and an unbudgeted charge never reads as going over the plan.
public struct BudgetGroup: Hashable, Sendable {
    public var lines: [BudgetLine]
    public var unbudgeted: [BudgetLine]

    public init(lines: [BudgetLine], unbudgeted: [BudgetLine]) {
        self.lines = lines
        self.unbudgeted = unbudgeted
    }

    public var planned: Decimal { lines.reduce(0) { $0 + ($1.planned ?? 0) } }
    public var actual: Decimal { (lines + unbudgeted).reduce(0) { $0 + $1.actual } }
    /// Each planned line's shortfall, added up: bills still to pay, or
    /// income still to come.
    public var outstanding: Decimal { lines.reduce(0) { $0 + max($1.remaining, 0) } }
    /// How far the planned lines went past their plans, added up.
    public var overPlan: Decimal { lines.reduce(0) { $0 + max(-$1.remaining, 0) } }
    /// What came in or went out with nothing planned for it.
    public var unbudgetedActual: Decimal { unbudgeted.reduce(0) { $0 + $1.actual } }
}

/// Flexible categories share one budget, so each line has an actual only.
public struct FlexibleGroup: Hashable, Sendable {
    public var budget: Decimal
    /// Biggest first; "Uncategorized" is a line of its own.
    public var lines: [BudgetLine]

    public init(budget: Decimal, lines: [BudgetLine]) {
        self.budget = budget
        self.lines = lines
    }

    public var actual: Decimal { lines.reduce(0) { $0 + $1.actual } }
    public var remaining: Decimal { budget - actual }
}

/// How much an emergency fund should hold: the fixed bills, for a stretch.
public struct EmergencyFundBasis: Hashable, Sendable {
    public var monthly: Decimal
    public var threeMonths: Decimal { monthly * 3 }
    public var sixMonths: Decimal { monthly * 6 }
}

/// The month laid out like Monarch's budget page. Transfers are in none of
/// it, and income never offsets an expense.
public struct BudgetSheet: Hashable, Sendable {
    public var income: BudgetGroup
    /// Planned is each bill's expected amount; actual is what was paid.
    public var fixed: BudgetGroup
    public var flexible: FlexibleGroup
    /// Irregular spending (an annual fee, charity): planned where they expect
    /// it this month, never part of the flexible budget.
    public var irregular: BudgetGroup
    /// Money moved into their own savings and investing accounts, by account
    /// (a line's `category` is the account's id). A job for income, but not
    /// an expense.
    public var savings: BudgetGroup
    /// Money in with no category yet, such as a paycheck from a new payroll
    /// merchant or one side of a transfer. Not income until it's filed, so
    /// it's in none of the totals.
    public var unfiledIn: Decimal
    /// Spending goals paid for this month, by goal: out of the expenses, as
    /// the money moved out of the goal's account to cover it is out of savings.
    public var paidFromGoals: [UUID: Decimal] = [:]

    public var plannedExpenses: Decimal { fixed.planned + flexible.budget + irregular.planned }
    public var actualExpenses: Decimal { fixed.actual + flexible.actual + irregular.actual }
    /// What's left once expenses and savings have their share.
    public var plannedNet: Decimal { income.planned - plannedExpenses - savings.planned }
    public var actualNet: Decimal { income.actual - actualExpenses - savings.actual }
    public var emergencyFund: EmergencyFundBasis { EmergencyFundBasis(monthly: fixed.planned) }
    /// Zero-based budgeting: planned income not yet given to a bill, the
    /// flexible budget or savings; below zero, planned past income. Nil with no
    /// income planned.
    public var leftToBudget: Decimal? { income.planned > 0 ? plannedNet : nil }
    /// Income and fixed categories with an actual but nothing planned.
    public var unbudgetedCount: Int { income.unbudgeted.count + fixed.unbudgeted.count }
}

extension FlexBudget {
    /// The plan with its flexible budget as what's left: planned income less
    /// fixed and irregular bills and savings, counted as the sheet counts
    /// them, never below zero. Without planned income, the flexible budget they
    /// set stands. Apply it after income is final (`Pay.planned`).
    public static func balanced(_ plan: BudgetPlan, kinds: [String: CategoryKind]) -> BudgetPlan {
        func kind(_ category: String) -> CategoryKind { kinds[category] ?? CategoryKind.guess(category) }
        let income = plan.plannedIncome(kinds: kinds)
        guard income > 0 else { return plan }
        let bills = plan.expected.filter { plan.role(of: $0.key) != .flexible && kind($0.key) == .spending }.values.reduce(0, +)
        var balanced = plan
        balanced.flexibleBudget = max(income - bills - plan.savings.values.reduce(0, +), 0)
        return balanced
    }

    /// The budget sheet for `month`: planned, actual and remaining for income,
    /// each fixed bill and flexible spending.
    /// `settling` is the part of each move out of a goal's account that
    /// paid for spending the goal covered (`GoalFunding.Ledger.settling`).
    public static func sheet(
        _ month: Month, transactions: [Transaction], kinds: [String: CategoryKind],
        plan: BudgetPlan, settling: [UUID: Decimal] = [:]
    ) -> BudgetSheet {
        func kind(_ category: String) -> CategoryKind { kinds[category] ?? CategoryKind.guess(category) }
        var received: [String: Decimal] = [:]
        var unfiledIn: Decimal = 0
        for transaction in transactions where Month(transaction.day) == month {
            guard let category = transaction.category else {
                if transaction.amount > 0 { unfiledIn += transaction.amount }
                continue
            }
            guard kind(category) == .income else { continue }
            received[category, default: 0] += transaction.amount
        }
        let spent = spending(in: month, transactions: transactions, kinds: kinds)
        let fixed = fixedCategories(plan: plan, spent: spent, kinds: kinds)
        // What a bill was paid, as on the pace card: a refund can't make it negative.
        let paid = Dictionary(
            uniqueKeysWithValues: fixed.compactMap { category in
                spent[category].map { (category, max($0, 0)) }
            })
        let flexible = spent.filter { plan.role(of: $0.key) == .flexible }
            .map { BudgetLine(category: $0.key, planned: nil, actual: $0.value) }
            .sorted { ($0.actual, $1.category) > ($1.actual, $0.category) }
        return BudgetSheet(
            income: group(planned: plan.plannedIncome.filter { kind($0.key) == .income }, actual: received),
            // A fixed bill with nothing planned or paid stays as a $0 line, so
            // one they stopped planning can be planned again.
            fixed: group(
                planned: plan.expected.filter { fixed.contains($0.key) }, actual: paid,
                listed: Set(plan.roles.keys).union(kinds.keys)
                    .filter { plan.role(of: $0) == .fixed && kind($0) == .spending }),
            flexible: FlexibleGroup(budget: plan.flexibleBudget, lines: flexible),
            irregular: group(
                planned: plan.expected.filter { plan.role(of: $0.key) == .irregular && kind($0.key) == .spending },
                actual: spent.filter { plan.role(of: $0.key) == .irregular }),
            savings: group(
                planned: Dictionary(uniqueKeysWithValues: plan.savings.map { ($0.key.uuidString, $0.value) }),
                actual: saved(in: month, transactions: transactions, kinds: kinds, plan: plan, settling: settling)),
            unfiledIn: unfiledIn,
            paidFromGoals: transactions.reduce(into: [:]) { paid, transaction in
                guard Month(transaction.day) == month, let goal = transaction.paidFromGoal,
                    Spending.spendingCategory(of: transaction, kinds: kinds) != nil
                else { return }
                paid[goal, default: 0] += transaction.paidByGoal
            }
        )
    }

    /// Money moved into each savings account in `month`, less money taken
    /// back out, by account id. A savings account is one they added to the
    /// budget's savings: an investing account they don't save into (a Roth
    /// they fund some other way) isn't one. Only moves filed as transfers count (an unfiled one is
    /// still spending, so counting it here too would count it twice), and
    /// only between a savings account and one that isn't: paying a card isn't saving, and brokerage to Roth isn't new
    /// saving. Pay put straight into a 401k never passes through their
    /// accounts, so it isn't here. Money taken out to cover spending a goal
    /// paid for isn't taken back: that spending is out of the budget too.
    static func saved(
        in month: Month, transactions: [Transaction], kinds: [String: CategoryKind],
        plan: BudgetPlan, settling: [UUID: Decimal] = [:]
    ) -> [String: Decimal] {
        let saving = Set(plan.savings.keys)
        let byID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        var saved: [String: Decimal] = [:]
        for pair in TransferMatch.pairs(in: transactions, kinds: kinds) {
            guard let out = byID[pair.outgoing], let into = byID[pair.incoming], Month(out.day) == month,
                out.category != nil, into.category != nil
            else { continue }
            switch (saving.contains(out.accountID), saving.contains(into.accountID)) {
            case (false, true): saved[into.accountID.uuidString, default: 0] += into.amount
            case (true, false): saved[out.accountID.uuidString, default: 0] += out.amount + (settling[out.id] ?? 0)
            default: continue
            }
        }
        return saved
    }

    /// Planned lines biggest plan first; unbudgeted ones biggest actual first.
    /// `listed` categories show unbudgeted even with nothing spent.
    private static func group(planned: [String: Decimal], actual: [String: Decimal], listed: Set<String> = []) -> BudgetGroup {
        let lines = planned.map { BudgetLine(category: $0.key, planned: $0.value, actual: actual[$0.key] ?? 0) }
            .sorted { ($0.planned ?? 0, $1.category) > ($1.planned ?? 0, $0.category) }
        let shown = actual.merging(listed.map { ($0, 0) }) { spent, _ in spent }
        let unbudgeted = shown.filter { planned[$0.key] == nil && ($0.value != 0 || listed.contains($0.key)) }
            .map { BudgetLine(category: $0.key, planned: nil, actual: $0.value) }
            .sorted { ($0.actual, $1.category) > ($1.actual, $0.category) }
        return BudgetGroup(lines: lines, unbudgeted: unbudgeted)
    }
}
