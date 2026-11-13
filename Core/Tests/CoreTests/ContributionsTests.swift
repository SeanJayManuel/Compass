import Core
import Foundation
import Testing

@Suite struct ContributionsTests {
    let checking = Account(name: "Checking", accountClass: .cash, source: .simplefin)
    let brokerage = Account(name: "Brokerage", accountClass: .taxable, source: .simplefin)
    let october = Month(year: 2026, month: 10)
    let today = Day(year: 2026, month: 11, day: 15)

    func day(_ month: Int, _ day: Int) -> Day { Day(year: 2026, month: month, day: day) }

    func balance(_ account: Account, _ amount: Decimal, _ month: Int, _ day: Int) -> BalanceSnapshot {
        BalanceSnapshot(accountID: account.id, day: self.day(month, day), source: .simplefin, balance: amount)
    }

    func txn(
        _ account: Account, _ amount: Decimal, _ month: Int, _ day: Int, _ merchant: String,
        category: String? = nil
    ) -> Transaction {
        Transaction(
            accountID: account.id, day: self.day(month, day), amount: amount, merchant: merchant,
            category: category, externalID: "\(merchant)-\(month)-\(day)-\(amount)")
    }

    /// Balances on Sep 30, mid-October and Oct 31.
    var balances: [BalanceSnapshot] {
        [balance(brokerage, 10_000, 9, 30), balance(brokerage, 10_400, 10, 15), balance(brokerage, 11_200, 10, 31)]
    }

    func october(
        _ transactions: [Transaction], snapshots: [BalanceSnapshot]? = nil,
        accounts: [Account]? = nil, today: Day? = nil
    ) -> ContributionMonth? {
        Contributions.report(
            accounts: accounts ?? [checking, brokerage], snapshots: snapshots ?? balances,
            transactions: transactions, kinds: [:], today: today ?? self.today,
            months: october...october
        )
        .first { $0.accountID == brokerage.id }?.months.first
    }

    @Test func aMatchedDepositIsAContributionAndTheRestIsTheMarket() throws {
        // A September trade shows the account's transactions reach back before October.
        let month = try #require(
            october([
                txn(brokerage, -50, 9, 2, "YOU BOUGHT VTI"),
                txn(checking, -500, 10, 5, "ONLINE PAYMENT"), txn(brokerage, 500, 10, 6, "ELECTRONIC FUNDS RECEIVED")
            ]))
        #expect(month.startingBalance == 10_000)
        #expect(month.endingBalance == 11_200)
        #expect(month.balanceChange == 1_200)
        #expect(month.moneyIn == 500)
        #expect(month.moneyOut == 0)
        #expect(month.netContributions == 500)
        #expect(month.marketChange == 700)
        #expect(month.isMonthToDate == false)
    }

    /// A trade in September, so the account's transactions reach back past October.
    var earlier: Transaction { txn(brokerage, -50, 9, 2, "YOU BOUGHT VTI") }

    @Test func tradesAndDividendsInsideTheAccountAreNotContributions() throws {
        let month = try #require(
            october([
                earlier,
                txn(brokerage, -2_000, 10, 7, "YOU BOUGHT VTI"),
                txn(brokerage, 1_500, 10, 9, "SOLD 10 SHARES"),
                txn(brokerage, 42, 10, 12, "DIVIDEND RECEIVED"),
                txn(brokerage, 30, 10, 14, "Cash", category: "Dividends & Capital Gains"),
                txn(brokerage, -800, 10, 16, "Vanguard", category: "Buy"),
                txn(brokerage, -3, 10, 20, "REINVESTMENT VTI"),
                txn(brokerage, -1, 10, 21, "ADVISORY FEE")
            ]))
        #expect(month.moneyIn == 0)
        #expect(month.moneyOut == 0)
        #expect(month.marketChange == 1_200)
    }

    @Test func aTradeIsNeverAContributionEvenWhenItPairsWithAnotherAccount() throws {
        // A $2,000 buy the same week as an unrelated $2,000 deposit to checking.
        let month = try #require(
            october([
                earlier, txn(brokerage, -2_000, 10, 7, "YOU BOUGHT VTI"), txn(checking, 2_000, 10, 8, "DEPOSIT")
            ]))
        #expect(month.moneyOut == 0)
    }

    @Test func moneyReadingLikeAMoveCountsWithoutAPartner() throws {
        // Payroll into a 401(k) or a deposit from an account Compass can't see.
        let month = try #require(
            october([
                earlier,
                txn(brokerage, 600, 10, 3, "Cash Fund Transfer", category: "Transfer"),
                txn(brokerage, 250, 10, 10, "EMPLOYEE CONTRIBUTION"),
                txn(brokerage, 100, 10, 17, "ACH DEPOSIT"),
                txn(brokerage, -300, 10, 24, "WITHDRAWAL TO BANK")
            ]))
        #expect(month.moneyIn == 950)
        #expect(month.moneyOut == 300)
        #expect(month.marketChange == 550)
    }

    @Test func incomeCategoriesAreNeverContributions() throws {
        let month = try #require(october([earlier, txn(brokerage, 75, 10, 3, "Cash", category: "Interest")]))
        #expect(month.moneyIn == 0)
    }

    @Test func unclearMoneyMakesTheMonthUnknown() throws {
        // No partner and no telling wording, filed or not: maybe a deposit,
        // maybe a trade (a 401(k)'s fund purchases filed as transfers).
        for category in [nil, "Transfer"] {
            let month = try #require(
                october([
                    earlier, txn(brokerage, 600, 10, 2, "ACH DEPOSIT"),
                    txn(brokerage, -400, 10, 3, "Russell 1000 Index", category: category)
                ]))
            #expect(month.moneyIn == nil)
            #expect(month.marketChange == nil)
            #expect(month.unclear == 1)
        }
    }

    @Test func aMoneyMarketSweepStaysInsideTheAccount() throws {
        let month = try #require(
            october([
                earlier, txn(brokerage, -900, 10, 3, "Cash Money Market", category: "Transfer"),
                txn(brokerage, -500, 10, 4, "TRANSFER TO CORE POSITION")
            ]))
        #expect(month.moneyOut == 0)
        #expect(month.unclear == 0)
    }

    @Test func aTransferCountsOnce() throws {
        // Paired with checking and worded like a transfer: still $500, not $1,000.
        let month = try #require(
            october([
                earlier, txn(checking, -500, 10, 5, "TRANSFER TO BROKERAGE"),
                txn(brokerage, 500, 10, 6, "TRANSFER FROM CHECKING", category: "Transfer")
            ]))
        #expect(month.moneyIn == 500)
    }

    @Test func withoutTransactionsOfItsOwnContributionsAreUnknownNotGrowth() throws {
        // Checking shows money going out, but the brokerage reports nothing.
        let month = try #require(october([txn(checking, -500, 10, 5, "VANGUARD BUY")]))
        #expect(month.balanceChange == 1_200)
        #expect(month.moneyIn == nil)
        #expect(month.netContributions == nil)
        #expect(month.marketChange == nil)
    }

    @Test func monthsBeforeTheAccountsFirstTransactionAreUnknown() throws {
        // Transactions only reach back to Oct 10 (SimpleFIN's 90 days): the
        // start of October isn't covered, so October can't be told.
        let month = try #require(october([txn(brokerage, 500, 10, 10, "ACH DEPOSIT")]))
        #expect(month.moneyIn == nil)
        // November is covered from its first day.
        let november = Contributions.report(
            accounts: [brokerage], snapshots: balances + [balance(brokerage, 11_300, 11, 14)],
            transactions: [txn(brokerage, 500, 10, 10, "ACH DEPOSIT")], kinds: [:], today: today,
            months: Month(year: 2026, month: 11)...Month(year: 2026, month: 11))[0].months[0]
        #expect(november.moneyIn == 0)
        #expect(november.marketChange == 100)
    }

    @Test func anAccountOpenedThisMonthIsCoveredFromItsFirstBalance() throws {
        let month = try #require(
            october(
                [txn(brokerage, 1_000, 10, 2, "INITIAL DEPOSIT")],
                snapshots: [balance(brokerage, 1_000, 10, 2), balance(brokerage, 1_040, 10, 31)]))
        // No balance before October: the change can't be told, but what went in can.
        #expect(month.startingBalance == nil)
        #expect(month.moneyIn == 1_000)
        #expect(month.marketChange == nil)
    }

    @Test func aMonthWithNoBalanceOfItsOwnHasNoMarketChange() throws {
        // Only Sep 30 and Nov 14: October's ending balance is carried, not known.
        let month = try #require(october([earlier], snapshots: [balance(brokerage, 10_000, 9, 30), balance(brokerage, 12_000, 11, 14)]))
        #expect(month.hasBalanceGap)
        #expect(month.marketChange == nil)
    }

    @Test func theCurrentMonthRunsToToday() throws {
        let month = try #require(october([earlier], today: day(10, 15)))
        #expect(month.isMonthToDate)
        #expect(month.endingBalance == 10_400)
        #expect(month.marketChange == 400)
    }

    @Test func anArchivedAccountStopsAtTheMonthItWasArchived() {
        var closed = brokerage
        closed.archivedOn = day(10, 20)
        let report = Contributions.report(
            accounts: [closed], snapshots: balances, transactions: [earlier], kinds: [:],
            today: today, months: october...Month(year: 2026, month: 11))
        #expect(report[0].months.map(\.month) == [october])
    }

    @Test func onlyInvestingAccountsCountedInNetWorthAreReported() {
        var excluded = Account(name: "Old IRA", accountClass: .retirement, source: .manual)
        excluded.excludedFromNetWorth = true
        let espp = Account(name: "ESPP", accountClass: .equity, source: .simplefin)
        let report = Contributions.report(
            accounts: [checking, brokerage, excluded, espp],
            snapshots: balances + [balance(checking, 5, 10, 1), balance(excluded, 5, 10, 1), balance(espp, 5, 10, 1)],
            transactions: [], kinds: [:], today: today, months: october...october)
        #expect(Set(report.map(\.accountID)) == [brokerage.id, espp.id])
    }

    @Test func aRetirementAccountWithoutDepositsCountsWhatItBuysAsHisMoney() throws {
        // A 401(k) whose payroll money only shows up as fund purchases filed as transfers.
        let plan = Account(name: "401k", accountClass: .retirement, source: .simplefin)
        let month = try #require(
            Contributions.report(
                accounts: [plan],
                snapshots: [balance(plan, 20_000, 9, 30), balance(plan, 21_500, 10, 31)],
                transactions: [
                    txn(plan, -600, 9, 15, "VANGUARD TARGET 2060", category: "Transfer"),
                    txn(plan, -600, 10, 3, "VANGUARD TARGET 2060", category: "Transfer"),
                    txn(plan, -600, 10, 17, "VANGUARD TARGET 2060", category: "Transfer"),
                    // A rebalance moves money between funds: nothing new.
                    txn(plan, 1_000, 10, 20, "FIDELITY 500 INDEX", category: "Transfer"),
                    txn(plan, -1_000, 10, 20, "RUSSELL 2000 INDEX", category: "Transfer"),
                    txn(plan, -12, 10, 25, "REINVESTMENT VTI")
                ],
                kinds: [:], today: today, months: october...october
            ).first?.months.first)
        #expect(month.moneyIn == 1_200)
        #expect(month.moneyOut == 0)
        #expect(month.marketChange == 300)
    }

    @Test func aBuyWordedWithItsExDividendDateIsStillATrade() throws {
        // Fidelity words some buys "YOU BOUGHT EX-DIV DATE …": a sale and that buy are a rebalance.
        let plan = Account(name: "401k", accountClass: .retirement, source: .simplefin)
        let month = try #require(
            Contributions.report(
                accounts: [plan],
                snapshots: [balance(plan, 15_000, 9, 30), balance(plan, 15_100, 10, 31)],
                transactions: [
                    txn(plan, -600, 9, 15, "VANGUARD TARGET 2060", category: "Transfer"),
                    txn(plan, 1_000, 10, 23, "YOU SOLD ENERGY FUELS INC COM NEW (UUUU) (Cash)", category: "Transfer"),
                    txn(
                        plan, -1_000, 10, 23, "YOU BOUGHT EX-DIV DATE 10/28/26RECORD DATE 10/28/26PAYABLE DTE 10/30/26 VANGUARD INDEX FUNDS (VTI) (Cash)",
                        category: "Transfer")
                ],
                kinds: [:], today: today, months: october...october
            ).first?.months.first)
        #expect(month.moneyIn == 0)
        #expect(month.moneyOut == 0)
    }

    @Test func anEmployerMatchLineDoesntStopAPlanReadingItsPurchases() throws {
        // Payroll-worded money in is the plan's own deposit, not one they make from their accounts.
        let plan = Account(name: "401k", accountClass: .retirement, source: .simplefin)
        let month = try #require(
            Contributions.report(
                accounts: [plan],
                snapshots: [balance(plan, 20_000, 9, 30), balance(plan, 21_000, 10, 31)],
                transactions: [
                    txn(plan, 250, 9, 15, "EMPLOYER MATCH"),
                    txn(plan, -600, 10, 3, "BLACKROCK RUSSELL 2000 INDX", category: "Transfer")
                ],
                kinds: [:], today: today, months: october...october
            ).first?.months.first)
        #expect(month.moneyIn == 600)
    }

    @Test func anIRAHeFundsWithDepositsNeverReadsItsTradesAsHisMoney() throws {
        // A Roth IRA they pay into themselves: a buy from cash already inside isn't new money.
        let ira = Account(name: "Roth IRA", accountClass: .retirement, source: .simplefin)
        let month = try #require(
            Contributions.report(
                accounts: [ira],
                snapshots: [balance(ira, 15_000, 9, 30), balance(ira, 15_100, 10, 31)],
                transactions: [
                    txn(ira, 5_000, 9, 12, "CASH CONTRIBUTION CURRENT YEAR (Cash)", category: "Transfer"),
                    txn(ira, 300, 10, 22, "REDEMPTION FROM CORE ACCOUNT FIDELITY GOVERNMENT MONEY MARKET (SPAXX)", category: "Transfer"),
                    txn(ira, -300, 10, 23, "YOU BOUGHT VANGUARD INDEX FUNDS (VTI) (Cash)", category: "Transfer")
                ],
                kinds: [:], today: today, months: october...october
            ).first?.months.first)
        #expect(month.moneyIn == 0)
        #expect(month.moneyOut == 0)
        #expect(month.marketChange == 100)
    }
}

/// An invested goal's pace is what they put in, not what the balances did
/// (Oct 30, 2026), so linking an account or a market swing can't move it.
@Suite struct ContributionPaceTests {
    let brokerage = Account(name: "Brokerage", accountClass: .taxable, source: .simplefin)
    let espp = Account(name: "ESPP", accountClass: .taxable, source: .simplefin)

    func month(_ account: Account, _ month: Int, net: Decimal?, market: Decimal?) -> ContributionMonth {
        ContributionMonth(
            accountID: account.id, month: Month(year: 2026, month: month), isMonthToDate: month == 10,
            startingBalance: 1_000, endingBalance: 1_000 + (net ?? 0) + (market ?? 0),
            moneyIn: net, moneyOut: net.map { _ in 0 })
    }

    @Test func theLastThreeFullMonthsOfContributionsOverAccountsThatCanBeTold() {
        let report = [
            AccountContributions(
                accountID: brokerage.id,
                months: [
                    month(brokerage, 6, net: 5_000, market: 0), month(brokerage, 7, net: 1_000, market: -100),
                    month(brokerage, 8, net: 1_000, market: 400), month(brokerage, 9, net: 500, market: 300),
                    month(brokerage, 10, net: 500, market: 50)
                ]),
            AccountContributions(accountID: espp.id, months: [month(espp, 9, net: nil, market: nil)])
        ]
        let pace = Contributions.pace(report, before: Month(year: 2026, month: 10))
        #expect(pace.perMonth == Decimal(2_500) / 3)
        #expect(pace.marketPerMonth == Decimal(600) / 3)
        #expect(pace.months == Month(year: 2026, month: 7)...Month(year: 2026, month: 9))
        #expect(pace.untold == [espp.id])
    }

    @Test func theMarketCountsTheMonthsItCanBeTold() {
        // An account linked in August: its contributions are known, its first month's market isn't.
        let plan = Account(name: "401(k)", accountClass: .retirement, source: .simplefin)
        var linked = month(plan, 8, net: 500, market: nil)
        linked.startingBalance = nil
        let report = [AccountContributions(accountID: plan.id, months: [linked, month(plan, 9, net: 500, market: -90)])]
        let pace = Contributions.pace(report, before: Month(year: 2026, month: 10))
        #expect(pace.perMonth == Decimal(1_000) / 3)
        #expect(pace.marketPerMonth == -30)
    }

    @Test func anInvestedGoalUsesItsContributionPace() {
        let goal = Goal(name: "$100K Invested", kind: .accountTotal([brokerage.id]), target: 100_000)
        let today = Day(year: 2026, month: 10, day: 30)
        // Balances jumped $30,000 when an account was linked; they put in $1,000 a month.
        let measured = [
            DailyTotal(day: Day(year: 2026, month: 7, day: 30), total: 30_000),
            DailyTotal(day: today, total: 70_000)
        ]
        let progress = GoalProgress.evaluate(goal, measured: measured, today: today, contributionPace: 1_000)
        #expect(progress.pacePerMonth == 1_000)
        #expect(progress.paceFromContributions)
        #expect(progress.projectedDate == Day(year: 2029, month: 4, day: 30))
    }
}
