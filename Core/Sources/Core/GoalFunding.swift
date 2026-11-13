import Foundation

extension Transaction {
    /// What a goal pays of money out, never more than spending counts.
    public var paidByGoal: Decimal {
        guard paidFromGoal != nil, spendingAmount < 0 else { return 0 }
        return min(max(paidFromGoalAmount ?? -spendingAmount, 0), -spendingAmount)
    }

    /// The amount as the budget counts it: spending less what a goal paid.
    public var budgetAmount: Decimal { spendingAmount + paidByGoal }
}

/// Spending a goal pays for (seam 44): a flight paid from the Travel Fund.
/// Spending still counts it, in its category; the budget doesn't, and the
/// money they move out of the goal's account to cover it isn't counted as
/// saving taken back out.
public enum GoalFunding {
    /// A goal can pay for things when it's active and measures cash accounts
    /// only: the Travel Fund or the Emergency Fund, not net worth or investing.
    public static func canPay(_ goal: Goal, accounts: [Account]) -> Bool {
        guard goal.status == .active, case .accountTotal(let ids) = goal.kind, !ids.isEmpty else { return false }
        let chosen = accounts.filter { ids.contains($0.id) }
        return chosen.count == ids.count && chosen.allSatisfy { $0.accountClass == .cash }
    }

    /// Marks money out as paid from `goal`: `amount` of it (dollars, above
    /// zero), or all of it when nil. No goal takes the mark off. Only
    /// spending is paid for, never a split (whose parts it couldn't divide).
    public static func pay(
        _ transaction: Transaction, from goal: Goal?, amount: Decimal?,
        accounts: [Account], kinds: [String: CategoryKind]
    ) throws -> Transaction {
        var paid = transaction
        guard let goal else {
            paid.paidFromGoal = nil
            paid.paidFromGoalAmount = nil
            return paid
        }
        guard canPay(goal, accounts: accounts) else {
            throw ClaudeRefusal("\(goal.name) can't pay for things; only an active goal of cash accounts can.")
        }
        if let category = transaction.category, (kinds[category] ?? CategoryKind.guess(category)) != .spending {
            throw ClaudeRefusal("It's filed as \(category), not spending; a goal pays only for spending.")
        }
        guard !transaction.isSplit else { throw ClaudeRefusal("It's split; take the split off before a goal pays for it.") }
        let spent = -transaction.spendingAmount
        guard spent > 0 else { throw ClaudeRefusal("Only money out is paid from a goal.") }
        if let amount {
            guard amount > 0 else { throw ClaudeRefusal("The amount a goal pays is above zero.") }
            guard amount <= spent else { throw ClaudeRefusal("A goal can pay at most \(spent) of it.") }
        }
        paid.paidFromGoal = goal.id
        paid.paidFromGoalAmount = amount == spent ? nil : amount
        return paid
    }

    /// Money moved out of a goal's account up to this many days before a
    /// charge it paid for still pays it: the card posts after they move it.
    public static let movedAheadDays = 14

    /// What each goal paid for, what's still to move out of its accounts to
    /// cover that, and which moves out of them covered it.
    public struct Ledger: Sendable {
        /// Moves out of a goal's account, by transaction id, and how much of
        /// each paid for spending the goal covered: that part isn't saving
        /// taken back out.
        public var settling: [UUID: Decimal] = [:]
        /// Each goal's amount to move, from each day it changed.
        var owed: [UUID: [DailyTotal]] = [:]
        var charges: [UUID: [Transaction]] = [:]

        public init() {}

        /// Spending the goal paid for that hasn't been moved out of its
        /// accounts yet, at the end of `day`.
        public func toMove(_ goal: UUID, on day: Day) -> Decimal {
            owed[goal]?.last(where: { $0.day <= day })?.total ?? 0
        }

        /// What the goal paid for, oldest first.
        public func paid(by goal: UUID) -> [Transaction] { charges[goal] ?? [] }

        /// What the goal had paid for by the end of `day`.
        func spent(_ goal: UUID, through day: Day) -> Decimal {
            paid(by: goal).filter { $0.day <= day }.reduce(0) { $0 + $1.paidByGoal }
        }
    }

    /// Day by day, a charge a goal paid for (on another account) is owed by
    /// the goal; money moved out of the goal's accounts to one outside it
    /// pays what's owed, and what's left of a move pays a charge that comes
    /// within `movedAheadDays` after it. A charge on the goal's own account
    /// is paid as it's made.
    public static func ledger(goals: [Goal], transactions: [Transaction], kinds: [String: CategoryKind]) -> Ledger {
        var ledger = Ledger()
        let charges = transactions.filter { transaction in
            transaction.paidFromGoal != nil && transaction.paidByGoal > 0
                && Spending.spendingCategory(of: transaction, kinds: kinds) != nil
        }
        guard !charges.isEmpty else { return ledger }
        let pairs = TransferMatch.pairs(in: transactions, kinds: kinds)
        let into = Dictionary(pairs.map { ($0.outgoing, $0.incoming) }, uniquingKeysWith: { first, _ in first })
        let paired = Set(pairs.flatMap { [$0.outgoing, $0.incoming] })
        let byID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for goal in goals {
            guard case .accountTotal(let ids) = goal.kind else { continue }
            let paid = charges.filter { $0.paidFromGoal == goal.id }.sorted { ($0.day, $0.externalID) < ($1.day, $1.externalID) }
            guard !paid.isEmpty else { continue }
            ledger.charges[goal.id] = paid
            let moves = transactions.filter { transaction in
                guard ids.contains(transaction.accountID), transaction.amount < 0 else { return false }
                if let other = into[transaction.id] { return byID[other].map { !ids.contains($0.accountID) } ?? false }
                guard !paired.contains(transaction.id), let category = transaction.category else { return false }
                return (kinds[category] ?? CategoryKind.guess(category)) == .transfer
            }
            enum Event { case charge(Transaction), move(Transaction) }
            let events = (paid.map(Event.charge) + moves.map(Event.move)).sorted { a, b in
                func key(_ event: Event) -> (Int, Int) {
                    switch event {
                    case .charge(let t): (t.day.ordinal, 0)
                    case .move(let t): (t.day.ordinal, 1)
                    }
                }
                return key(a) < key(b)
            }
            var owed: Decimal = 0
            var credits: [(id: UUID, day: Day, amount: Decimal)] = []
            var timeline: [DailyTotal] = []
            for event in events {
                switch event {
                case .charge(let charge):
                    guard !ids.contains(charge.accountID) else { continue }
                    var due = charge.paidByGoal
                    credits.removeAll { $0.day.ordinal < charge.day.ordinal - movedAheadDays }
                    while due > 0, !credits.isEmpty {
                        let take = min(credits[0].amount, due)
                        ledger.settling[credits[0].id, default: 0] += take
                        due -= take
                        credits[0].amount -= take
                        if credits[0].amount == 0 { credits.removeFirst() }
                    }
                    owed += due
                    timeline.append(DailyTotal(day: charge.day, total: owed))
                case .move(let move):
                    let out = -move.amount
                    let take = min(owed, out)
                    if take > 0 {
                        ledger.settling[move.id, default: 0] += take
                        owed -= take
                        timeline.append(DailyTotal(day: move.day, total: owed))
                    }
                    if out > take { credits.append((move.id, move.day, out - take)) }
                }
            }
            ledger.owed[goal.id] = timeline
        }
        return ledger
    }

    /// A goal's measured value less what's still to move out of it, so its
    /// progress is what's left to spend. Changes (and so its pace) leave out
    /// what it paid for: spending from a fund isn't saving less.
    public static func available(_ measured: [DailyTotal], goal: UUID, ledger: Ledger) -> [DailyTotal] {
        guard !ledger.paid(by: goal).isEmpty else { return measured }
        return measured.map { value in
            DailyTotal(
                day: value.day, total: value.total - ledger.toMove(goal, on: value.day),
                opened: value.opened - ledger.spent(goal, through: value.day))
        }
    }
}
