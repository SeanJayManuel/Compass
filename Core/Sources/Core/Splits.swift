import Foundation

/// One part of a split transaction: a category and its share of the amount,
/// signed as the transaction is.
public struct TransactionSplit: Hashable, Codable, Sendable {
    public var category: String
    public var amount: Decimal

    public init(category: String, amount: Decimal) {
        self.category = category
        self.amount = amount
    }
}

extension Transaction {
    public var isSplit: Bool { !splits.isEmpty }

    /// What spending and the budget count: each part as a transaction of
    /// its own (same id, so take parts only where nothing keys by id), or
    /// the transaction itself when it isn't split.
    public var parts: [Transaction] {
        guard isSplit else { return [self] }
        return splits.map { split in
            var part = self
            part.category = split.category
            part.amount = split.amount
            part.splits = []
            return part
        }
    }
}

/// A transaction split into categories (seam 43): a Target run that was
/// part groceries, part household. Spending, the budget, day totals and
/// search count each part in its category; the transaction keeps its
/// largest part's category, so rules, review and guessing see a whole one.
public enum Splits {
    /// Every transaction's parts, for totals by category.
    public static func parts(_ transactions: [Transaction]) -> [Transaction] {
        transactions.contains(where: \.isSplit) ? transactions.flatMap(\.parts) : transactions
    }

    /// Splits a transaction into parts given as dollars (signed as the
    /// transaction is), or with none takes its split off. Two or more parts
    /// in different spending categories, none zero or below, adding up to
    /// the amount; not on a transaction someone owes them for, nor one filed
    /// as income or a transfer.
    public static func split(
        _ transaction: Transaction, into parts: [(category: String, amount: Decimal)],
        kinds: [String: CategoryKind]
    ) throws -> Transaction {
        var split = transaction
        guard !parts.isEmpty else {
            split.splits = []
            return split
        }
        func kind(_ category: String) -> CategoryKind { kinds[category] ?? CategoryKind.guess(category) }
        if let category = transaction.category, kind(category) != .spending {
            throw ClaudeRefusal("It's filed as \(category), \(kind(category) == .income ? "income" : "a transfer"); only spending is split.")
        }
        guard !transaction.reimbursable else { throw ClaudeRefusal("It's marked owed back to them; take that off before splitting it.") }
        guard transaction.paidFromGoal == nil else { throw ClaudeRefusal("A goal paid for it; take that off before splitting it.") }
        guard parts.count >= 2 else { throw ClaudeRefusal("A split needs two parts or more; to file all of it one way, change its category.") }
        let sign: Decimal = transaction.amount < 0 ? -1 : 1
        var seen: Set<String> = []
        split.splits = try parts.map { part in
            let category = CategoryRules.tidy(part.category)
            guard !category.isEmpty else { throw ClaudeRefusal("Each part needs a category.") }
            guard kind(category) == .spending else { throw ClaudeRefusal("\(category) isn't a spending category; parts are spending.") }
            guard seen.insert(category.lowercased()).inserted else { throw ClaudeRefusal("\(category) is in the split twice; add those parts together.") }
            guard part.amount > 0 else { throw ClaudeRefusal("Each part is an amount above zero.") }
            return TransactionSplit(category: category, amount: part.amount * sign)
        }
        let total = split.splits.reduce(0) { $0 + $1.amount }
        guard total == transaction.amount else {
            throw ClaudeRefusal("The parts add up to \(abs(total)), not \(abs(transaction.amount)).")
        }
        split.category = largest(split.splits)
        return split
    }

    /// With one category renamed, or merged into another already in the
    /// split (their parts added together; one part left is no split).
    public static func renaming(_ transaction: Transaction, _ old: String, to new: String) -> Transaction {
        guard transaction.splits.contains(where: { $0.category == old }) else { return transaction }
        var merged: [TransactionSplit] = []
        for var split in transaction.splits {
            if split.category == old { split.category = new }
            if let index = merged.firstIndex(where: { $0.category == split.category }) {
                merged[index].amount += split.amount
            } else {
                merged.append(split)
            }
        }
        var renamed = transaction
        renamed.splits = merged.count > 1 ? merged : []
        renamed.category = largest(merged)
        return renamed
    }

    /// The category of the part with the most money, the first on a tie.
    static func largest(_ splits: [TransactionSplit]) -> String? {
        splits.reduce(nil as TransactionSplit?) { best, split in
            best.map { abs(split.amount) > abs($0.amount) ? split : $0 } ?? split
        }?.category
    }
}
