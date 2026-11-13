import Core
import Foundation
import SwiftData

@Model
final class TransactionRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var externalID: String
    var accountID: UUID
    var dayOrdinal: Int
    var amount: Decimal
    var merchant: String
    var statement: String
    var category: String?
    /// True while a synced transaction waits for them to confirm its category
    /// (a guess counts in the budget meanwhile). Nil for history, which
    /// arrived reviewed, and for stores from before review.
    var reviewPending: Bool?
    /// Their note, and whether it's a one-off or owed back to them (all of it
    /// when `reimbursableAmount` is nil). Never from a sync.
    var note: String = ""
    var oneOff: Bool = false
    var reimbursable: Bool = false
    var reimbursableAmount: Decimal?
    /// Its parts when split into categories (seam 43), as JSON; nil when it isn't.
    var splitsData: Data?
    /// The goal whose money paid for it (seam 44), and how much (all of it when nil).
    var paidFromGoal: UUID?
    var paidFromGoalAmount: Decimal?

    init(_ transaction: Transaction) {
        id = transaction.id
        externalID = transaction.externalID
        accountID = transaction.accountID
        dayOrdinal = transaction.day.ordinal
        amount = transaction.amount
        merchant = transaction.merchant
        statement = transaction.statement
        category = transaction.category
        note = transaction.note
        oneOff = transaction.oneOff
        reimbursable = transaction.reimbursable
        reimbursableAmount = transaction.reimbursableAmount
        splits = transaction.splits
        paidFromGoal = transaction.paidFromGoal
        paidFromGoalAmount = transaction.paidFromGoalAmount
    }

    var splits: [TransactionSplit] {
        get { splitsData.flatMap { try? JSONDecoder().decode([TransactionSplit].self, from: $0) } ?? [] }
        set { splitsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    /// Files all of it under one category (or none), taking any split off.
    /// A charge a goal paid for asks goals to refresh: whether it still
    /// counts for the goal depends on its category.
    func refile(_ category: String?) {
        self.category = category
        splitsData = nil
        if paidFromGoal != nil {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .goalPaymentsChanged, object: nil) }
        }
    }

    var transaction: Transaction {
        withNotes(
            Transaction(
                id: id, accountID: accountID, day: Day(ordinal: dayOrdinal), amount: amount,
                merchant: merchant, statement: statement, category: category, externalID: externalID))
    }

    /// `transaction` with this record's note and flags, for reads built field by field.
    func withNotes(_ transaction: Transaction) -> Transaction {
        var transaction = transaction
        transaction.note = note
        transaction.oneOff = oneOff
        transaction.reimbursable = reimbursable
        transaction.reimbursableAmount = reimbursableAmount
        transaction.splits = splits
        transaction.paidFromGoal = paidFromGoal
        transaction.paidFromGoalAmount = paidFromGoalAmount
        return transaction
    }
}

extension Notification.Name {
    /// A transaction a goal paid for (or pays for now) was saved: goals'
    /// progress, which transaction saves don't otherwise refresh, changes.
    static let goalPaymentsChanged = Notification.Name("CompassGoalPaymentsChanged")
}

/// One category per merchant, learned at import or set by filing.
@Model
final class CategoryRuleRecord {
    @Attribute(.unique) var merchantKey: String
    var category: String

    init(merchantKey: String, category: String) {
        self.merchantKey = merchantKey
        self.category = category
    }
}

/// A category's kind when it differs from the default guess.
@Model
final class CategoryKindRecord {
    @Attribute(.unique) var category: String
    var kindRaw: String

    init(category: String, kind: CategoryKind) {
        self.category = category
        kindRaw = kind.rawValue
    }
}
