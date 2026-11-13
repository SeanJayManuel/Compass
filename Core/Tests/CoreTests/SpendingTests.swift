import Core
import Foundation
import Testing

@Suite struct SpendingTests {
    let account = UUID()
    func txn(_ category: String?, _ amount: Decimal, _ year: Int, _ month: Int, day: Int = 5) -> Transaction {
        Transaction(
            accountID: account, day: Day(year: year, month: month, day: day), amount: amount,
            merchant: "M", category: category, externalID: UUID().uuidString)
    }

    @Test func categoryKindsDefaultFromTheirNames() {
        #expect(CategoryKind.guess("Paychecks") == .income)
        #expect(CategoryKind.guess("Rental Income") == .income)
        // A name typed for pay, singular or not, is income.
        #expect(CategoryKind.guess("Paycheck") == .income)
        #expect(CategoryKind.guess("Salary") == .income)
        #expect(CategoryKind.guess("Costco Payroll") == .income)
        #expect(CategoryKind.guess("Wages") == .income)
        #expect(CategoryKind.guess("Credit Card Payment") == .transfer)
        #expect(CategoryKind.guess("Transfer") == .transfer)
        #expect(CategoryKind.guess("Car Payment") == .spending)
        #expect(CategoryKind.guess("Restaurants & Bars") == .spending)
    }

    @Test func investingAndSavingNamesAreGuessedAsTransfers() {
        for name in [
            "Buy", "Sell", "Stock Purchase", "Stocks", "Shares", "Brokerage", "Investments", "Invest",
            "Crypto", "Trade", "Securities", "Savings Transfer", "Transfer to Savings"
        ] {
            #expect(CategoryKind.guess(name) == .transfer, "\(name)")
        }
    }

    @Test func spendingNamesThatShareLettersWithInvestingStaySpending() {
        for name in [
            "Shopping", "Taxi & Ride Shares", "Rideshare", "Trader Joe's", "Groceries", "Restaurants & Bars",
            "Financial & Legal Services", "Entertainment & Recreation", "Electronics", "Miscellaneous", "Software"
        ] {
            #expect(CategoryKind.guess(name) == .spending, "\(name)")
        }
        // Income still wins when the name says so.
        #expect(CategoryKind.guess("Investment Income") == .income)
        #expect(CategoryKind.guess("Dividends & Capital Gains") == .income)
    }

    @Test func feesAndSharedRidesAreSpendingWhateverElseTheNameSays() {
        // Fees paid to a broker or a bank are money spent, not moved.
        for name in [
            "Investment Fees", "Brokerage Fees", "Bank Fee", "Balance Transfer Fee", "Wire Transfer Fees",
            "Car Share", "Bike Share", "Scooter Shares", "Trades & Contractors", "Stock Photos"
        ] {
            #expect(CategoryKind.guess(name) == .spending, "\(name)")
        }
    }

    @Test func savingAndRetirementNamesAreGuessedAsTransfers() {
        for name in [
            "Savings", "Saving", "Emergency Fund", "Retirement", "401k Contribution", "403b", "Roth IRA", "IRA",
            "RRSP", "TFSA", "Index Funds"
        ] {
            #expect(CategoryKind.guess(name) == .transfer, "\(name)")
        }
    }

    @Test func thisMonthAgainstTheSixFullMonthsBefore() {
        var transactions = [txn("Restaurants", -120, 2026, 10), txn("Restaurants", -30, 2026, 10, day: 9)]
        // Apr to Sep: 100, 200, 0, 300, 100, 200 → average 150. March is outside the window.
        for (month, amount) in [(4, -100), (5, -200), (7, -300), (8, -100), (9, -200), (3, -999)] {
            transactions.append(txn("Restaurants", Decimal(amount), 2026, month))
        }
        let report = Spending.month(Month(year: 2026, month: 10), transactions: transactions, kinds: [:])
        #expect(report == [CategorySpend(category: "Restaurants", thisMonth: 150, sixMonthAverage: 150)])
    }

    @Test func refundsReduceSpendingAndIncomeAndTransfersAreLeftOut() {
        let report = Spending.month(
            Month(year: 2026, month: 10),
            transactions: [
                txn("Shopping", -80, 2026, 10), txn("Shopping", 30, 2026, 10),
                txn("Paychecks", 5000, 2026, 10), txn("Credit Card Payment", -900, 2026, 10),
                txn("Groceries", -60, 2026, 10)
            ], kinds: ["Paychecks": .income, "Credit Card Payment": .transfer])
        #expect(report.map(\.category) == ["Groceries", "Shopping"])
        #expect(report.map(\.thisMonth) == [60, 50])
    }

    @Test func aCategoryWithNoSpendingThisMonthStillShowsIfItHasAnAverage() {
        let report = Spending.month(Month(year: 2026, month: 10), transactions: [txn("Travel", -600, 2026, 9)], kinds: [:])
        #expect(report == [CategorySpend(category: "Travel", thisMonth: 0, sixMonthAverage: 100)])
    }

    @Test func uncategorizedSpendingIsItsOwnLine() {
        let report = Spending.month(Month(year: 2026, month: 10), transactions: [txn(nil, -25, 2026, 10)], kinds: [:])
        #expect(report.map(\.category) == ["Uncategorized"])
    }

    @Test func theTrendCoversTwelveMonthsOldestFirstWithEmptyMonthsAsZero() {
        let trend = Spending.trend(
            "Restaurants", endingIn: Month(year: 2026, month: 10),
            transactions: [txn("Restaurants", -40, 2026, 10), txn("Restaurants", -10, 2025, 11)],
            kinds: [:])
        #expect(trend.count == 12)
        #expect(trend.first == MonthTotal(month: Month(year: 2025, month: 11), total: 10))
        #expect(trend.last == MonthTotal(month: Month(year: 2026, month: 10), total: 40))
        #expect(trend.dropFirst().dropLast().allSatisfy { $0.total == 0 })
    }

    @Test func wellAboveAverageMeansMoreThanTwentyPercentOver() {
        #expect(CategorySpend(category: "A", thisMonth: 121, sixMonthAverage: 100).isWellAboveAverage)
        #expect(!CategorySpend(category: "A", thisMonth: 120, sixMonthAverage: 100).isWellAboveAverage)
        #expect(!CategorySpend(category: "A", thisMonth: 50, sixMonthAverage: 0).isWellAboveAverage)
    }

    @Test func monthlyByCategoryIsAGridOfTwelveMonthsPerCategoryBiggestFirst() {
        let grid = Spending.monthlyByCategory(
            endingIn: Month(year: 2026, month: 10),
            transactions: [
                txn("Restaurants", -40, 2026, 10, day: 31),
                txn("Restaurants", -10, 2026, 9, day: 30),
                txn("Groceries", -200, 2026, 10, day: 1),
                txn("Paychecks", 5000, 2026, 10),
                txn("Groceries", -999, 2025, 10)  // outside the 12 months
            ], kinds: [:])
        #expect(grid.map(\.category) == ["Groceries", "Restaurants"])
        #expect(grid.allSatisfy { $0.months.count == 12 })
        #expect(grid[0].months.first?.month == Month(year: 2025, month: 11))
        #expect(grid[1].months.suffix(2).map(\.total) == [10, 40])
        #expect(grid[0].months.map(\.total).reduce(0, +) == 200)
    }
}
