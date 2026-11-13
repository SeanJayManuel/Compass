import Core
import Foundation
import Testing

@Suite struct MonthlyReviewTests {
    let checking = Account(name: "Checking", accountClass: .cash, source: .simplefin)
    let brokerage = Account(name: "Brokerage", accountClass: .taxable, source: .simplefin)
    let ira = Account(name: "IRA", accountClass: .retirement, source: .manual)
    let october = Month(year: 2026, month: 10)

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

    var accounts: [Account] { [checking, brokerage, ira] }

    /// Checking 5,000 → 3,600 (paid 2,000 of pay in, 500 to the brokerage,
    /// 2,900 spent); the brokerage 10,000 → 11,200; the IRA 20,000 → 20,300
    /// with no transactions of its own.
    var snapshots: [BalanceSnapshot] {
        [
            balance(checking, 5_000, 9, 30), balance(checking, 3_600, 10, 31),
            balance(brokerage, 10_000, 9, 30), balance(brokerage, 11_200, 10, 31),
            balance(ira, 20_000, 9, 30), balance(ira, 20_300, 10, 31)
        ]
    }

    var transactions: [Transaction] {
        var all = [
            txn(brokerage, -50, 9, 2, "YOU BOUGHT VTI", category: "Buy"),
            txn(checking, 2_000, 10, 1, "ACME PAYROLL", category: "Paychecks"),
            txn(checking, -500, 10, 5, "TRANSFER", category: "Transfer"),
            txn(brokerage, 500, 10, 6, "TRANSFER", category: "Transfer"),
            txn(checking, -1_800, 10, 1, "Landlord", category: "Rent"),
            txn(checking, -900, 10, 12, "Grocer", category: "Groceries"),
            txn(checking, -200, 10, 20, "Bistro", category: "Restaurants")
        ]
        // Six usual months before: groceries 600, restaurants 200, rent 1,800.
        for month in 4...9 {
            all += [
                txn(checking, -600, month, 10, "Grocer", category: "Groceries"),
                txn(checking, -200, month, 11, "Bistro", category: "Restaurants"),
                txn(checking, -1_800, month, 1, "Landlord", category: "Rent")
            ]
        }
        return all
    }

    let plan = BudgetPlan(
        flexibleBudget: 1_000, roles: ["Rent": .fixed], expected: ["Rent": 1_800],
        plannedIncome: ["Paychecks": 2_000])

    func review(
        _ month: Month? = nil, today: Day? = nil, goals: [Goal] = [],
        snapshots: [BalanceSnapshot]? = nil, transactions: [Transaction]? = nil
    ) -> MonthlyReview {
        let today = today ?? day(11, 15)
        let snapshots = snapshots ?? self.snapshots
        return MonthlyReview.make(
            month: month ?? october, today: today, accounts: accounts, snapshots: snapshots,
            breakdown: NetWorthSeries.breakdown(accounts: accounts, snapshots: snapshots, through: today),
            transactions: transactions ?? self.transactions, kinds: [:], plan: plan, goals: goals)
    }

    @Test func netWorthChangeSplitsIntoTheMarketAndEverythingElse() {
        let review = review()
        #expect(review.netWorthStart == 35_000)
        #expect(review.netWorthEnd == 35_100)
        #expect(review.netWorthChange == 100)
        // The brokerage's 1,200 rise was 500 of their money and 700 of market.
        #expect(review.contributions == 500)
        #expect(review.marketChange == 700)
        // A move from checking to the brokerage doesn't change net worth: the
        // rest is spending, pay and the IRA, whose split can't be told.
        #expect(review.otherChange == -600)
        #expect(review.untold == [ira.id])
        #expect(review.investing.count == 2)
    }

    @Test func spendingAgainstTheBudgetBillsAndIncome() {
        let review = review()
        #expect(review.flexible.flexibleBudget == 1_000)
        #expect(review.flexible.flexibleSpent == 1_100)
        #expect(review.flexible.fixedPaid == 1_800)
        #expect(review.income == 2_000)
        #expect(review.plannedIncome == 2_000)
    }

    @Test func categoriesFurthestFromUsualComeFirst() {
        let review = review()
        #expect(review.categories.map(\.category) == ["Groceries", "Rent", "Restaurants"])
        #expect(review.categories[0].thisMonth == 900)
        #expect(review.categories[0].usual == 600)
        #expect(review.categories[0].difference == 300)
    }

    @Test func theCurrentMonthIsMonthToDateAndComparedWithAShareOfUsual() {
        // On Oct 10, groceries' usual 600 is 600 × 10/31 so far.
        let review = review(
            today: day(10, 10), snapshots: snapshots.filter { $0.day < day(10, 1) },
            transactions: transactions.filter { $0.day <= day(10, 10) })
        #expect(review.isMonthToDate)
        #expect(review.through == day(10, 10))
        let restaurants = review.categories.first { $0.category == "Restaurants" }
        #expect(restaurants?.thisMonth == 0)
        #expect(restaurants?.usual == Decimal(200) * 10 / 31)
        // A past month is whole.
        #expect(self.review().isMonthToDate == false)
        #expect(self.review().through == day(10, 31))
    }

    @Test func eachGoalsMovementOverTheMonth() {
        let goal = Goal(name: "Investing", kind: .accountTotal([brokerage.id, ira.id]), target: 50_000)
        let netWorth = Goal(name: "Net worth", kind: .netWorth, target: 100_000)
        let review = review(goals: [goal, netWorth])
        let investing = review.goals.first { $0.goalID == goal.id }
        #expect(investing?.start == 30_000)
        #expect(investing?.end == 31_500)
        #expect(investing?.change == 1_500)
        #expect(review.goals.first { $0.goalID == netWorth.id }?.change == 100)
    }

    @Test func aMonthStartingBeforeAnyBalanceHasNoStart() {
        let review = review(Month(year: 2026, month: 9))
        // Balances start on Sep 30, so September has an end but no start.
        #expect(review.netWorthStart == nil)
        #expect(review.netWorthEnd == 35_000)
        #expect(review.netWorthChange == nil)
    }
}
