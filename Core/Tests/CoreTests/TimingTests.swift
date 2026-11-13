import Core
import Foundation
import Testing

/// Watches performance from M1 on. The budget is loose now (debug build,
/// shared CI runners); M6 tightens it.
@Suite struct TimingTests {
    @Test func tenYearsOfDailySnapshotsBuildsTheSeriesQuickly() {
        let end = Day(year: 2026, month: 10, day: 20)
        let snapshots = SyntheticData.dailySnapshots(accounts: 25, years: 10, endingOn: end)
        #expect(snapshots.count > 90_000)

        let clock = ContinuousClock()
        var series: [DailyTotal] = []
        let elapsed = clock.measure {
            series = NetWorthSeries.daily(snapshots: snapshots, through: end)
        }

        print("[timing] daily series over \(snapshots.count) snapshots: \(elapsed)")
        #expect(series.count >= 3_650)
        #expect(elapsed < .seconds(1), "Net worth series took \(elapsed)")
    }

    @Test func tenYearsOfDailySnapshotsBuildsTheBreakdownQuickly() {
        let end = Day(year: 2026, month: 10, day: 20)
        let snapshots = SyntheticData.dailySnapshots(accounts: 25, years: 10, endingOn: end)
        var seen = Set<UUID>()
        let classes = AccountClass.allCases
        let accounts = snapshots.compactMap { snapshot -> Account? in
            guard seen.insert(snapshot.accountID).inserted else { return nil }
            return Account(
                id: snapshot.accountID, name: "Account \(seen.count)",
                accountClass: classes[seen.count % classes.count], source: snapshot.source)
        }

        let clock = ContinuousClock()
        var breakdown: [DailyBreakdown] = []
        let elapsed = clock.measure {
            breakdown = NetWorthSeries.breakdown(accounts: accounts, snapshots: snapshots, through: end)
        }

        print("[timing] breakdown over \(snapshots.count) snapshots: \(elapsed)")
        #expect(breakdown.count >= 3_650)
        #expect(elapsed < .seconds(1), "Breakdown took \(elapsed)")
    }

    /// Find transfers runs once over their whole history: 30,000 transactions
    /// over ten years, many sharing an amount, a fifth of them uncategorized.
    @Test func findingTransfersAcrossTenYearsIsQuick() {
        let accounts = (0..<4).map { _ in UUID() }
        var state: UInt64 = 11
        func next() -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int(state >> 33) }
        let end = Day(year: 2026, month: 10, day: 20)
        let transactions = (0..<30_000).map { index in
            Transaction(
                accountID: accounts[next() % 4], day: Day(ordinal: end.ordinal - next() % 3653),
                amount: Decimal(next() % 400 + 1) * (next() % 2 == 0 ? 5 : -5),
                merchant: "M", category: index % 5 == 0 ? nil : "Transfer", externalID: "t\(index)")
        }

        let clock = ContinuousClock()
        var filed = Set<UUID>()
        let elapsed = clock.measure { filed = TransferMatch.toFile(in: transactions, kinds: [:]) }

        print("[timing] transfers over \(transactions.count) transactions: \(elapsed)")
        #expect(!filed.isEmpty)
        #expect(elapsed < .seconds(1), "Finding transfers took \(elapsed)")
    }

    /// Opening Spending works out the budget sheet, the pace, the transfers
    /// still to find and the month's days from the two months it reads: at
    /// the perf seed's density (30,000 over ten years) that's about 500
    /// transactions, here with a fifth uncategorized across four accounts.
    @Test func openingSpendingWorksOutTheMonthQuickly() {
        let accounts = (0..<4).map { _ in UUID() }
        let categories = [
            "Groceries", "Restaurants & Bars", "Coffee Shops", "Shopping", "Travel", "Gas", "Utilities",
            "Entertainment", "Health", "Home", "Gifts", "Subscriptions", "Paychecks", "Transfer"
        ]
        let today = Day(year: 2026, month: 10, day: 20)
        let month = Month(today)
        let first = Day(year: 2026, month: 9, day: 1).ordinal
        let transactions = (0..<500).map { index in
            let category = index % 5 == 0 ? nil : categories[index % categories.count]
            let cents = 500 + (index * 7919) % 20_000
            return Transaction(
                accountID: accounts[index % 4], day: Day(ordinal: first + index * 50 / 500),
                amount: Decimal(category == "Paychecks" || index % 10 == 5 ? cents * 20 : -cents) / 100,
                merchant: "Merchant \(index % 400)", category: category, externalID: "t\(index)")
        }
        let kinds: [String: CategoryKind] = ["Paychecks": .income, "Transfer": .transfer]
        let plan = BudgetPlan(
            flexibleBudget: 1_800, expected: ["Utilities": 120, "Subscriptions": 24],
            plannedIncome: ["Paychecks": 5_200])

        let clock = ContinuousClock()
        var days: [TransactionDay] = []
        let elapsed = clock.measure {
            _ = TransferMatch.toFile(in: transactions, kinds: kinds)
            _ = FlexBudget.sheet(month, transactions: transactions, kinds: kinds, plan: plan)
            _ = FlexBudget.month(month, today: today, transactions: transactions, kinds: kinds, plan: plan)
            days = TransactionSearch.byDay(transactions.filter { Month($0.day) == month })
        }

        print("[timing] opening Spending over \(transactions.count) transactions: \(elapsed)")
        #expect(!days.isEmpty)
        #expect(elapsed < .milliseconds(100), "Working out Spending took \(elapsed)")
    }

    /// Transactions builds its search index in the background once, then
    /// searches it on each keystroke: 30,000 transactions, 400 merchants.
    @Test func searchingTenYearsOfTransactionsIsQuick() {
        let end = Day(year: 2026, month: 10, day: 20)
        let transactions = (0..<30_000).map { index in
            Transaction(
                accountID: UUID(), day: Day(ordinal: end.ordinal - index * 3653 / 30_000), amount: -12,
                merchant: "Merchant \(index % 400)", statement: "POS PURCHASE MERCHANT \(index % 400) #\(index)",
                category: index % 7 == 0 ? nil : "Groceries", externalID: "t\(index)")
        }

        let clock = ContinuousClock()
        var index = TransactionIndex([])
        let built = clock.measure { index = TransactionIndex(transactions) }
        var found: [Transaction] = []
        let searched = clock.measure {
            found = index.filter(TransactionQuery(text: "merchant 12", category: .named("Groceries")))
        }

        print("[timing] index over \(transactions.count) transactions: \(built); one search: \(searched)")
        #expect(!found.isEmpty)
        #expect(index.months.count >= 120)
        #expect(built < .seconds(2), "Building the index took \(built)")
        #expect(searched < .milliseconds(250), "Searching took \(searched)")
    }
}
