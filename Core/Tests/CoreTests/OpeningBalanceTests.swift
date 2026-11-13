import Core
import Foundation
import Testing

/// Linking an account brings in money that was already theirs: its first
/// balance is an opening balance, not a change.
@Suite struct OpeningBalanceTests {
    let checking = Account(name: "Checking", accountClass: .cash, source: .simplefin)
    let plan = Account(name: "401(k)", accountClass: .retirement, source: .simplefin)
    let brokerage = Account(name: "Brokerage", accountClass: .taxable, source: .simplefin)
    let today = Day(year: 2026, month: 10, day: 30)

    func day(_ month: Int, _ day: Int) -> Day { Day(year: 2026, month: month, day: day) }

    func balance(_ account: Account, _ amount: Decimal, _ month: Int, _ day: Int) -> BalanceSnapshot {
        BalanceSnapshot(accountID: account.id, day: self.day(month, day), source: .simplefin, balance: amount)
    }

    func txn(_ account: Account, _ amount: Decimal, _ month: Int, _ day: Int, _ merchant: String) -> Transaction {
        Transaction(
            accountID: account.id, day: self.day(month, day), amount: amount, merchant: merchant,
            category: "Transfer", externalID: "\(merchant)-\(month)-\(day)-\(amount)")
    }

    /// Checking grows $200 a month; the 401(k) is linked on Aug 27 with $29,000 in it.
    var linked: [BalanceSnapshot] {
        [
            balance(checking, 1_000, 6, 30), balance(checking, 1_200, 7, 31), balance(checking, 1_400, 8, 31),
            balance(plan, 29_000, 8, 27), balance(checking, 1_600, 9, 30), balance(plan, 29_300, 9, 30)
        ]
    }

    func netWorth(_ snapshots: [BalanceSnapshot], accounts: [Account]? = nil, moves: [NetWorthSeries.Move] = []) -> [DailyTotal] {
        NetWorthSeries.breakdown(accounts: accounts ?? [checking, plan], snapshots: snapshots, through: today, moves: moves)
            .map(\.netWorth)
    }

    @Test func aLinkedAccountsFirstBalanceIsNotAMonthsChange() {
        let series = netWorth(linked)
        let changes = NetWorthSeries.monthlyChange(series)
        #expect(changes.map(\.total) == [0, 200, 200, 500, 0])
        #expect(series.first { $0.day == day(8, 31) }?.total == 30_400)
        #expect(series.last?.total == 30_900)
    }

    @Test func aChangeSinceADayLeavesOutAccountsLinkedSince() {
        #expect(NetWorthSeries.change(in: netWorth(linked), since: day(7, 31)) == 700)
    }

    @Test func moneyMovedInFromAnotherOfHisAccountsIsNotAnOpening() {
        // They open a brokerage with $3,000 from checking: net worth didn't move.
        let snapshots = [balance(checking, 5_000, 10, 1), balance(checking, 2_000, 10, 10), balance(brokerage, 3_000, 10, 10)]
        let moves = NetWorthSeries.moves(
            in: [
                txn(checking, -3_000, 10, 10, "TRANSFER TO BROKERAGE"),
                txn(brokerage, 3_000, 10, 10, "ELECTRONIC FUNDS RECEIVED")
            ], kinds: [:])
        let series = netWorth(snapshots, accounts: [checking, brokerage], moves: moves)
        #expect(NetWorthSeries.change(in: series, since: day(10, 1)) == 0)
        // Without the move, the new account's $3,000 would be an opening and checking's drop a loss.
        #expect(NetWorthSeries.change(in: netWorth(snapshots, accounts: [checking, brokerage]), since: day(10, 1)) == -3_000)
    }

    @Test func aGoalsPaceLeavesOutAnAccountLinkedInItsWindow() {
        let goal = Goal(name: "$100K", kind: .netWorth, target: 100_000)
        let progress = GoalProgress.evaluate(goal, accounts: [checking, plan], snapshots: linked, today: day(9, 30))
        // $200 a month from checking, plus the 401(k)'s $300 since it was linked, over three months.
        #expect(progress.current == 30_900)
        #expect(progress.pacePerMonth == Decimal(900) / 3)
    }

    @Test func theMonthlyReviewLeavesOpeningsOutOfTheChangeAndNamesThem() {
        let accounts = [checking, plan]
        let breakdown = NetWorthSeries.breakdown(accounts: accounts, snapshots: linked, through: today)
        let review = MonthlyReview.make(
            month: Month(year: 2026, month: 8), today: today, accounts: accounts, snapshots: linked,
            breakdown: breakdown, transactions: [], kinds: [:], plan: BudgetPlan(flexibleBudget: 0), goals: [])
        #expect(review.netWorthStart == 1_200)
        #expect(review.netWorthEnd == 30_400)
        #expect(review.openingBalances == 29_000)
        #expect(review.netWorthChange == 200)
    }
}
