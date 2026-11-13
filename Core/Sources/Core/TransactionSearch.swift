import Foundation

public enum CategoryFilter: Hashable, Sendable {
    case any
    case unfiled
    case named(String)
}

public struct TransactionQuery: Hashable, Sendable {
    public var text: String
    public var category: CategoryFilter
    public var month: Month?
    /// Nil matches either way.
    public var hasNote: Bool?
    public var oneOff: Bool?
    public var reimbursable: Bool?
    /// Matches the note, ignoring case.
    public var noteText: String

    public init(
        text: String = "", category: CategoryFilter = .any, month: Month? = nil,
        hasNote: Bool? = nil, oneOff: Bool? = nil, reimbursable: Bool? = nil, noteText: String = ""
    ) {
        self.text = text
        self.category = category
        self.month = month
        self.hasNote = hasNote
        self.oneOff = oneOff
        self.reimbursable = reimbursable
        self.noteText = noteText
    }
}

/// One day's transactions and what they came to.
public struct TransactionDay: Hashable, Sendable, Identifiable {
    public var day: Day
    /// Credits count up, debits down.
    public var net: Decimal
    /// Money out in spending categories (uncategorized money out included), net
    /// of refunds; negative when refunds beat charges. Transfers and income are
    /// never in it, nor an unfiled transaction matched as a transfer (a card
    /// autopay and its "payment thank you"). What a goal paid for isn't in it.
    public var spent: Decimal
    /// What goals paid for on the day (seam 44).
    public var paidFromGoals: Decimal = 0
    /// Money in under income categories. Money in with no category isn't income
    /// until it's filed, as on the budget.
    public var received: Decimal
    /// Every transaction on the day is filed under a transfer category (a card
    /// payment, money moved between their accounts) or matched as one. Other
    /// unfiled money, in or out, never counts, so a day with only an unfiled
    /// deposit isn't one.
    public var transfersOnly: Bool
    public var transactions: [Transaction]

    public var id: Int { day.ordinal }
}

public enum TransactionSearch {
    /// Transactions grouped by day, newest first; within a day, in the same
    /// order as `filter`. `transfers` are unfiled transactions matched as
    /// transfers (`TransferMatch.toFile`), found across more history than
    /// `transactions` when they're one page or month, so a pair that spans the
    /// edge still matches.
    public static func byDay(
        _ transactions: [Transaction], kinds: [String: CategoryKind] = [:],
        transfers: Set<UUID> = []
    ) -> [TransactionDay] {
        Dictionary(grouping: transactions, by: \.day)
            .map { day, list in
                var spent: Decimal = 0, paidFromGoals: Decimal = 0
                var received: Decimal = 0
                var transfersOnly = true
                for transaction in list {
                    if transfers.contains(transaction.id) { continue }
                    if let category = transaction.category {
                        if (kinds[category] ?? CategoryKind.guess(category)) != .transfer { transfersOnly = false }
                    } else {
                        transfersOnly = false
                    }
                    for part in transaction.parts {
                        if Spending.spendingCategory(of: part, kinds: kinds) != nil {
                            spent -= part.budgetAmount
                            paidFromGoals += part.paidByGoal
                        } else if let category = part.category, (kinds[category] ?? CategoryKind.guess(category)) == .income {
                            // As the budget counts income: what the day brought in under income categories.
                            received += part.amount
                        }
                    }
                }
                return TransactionDay(
                    day: day, net: list.reduce(0) { $0 + $1.amount }, spent: spent, paidFromGoals: paidFromGoals,
                    received: received, transfersOnly: transfersOnly,
                    transactions: list.sorted { $0.externalID > $1.externalID })
            }
            .sorted { $0.day > $1.day }
    }

    /// The newest `count` of `sorted` (newest first, as `filter` returns
    /// them) and the rest of the last one's day, so a page never stops
    /// partway through a day and each day's net is the whole day's.
    public static func page(_ sorted: [Transaction], count: Int) -> ArraySlice<Transaction> {
        guard count > 0, count < sorted.count else { return sorted.prefix(max(count, 0)) }
        var end = count
        let lastDay = sorted[count - 1].day
        while end < sorted.count, sorted[end].day == lastDay { end += 1 }
        return sorted[..<end]
    }

    /// A freshly read `page` (newest first, ending at a day's end) on top of
    /// an `older` read of the whole history, which supplies the days before
    /// the page's last. Until the history is read again, a list scrolled
    /// deep keeps its length while the page shows what just changed.
    public static func splice(_ page: [Transaction], onto older: [Transaction]) -> [Transaction] {
        guard let last = page.last?.day else { return older }
        return page + older.drop { $0.day >= last }
    }

    /// Matching transactions, newest first. Text matches the merchant or the
    /// bank's statement, ignoring case, punctuation and store numbers.
    public static func filter(_ transactions: [Transaction], _ query: TransactionQuery) -> [Transaction] {
        let needle = Merchant.key(query.text)
        return transactions.filter { transaction in
            matches(transaction, in: Month(transaction.day), query, needle: needle) {
                Merchant.key(transaction.merchant).contains(needle) || Merchant.key(transaction.statement).contains(needle)
            }
        }
        .sorted(by: newestFirst)
    }

    static func matches(
        _ transaction: Transaction, in month: @autoclosure () -> Month, _ query: TransactionQuery,
        needle: String, text: () -> Bool
    ) -> Bool {
        if let wanted = query.month, month() != wanted { return false }
        switch query.category {
        case .any: break
        case .unfiled: if transaction.category != nil { return false }
        case .named(let name): if transaction.category != name, !transaction.splits.contains(where: { $0.category == name }) { return false }
        }
        if let hasNote = query.hasNote, transaction.note.isEmpty == hasNote { return false }
        if let oneOff = query.oneOff, transaction.oneOff != oneOff { return false }
        if let reimbursable = query.reimbursable, transaction.reimbursable != reimbursable { return false }
        let noteNeedle = query.noteText.trimmingCharacters(in: .whitespaces)
        if !noteNeedle.isEmpty, !transaction.note.localizedCaseInsensitiveContains(noteNeedle) { return false }
        return needle.isEmpty || text()
    }

    static func newestFirst(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
        (lhs.day, lhs.externalID) > (rhs.day, rhs.externalID)
    }
}

/// A long history made ready to search: sorted newest first and keyed once,
/// so each search is one pass with no sorting or re-keying. Finds exactly
/// what `TransactionSearch.filter` finds.
public struct TransactionIndex: Sendable {
    /// Newest first.
    public let transactions: [Transaction]
    /// Newest first.
    public let months: [Month]
    public let categories: Set<String>
    private let keys: [(merchant: String, statement: String, month: Month)]

    public init(_ transactions: [Transaction]) {
        let sorted = transactions.sorted(by: TransactionSearch.newestFirst)
        self.transactions = sorted
        var keys: [(merchant: String, statement: String, month: Month)] = []
        keys.reserveCapacity(sorted.count)
        var months: [Month] = []
        // Sorted, so each day's month is worked out once, not per row.
        var day: Day?
        var month = Month(year: 0, month: 1)
        for transaction in sorted {
            if transaction.day != day {
                day = transaction.day
                month = Month(transaction.day)
                if months.last != month { months.append(month) }
            }
            keys.append((Merchant.key(transaction.merchant), Merchant.key(transaction.statement), month))
        }
        self.keys = keys
        self.months = months
        categories = Set(sorted.compactMap(\.category)).union(sorted.flatMap { $0.splits.map(\.category) })
    }

    public var count: Int { transactions.count }

    /// The newest `count`, for a first page.
    public func newest(_ count: Int) -> [Transaction] { Array(transactions.prefix(count)) }

    public func filter(_ query: TransactionQuery) -> [Transaction] {
        let needle = Merchant.key(query.text)
        if needle.isEmpty, query.month == nil, query.category == .any { return transactions }
        var found: [Transaction] = []
        for (index, transaction) in transactions.enumerated() {
            let key = keys[index]
            if TransactionSearch.matches(
                transaction, in: key.month, query, needle: needle,
                text: {
                    key.merchant.contains(needle) || key.statement.contains(needle)
                })
            {
                found.append(transaction)
            }
        }
        return found
    }
}

/// Summary of the complete matching set, independent of list pagination.
public struct TransactionSummary: Equatable, Sendable {
    public struct Monthly: Equatable, Sendable {
        public var month: Month
        public var income: Decimal = 0
        public var spending: Decimal = 0
        /// This month's spending by category, biggest first.
        public var categories: [Category] = []

        public init(month: Month, income: Decimal = 0, spending: Decimal = 0, categories: [Category] = []) {
            self.month = month
            self.income = income
            self.spending = spending
            self.categories = categories
        }
    }
    public struct Category: Equatable, Sendable {
        public var category: String
        public var amount: Decimal
    }
    public var months: [Monthly]
    public var categories: [Category]
    public var income: Decimal { months.reduce(0) { $0 + $1.income } }
    public var spending: Decimal { months.reduce(0) { $0 + $1.spending } }
}

extension TransactionSearch {
    /// The same income and spending rules as day groups, with goal-paid
    /// spending included (as on Spending). `transfers` comes from the full
    /// history, so filtering out the other side never turns a move into spending.
    public static func summary(
        _ transactions: [Transaction], kinds: [String: CategoryKind] = [:],
        transfers: Set<UUID> = []
    ) -> TransactionSummary {
        var months: [Month: TransactionSummary.Monthly] = [:]
        var categories: [String: Decimal] = [:]
        var monthCategories: [Month: [String: Decimal]] = [:]
        for transaction in transactions {
            let month = Month(transaction.day)
            if months[month] == nil { months[month] = .init(month: month) }
            guard !transfers.contains(transaction.id) else { continue }
            for part in transaction.parts {
                if let category = Spending.spendingCategory(of: part, kinds: kinds) {
                    months[month]!.spending -= part.spendingAmount
                    categories[category, default: 0] -= part.spendingAmount
                    monthCategories[month, default: [:]][category, default: 0] -= part.spendingAmount
                } else if let category = part.category, (kinds[category] ?? CategoryKind.guess(category)) == .income {
                    months[month]!.income += part.amount
                }
            }
        }
        if let first = months.keys.min(), let last = months.keys.max() {
            var month = first
            while month < last {
                if months[month] == nil { months[month] = .init(month: month) }
                month = month.adding(1)
            }
        }
        for (month, spent) in monthCategories { months[month]?.categories = ranked(spent) }
        return TransactionSummary(months: months.values.sorted { $0.month < $1.month }, categories: ranked(categories))
    }

    /// Biggest first; ties by name.
    private static func ranked(_ amounts: [String: Decimal]) -> [TransactionSummary.Category] {
        amounts.map { .init(category: $0.key, amount: $0.value) }
            .sorted { ($0.amount, $1.category) > ($1.amount, $0.category) }
    }
}
