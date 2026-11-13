import Core
import Foundation
import SwiftData

@Model
final class GoalRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var kindRaw: String
    var accountIDs: [UUID] = []
    var annualSpending: Decimal?
    var multiplier: Decimal?
    var target: Decimal
    var targetMin: Decimal?
    var targetDateOrdinal: Int?
    var statusRaw: String
    var achievedOrdinal: Int?
    var achievedValue: Decimal?
    var retiredReason: String?
    var rewardName: String?
    var rewardCost: Decimal?
    var rewardClaimedOrdinal: Int?
    var predecessorID: UUID?
    /// Why it matters, in their words.
    var note: String = ""
    var createdAt: Date
    /// The achievement moment plays once.
    var celebrated: Bool = false
    /// The suggested next goal was dismissed.
    var successorDismissed: Bool = false
    /// An optional photo of the claimed reward, downscaled JPEG.
    @Attribute(.externalStorage) var rewardPhoto: Data?

    init(_ goal: Goal, createdAt: Date = .now) {
        id = goal.id
        name = goal.name
        kindRaw = "netWorth"
        target = goal.target
        statusRaw = "active"
        self.createdAt = createdAt
        update(from: goal)
    }

    func update(from goal: Goal) {
        name = goal.name
        switch goal.kind {
        case .netWorth:
            kindRaw = "netWorth"
            accountIDs = []
        case .accountTotal(let ids):
            kindRaw = "accountTotal"
            accountIDs = Array(ids)
        case .fire(let spending, let multiplier):
            kindRaw = "fire"
            annualSpending = spending
            self.multiplier = multiplier
        }
        target = goal.target
        targetMin = goal.targetMin
        targetDateOrdinal = goal.targetDate?.ordinal
        switch goal.status {
        case .active:
            statusRaw = "active"
        case .achieved(let day, let value):
            statusRaw = "achieved"
            achievedOrdinal = day.ordinal
            achievedValue = value
        case .retired(let reason):
            statusRaw = "retired"
            retiredReason = reason
        }
        // Removing the reward removes its photo too.
        if goal.reward == nil { rewardPhoto = nil }
        rewardName = goal.reward?.name
        rewardCost = goal.reward?.cost
        rewardClaimedOrdinal = goal.reward?.claimedOn?.ordinal
        predecessorID = goal.predecessorID
        note = goal.note
    }

    var goal: Goal {
        let kind: GoalKind =
            switch kindRaw {
            case "accountTotal": .accountTotal(Set(accountIDs))
            case "fire": .fire(annualSpending: annualSpending ?? 0, multiplier: multiplier ?? 25)
            default: .netWorth
            }
        let status: GoalStatus =
            switch statusRaw {
            case "achieved": .achieved(on: Day(ordinal: achievedOrdinal ?? 0), value: achievedValue ?? 0)
            case "retired": .retired(reason: retiredReason ?? "")
            default: .active
            }
        return Goal(
            id: id, name: name, kind: kind, target: target, targetMin: targetMin,
            targetDate: targetDateOrdinal.map(Day.init(ordinal:)), status: status,
            reward: rewardName.map { Reward(name: $0, cost: rewardCost, claimedOn: rewardClaimedOrdinal.map(Day.init(ordinal:))) },
            predecessorID: predecessorID, note: note
        )
    }
}

extension CompassStore {
    func goals() throws -> [Goal] {
        try context.fetch(FetchDescriptor<GoalRecord>(sortBy: [SortDescriptor(\.createdAt)])).map(\.goal)
    }

    /// What each goal paid for, what's still to move out of it, and which
    /// moves out of a goal's account covered it (seam 44). Unless given the
    /// transactions, reads every one (a move can cover a charge from months
    /// before), but only once a goal has paid for something.
    func goalLedger(transactions: [Transaction]? = nil, kinds: [String: CategoryKind]? = nil) throws -> GoalFunding.Ledger {
        guard let transactions else { return GoalFunding.ledger(in: context) }
        return try GoalFunding.ledger(goals: goals(), transactions: transactions, kinds: kinds ?? self.kinds())
    }

    func save(_ goal: Goal) throws {
        let id = goal.id
        var descriptor = FetchDescriptor<GoalRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.update(from: goal)
        } else {
            context.insert(GoalRecord(goal))
        }
        try context.save()
    }

    func record(for goalID: UUID) throws -> GoalRecord? {
        var descriptor = FetchDescriptor<GoalRecord>(predicate: #Predicate { $0.id == goalID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Marks goals achieved when their measured value first reached the
    /// target. Runs whenever balances change.
    func refreshGoals(today: Day) throws {
        let accounts = try accounts()
        let snapshots = try snapshots()
        try refreshGoals(
            today: today, accounts: accounts, snapshots: snapshots,
            breakdown: NetWorthSeries.breakdown(accounts: accounts, snapshots: snapshots, through: today))
    }

    /// For callers that already hold the breakdown (NetWorthCache).
    func refreshGoals(today: Day, accounts: [Account], snapshots: [BalanceSnapshot], breakdown: [DailyBreakdown]) throws {
        let active = try context.fetch(FetchDescriptor<GoalRecord>()).filter { $0.statusRaw == "active" }
        guard !active.isEmpty else { return }
        let ledger = try goalLedger()
        for record in active {
            let goal = record.goal
            let measured = GoalFunding.available(
                GoalProgress.measured(
                    goal, accounts: accounts, snapshots: snapshots,
                    today: today, breakdown: breakdown),
                goal: goal.id, ledger: ledger)
            let updated = GoalLifecycle.update(goal, measured: measured)
            if updated.status != goal.status { record.update(from: updated) }
        }
        if context.hasChanges { try context.save() }
    }
}

extension GoalFunding {
    /// `CompassStore.goalLedger` on a context of its own, off the main
    /// thread: every transaction, read only once a goal has paid for something.
    nonisolated static func ledger(in context: ModelContext) -> Ledger {
        var paid = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.paidFromGoal != nil })
        paid.fetchLimit = 1
        guard let any = try? context.fetch(paid), !any.isEmpty else { return Ledger() }
        let goals = context.all(GoalRecord.self).map(\.goal)
        let transactions = context.all(TransactionRecord.self).map(\.transaction)
        let kinds = Dictionary(
            context.all(CategoryKindRecord.self).compactMap { record in
                CategoryKind(rawValue: record.kindRaw).map { (record.category, $0) }
            }, uniquingKeysWith: { first, _ in first })
        return ledger(goals: goals, transactions: transactions, kinds: kinds)
    }
}
