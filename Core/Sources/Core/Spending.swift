import Foundation

public enum CategoryKind: String, Hashable, Codable, Sendable, CaseIterable {
    case spending
    case income
    case transfer

    /// Monarch's own income and transfer categories, plus anything named like
    /// one (pay, as in "Paycheck" or "Salary", is income). Investing, saving and retirement move money between their own
    /// accounts, so names like "Buy", "Stock", "Savings" or "Roth IRA" are
    /// transfers. Whole words only, so "Trader Joe's" stays spending. A fee
    /// is always spending ("Brokerage Fees", "Balance Transfer Fee"), and so
    /// is a shared ride, car or bike ("Taxi & Ride Shares", "Car Share").
    public static func guess(_ category: String) -> CategoryKind {
        let lowered = category.lowercased()
        let income = ["paychecks", "interest", "dividends & capital gains", "business income", "other income"]
        let transfer = ["credit card payment", "balance adjustments", "loan repayment"]
        // Letters and digits, so "401k" stays one word.
        let words = Set(lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if income.contains(lowered) || lowered.contains("income") || !words.isDisjoint(with: pay) { return .income }
        if !words.isDisjoint(with: spent) { return .spending }
        if transfer.contains(lowered) || lowered.contains("transfer") { return .transfer }
        let shared = !words.isDisjoint(with: ["share", "shares"]) && !words.isDisjoint(with: vehicles)
        if !words.isDisjoint(with: moving), !shared { return .transfer }
        return .spending
    }

    /// Pay as they might type it: "Paycheck", "Salary", "Acme Payroll".
    private static let pay: Set<String> = ["paycheck", "paychecks", "salary", "salaries", "payroll", "wage", "wages"]

    private static let moving: Set<String> = [
        "buy", "buys", "sell", "sells", "stock", "stocks", "share", "shares", "brokerage", "invest", "investing",
        "investment", "investments", "crypto", "cryptocurrency", "trade", "trades", "trading", "securities",
        "fund", "funds", "savings", "saving", "retirement", "401k", "403b", "ira", "roth", "rrsp", "tfsa"
    ]
    /// Words that make a name spending even beside a transfer word.
    private static let spent: Set<String> = ["fee", "fees", "contractor", "contractors", "photo", "photos"]
    private static let vehicles: Set<String> = ["ride", "rides", "car", "cars", "bike", "bikes", "scooter", "scooters"]
}

public struct Month: Hashable, Comparable, Codable, Sendable {
    public var year: Int
    public var month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    public init(_ day: Day) {
        self.init(year: day.year, month: day.month)
    }

    public var daysInMonth: Int {
        Day(year: adding(1).year, month: adding(1).month, day: 1).ordinal - Day(year: year, month: month, day: 1).ordinal
    }

    public func adding(_ months: Int) -> Month {
        let index = year * 12 + (month - 1) + months
        return Month(year: index / 12, month: index % 12 + 1)
    }

    public static func < (lhs: Month, rhs: Month) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

public struct CategorySpend: Hashable, Sendable {
    public var category: String
    public var thisMonth: Decimal
    public var sixMonthAverage: Decimal

    public init(category: String, thisMonth: Decimal, sixMonthAverage: Decimal) {
        self.category = category
        self.thisMonth = thisMonth
        self.sixMonthAverage = sixMonthAverage
    }

    /// More than 20% over the 6-month average: worth a second look.
    public var isWellAboveAverage: Bool {
        sixMonthAverage > 0 && thisMonth > sixMonthAverage * Decimal(string: "1.2")!
    }
}

public struct CategoryMonths: Hashable, Sendable {
    public var category: String
    public var months: [MonthTotal]

    public var yearTotal: Decimal { months.reduce(0) { $0 + $1.total } }

    public init(category: String, months: [MonthTotal]) {
        self.category = category
        self.months = months
    }
}

public struct MonthTotal: Hashable, Sendable {
    public var month: Month
    public var total: Decimal

    public init(month: Month, total: Decimal) {
        self.month = month
        self.total = total
    }
}

/// Where did it go? Spending is money out net of refunds and of what they're
/// owed back (`Transaction.spendingAmount`), in spending categories only.
public enum Spending {
    public static let uncategorized = "Uncategorized"

    /// Each category's spending in `month` against its average over the six
    /// full months before, biggest first.
    public static func month(_ month: Month, transactions: [Transaction], kinds: [String: CategoryKind]) -> [CategorySpend] {
        let window = month.adding(-6)..<month
        var thisMonth: [String: Decimal] = [:]
        var before: [String: Decimal] = [:]
        for transaction in Splits.parts(transactions) {
            guard let category = spendingCategory(of: transaction, kinds: kinds) else { continue }
            let when = Month(transaction.day)
            if when == month {
                thisMonth[category, default: 0] -= transaction.spendingAmount
            } else if window.contains(when) {
                before[category, default: 0] -= transaction.spendingAmount
            }
        }
        return Set(thisMonth.keys).union(before.keys)
            .map { CategorySpend(category: $0, thisMonth: thisMonth[$0] ?? 0, sixMonthAverage: (before[$0] ?? 0) / 6) }
            .sorted { ($0.thisMonth, $0.sixMonthAverage, $1.category) > ($1.thisMonth, $1.sixMonthAverage, $0.category) }
    }

    /// One category's spending per month for the twelve months ending with
    /// `end`, oldest first.
    public static func trend(_ category: String, endingIn end: Month, transactions: [Transaction], kinds: [String: CategoryKind]) -> [MonthTotal] {
        let start = end.adding(-11)
        var totals: [Month: Decimal] = [:]
        for transaction in Splits.parts(transactions) where spendingCategory(of: transaction, kinds: kinds) == category {
            let when = Month(transaction.day)
            if when >= start && when <= end { totals[when, default: 0] -= transaction.spendingAmount }
        }
        return (0..<12).map { offset in
            let month = start.adding(offset)
            return MonthTotal(month: month, total: totals[month] ?? 0)
        }
    }

    /// Every spending category's monthly totals for the twelve months ending
    /// with `end`, oldest first, biggest category (over the year) first.
    public static func monthlyByCategory(endingIn end: Month, transactions: [Transaction], kinds: [String: CategoryKind]) -> [CategoryMonths] {
        let start = end.adding(-11)
        var totals: [String: [Month: Decimal]] = [:]
        for transaction in Splits.parts(transactions) {
            guard let category = spendingCategory(of: transaction, kinds: kinds) else { continue }
            let when = Month(transaction.day)
            guard when >= start && when <= end else { continue }
            totals[category, default: [:]][when, default: 0] -= transaction.spendingAmount
        }
        return totals.map { category, byMonth in
            CategoryMonths(
                category: category,
                months: (0..<12).map { offset in
                    let month = start.adding(offset)
                    return MonthTotal(month: month, total: byMonth[month] ?? 0)
                })
        }
        .sorted { ($0.yearTotal, $1.category) > ($1.yearTotal, $0.category) }
    }

    static func spendingCategory(of transaction: Transaction, kinds: [String: CategoryKind]) -> String? {
        guard let category = transaction.category else {
            return transaction.amount < 0 ? uncategorized : nil
        }
        return (kinds[category] ?? CategoryKind.guess(category)) == .spending ? category : nil
    }
}
