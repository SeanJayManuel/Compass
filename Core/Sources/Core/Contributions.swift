import Foundation

/// One investing account's month: what it started and ended at, the money the owner
/// put in or took out, and what the market did with the rest.
public struct ContributionMonth: Hashable, Sendable {
    public var accountID: UUID
    public var month: Month
    /// The current month, counted through today.
    public var isMonthToDate: Bool
    /// The balance at the end of the month before; nil when the account's
    /// balances start this month.
    public var startingBalance: Decimal?
    /// At the end of the month, or today for the current month.
    public var endingBalance: Decimal
    /// Money in and out from their side; nil when Compass can't tell (no
    /// transactions of the account's own cover the month, or some are unclear).
    public var moneyIn: Decimal?
    public var moneyOut: Decimal?
    /// Money in or out with no partner and no wording that tells a deposit
    /// from a trade. Any makes the month's contributions unknown.
    public var unclear: Int
    /// No balance was recorded this month, so the ending balance is carried
    /// from before and the market change can't be told.
    public var hasBalanceGap: Bool
    /// Told from their paystubs rather than the account's transactions, with
    /// their part and their employer's apart.
    public var payroll: PayrollMoney?

    public init(
        accountID: UUID, month: Month, isMonthToDate: Bool, startingBalance: Decimal?,
        endingBalance: Decimal, moneyIn: Decimal?, moneyOut: Decimal?, unclear: Int = 0,
        hasBalanceGap: Bool = false, payroll: PayrollMoney? = nil
    ) {
        self.accountID = accountID
        self.month = month
        self.isMonthToDate = isMonthToDate
        self.startingBalance = startingBalance
        self.endingBalance = endingBalance
        self.moneyIn = moneyIn
        self.moneyOut = moneyOut
        self.unclear = unclear
        self.hasBalanceGap = hasBalanceGap
        self.payroll = payroll
    }

    public var balanceChange: Decimal? { startingBalance.map { endingBalance - $0 } }

    public var netContributions: Decimal? {
        guard let moneyIn, let moneyOut else { return nil }
        return moneyIn - moneyOut
    }

    /// The balance change less net contributions: growth, dividends and fees.
    public var marketChange: Decimal? {
        guard !hasBalanceGap, let balanceChange, let netContributions else { return nil }
        return balanceChange - netContributions
    }
}

public struct AccountContributions: Hashable, Sendable {
    public var accountID: UUID
    /// Oldest first; only months the account has balances for.
    public var months: [ContributionMonth]

    public init(accountID: UUID, months: [ContributionMonth]) {
        self.accountID = accountID
        self.months = months
    }
}

/// What they've been putting into investing a month, for an invested goal's pace.
public struct ContributionPace: Hashable, Sendable {
    /// Net contributions a month over `months`, over the accounts that can be
    /// told every month; nil when none can.
    public var perMonth: Decimal?
    /// What the market did a month over the same accounts, counting the
    /// months it can be told (not one whose balances start in it).
    public var marketPerMonth: Decimal?
    public var months: ClosedRange<Month>
    /// Accounts left out: some month's contributions can't be told.
    public var untold: [UUID]
}

/// Splits each investing account's months into contributions and market
/// change.
public enum Contributions {
    /// Taxable, retirement and equity accounts counted in net worth, each
    /// month in `months` that it has balances for. An account their pay goes
    /// into (`payroll`) takes its contributions from their paychecks in months
    /// where every payday can be told, their part and the employer's apart.
    public static func report(
        accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction],
        kinds: [String: CategoryKind], today: Day,
        months: ClosedRange<Month>, payroll: Payroll = Payroll()
    ) -> [AccountContributions] {
        let investing = accounts.filter { [.taxable, .retirement, .equity].contains($0.accountClass) && !$0.excludedFromNetWorth }
        let paired = Set(TransferMatch.pairs(in: transactions, kinds: kinds).flatMap { [$0.outgoing, $0.incoming] })
        let snapshotsByAccount = Dictionary(grouping: snapshots, by: \.accountID)
        let transactionsByAccount = Dictionary(grouping: transactions, by: \.accountID)
        let current = Month(today)

        return investing.map { account in
            let own = snapshotsByAccount[account.id] ?? []
            let series = NetWorthSeries.daily(snapshots: own, through: today)
            let mine = transactionsByAccount[account.id] ?? []
            // An account they pay into themselves (an IRA) buys with cash already
            // inside, so its purchases are never read as their money arriving.
            // Payroll's own deposits (a match, a rollover) don't make it one.
            let takesDeposits = mine.contains { transaction in
                transaction.amount > 0 && !isPayroll(transaction)
                    && role(of: transaction, paired: paired.contains(transaction.id), kinds: kinds) == .contribution
            }
            // Their transactions tell contributions from their earliest day to
            // the latest one, or to today for an account that still syncs.
            let covered: ClosedRange<Day>? = mine.map(\.day).min().map { first in
                first...(account.source == .simplefin ? today : Month(mine.map(\.day).max()!).lastDay)
            }
            var result: [ContributionMonth] = []
            var month = months.lowerBound
            while month <= months.upperBound, month <= current {
                defer { month = month.adding(1) }
                // An archived account stops counting; its balance isn't carried on.
                if let archivedOn = account.archivedOn, month.firstDay > archivedOn { break }
                let end = month == current ? today : month.lastDay
                guard let ending = value(on: end, in: series), let firstBalance = series.first?.day else { continue }
                let starting = value(on: month.firstDay.adding(-1), in: series)
                let from = max(month.firstDay, firstBalance)
                let isCovered = covered.map { $0.lowerBound <= from && $0.upperBound >= end } ?? false
                var moneyIn: Decimal = 0, moneyOut: Decimal = 0, unclear = 0
                // What the month's purchases and sales came to, unclear ones included.
                var bought: Decimal = 0
                for transaction in mine where (from...end).contains(transaction.day) {
                    switch role(of: transaction, paired: paired.contains(transaction.id), kinds: kinds) {
                    case .contribution:
                        if transaction.amount > 0 { moneyIn += transaction.amount } else { moneyOut -= transaction.amount }
                    case .unclear:
                        unclear += 1
                        bought += Self.bought(transaction, paired: paired.contains(transaction.id), kinds: kinds)
                    case .inside:
                        bought += Self.bought(transaction, paired: paired.contains(transaction.id), kinds: kinds)
                    }
                }
                // A retirement account whose deposits never arrive (a 401(k)
                // paid from payroll): what it bought, less what it sold, is
                // the money that came in. A rebalance comes to nothing, and
                // reinvested dividends stay the market's.
                if account.accountClass == .retirement, !takesDeposits, moneyIn == 0, unclear > 0 || bought != 0 {
                    moneyIn = max(bought, 0)
                    moneyOut = max(-bought, 0)
                    unclear = 0
                }
                if let pay = payroll.money(into: account.id, over: from...end) {
                    result.append(
                        ContributionMonth(
                            accountID: account.id, month: month, isMonthToDate: month == current,
                            startingBalance: starting, endingBalance: ending, moneyIn: pay.total, moneyOut: 0,
                            hasBalanceGap: !own.contains { (from...end).contains($0.day) }, payroll: pay))
                    continue
                }
                result.append(
                    ContributionMonth(
                        accountID: account.id, month: month, isMonthToDate: month == current,
                        startingBalance: starting, endingBalance: ending,
                        // Unclear money might be their: the month can't be told either.
                        moneyIn: isCovered && unclear == 0 ? moneyIn : nil, moneyOut: isCovered && unclear == 0 ? moneyOut : nil,
                        unclear: isCovered ? unclear : 0,
                        hasBalanceGap: !own.contains { (from...end).contains($0.day) }))
            }
            return AccountContributions(accountID: account.id, months: result)
        }
    }

    /// The three full months before `month`, averaged. An account counts
    /// only if every one of them can be told; one it has no balances for
    /// counts as nothing put in.
    public static func pace(_ report: [AccountContributions], before month: Month) -> ContributionPace {
        let months = month.adding(-3)...month.adding(-1)
        var net: Decimal = 0, market: Decimal = 0, untold: [UUID] = [], told = 0
        for account in report {
            let shown = account.months.filter { months.contains($0.month) }
            guard shown.allSatisfy({ $0.netContributions != nil }) else { untold.append(account.accountID); continue }
            told += 1
            net += shown.compactMap(\.netContributions).reduce(0, +)
            market += shown.compactMap(\.marketChange).reduce(0, +)
        }
        return ContributionPace(
            perMonth: told > 0 ? net / 3 : nil, marketPerMonth: told > 0 ? market / 3 : nil,
            months: months, untold: untold)
    }

    enum Role { case contribution, inside, unclear }

    /// Trades, dividends, interest, fees and sweeps (money market, core position) stay inside
    /// the account, whatever pairs with them, and so does income. Money
    /// matched to another of their accounts, or worded like a deposit, transfer
    /// or withdrawal, is their money moving, and so is spending from the
    /// account. A transfer category alone doesn't tell: a 401(k)'s fund
    /// purchases come filed as transfers. Anything else can't be told.
    static func role(of transaction: Transaction, paired: Bool, kinds: [String: CategoryKind]) -> Role {
        func words(_ parts: String...) -> String { " " + Merchant.key(parts.joined(separator: " ")) + " " }
        let described = words(transaction.merchant, transaction.statement)
        if insideWords.contains(where: { words(transaction.category ?? "", described).contains(" \($0) ") }) { return .inside }
        let kind = transaction.category.map { kinds[$0] ?? CategoryKind.guess($0) }
        if kind == .income { return .inside }
        if paired || movingWords.contains(where: { described.contains(" \($0) ") }) { return .contribution }
        return kind == .spending ? .contribution : .unclear
    }

    /// What `transaction` bought, as a retirement account paid from payroll
    /// reads it (negative for a sale): its trades and the money it can't
    /// tell, never a dividend or their own money moving.
    static func bought(_ transaction: Transaction, paired: Bool, kinds: [String: CategoryKind]) -> Decimal {
        switch role(of: transaction, paired: paired, kinds: kinds) {
        case .unclear: -transaction.amount
        case .inside: isTrade(transaction) ? -transaction.amount : 0
        case .contribution: 0
        }
    }

    /// Worded as payroll's own deposit (a match, a rollover), not money they moved.
    static func isPayroll(_ transaction: Transaction) -> Bool {
        let described = " " + Merchant.key(transaction.merchant + " " + transaction.statement) + " "
        return payrollWords.contains { described.contains(" \($0) ") }
    }

    /// A purchase or sale of a fund, not a dividend, its reinvestment, interest or a fee.
    static func isTrade(_ transaction: Transaction) -> Bool {
        // "YOU BOUGHT EX-DIV DATE 09/28/26…" is a buy, not a dividend.
        let described = (" " + Merchant.key([transaction.category ?? "", transaction.merchant, transaction.statement].joined(separator: " ")) + " ")
            .replacingOccurrences(of: " ex div ", with: " ")
        let income = [
            "dividend", "dividends", "div", "reinvest", "reinvestment", "reinvested", "interest",
            "capital gain", "capital gains", "cap gain", "fee", "fees", "money market", "core position"
        ]
        guard !income.contains(where: { described.contains(" \($0) ") }) else { return false }
        return ["buy", "bought", "sell", "sold", "purchase", "trade", "exchange"].contains { described.contains(" \($0) ") }
    }

    static let insideWords = [
        "buy", "bought", "sell", "sold", "purchase", "trade", "reinvest", "reinvestment", "reinvested",
        "dividend", "dividends", "div", "interest", "capital gain", "capital gains", "cap gain", "fee", "fees",
        "split", "exchange", "money market", "core position"
    ]
    static let payrollWords = ["payroll", "employer", "match", "rollover"]
    static let movingWords = [
        "contribution", "contributions", "contrib", "deposit", "transfer", "ach", "eft", "rollover",
        "withdrawal", "distribution", "payroll", "employer", "match"
    ]

    /// The balance carried to `day`, or nil before the first one.
    static func value(on day: Day, in series: [DailyTotal]) -> Decimal? {
        guard let first = series.first, day >= first.day else { return nil }
        let index = min(day.ordinal - first.day.ordinal, series.count - 1)
        return series[index].total
    }
}

extension Month {
    public var firstDay: Day { Day(year: year, month: month, day: 1) }
    public var lastDay: Day { adding(1).firstDay.adding(-1) }
}

extension Day {
    public func adding(_ days: Int) -> Day { Day(ordinal: ordinal + days) }
}
