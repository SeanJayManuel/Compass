import Foundation

/// One planned amount: the flexible budget, a bill's expected amount or an
/// income category's planned amount.
public enum BudgetAmount: Hashable, Sendable {
    case flexible
    case bill(String)
    case income(String)
    /// Money moved into an account (its id) a month.
    case saving(UUID)
}

extension BudgetPlan {
    /// Nil when nothing is planned for it. The flexible budget is always set.
    public subscript(amount: BudgetAmount) -> Decimal? {
        get {
            switch amount {
            case .flexible: flexibleBudget
            case .bill(let category): expected[category]
            case .income(let category): plannedIncome[category]
            case .saving(let account): savings[account]
            }
        }
        set {
            switch amount {
            case .flexible: flexibleBudget = newValue ?? 0
            case .bill(let category): expected[category] = newValue
            case .income(let category): plannedIncome[category] = newValue
            case .saving(let account): savings[account] = newValue
            }
        }
    }
}

/// The budget month by month, as stored. Each month plans what the most
/// recent change on or before it planned; months before any change use the
/// first plan. Fixed or flexible is the same in every month.
public struct BudgetSchedule: Hashable, Sendable {
    /// What each month plans until a change: the roles, and the amounts
    /// before any month changed them.
    public private(set) var base: BudgetPlan
    /// The months a change starts in, each with its full set of amounts.
    private var changes: [Month: BudgetPlan]

    public enum Scope: Sendable {
        /// This month and every one after, replacing their own changes to it.
        case onward
        /// This month only; the next month keeps what it had.
        case onlyThisMonth
    }

    public init(_ base: BudgetPlan) {
        self.base = base
        changes = [:]
    }

    /// The plan `month` follows, ready for `FlexBudget`.
    public func plan(for month: Month) -> BudgetPlan {
        var plan = changes.filter { $0.key <= month }.max { $0.key < $1.key }?.value ?? base
        plan.roles = base.roles
        return plan
    }

    /// The schedule with `edit` made to `month`'s plan: for that month only,
    /// or from it on. Role changes apply to every month.
    public func changing(_ month: Month, _ scope: Scope, _ edit: (inout BudgetPlan) -> Void) -> BudgetSchedule {
        var after = plan(for: month)
        edit(&after)
        var schedule = self
        schedule.base.roles = after.roles
        switch scope {
        case .onlyThisMonth:
            let next = month.adding(1)
            if changes[next] == nil { schedule.changes[next] = plan(for: next) }
        case .onward:
            for later in changes.keys where later > month { edit(&schedule.changes[later]!) }
        }
        schedule.changes[month] = after
        return schedule.tidied()
    }

    public func setting(_ amount: BudgetAmount, to value: Decimal?, in month: Month, _ scope: Scope) -> BudgetSchedule {
        changing(month, scope) { $0[amount] = value }
    }

    /// `plan` from `month` on, as each of its amounts typed in turn: only
    /// the amounts it changes reach later months' own changes.
    public func applying(_ plan: BudgetPlan, from month: Month) -> BudgetSchedule {
        let current = self.plan(for: month)
        let amounts =
            [BudgetAmount.flexible]
            + Set(current.expected.keys).union(plan.expected.keys).map(BudgetAmount.bill)
            + Set(current.plannedIncome.keys).union(plan.plannedIncome.keys).map(BudgetAmount.income)
            + Set(current.savings.keys).union(plan.savings.keys).map(BudgetAmount.saving)
        let changed = amounts.filter { current[$0] != plan[$0] }
        return changing(month, .onward) { edited in
            edited.roles = plan.roles
            for amount in changed { edited[amount] = plan[amount] }
        }
    }

    /// Whether `month` plans a different `amount` from the month before it.
    public func differsFromMonthBefore(_ amount: BudgetAmount, in month: Month) -> Bool {
        plan(for: month)[amount] != plan(for: month.adding(-1))[amount]
    }

    /// Keeps `month`'s own change to `amount` to that month: the months after
    /// it go back to what the month before planned, up to a later change.
    public func keepingOnly(_ amount: BudgetAmount, in month: Month) -> BudgetSchedule {
        let kept = plan(for: month)[amount], before = plan(for: month.adding(-1))[amount]
        let next = month.adding(1)
        var schedule = self
        if changes[next] == nil { schedule.changes[next] = plan(for: next) }
        for later in schedule.changes.keys.sorted() where later >= next {
            guard schedule.changes[later]?[amount] == kept else { break }
            schedule.changes[later]?[amount] = before
        }
        return schedule.tidied()
    }

    /// No month plans anything, so Spending asks for a first budget.
    public var isEmpty: Bool {
        base.isEmpty && changes.values.allSatisfy(\.isEmpty)
    }

    /// Every category any month plans or gives a role.
    public var categories: Set<String> {
        ([base] + changes.values).reduce(into: Set(base.roles.keys)) { names, plan in
            names.formUnion(plan.expected.keys)
            names.formUnion(plan.plannedIncome.keys)
        }
    }

    /// `BudgetPlan.renaming`, in every month.
    public func renaming(_ old: String, to new: String, into existing: Bool = false) -> BudgetSchedule {
        var schedule = self
        schedule.base = base.renaming(old, to: new, into: existing)
        for (month, plan) in changes {
            var plan = plan
            plan.roles = base.roles
            schedule.changes[month] = plan.renaming(old, to: new, into: existing)
        }
        return schedule.tidied()
    }

    /// The expected amount a merge would drop, from the latest month that
    /// plans one.
    public func billDropped(merging old: String, into new: String) -> Decimal? {
        let latestFirst = changes.sorted { $0.key > $1.key }.map(\.value) + [base]
        return latestFirst.lazy.compactMap { plan in
            var plan = plan
            plan.roles = base.roles
            return plan.billDropped(merging: old, into: new)
        }.first
    }

    /// Drops changes that plan the same as the month before them. A change
    /// keeps no roles of its own: they're the base's, for every month.
    private func tidied() -> BudgetSchedule {
        var schedule = self
        var previous = base
        previous.roles = [:]
        for month in changes.keys.sorted() {
            var plan = changes[month]!
            plan.roles = [:]
            schedule.changes[month] = plan == previous ? nil : plan
            previous = plan
        }
        return schedule
    }
}

/// Stored as the first plan's fields, as plans were before months, with the
/// changes alongside, so a plan saved before reads back as every month's.
extension BudgetSchedule: Codable {
    private enum CodingKeys: String, CodingKey { case months }

    private struct Change: Codable {
        var month: String
        var plan: BudgetPlan
    }

    public init(from decoder: Decoder) throws {
        base = try BudgetPlan(from: decoder)
        changes = [:]
        let container = try decoder.container(keyedBy: CodingKeys.self)
        for change in try container.decodeIfPresent([Change].self, forKey: .months) ?? [] {
            let parts = change.month.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            changes[Month(year: parts[0], month: parts[1])] = change.plan
        }
    }

    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        let months = changes.sorted { $0.key < $1.key }.map { month, plan in
            Change(month: String(format: "%04d-%02d", month.year, month.month), plan: plan)
        }
        if !months.isEmpty { try container.encode(months, forKey: .months) }
    }
}
